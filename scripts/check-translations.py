#!/usr/bin/env python3
"""检查翻译是否完整。

- 代码里每条 L("...") 文案，各语言词典都要有；词典里也不能留着用不到的条目。
- L() 只能直接写文字，传变量的话这个检查就看不到那条文案。
- 各语言的 InfoPlist.strings（权限说明）要有相同的键。

有问题时以非零状态退出，可以直接放进 CI。用法：python3 scripts/check-translations.py
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
sources = root / 'Sources' / 'NotchDeck'
dictionaries = sources / 'Translations'
problems = []

code = [p for p in sources.rglob('*.swift') if dictionaries not in p.parents]
used = set()
for path in code:
    for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        used.update(re.findall(r'\bL\("((?:[^"\\]|\\.)*)"', line))
        if re.search(r'\bL\((?!")', line) and 'func L(' not in line:
            problems.append(f'{path.relative_to(root)}:{number}: L() 的参数不是文字，翻译检查看不到它')

for path in sorted(dictionaries.glob('*.swift')):
    keys = set(re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*:', path.read_text(encoding='utf-8'), re.M))
    for key in sorted(used - keys):
        problems.append(f'{path.name}: 缺少 "{key}"')
    for key in sorted(keys - used):
        problems.append(f'{path.name}: 没有用到 "{key}"')

plist_keys = {}
for path in sorted((root / 'Resources').glob('*.lproj/InfoPlist.strings')):
    plist_keys[path.parent.name] = set(re.findall(r'^"([^"]+)"\s*=', path.read_text(encoding='utf-8'), re.M))
reference = plist_keys.get('en.lproj', set())
for language, keys in plist_keys.items():
    for key in sorted(reference ^ keys):
        problems.append(f'{language}/InfoPlist.strings: "{key}" 和英文版不一致')

if problems:
    print('\n'.join(problems))
    sys.exit(1)
print(f'翻译完整：{len(used)} 条文案，{len(list(dictionaries.glob("*.swift")))} 种其他语言，{len(plist_keys)} 份权限说明')
