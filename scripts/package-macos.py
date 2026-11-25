#!/usr/bin/env python3
"""Package the already-built local companion; does not install or launch it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
from pdfium_bundle import LIBRARY as PDFIUM_LIBRARY, binary_arch, install as install_pdfium
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
# The App ships on its own cadence while the DSH bridge stays at its package version.
release = json.loads((root / 'release.json').read_text())
version = release['version']
if not isinstance(version, str) or re.fullmatch(r'(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}', version) is None:
    raise SystemExit('release.json version must contain three dot-separated integers.')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', type=Path, default=root / '.build/arm64-apple-macosx/release/DSHPet')
parser.add_argument('--output', type=Path, required=True, help='Path for a new staging .app bundle')
parser.add_argument('--sign-identity', default='-', help='Existing macOS code-signing certificate fingerprint or name (default: ad-hoc)')
parser.add_argument('--local-signing-keychain', type=Path, help='Explicit keychain for the local certificate pinned by --sign-identity (40 hex SHA-1 digits)')
parser.add_argument('--previous-app', type=Path, help='Check whether this build satisfies the installed app’s designated requirement')
parser.add_argument('--require-same-identity', action='store_true', help='Fail unless candidate and --previous-app satisfy each other’s designated requirements')
parser.add_argument('--reuse-installed-resources', action='store_true', help='Copy resources and frameworks from the verified --previous-app for a local build')
parser.add_argument('--public-bridge', type=Path, help='Build a distribution bundle using only the public manifest, setup guide and this freshly built bridge tarball')
parser.add_argument('--pdfium-archive', type=Path, help='Use the SHA-256 pinned PDFium archive from disk instead of downloading it')
options = parser.parse_args()
if options.local_signing_keychain:
    if options.public_bridge or not re.fullmatch(r'[0-9a-fA-F]{40}', options.sign_identity):
        parser.error('--local-signing-keychain requires a 40-hex --sign-identity and a local bundle.')
    if not options.local_signing_keychain.is_absolute() or not options.local_signing_keychain.is_file():
        parser.error('--local-signing-keychain must point to an existing keychain at an absolute path.')
if (options.reuse_installed_resources or options.require_same_identity) and not options.previous_app:
    parser.error('--reuse-installed-resources and --require-same-identity require --previous-app.')
if options.reuse_installed_resources and (options.public_bridge or options.pdfium_archive):
    parser.error('--reuse-installed-resources is only for local builds that reuse the installed PDFium.')
binary = options.binary.resolve()
if not binary.is_file():
    raise SystemExit('Build the Swift release executable first.')
app = options.output.resolve()
if app.suffix != '.app' or app.exists():
    raise SystemExit('Choose a new staging .app path. The running application is never overwritten by this script.')

info = dict(CFBundleDisplayName='科研助手', CFBundleExecutable='ResearchCompanion',
            CFBundleIdentifier=release['bundleIdentifier'], CFBundleName='Research Companion',
            CFBundleIconFile='ResearchCompanionWormhole.icns', CFBundlePackageType='APPL',
            CFBundleShortVersionString=version, CFBundleVersion=version,
            LSMinimumSystemVersion=release['minimumMacOS'], NSHighResolutionCapable=True)


info['NSServices'] = [
    dict(NSMenuItem={'default': '选取文字（科研助手）'}, NSMessage='previewResearchSelection', NSRequiredContext={},
         NSPortName='Research Companion', NSSendTypes=['public.utf8-plain-text', 'NSStringPboardType'])
]


def install_icon(directory, resources):
    points = (16, 32, 128, 256, 512)
    sizes = sorted(set(points) | {p * 2 for p in points})
    cache = str(Path(directory) / 'icon-module-cache')
    subprocess.run([
        '/usr/bin/swift', '-module-cache-path', cache,
        str(root / 'scripts/render-app-icon.swift'), str(root / 'Resources/AppIcon.png'), str(directory),
        *(str(pixels) for pixels in sizes),
    ], env={**os.environ, 'CLANG_MODULE_CACHE_PATH': cache}, check=True)
    shutil.copyfile(Path(directory) / 'ResearchCompanionMark.png',
                    resources / 'Transcript' / 'ResearchCompanionMark.png')
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


def designated_requirement(bundle):
    detail = subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(bundle)],
                            capture_output=True, text=True, check=True)
    for line in (detail.stdout + "\n" + detail.stderr).splitlines():
        line = line.removeprefix('# ').strip()
        if line.startswith('designated => '):
            return line.removeprefix('designated => ')
    raise SystemExit(f'No designated requirement reported for {bundle}.')


def satisfies_requirement(bundle, requirement):
    return subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict',
                           f'-R={requirement}', str(bundle)], capture_output=True).returncode == 0


previous = options.previous_app.resolve(strict=True) if options.previous_app else None
if previous:
    if previous.suffix != '.app':
        raise SystemExit('--previous-app must point to an existing installed .app.')
    with (previous / 'Contents' / 'Info.plist').open('rb') as file:
        previous_info = plistlib.load(file)
    if previous_info['CFBundleIdentifier'] != info['CFBundleIdentifier']:
        raise SystemExit('Previous app and candidate have different bundle identifiers.')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(previous)], check=True)
    if options.reuse_installed_resources:
        if previous_info.get('ResearchCompanionPublicDistribution') or previous_info.get('ResearchCompanionBridgeArchive'):
            raise SystemExit('This option only reuses resources from an installed local build.')
        library = previous / 'Contents' / 'Frameworks' / PDFIUM_LIBRARY
        if binary_arch(library) != binary_arch(binary):
            raise SystemExit('The installed PDFium and new executable have different architectures.')


app.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='.companion-package-', dir=app.parent) as directory:
    stage = Path(directory) / app.name
    contents = stage / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    shutil.copy2(binary, contents / 'MacOS/ResearchCompanion')
    if options.public_bridge:
        info['ResearchCompanionPublicDistribution'] = True
        info['ResearchCompanionBridgeArchive'] = options.public_bridge.name
        distribution_resources(contents / 'Resources')
        subprocess.run(['/usr/bin/strip', '-S', '-x', str(contents / 'MacOS/ResearchCompanion')], check=True)
    elif options.reuse_installed_resources:
        for name in ('Resources', 'Frameworks'):
            source = previous / 'Contents' / name
            if not source.is_dir() or source.is_symlink():
                raise SystemExit(f'Unexpected installed app {name} directory.')
            subprocess.run(['/usr/bin/ditto', str(source), str(contents / name)], check=True)
        resources = contents / 'Resources'
        shutil.rmtree(resources / 'Transcript')
        shutil.copytree(root / 'Resources' / 'Transcript', resources / 'Transcript',
                        ignore=shutil.ignore_patterns('.DS_Store'))
        shutil.copyfile(root / 'Resources' / 'PublicManifest.txt', resources / 'PublicManifest.txt')
        shutil.copyfile(root / 'Resources' / 'ThirdPartyNotices.txt', resources / 'ThirdPartyNotices.txt')
        legacy_brand = resources / 'Brand'
        if legacy_brand.exists():
            shutil.rmtree(legacy_brand)
        for name in ('ResearchCompanion.icns', 'ResearchCompanionPage.icns', 'ResearchCompanionContour.icns'):
            (resources / name).unlink(missing_ok=True)
    else:
        shutil.copytree(root / 'Resources', contents / 'Resources',
                        ignore=shutil.ignore_patterns('.DS_Store', 'AppIcon.png'))
    if not options.reuse_installed_resources:
        pdfium_identity = '-' if options.local_signing_keychain else options.sign_identity
        install_pdfium(contents, contents / 'MacOS/ResearchCompanion', options.pdfium_archive, pdfium_identity)
    install_icon(directory, contents / 'Resources')
    with (contents / 'Info.plist').open('wb') as file:
        plistlib.dump(info, file)
    if options.local_signing_keychain:
        fingerprint = options.sign_identity.lower()
        requirement = f'designated => identifier "{info["CFBundleIdentifier"]}" and certificate leaf = H"{fingerprint}"'
        signing = ['--keychain', str(options.local_signing_keychain), '--timestamp=none', f'-r={requirement}']
    else:
        signing = ['--options', 'runtime', '--timestamp'] if options.sign_identity != '-' else []
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', options.sign_identity, *signing, str(stage)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(stage)], check=True)
    matched = {}
    if previous:
        forward = satisfies_requirement(stage, designated_requirement(previous))
        reverse = satisfies_requirement(previous, designated_requirement(stage))
        matched = {'satisfiesPreviousDesignatedRequirement': forward,
                   'mutuallyCompatibleDesignatedRequirements': forward and reverse}
        if options.require_same_identity and not matched['mutuallyCompatibleDesignatedRequirements']:
            raise SystemExit('Candidate and previous app do not satisfy each other’s designated requirements.')
    stage.rename(app)

print(json.dumps({'app': str(app), 'version': version,
                  **matched,
                  'executableSha256': hashlib.sha256((app / 'Contents/MacOS/ResearchCompanion').read_bytes()).hexdigest()}))
