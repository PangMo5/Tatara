#!/usr/bin/env python3
"""Reproduce dependency notices from exactly the resolved dependency checkouts."""
import argparse
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
pins = json.loads((root / 'Tuist/Package.resolved').read_text())['pins']
parts = ['# Third-Party Notices', '',
         'Tatara is licensed under AGPL-3.0-only. Dependencies retain their own licenses.',
         'Versions below come from Tuist/Package.resolved. Notices include build dependencies and vendored components.',
         '', '<!-- REUSE-IgnoreStart -->', '']
for pin in pins:
    directory = root / 'Tuist/.build/checkouts' / pin['identity']
    assert directory.exists(), f'Run tuist install: {directory}'
    files = sorted(p for p in directory.rglob('*') if p.is_file() and p.name.upper().split('.')[0] in ('LICENSE', 'LICENCE', 'NOTICE', 'COPYING') and '.git' not in p.parts)
    assert files, f'No license found for {pin["identity"]}'
    parts += [f'## {pin["identity"]} {pin["state"].get("version", "")}', '', f'Source: {pin["location"]}', '', f'Revision: `{pin["state"]["revision"]}`', '']
    for file in files:
        parts += [f'### {file.relative_to(directory)}', '', '~~~~text', file.read_text(errors='strict').strip(), '~~~~', '']
    if pin['identity'] == 'swift-toml':
        header = (directory / 'Sources/CTomlPlusPlus/toml.hpp').read_text()
        parts += ['### Vendored toml++', '', '~~~~text', header.split('#ifndef')[0].strip(), '~~~~', '']
parts += ['## Catppuccin palette', '', 'Source: https://github.com/catppuccin/catppuccin', '', '~~~~text', (root / 'ThirdParty/Catppuccin.txt').read_text().strip(), '~~~~', '', '<!-- REUSE-IgnoreEnd -->', '']
text = '\n'.join(parts)
p = argparse.ArgumentParser(); p.add_argument('--check', action='store_true'); args = p.parse_args()
target = root / 'THIRD_PARTY_NOTICES.md'
if args.check:
    assert target.read_text() == text, 'Run python3 Scripts/generate-notices.py'
else:
    target.write_text(text)
print(f'Validated notices for {len(pins)} resolved packages and Catppuccin.')
