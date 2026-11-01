#!/usr/bin/env python3
"""Every Settings search entry lands on a row that's marked for it.

A search entry (`SettingsItem(...)`) opens its page and lights the row marked
with its anchor, or its key when it has no anchor, and its parent while the row
is hidden. A mark is set with `.settingsItem(...)`. An entry whose mark no row
has opens the page with nothing lit, and nothing else notices. Marks and
entries built at run time (`"widget.\\(...)"`, a property, a function) are
matched by their pattern, or skipped when the script can't read them. Run from
the repository root: python3 scripts/check-settings-search.py
"""
import pathlib
import re
import sys

SOURCES = sorted(pathlib.Path('Underbrim').rglob('*.swift'))
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')


def arguments(text, start):
    """The text between the parenthesis at `start` and its match, skipping string literals."""
    depth, i = 0, start
    while i < len(text):
        c = text[i]
        if c == '"':
            i = LITERAL.match(text, i).end()
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
        i += 1
    return ''


def block(text, start):
    """What a definition at `start` gives: its `{ ... }`, or the rest of the line after its `=`.
    Nothing for one with neither on its line (a stored property)."""
    line_end = text.find('\n', start)
    brace, equals = text.find('{', start, line_end), text.find('=', start, line_end)
    if equals != -1 and (brace == -1 or equals < brace):
        return text[equals:line_end]
    if brace == -1:
        return ''
    depth = 0
    for i in range(brace, len(text)):
        depth += {'{': 1, '}': -1}.get(text[i], 0)
        if depth == 0:
            return text[brace:i + 1]
    return ''


def line(text, index):
    return text.count('\n', 0, index) + 1


files = {path: path.read_text(encoding='utf-8') for path in SOURCES}

# Marks: literals inside `.settingsItem(...)`, literals handed on as a `mark:` or
# `sectionMark:` argument, and the literals a name given to `.settingsItem(...)` is defined with,
# or given as an argument of that name (a stored property set through its initializer).
marks, names = set(), set()
for text in files.values():
    for match in re.finditer(r'\.settingsItem\(', text):
        expression = arguments(text, match.end() - 1)
        literals = LITERAL.findall(expression)
        marks.update(literals)
        if not literals:
            names.update(re.findall(r'(\w+)\s*(?:\([^()]*\))?\s*$', expression))
    marks.update(re.findall(r'\b\w*[mM]ark:\s*"((?:[^"\\]|\\.)*)"', text))
for text in files.values():
    for name in names:
        for match in re.finditer(rf'\b(?:var|let|func)\s+{name}\b', text):
            marks.update(LITERAL.findall(block(text, match.end())))
        marks.update(re.findall(rf'\b{name}:\s*"((?:[^"\\]|\\.)*)"', text))

exact = {mark for mark in marks if '\\(' not in mark}
patterns = [re.compile(''.join('.+' if part.startswith('\\(') else re.escape(part)
                               for part in re.split(r'(\\\([^)]*\))', mark)) + '$')
            for mark in marks if '\\(' in mark]


def marked(mark):
    return mark in exact or any(pattern.match(mark) for pattern in patterns)


problems, checked = [], 0
for path, text in files.items():
    # Entries: the anchor, else the key; and the parent. Only string literals with nothing interpolated.
    for match in re.finditer(r'(?<![\w.])SettingsItem\(', text):
        args = arguments(text, match.end() - 1)
        fields = dict(re.findall(r'\b(key|anchor|parent):\s*("(?:[^"\\]|\\.)*"|[^,]+)', args))
        target = fields.get('anchor', fields.get('key'))
        for label, value in (('mark', target), ('parent', fields.get('parent'))):
            if not value or not value.startswith('"') or '\\(' in value:
                continue
            checked += 1
            if not marked(value[1:-1]):
                problems.append(f'{path}:{line(text, match.start())}: no row is marked {value} (the entry\'s {label})')
    # Advanced areas light their feature's switch while hidden.
    for match in re.finditer(r'\bvar feature\b', text):
        for value in re.findall(r'\(\.\w+,\s*("(?:[^"\\]|\\.)*")\)', block(text, match.end())):
            checked += 1
            if not marked(value[1:-1]):
                problems.append(f'{path}:{line(text, match.start())}: no row is marked {value} (an area\'s feature)')

for problem in problems:
    print(problem)
print(f'{checked} mark(s) checked, {len(problems)} problem(s)')
sys.exit(1 if problems else 0)
