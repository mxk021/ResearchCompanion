#!/usr/bin/env python3
"""Build an uninstalled, reproducible Zotero XPI. No network or dependencies."""
import argparse, pathlib, zipfile, json
root = pathlib.Path(__file__).resolve().parent
version = json.loads((root / 'manifest.json').read_text())['version']
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=pathlib.Path, default=root / f'research-companion-context-{version}.xpi')
out = parser.parse_args().output
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for name in ['manifest.json', 'bootstrap.js', 'core.js', 'LICENSE']:
        entry = zipfile.ZipInfo(name, date_time=(2026, 11, 15, 0, 0, 0))
        entry.compress_type = zipfile.ZIP_DEFLATED
        entry.external_attr = 0o644 << 16
        source = (root.parent if name == 'LICENSE' else root) / name
        z.writestr(entry, source.read_bytes())
print(out)
