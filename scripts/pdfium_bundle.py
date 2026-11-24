"""Build-time inputs for the narrow, offline PDFium rendering path."""
import hashlib
import io
from pathlib import Path
import subprocess
import tarfile
from urllib.request import Request, urlopen


VERSION = '8165'
ARTIFACTS = {
    'arm64': ('arm64', '112e74d717f3e0310273b70f3c8780e8a61ff11b34834124465c8305c841d350'),
    'x86_64': ('x64', '07285915b564e46a432a9909dbc1f15892885ca6489e3faeefc70dee77ed371a'),
}
LIBRARY = 'libpdfium.dylib'
NOTICE_DIRECTORY = 'LicenseNotices/PDFium'
NOTICES = (
    'abseil.txt', 'agg23.txt', 'dragonbox-Apache2-LLVM.txt', 'dragonbox-Boost.txt',
    'fast_float.txt', 'freetype.txt', 'harfbuzz.txt', 'highway.txt', 'icu.txt',
    'lcms.txt', 'libjpeg_turbo.ijg', 'libjpeg_turbo.md', 'libopenjpeg.txt',
    'libpng.txt', 'llvm-libc.txt', 'pdfium.txt', 'simdutf.txt', 'zlib.txt',
)
RESOURCE_PATHS = {f'{NOTICE_DIRECTORY}/{name}' for name in ('distribution-MIT.txt', *NOTICES)}


def binary_arch(path):
    return subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True).strip()


def archive_data(arch, local):
    platform_name, expected = ARTIFACTS[arch]
    filename = f'pdfium-mac-{platform_name}.tgz'
    if local is not None:
        with Path(local).open('rb') as handle:
            data = handle.read(8_000_000)
    else:
        url = f'https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/{VERSION}/{filename}'
        with urlopen(Request(url, headers={'User-Agent': 'Research Companion build'}), timeout=30) as handle:
            data = handle.read(8_000_000)
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f'PDFium {VERSION} archive SHA-256 mismatch for {arch}.')
    return data


def install(contents, executable, local_archive, signing_identity):
    arch = binary_arch(executable)
    if arch not in ARTIFACTS:
        raise ValueError(f'No pinned PDFium build for executable architecture {arch}.')
    data = archive_data(arch, local_archive)
    frameworks = contents / 'Frameworks'
    notices = contents / 'Resources' / NOTICE_DIRECTORY
    frameworks.mkdir()
    notices.mkdir(parents=True, exist_ok=True)
    library = frameworks / LIBRARY
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as source:
        members = {
            'LICENSE': notices / 'distribution-MIT.txt',
            f'lib/{LIBRARY}': library,
            **{f'licenses/{name}': notices / name for name in NOTICES},
        }
        for name, destination in members.items():
            member = source.getmember(name)
            if not member.isfile() or not 0 < member.size <= 12_000_000:
                raise ValueError(f'Unexpected PDFium archive entry {name}.')
            with destination.open('xb') as out:
                out.write(source.extractfile(member).read())
    if binary_arch(library) != arch:
        raise ValueError('PDFium and the application executable require different architectures.')
    # The pinned distribution includes debug symbols with the upstream build
    # machine's absolute paths. Drop those before signing; keep exported symbols.
    subprocess.run(['/usr/bin/strip', '-S', str(library)], check=True)
    timestamp = ['--timestamp'] if signing_identity != '-' else []
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', signing_identity, *timestamp, str(library)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(library)], check=True)
