#!/usr/bin/env python3
"""Test and package the currently checked-out Research Companion for this Mac's architecture."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pdfium_bundle import LIBRARY as PDFIUM_LIBRARY, RESOURCE_PATHS as PDFIUM_NOTICES

ROOT = Path(__file__).resolve().parent.parent
META = json.loads((ROOT / 'release.json').read_text())
APP = 'Research Companion.app'
PYTHON = sys.executable


def run(*args, cwd=ROOT, env=None):
    subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True)


def output(*args, cwd=ROOT, env=None):
    return subprocess.check_output([str(a) for a in args], cwd=cwd, env=env, text=True).strip()


def copy_to_stage(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)


def build_bridge(temp, payload, offline, test_env):
    build = temp / 'bridge'
    inputs = ['package.json', 'pnpm-lock.yaml', 'tsconfig.json', 'tsconfig.build.json', 'cordis.patch.yml',
              'LICENSE', 'docs/SETUP.md', 'scripts/build-local.mjs', 'scripts/package-bridge.py',
              'scripts/probe-companion.mjs', 'zotero-context-bridge/core.js', 'zotero-context-bridge/package.json']
    for name in inputs:
        copy_to_stage(ROOT / name, build / name)
    for pattern in ('src/*.ts', 'src/client.js', 'tests/*.mjs'):
        for source in ROOT.glob(pattern):
            copy_to_stage(source, build / source.relative_to(ROOT))
    # The renderer tests use the exact same first-party and vendored JS as the app.
    for name in ('markdown.js', 'vendor/katex/katex.min.js', 'vendor/markdown-it/browser/markdown-it.umd.min.js'):
        relative = Path('Resources/Transcript') / name
        copy_to_stage(ROOT / relative, build / relative)
    pnpm = shutil.which('pnpm')
    if pnpm is None:
        raise SystemExit('Install pnpm before building the research bridge.')
    run(pnpm, 'install', '--frozen-lockfile', '--ignore-scripts', *(['--offline'] if offline else []), cwd=build)
    run(pnpm, 'exec', 'tsc', '-p', 'tsconfig.build.json', cwd=build)
    run('node', 'scripts/build-local.mjs', cwd=build)
    run('node', '--test', *sorted((build / 'tests').glob('*.test.mjs')), cwd=build, env=test_env)
    run('node', '--test', 'zotero-context-bridge/tests/bridge.test.cjs', env=test_env)
    package = json.loads((build / 'package.json').read_text())
    target = payload / f"{package['name']}-{package['version']}.tgz"
    run(PYTHON, build / 'scripts/package-bridge.py', '--public', '--output', target, cwd=build)
    return target


def isolated_environment(test_home):
    test_home = test_home.resolve()
    env = {key: value for key, value in os.environ.items() if not key.upper().startswith('DSH_')}
    env.update(HOME=str(test_home), CFFIXED_USER_HOME=str(test_home))
    if os.name == 'nt':
        for name, relative in [('USERPROFILE', '.'), ('APPDATA', 'AppData/Roaming'), ('LOCALAPPDATA', 'AppData/Local')]:
            path = test_home / relative
            path.mkdir(parents=True, exist_ok=True)
            env[name] = str(path)
        # Node fixtures use os.tmpdir(). Supply a canonical path so 8.3
        # aliases inherited from the runner do not trip the bridge's realpath check.
        fixture_temp = test_home / 'Temp'
        fixture_temp.mkdir()
        env.update(TEMP=str(fixture_temp), TMP=str(fixture_temp))
    return env


def bridge_only(options):
    dest = options.output.resolve()
    dest.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='rc-bridge-', dir='/private/tmp' if sys.platform == 'darwin' else None) as directory:
        temp = Path(directory).resolve()
        test_home = temp / 'home'
        test_home.mkdir(mode=0o700)
        archive = build_bridge(temp, dest, options.offline, isolated_environment(test_home))
    print(archive)


def native_checks(temp, env, clt_only):
    swift = ['--scratch-path', temp / 'swift', '--cache-path', temp / 'cache', '--disable-index-store',
             '--disable-sandbox', '--sdk', env['SDKROOT'], '--build-system', 'native',
             '-Xswiftc', '-module-cache-path', '-Xswiftc', temp / 'modules']
    for path, replacement in [(ROOT, '.'), (temp, '/build')]:
        for key in ['-file-prefix-map', '-debug-prefix-map']:
            swift += ['-Xswiftc', key, '-Xswiftc', f'{path}={replacement}']
    if clt_only:
        print('CLT mode: XCTest is not executed. Full Xcode is required for the release test gate.', flush=True)
    else:
        run('swift', 'test', *swift, env=env)
    common = ['swiftc', '-sdk', env['SDKROOT'], '-parse-as-library', '-module-cache-path', temp / 'modules']
    for check, source in [('check-note-export', 'ResearchNoteStorage'), ('check-composer', 'ComposerTextView'),
                          ('check-transcript', 'ResearchWindowGeometry'), ('check-pdf-layout', 'ResearchPDFLayout')]:
        binary = temp / check
        sources = [ROOT / f'Sources/DSHPet/{source}.swift']
        if check == 'check-pdf-layout':
            sources.append(ROOT / 'Sources/DSHPet/ResearchPDFImageGeometry.swift')
        run(*common, *sources, ROOT / f'scripts/{check}.swift', '-o', binary, env=env)
        args = [ROOT / 'Resources/Transcript'] if check == 'check-transcript' else []
        run(binary, *args, env=env)
    for flags in ([], ['--selection']):
        run(PYTHON, 'scripts/check-long-pdf.py', *flags, env=env)
    app_sources = sorted(p for p in (ROOT / 'Sources/DSHPet').glob('*.swift') if p.name != 'DSHPetMain.swift')
    target = f'{platform.machine()}-apple-macos14.0'
    for name in ['check-pdf-query', 'check-pdf-card']:
        executable = temp / name
        run(*common, '-target', target, '-whole-module-optimization', *app_sources,
            ROOT / f'scripts/{name}.swift', '-o', executable, env=env)
        arguments = [temp, '--render', '--check-bridge'] if name == 'check-pdf-card' else []
        run(executable, *arguments, env=env)
    run('swift', 'build', *swift, '-c', 'release', env=env)
    path = Path(output('swift', 'build', *swift, '-c', 'release', '--show-bin-path', env=env))
    return path / 'DSHPet'


def verify_app(app, bridge_name, expected_arch, forbidden_paths):
    contents = app / 'Contents'
    resources = contents / 'Resources'
    info = plistlib.loads((contents / 'Info.plist').read_bytes())
    if (info['CFBundleIdentifier'], info['CFBundleShortVersionString'], info['CFBundleVersion'],
        info['ResearchCompanionPublicDistribution'], info['ResearchCompanionBridgeArchive']) != (
            META['bundleIdentifier'], META['version'], META['version'], True, bridge_name):
        raise ValueError('Unexpected bundle identity, release version, or distribution flavor')
    executable = contents / 'MacOS' / info['CFBundleExecutable']
    if output('lipo', '-archs', executable).split() != [expected_arch]:
        raise ValueError('Binary architecture does not match the DMG name')
    run('codesign', '--verify', '--strict', '--deep', app)
    listed = set((ROOT / 'Resources/PublicManifest.txt').read_text().splitlines())
    listed |= {'SETUP.md', 'LICENSE', info['CFBundleIconFile'], bridge_name,
               'Transcript/ResearchCompanionMark.png'}
    listed |= PDFIUM_NOTICES
    actual = {p.relative_to(resources).as_posix() for p in resources.rglob('*') if p.is_file()}
    if actual != listed or any(p.is_symlink() for p in contents.rglob('*')):
        raise ValueError(f'Unexpected app resources: {sorted(actual ^ listed)}')
    frameworks = contents / 'Frameworks'
    if sorted(p.name for p in frameworks.iterdir()) != [PDFIUM_LIBRARY] or (
            output('lipo', '-archs', frameworks / PDFIUM_LIBRARY).split() != [expected_arch]):
        raise ValueError('Unexpected bundled PDF rasterizer.')
    for p in contents.rglob('*'):
        if p.is_file() and any(value in p.read_bytes() for value in forbidden_paths):
            raise ValueError(f'Local path in distribution file: {p.relative_to(contents)}')
    with tarfile.open(resources / bridge_name, 'r:gz') as archive:
        for entry in archive:
            if not entry.isfile() or entry.uid or entry.gid or entry.uname or entry.gname or entry.pax_headers:
                raise ValueError(f'Unexpected archive metadata: {entry.name}')
            data = archive.extractfile(entry).read()
            if any(value in data for value in forbidden_paths):
                raise ValueError(f'Local path in bridge: {entry.name}')


def check_pdf_rasterizer(temp, app, arch, env):
    # Run the production rasterizer against synthetic rotated pages in a small
    # test bundle, with the exact signed library taken from the packaged App.
    contents = temp / 'PDFRasterCheck.app/Contents'
    frameworks = contents / 'Frameworks'
    frameworks.mkdir(parents=True)
    shutil.copy2(app / 'Contents/Frameworks' / PDFIUM_LIBRARY, frameworks)
    executable = contents / 'MacOS/PDFRasterCheck'
    executable.parent.mkdir()
    (contents / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': executable.name,
        'CFBundleIdentifier': 'com.local.research-companion.pdf-raster-check',
        'CFBundlePackageType': 'APPL',
    }))
    run('swiftc', '-O', '-parse-as-library', '-sdk', env['SDKROOT'], '-target', f'{arch}-apple-macos14.0',
        '-module-cache-path', temp / 'raster-modules', ROOT / 'scripts/check-pdf-raster.swift',
        ROOT / 'Sources/DSHPet/ResearchPDFCropRenderer.swift', '-o', executable, env=env)
    run(executable, env=env)


def package(options):
    arch = platform.machine()
    if platform.system() != 'Darwin':
        raise SystemExit('This packaging command requires macOS.')
    if options.notary_profile and options.clt_only:
        raise SystemExit('The notarized release path requires the full Xcode test gate.')
    if options.notary_profile and options.identity == '-':
        raise SystemExit('Notarization requires a Developer ID Application identity.')
    if options.offline and options.pdfium_archive is None:
        raise SystemExit('--offline requires --pdfium-archive for the pinned PDFium input.')
    name = f"ResearchCompanion-{META['version']}-{arch}.dmg"
    dest = options.output.resolve()
    dest.mkdir(parents=True, exist_ok=True)
    target = dest / name
    checksum = dest / (name + '.sha256')
    if target.exists() or checksum.exists():
        raise SystemExit('Choose an empty output location or move the previous release yourself.')
    real_home = Path.home()
    with tempfile.TemporaryDirectory(prefix='rc-rel-', dir='/private/tmp') as directory:
        temp = Path(directory)
        payload = temp / 'payload'
        payload.mkdir()
        dmg_root = temp / 'image'
        dmg_root.mkdir()
        test_home = temp / 'home'
        test_home.mkdir(mode=0o700)
        if not options.clt_only:
            # Xcode manages read-only Metal toolchain mounts in its user cache.
            # Keep their lifecycle with Xcode. The disposable HOME used by the
            # app tests must never recursively traverse a mounted toolchain.
            relative = Path('Library/Developer/DVTDownloads/MetalToolchain')
            system_cache = real_home / relative
            system_cache.mkdir(parents=True, exist_ok=True)
            link = test_home / relative
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(system_cache, target_is_directory=True)
        env = isolated_environment(test_home)
        env.update(SDKROOT=os.environ.get('SDKROOT') or output('xcrun', '--sdk', 'macosx', '--show-sdk-path'),
                   CLANG_MODULE_CACHE_PATH=str(temp / 'clang'), SWIFTPM_MODULECACHE_OVERRIDE=str(temp / 'modules'))
        bridge = build_bridge(temp, payload, options.offline, env)
        binary = native_checks(temp, env, options.clt_only)
        app = dmg_root / APP
        pdfium = ['--pdfium-archive', options.pdfium_archive.resolve()] if options.pdfium_archive else []
        run(PYTHON, 'scripts/package-macos.py', '--binary', binary, '--output', app, '--public-bridge', bridge,
            '--sign-identity', options.identity, *pdfium, env={**os.environ, 'SDKROOT': env['SDKROOT']})
        forbidden = [str(path).encode() for path in (real_home, ROOT, temp)]
        verify_app(app, bridge.name, arch, forbidden)
        check_pdf_rasterizer(temp, app, arch, env)
        if options.identity != '-':
            detail = subprocess.run(['codesign', '-dv', '--verbose=4', app], capture_output=True, check=True, text=True).stderr
            if 'Authority=Developer ID Application:' not in detail or 'runtime' not in detail or 'Timestamp=' not in detail:
                raise ValueError('Developer ID Application, hardened runtime, and secure timestamp are required')
        zotero = json.loads((ROOT / 'zotero-context-bridge/manifest.json').read_text())
        xpi = dmg_root / f"research-companion-context-{zotero['version']}.xpi"
        run(PYTHON, 'zotero-context-bridge/build.py', '--output', xpi)
        with zipfile.ZipFile(xpi) as archive:
            if sorted(archive.namelist()) != ['LICENSE', 'bootstrap.js', 'core.js', 'manifest.json'] or archive.testzip():
                raise ValueError('Unexpected Zotero extension payload')
            for entry in archive.infolist():
                if entry.extra or entry.comment or any(path in archive.read(entry) for path in forbidden):
                    raise ValueError(f'Unexpected metadata or local path in extension: {entry.filename}')
        shutil.copyfile(ROOT / 'docs/SETUP.md', dmg_root / 'SETUP.md')
        (dmg_root / 'Applications').symlink_to('/Applications')
        image = temp / name
        run('hdiutil', 'create', '-volname', 'Research Companion', '-fs', 'HFS+', '-format', 'UDZO', '-srcfolder', dmg_root, image)
        if options.identity != '-':
            run('codesign', '--sign', options.identity, '--timestamp', image)
        if options.notary_profile:
            result = json.loads(output('xcrun', 'notarytool', 'submit', image, '--keychain-profile', options.notary_profile,
                                       '--wait', '--output-format', 'json'))
            if result.get('status') != 'Accepted':
                raise ValueError('Notarization unsuccessful: ' + str(result.get('id')))
            run('xcrun', 'stapler', 'staple', image)
            run('xcrun', 'stapler', 'validate', image)
            run('spctl', '-a', '-t', 'open', '--context', 'context:primary-signature', image)
        run('hdiutil', 'verify', image)
        mount = temp / 'mounted'
        mount.mkdir()
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, image)
        try:
            verify_app(mount / APP, bridge.name, arch, forbidden)
            if ((mount / 'Applications').readlink() != Path('/Applications') or
                    (mount / 'SETUP.md').read_bytes() != (dmg_root / 'SETUP.md').read_bytes() or
                    (mount / xpi.name).read_bytes() != xpi.read_bytes()):
                raise ValueError('Mounted installation payload differs from the build')
        finally:
            run('hdiutil', 'detach', mount)
        digest = hashlib.sha256(image.read_bytes()).hexdigest()
        with target.open('xb') as f, image.open('rb') as source:
            shutil.copyfileobj(source, f)
        with checksum.open('x') as f:
            f.write(f'{digest}  {name}\n')
        print(f'{target}\n{digest}  {name}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist')
    parser.add_argument('--tag', help='Require this tag to match release.json')
    parser.add_argument('--identity', default='-', help='Developer ID Application signing identity; omit for ad-hoc')
    parser.add_argument('--notary-profile', help='Explicitly submit the DMG to Apple using this Keychain profile')
    parser.add_argument('--offline', action='store_true', help='Use integrity-locked pnpm packages and, for a DMG, local PDFium')
    parser.add_argument('--bridge-only', action='store_true', help='Build and test the same public bridge on macOS or Windows')
    parser.add_argument('--pdfium-archive', type=Path, help='Use the SHA-256 pinned PDFium archive from disk')
    parser.add_argument('--clt-only', action='store_true', help='Draft verification on Command Line Tools without XCTest')
    options = parser.parse_args()
    if options.tag and options.tag != f"v{META['version']}":
        raise SystemExit('Requested tag and release.json version differ.')
    if options.bridge_only:
        if options.identity != '-' or options.notary_profile or options.clt_only or options.pdfium_archive:
            parser.error('macOS app options apply to DMG builds only.')
        bridge_only(options)
    else:
        package(options)
