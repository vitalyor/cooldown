#!/usr/bin/env python3
"""Wraps user-facing Russian string literals in L(...) and lists every key.

  scripts/l10n_wrap.py wrap     rewrites Sources/ in place (idempotent)
  scripts/l10n_wrap.py keys     prints the catalog of keys as JSON (key -> first file:line)

A literal is left alone on lines marked `// l10n:skip`, in files marked `l10n:file-skip`,
and when it is already the first argument of L(. Interpolations become %@ with the value
passed as "\\(value)", so the translation decides the word order.
"""
import json, os, re, sys

CYR = re.compile('[А-Яа-яЁё]')
ROOT = os.path.join(os.path.dirname(__file__), '..', 'Sources', 'Cooldown')


def parse_string(src, i):
    """src[i] == '"'. Returns (end, parts); parts: ('t', raw text) / ('i', raw code)."""
    assert src[i] == '"'
    i += 1
    parts, buf = [], []
    while True:
        c = src[i]
        if c == '\\':
            if src[i + 1] == '(':
                if buf: parts.append(('t', ''.join(buf))); buf = []
                j, depth = i + 2, 1
                while depth:
                    ch = src[j]
                    if ch == '"':
                        j, _ = parse_string(src, j)
                        continue
                    if ch == '(': depth += 1
                    elif ch == ')': depth -= 1
                    j += 1
                parts.append(('i', src[i + 2:j - 1]))
                i = j
                continue
            buf.append(src[i:i + 2]); i += 2
            continue
        if c == '"':
            if buf: parts.append(('t', ''.join(buf)))
            return i + 1, parts
        if c == '\n':
            raise ValueError('newline in string at %d' % i)
        buf.append(c); i += 1


def unescape(raw):
    out, i = [], 0
    while i < len(raw):
        if raw[i] == '\\':
            n = raw[i + 1]
            if n == 'n': out.append('\n'); i += 2
            elif n == 't': out.append('\t'); i += 2
            elif n == '0': out.append('\0'); i += 2
            elif n in '"\'\\': out.append(n); i += 2
            elif n == 'u':
                j = raw.index('}', i); out.append(chr(int(raw[i + 3:j], 16))); i = j + 1
            else: out.append(raw[i:i + 2]); i += 2
        else:
            out.append(raw[i]); i += 1
    return ''.join(out)


class Wrapper:
    def __init__(self, path):
        self.path = path
        self.keys = {}

    def line_of(self, src, i):
        start = src.rfind('\n', 0, i) + 1
        end = src.find('\n', i)
        return src[start:end if end >= 0 else len(src)], src.count('\n', 0, i) + 1

    def transform(self, src, base=0, whole=None):
        whole = whole if whole is not None else src
        out, i = [], 0
        while i < len(src):
            c = src[i]
            if src.startswith('//', i):
                j = src.find('\n', i); j = len(src) if j < 0 else j
                out.append(src[i:j]); i = j; continue
            if src.startswith('/*', i):
                j = src.index('*/', i) + 2
                out.append(src[i:j]); i = j; continue
            if src.startswith('"""', i):
                j = src.index('"""', i + 3) + 3
                out.append(src[i:j]); i = j; continue
            if c == '#' and src[i + 1:i + 2] in ('"', '#'):
                m = re.match(r'(#+)"', src[i:])
                if m:
                    closing = '"' + m.group(1)
                    j = src.index(closing, i + len(m.group(0))) + len(closing)
                    out.append(src[i:j]); i = j; continue
            if c == '"':
                end, parts = parse_string(src, i)
                out.append(self.literal(src, i, end, parts, base, whole))
                i = end; continue
            out.append(c); i += 1
        return ''.join(out)

    def literal(self, src, start, end, parts, base, whole):
        original = src[start:end]
        text = ''.join(p[1] for p in parts if p[0] == 't')
        line, number = self.line_of(whole, base + start)
        before = src[:start].rstrip()
        wrapped_already = before.endswith('L(')
        interps = [p for p in parts if p[0] == 'i']
        # Interpolations may hold literals of their own.
        new_parts = [(k, self.transform(v, base + start, whole) if k == 'i' else v) for k, v in parts]
        if not CYR.search(text) or 'l10n:skip' in line or wrapped_already:
            if wrapped_already and CYR.search(text):
                self.keys.setdefault(unescape(text), '%s:%d' % (self.path, number))
            return '"' + ''.join(v if k == 't' else '\\(' + v + ')' for k, v in new_parts) + '"'
        if not interps:
            self.keys.setdefault(unescape(text), '%s:%d' % (self.path, number))
            return 'L(' + original + ')'
        key_raw = ''.join(v.replace('%', '%%') if k == 't' else '%@' for k, v in new_parts)
        self.keys.setdefault(unescape(key_raw), '%s:%d' % (self.path, number))
        args = ', '.join('"\\(' + v + ')"' for k, v in new_parts if k == 'i')
        return 'L("' + key_raw + '", ' + args + ')'


def files():
    for folder, _, names in os.walk(ROOT):
        for name in sorted(names):
            if name.endswith('.swift') and name != 'Localization.swift':
                yield os.path.join(folder, name)


def main():
    mode = sys.argv[1]
    catalog = {}
    for path in files():
        src = open(path, encoding='utf-8').read()
        rel = os.path.relpath(path, ROOT)
        if 'l10n:file-skip' in src:
            # Already wrapped by hand: just collect its keys.
            for m in re.finditer(r'L\("((?:[^"\\\n]|\\.)*)"', src):
                catalog.setdefault(unescape(m.group(1)), rel)
            continue
        wrapper = Wrapper(rel)
        result = wrapper.transform(src)
        for k, v in wrapper.keys.items(): catalog.setdefault(k, v)
        if mode == 'wrap' and result != src:
            open(path, 'w', encoding='utf-8').write(result)
    if mode == 'keys':
        json.dump(catalog, sys.stdout, ensure_ascii=False, indent=1, sort_keys=True)
    else:
        print(len(catalog), 'keys')


main()
