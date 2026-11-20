#!/usr/bin/env python3
"""Create the bridge tarball from compiled JS and declarations without host metadata."""
import argparse
import gzip
import io
import json
from pathlib import Path
import tarfile

root = Path(__file__).resolve().parent.parent
metadata = json.loads((root / 'package.json').read_text())
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=root / f"dist/{metadata['name']}-{metadata['version']}.tgz")
parser.add_argument('--public', action='store_true', help='Include the audited public setup guide')
options = parser.parse_args()
target = options.output.resolve()
target.parent.mkdir(parents=True, exist_ok=True)
files = {name: root / name for name in ('package.json', 'cordis.patch.yml', 'LICENSE')}
files['README.md'] = root / ('docs/SETUP.md' if options.public else 'README.md')
for name in ('index', 'client', 'ResearchContext', 'ResearchSessionIndex'):
    files[f'lib/{name}.js'] = root / 'lib' / f'{name}.js'
for source in sorted((root / 'src').glob('*.ts')):
    name = 'lib/types/' + source.stem + '.d.ts'
    files[name] = root / name
with target.open('xb') as raw:
    try:
        with gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                for name, source in sorted(files.items()):
                    if source.resolve() != source or not source.is_file():
                        raise ValueError(f'Missing regular build input: {name}')
                    data = source.read_bytes()
                    member = tarfile.TarInfo('package/' + name)
                    member.mode = 0o644
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))
    except BaseException:
        target.unlink()
        raise
print(target)
