from pathlib import Path
import re

import sys
root = Path(__file__).resolve().parents[3]
spec = Path(sys.argv[1]).read_text()
section = spec.split('### 4.1 ')[1].split('## 5.')[0]
lines = (root/'Sources/KabanProtocol/Pipeline.swift').read_text().splitlines()
start = next(i for i, line in enumerate(lines) if 'public enum ValidationCode' in line)
codes = {}
for n, line in enumerate(lines[start:], start + 1):
    match = re.search(r'public static let (\w+) = "([^"]+)"', line)
    if match:
        codes[match[2]] = (match[1], n)
rows = {}
for line in section.splitlines():
    match = re.match(r'\| `([a-z_]+)`(?: ⚠)? \| (.*?) \| (.*?) \|$', line)
    if match and match[1] in codes:
        if match[1] in rows:
            raise ValueError('duplicate ' + match[1])
        rows[match[1]] = (match[2], match[3])
assert len(codes) == 37, len(codes)
assert set(codes) == set(rows), (set(codes)-set(rows),set(rows)-set(codes))
producer = (root/'Sources/KabanKit/Pipeline/PipelineParser.swift').read_text() + (root/'Sources/KabanKit/Pipeline/PipelineValidator.swift').read_text()
assert all('ValidationCode.' + member in producer for member, _ in codes.values())
output = ['| Код | Protocol.swift:строка | Подстановки текста §4.1 | Статус |', '|---|---|---|---|']
for code, (member, n) in codes.items():
    placeholders = sorted(set(re.findall(r'\{(\w+)\}', rows[code][1])))
    output.append(f'| `{code}` | `Pipeline.swift:{n}` | '+ (', '.join('`'+p+'`' for p in placeholders) or '—') + ' | Код и текст есть; см. правила подстановки ниже |')

print('37/37 codes: unique names match spec table; all have parser/validator producer references.')
print('\n'.join(output))
