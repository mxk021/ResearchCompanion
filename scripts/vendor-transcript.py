#!/usr/bin/env python3
"""Refresh the audited, offline transcript resources from pinned npm releases."""
import argparse
import base64
import hashlib
import io
from pathlib import Path, PurePosixPath
import subprocess
import tarfile


ROOT = Path(__file__).resolve().parents[1] / 'Resources' / 'Transcript' / 'vendor'
RELEASES = {
    'katex': ('0.19.1', 'jG8uKntjSEcm2EpQOh0XturpPuuC9r3Sq5HLHdsFdWZT27E672SF19QEi+of0/YeOy15lDgRhKvr5614uRrEfA=='),
    'markdown-it': ('15.0.3', '+Az7Ojz3iRGu8KYMvJ6xVhvrxP3eE+vEtJX75Ow88XBpcQNV/0lGX5ZynIIBftREo4DC2jsveAMDaeltmm8QvQ=='),
}


def fetch(name, version, integrity):
    url = f'https://registry.npmjs.org/{name}/-/{name}-{version}.tgz'
    archive = subprocess.check_output(['/usr/bin/curl', '--fail', '--silent', '--show-error',
                                       '--proto', '=https', '--max-time', '30', url])
    if base64.b64encode(hashlib.sha512(archive).digest()).decode() != integrity:
        raise ValueError(f'Unexpected archive digest: {name}')
    required = {'dist/katex.min.js' if name == 'katex' else 'dist/browser/markdown-it.umd.min.js', 'LICENSE'}
    if name == 'katex':
        required.add('dist/katex.min.css')
    files = {}
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as package:
        for member in package.getmembers():
            path = PurePosixPath(member.name)
            if not path.parts or path.parts[0] != 'package' or '..' in path.parts:
                continue
            relative = PurePosixPath(*path.parts[1:])
            is_font = (name == 'katex' and relative.parent == PurePosixPath('dist/fonts')
                       and relative.suffix in ('.woff2', '.woff', '.ttf'))
            if member.isfile() and (str(relative) in required or is_font):
                output = relative.relative_to('dist') if relative.parts[0] == 'dist' else relative
                with package.extractfile(member) as file:
                    files[str(output)] = file.read()
    if any(path.removeprefix('dist/') not in files for path in required):
        raise ValueError(f'Missing upstream distribution content: {name}')
    if name == 'katex' and not any(path.endswith('.woff2') for path in files):
        raise ValueError('KaTeX fonts are missing')
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify', action='store_true', help='Compare installed assets to the pinned releases')
    args = parser.parse_args()
    for name, (version, integrity) in RELEASES.items():
        files = fetch(name, version, integrity)
        for relative, data in files.items():
            destination = ROOT / name / relative
            if args.verify:
                if destination.read_bytes() != data:
                    raise ValueError(f'Changed resource: {name}/{relative}')
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
        print(f'{name} {version}: {len(files)} files checked against pinned npm SRI')


if __name__ == '__main__':
    main()
