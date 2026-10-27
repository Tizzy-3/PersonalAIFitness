#!/usr/bin/env python3
"""Crude but useful Swift delimiter balance check.

This does NOT replace compilation. It catches the class of error that costs a full CI round trip:
unbalanced (), [], {} outside strings and comments. String interpolation, multi-line strings and
character literals are handled conservatively; anything ambiguous is reported rather than assumed.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def strip_code(text):
    """Return text with string literals and comments blanked, plus a line map."""
    out = []
    i = 0
    n = len(text)
    line = 1
    while i < n:
        ch = text[i]
        # Swift extended-delimiter strings: backslashes/quotes inside #"..."# are literal
        # unless followed by the matching number of hashes. Do not lex JSON as Swift code.
        if ch == '#':
            start = i
            while i < n and text[i] == '#':
                i += 1
            hashes = text[start:i]
            if i < n and text[i] == '"':
                quote = '"""' if text.startswith('"""', i) else '"'
                i += len(quote)
                end = text.find(quote + hashes, i)
                if end < 0:
                    raise ValueError('Unterminated extended string at line %d' % line)
                line += text[i:end].count('\n')
                i = end + len(quote) + len(hashes)
                continue
            i = start
        # Line comment
        if text.startswith('//', i):
            while i < n and text[i] != '\n':
                i += 1
            continue
        # Block comment (nestable in Swift)
        if text.startswith('/*', i):
            depth = 1
            i += 2
            while i < n and depth:
                if text.startswith('/*', i):
                    depth += 1
                    i += 2
                elif text.startswith('*/', i):
                    depth -= 1
                    i += 2
                else:
                    if text[i] == '\n':
                        line += 1
                    i += 1
            continue
        # Multi-line string
        if text.startswith('"""', i):
            i += 3
            while i < n and not text.startswith('"""', i):
                if text[i] == '\\':
                    i += 1
                if i < n and text[i] == '\n':
                    line += 1
                i += 1
            i += 3
            continue
        # Single-line string
        if ch == '"':
            i += 1
            depth = 0
            while i < n:
                if text[i] == '\\':
                    i += 2
                    continue
                if depth == 0 and text[i] == '"':
                    i += 1
                    break
                if text.startswith('\\(', i):
                    depth += 1
                    i += 2
                    continue
                if depth and text[i] == ')':
                    depth -= 1
                if text[i] == '\n':
                    line += 1
                i += 1
            continue
        if ch == '\n':
            line += 1
        out.append((ch, line))
        i += 1
    return out


PAIRS = {')': '(', ']': '[', '}': '{'}
OPEN = set('([{')


def check(path):
    text = path.read_text(encoding='utf-8-sig')
    try:
        code = strip_code(text)
    except Exception as exc:  # pragma: no cover - defensive
        return [f'{path}: lexer error {exc}']
    stack = []
    errors = []
    for ch, line in code:
        if ch in OPEN:
            stack.append((ch, line))
        elif ch in PAIRS:
            if not stack:
                errors.append(f'{path}:{line}: unexpected {ch!r}')
            elif stack[-1][0] != PAIRS[ch]:
                opener, open_line = stack[-1]
                errors.append(f'{path}:{line}: {ch!r} closes {opener!r} opened at line {open_line}')
                stack.pop()
            else:
                stack.pop()
    for opener, line in stack:
        errors.append(f'{path}:{line}: unclosed {opener!r}')
    return errors


def main():
    files = []
    for folder in ('Sources', 'Packages', 'Tests'):
        files.extend((ROOT / folder).rglob('*.swift'))
    all_errors = []
    for path in sorted(files):
        all_errors.extend(check(path))
    if all_errors:
        print('\n'.join(all_errors))
        raise SystemExit(1)
    print(f'DELIMITERS BALANCED: {len(files)} Swift files')
    print('NOT checked here: types, signatures, availability, Swift compilation.')


if __name__ == '__main__':
    main()
