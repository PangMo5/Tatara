#!/usr/bin/env python3
import re
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
results = re.findall(r'Test run with (\d+) tests? (?:in \d+ suites? )?passed', text)
assert results and int(results[-1]) > 0, 'No nonzero successful Swift Testing run found.'
print(f'Confirmed {results[-1]} executed Swift Testing tests.')
