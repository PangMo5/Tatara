#!/usr/bin/env python3
import re
from pathlib import Path
source = (Path(__file__).resolve().parent.parent / 'Project.swift').read_text()
match = re.search(r'^let appVersion = "(\d+\.\d+\.\d+)"$', source, re.M)
if not match:
    raise SystemExit('Project.swift must declare one semantic appVersion.')
print(match[1])
