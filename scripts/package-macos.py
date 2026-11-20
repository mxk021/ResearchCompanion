#!/usr/bin/env python3
"""Package the already-built local companion; does not install or launch it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
# The App ships on its own cadence while the DSH bridge stays at its package version.
release = json.loads((root / 'release.json').read_text())
version = release['version']
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', type=Path, default=root / '.build/arm64-apple-macosx/release/DSHPet')
parser.add_argument('--output', type=Path, required=True, help='Path for a new staging .app bundle')
parser.add_argument('--sign-identity', default='-', help='Existing macOS code-signing certificate fingerprint or name (default: ad-hoc)')
parser.add_argument('--public-bridge', type=Path, help='Build a distribution bundle using only the public manifest, setup guide and this freshly built bridge tarball')
options = parser.parse_args()
binary = options.binary.resolve()
if not binary.is_file():
    raise SystemExit('Build the Swift release executable first.')
app = options.output.resolve()
if app.suffix != '.app' or app.exists():
    raise SystemExit('Choose a new staging .app path. The running application is never overwritten by this script.')

info = dict(CFBundleDisplayName='科研助手', CFBundleExecutable='ResearchCompanion',
            CFBundleIdentifier=release['bundleIdentifier'], CFBundleName='Research Companion',
            CFBundleIconFile='ResearchCompanionPage.icns', CFBundlePackageType='APPL',
            CFBundleShortVersionString=version, CFBundleVersion=release['build'],
            LSMinimumSystemVersion=release['minimumMacOS'], NSHighResolutionCapable=True)


info['NSServices'] = [
    dict(NSMenuItem={'default': label}, NSMessage=selector, NSRequiredContext={},
         NSPortName='Research Companion', NSSendTypes=['public.utf8-plain-text', 'NSStringPboardType'])
    for label, selector in [('选取文字（科研助手）', 'previewResearchSelection'), ('翻译选区', 'translateResearchSelection')]
]


def install_icon(directory, resources):
    points = (16, 32, 128, 256, 512)
    sizes = sorted(set(points) | {p * 2 for p in points})
    cache = str(Path(directory) / 'icon-module-cache')
    subprocess.run([
        '/usr/bin/swift', '-module-cache-path', cache,
        str(root / 'scripts/render-app-icon.swift'), str(directory),
        *(str(pixels) for pixels in sizes),
    ], env={**os.environ, 'CLANG_MODULE_CACHE_PATH': cache}, check=True)
    iconset = Path(directory) / 'ResearchCompanion.iconset'
    iconset.mkdir()
    for p in points:
        for scale, suffix in ((1, ''), (2, '@2x')):
            shutil.copyfile(Path(directory) / f'icon-{p * scale}.png',
                            iconset / f'icon_{p}x{p}{suffix}.png')
    subprocess.run(['/usr/bin/iconutil', '-c', 'icns', '-o',
                    str(resources / info['CFBundleIconFile']), str(iconset)], check=True)


def distribution_resources(target):
    resources = root / 'Resources'
    paths = (resources / 'PublicManifest.txt').read_text().splitlines()
    if not paths or len(set(paths)) != len(paths):
        raise SystemExit('Missing or duplicate public resources')
    for name in paths:
        relative = Path(name)
        if (not name or relative.as_posix() != name or relative.is_absolute() or
                any(part.startswith('.') for part in relative.parts) or
                relative.parts[0] not in ('LicenseNotices', 'Transcript', 'ThirdPartyNotices.txt')):
            raise SystemExit(f'Unexpected public resource: {name}')
        source = resources / relative
        if source.resolve() != source or not source.is_file():
            raise SystemExit(f'Missing public file or unexpected link: {name}')
        (target / relative.parent).mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target / relative)
    bridge = options.public_bridge
    bridge_version = json.loads((root / 'package.json').read_text())['version']
    if bridge.name != f'dsh-research-companion-{bridge_version}.tgz' or not bridge.is_file():
        raise SystemExit('Expected the bridge archive built from this checkout')
    shutil.copyfile(bridge, target / bridge.name)
    shutil.copyfile(root / 'docs/SETUP.md', target / 'SETUP.md')
    shutil.copyfile(root / 'LICENSE', target / 'LICENSE')


app.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='.companion-package-', dir=app.parent) as directory:
    stage = Path(directory) / app.name
    contents = stage / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    shutil.copy2(binary, contents / 'MacOS/ResearchCompanion')
    if options.public_bridge:
        info['ResearchCompanionPublicDistribution'] = True
        distribution_resources(contents / 'Resources')
        subprocess.run(['/usr/bin/strip', '-S', '-x', str(contents / 'MacOS/ResearchCompanion')], check=True)
    else:
        shutil.copytree(root / 'Resources', contents / 'Resources', ignore=shutil.ignore_patterns('.DS_Store'))
    install_icon(directory, contents / 'Resources')
    with (contents / 'Info.plist').open('wb') as file:
        plistlib.dump(info, file)
    signing = ['--options', 'runtime', '--timestamp'] if options.sign_identity != '-' else []
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', options.sign_identity, *signing, str(stage)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(stage)], check=True)
    stage.rename(app)

print(json.dumps({'app': str(app), 'version': version,
                  'executableSha256': hashlib.sha256((app / 'Contents/MacOS/ResearchCompanion').read_bytes()).hexdigest()}))
