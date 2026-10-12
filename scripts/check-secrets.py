"""Reject apparent real credentials in tracked project sources without printing them."""
from pathlib import Path
import re
import subprocess
paths = subprocess.check_output(['git', 'ls-files', '-z']).decode().split('\0')
if not any(paths):
    paths = [str(p) for root in ['Sources', 'Tests', 'scripts'] for p in Path(root).rglob('*') if p.is_file()]
violations = []
for name in paths:
    if not name or not Path(name).is_file():
        continue
    for match in re.finditer(r'sk-(?:proj-)?[A-Za-z0-9_-]{40,}', Path(name).read_text(errors='ignore')):
        violations.append(name)
if violations:
    raise SystemExit('Possible credentials detected in: ' + ', '.join(sorted(set(violations))))
print('Credential scan passed.')
