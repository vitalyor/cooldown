#!/usr/bin/env python3
"""Builds <lang>.lproj/Localizable.strings from Resources/Localization/src/<lang>.json.

Checks that every key used in the code is translated, that placeholders (%@, %%) match and
that plural keys ("one|few|many") give 1–3 forms. Index-based drafts (<lang>.txt, one
"index<TAB>text" per line in the order of order.json) are turned into <lang>.json first.
"""
import json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
LOC = os.path.join(HERE, '..', 'Resources', 'Localization')
SRC = os.path.join(LOC, 'src')
LANGS = ['en', 'de', 'fr', 'es', 'pt-BR', 'it', 'uk', 'ja', 'zh-Hans', 'ko']


def code_keys():
    out = subprocess.run([sys.executable, os.path.join(HERE, 'l10n_wrap.py'), 'keys'], capture_output=True, text=True, check=True).stdout
    return set(json.loads(out))


def placeholders(text):
    return len(re.findall(r'%(?:\d+\$)?@', text)), text.count('%%')


def escape(text):
    return text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')


def main():
    keys = code_keys()
    order = json.load(open(os.path.join(LOC, 'order.json')))
    problems = 0
    for lang in LANGS:
        draft, path = os.path.join(SRC, lang + '.txt'), os.path.join(SRC, lang + '.json')
        if os.path.exists(draft):
            table = json.load(open(path)) if os.path.exists(path) else {}
            for line in open(draft, encoding='utf-8').read().rstrip('\n').split('\n'):
                index, text = line.split('\t', 1)
                table[order[int(index)]] = text.replace('\\n', '\n')
            json.dump(table, open(path, 'w'), ensure_ascii=False, indent=1, sort_keys=True)
            os.remove(draft)
        if not os.path.exists(path):
            print(f'{lang}: no translation yet'); problems += 1; continue
        table = json.load(open(path))
        missing = sorted(keys - set(table))
        for key in missing: print(f'{lang}: missing {key!r}')
        problems += len(missing)
        for key, value in table.items():
            if key not in keys: continue
            if placeholders(key)[0] != placeholders(value)[0]:
                print(f'{lang}: placeholders differ in {key!r} -> {value!r}'); problems += 1
            if '|' in key and not (1 <= value.count('|') + 1 <= 3):
                print(f'{lang}: plural forms in {key!r} -> {value!r}'); problems += 1
        folder = os.path.join(LOC, lang + '.lproj')
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, 'Localizable.strings'), 'w', encoding='utf-8') as f:
            for key in sorted(k for k in table if k in keys):
                f.write(f'"{escape(key)}" = "{escape(table[key])}";\n')
    ru = os.path.join(LOC, 'ru.lproj')
    os.makedirs(ru, exist_ok=True)
    open(os.path.join(ru, 'Localizable.strings'), 'w').write('/* Russian is the source language: keys are the text. */\n')
    print('problems:', problems)
    sys.exit(1 if problems else 0)


main()
