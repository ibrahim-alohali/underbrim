#!/usr/bin/env python3
"""Every string in every language the app ships, with the English placeholders.

The shipped languages are the ones the String Catalogs contain: a language that
covers only part of the strings, or is missing from one catalog, fails, so the
app never shows a half-translated language. Run from the repository root:
python3 scripts/check-translations.py
"""
import json
import plistlib
import re
import sys
from collections import Counter

CATALOGS = ['Underbrim/Localizable.xcstrings', 'Underbrim/InfoPlist.xcstrings',
            'UnderbrimHelper/InfoPlist.xcstrings']
# A format specifier: position, flags, width and precision ("%2$@", "%02d", "%.1f"). Not
# the space flag, which Swift never writes: "100 % de" is a stray %, not a placeholder.
SPEC = re.compile(r'%(?:(\d+)\$)?[-+#0]*\d*(?:\.\d+)?(lld|ld|d|llu|lu|u|lf|f|@)')
KIND = {'lld': 'int', 'ld': 'int', 'd': 'int', 'llu': 'int', 'lu': 'int', 'u': 'int', '@': 'object'}
# The plural forms a language needs (CLDR); the others need "other".
PLURALS = {'ar': {'zero', 'one', 'two', 'few', 'many', 'other'}, 'ru': {'one', 'few', 'many', 'other'}}
# Forms for one number only, which may leave the count out ("Eine Minute"; Arabic
# says "two minutes" in one word). Not "one" in French and Portuguese (0 too) or
# Russian (21 too).
ONE_NUMBER = {'ar': {'zero', 'one', 'two'}, 'de': {'one'}, 'en': {'one'}, 'es': {'one'}, 'it': {'one'}, 'tr': {'one'}}


def placeholders(text):
    found = []
    for n, m in enumerate(SPEC.finditer(text.replace('%%', '')), start=1):
        found.append((int(m.group(1) or n), KIND.get(m.group(2), 'float')))
    return sorted(found)


def units(localization):
    """A localization's string units: one, or one per plural form. None for a
    shape this script can't check (substitutions, other variations)."""
    if 'substitutions' in localization:
        return None
    if 'stringUnit' in localization:
        return {'': localization['stringUnit']}
    variations = localization.get('variations', {})
    if set(variations) == {'plural'}:
        return {name: form['stringUnit'] for name, form in variations['plural'].items()}
    return None


problems = []
catalogs = {path: json.load(open(path, encoding='utf-8'))['strings'] for path in CATALOGS}
# Every catalog needs every language: one missing from InfoPlist would show English permission prompts.
languages = sorted({lang for strings in catalogs.values() for entry in strings.values()
                    for lang in entry.get('localizations', {})} - {'en'})
for path, strings in catalogs.items():
    for key, entry in strings.items():
        if not key or entry.get('shouldTranslate') is False:
            continue
        localizations = entry.get('localizations', {})
        english = units(localizations['en']) if 'en' in localizations else {'': {'value': key}}
        if english is None:
            problems.append(f"{path}: en in a shape this script can't check: {key!r}")
            continue
        english_text = (english.get('other') or english.get('') or {'value': key})['value']
        expected = placeholders(english_text)
        for lang in languages:
            if lang not in localizations:
                problems.append(f'{path}: {lang} missing: {key!r}')
                continue
            texts = units(localizations[lang])
            if texts is None:
                problems.append(f"{path}: {lang} in a shape this script can't check: {key!r}")
                continue
            needed = PLURALS.get(lang, {'other'})
            if '' not in texts and not needed <= set(texts):
                problems.append(f'{path}: {lang} plural without {sorted(needed - set(texts))}: {key!r}')
            for name, unit in texts.items():
                text = unit['value']
                found = placeholders(text)
                if unit.get('state') != 'translated':
                    problems.append(f'{path}: {lang} not marked translated: {key!r}')
                if not text.strip() and english_text.strip():
                    problems.append(f'{path}: {lang} empty: {key!r}')
                elif found != expected and not (name in ONE_NUMBER.get(lang, ()) and not Counter(found) - Counter(expected)):
                    problems.append(f'{path}: {lang} placeholders differ from the English: {key!r} -> {text!r}')
                elif expected and '%' in SPEC.sub('', text.replace('%%', '')):
                    # In a format string String(format:) reads one anyway: a garbage value, or a
                    # crash. (A string with no placeholders isn't formatted: "100 %" is fine.)
                    problems.append(f'{path}: {lang} has a % that starts no placeholder (write %%): {key!r} -> {text!r}')

# The catalog's English permission prompts and copyright line are the ones
# Info.plist and the build settings give (any target's), not an older wording.
def unquote(value):
    if not value.startswith('"'):
        return value
    return re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), value[1:-1])


settings = {}
project = open('Underbrim.xcodeproj/project.pbxproj', encoding='utf-8').read()
for key, value in re.findall(r'INFOPLIST_KEY_(\w+) = ("(?:[^"\\]|\\.)*"|[^;\s]+);', project):
    settings.setdefault(key, set()).add(unquote(value))
info = plistlib.load(open('Underbrim/Info.plist', 'rb'))
for key, entry in catalogs['Underbrim/InfoPlist.xcstrings'].items():
    english = entry.get('localizations', {}).get('en', {}).get('stringUnit', {}).get('value')
    sources = settings.get(key) or ({info[key]} if isinstance(info.get(key), str) else set())
    if isinstance(english, str) and sources and english not in sources:
        problems.append(f'Underbrim/InfoPlist.xcstrings: en differs from Info.plist or the build settings: {key!r}')

for problem in problems:
    print(problem)
print(f'{len(problems)} problem(s)')
sys.exit(1 if problems else 0)
