#!/usr/bin/env python3
import re
from pathlib import Path
root = Path(__file__).resolve().parent.parent
version = re.search(r'^let appVersion = "([^"]+)"$', (root / 'Project.swift').read_text(), re.M)[1]
match = re.search(rf'^## {re.escape(version)}\s*\n(.*?)(?=^## |\Z)', (root / 'CHANGELOG.md').read_text(), re.M | re.S)
assert match and match[1].strip(), 'Missing release changelog.'
print(match[1].strip())
print(f'\nInstall (recommended): `mise use -g github:PangMo5/Tatara@{version}`')
print('\nRuntime tools: `mise use -g aqua:cli/cli aqua:Wilfred/difftastic`')
print('\nHomebrew: `brew install PangMo5/tap/tatara`')
print(f'\n[Corresponding source](https://github.com/PangMo5/Tatara/releases/download/v{version}/Tatara-{version}-source.tar.gz) · [Licenses and notices](https://github.com/PangMo5/Tatara/blob/v{version}/THIRD_PARTY_NOTICES.md)')
