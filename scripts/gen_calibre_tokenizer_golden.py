# SPDX-License-Identifier: GPL-3.0-only
"""Generate AmbrosiaTests/calibre_tokenizer_golden.json from Calibre's own tokenizer.

Run by a maintainer with Calibre installed:

    calibre-debug -e scripts/gen_calibre_tokenizer_golden.py > AmbrosiaTests/calibre_tokenizer_golden.json

Optional: pass a plain-text file after `--` to add public-domain paragraphs, for example
a Project Gutenberg book:

    calibre-debug -e scripts/gen_calibre_tokenizer_golden.py -- book.txt > ...

The call mirrors calibre/db/tests/fts.py: NFKC-normalize, then
tokenize(text, remove_diacritics, flags) with positional arguments (the C binding parses
a tuple, not keywords). Versions in `meta` are read from Calibre, never hard-coded.
"""
import json
import sys
import unicodedata


def corpus(extra_paragraphs):
    cases = [
        'Some w\u00f6rds', "don't 'bug'", 'a,b. c', 'a*b+c', 'a(b[{^c', 'a\U0001F600smile',
        "\u4f60don't\u53eb" + 'mess', '\u4f60\u53eb\u4ec0\u4e48\u540d\u5b57', '\u4f60\u53eb' + 'abc',
        'a\u4f60b\u53eb\u4ec0\u4e48\u540d\u5b57', "don't 'its' w\u00f6rds", "l'hospital", "x'bug'",
        # accents and combining marks
        'caf\u00e9 r\u00e9sum\u00e9 na\u00efve fa\u00e7ade', 'co\u1ed9l', 'cooo\u0302\u0323l',
        # ligatures and case folds
        '\ufb01nd Stra\u00dfe \u03a3\u038a\u03a3\u03a5\u03a6\u039f\u03a3',
        # Turkish dotted I
        '\u0130stanbul I\u0307stanbul',
        # soft hyphen and no-break space
        'co\u00adoperate', 'non\u00a0breaking space',
        # emoji and ZWJ sequences
        '\U0001F468\u200d\U0001F469\u200d\U0001F467 family', '\U0001F44D\U0001F3FD thumbs',
        # numbers and currency
        '$100 3.14 1,000 \u00bd', '\u20ac5 \u00a32 \u00a510',
        # apostrophes and quotes, straight and curly
        'it\u2019s \u2018quoted\u2019 \u201cdouble\u201d "straight" \'single\'',
        # hyphenated and slashed words
        'well-known and/or either/or re-init', 'C++ and C# and .NET',
        # CJK
        '\u4f60\u597d\u4e16\u754c', '\u65e5\u672c\u8a9e\u306e\u30c6\u30ad\u30b9\u30c8', '\ud55c\uad6d\uc5b4 \ud14d\uc2a4\ud2b8',
        # Thai
        '\u0e2a\u0e27\u0e31\u0e2a\u0e14\u0e35\u0e04\u0e23\u0e31\u0e1a',
        # mixed scripts
        'Hello\u4e16\u754c\u3053\u3093\u306b\u3061\u306f',
        # RTL
        '\u0645\u0631\u062d\u0628\u0627 \u0628\u0627\u0644\u0639\u0627\u0644\u0645', '\u05e9\u05dc\u05d5\u05dd \u05e2\u05d5\u05dc\u05dd',
        # Cyrillic and Greek
        '\u041f\u0440\u0438\u0432\u0435\u0442 \u043c\u0438\u0440 \u0401\u043b\u043a\u0430', '\u039a\u03b1\u03bb\u03b7\u03bc\u03ad\u03c1\u03b1 \u03ba\u03cc\u03c3\u03bc\u03b5',
        # empty and whitespace-only
        '', '   \n\t ',
    ]
    cases.extend(extra_paragraphs)
    cases.append(synthetic_paragraph())
    return cases


def synthetic_paragraph():
    # Deterministic ~5 KB of English-like text, authored for this repo (no third-party text).
    words = ("the quick brown fox can't jump over lazy dogs while 42 well-known witnesses "
             "watched r\u00e9sum\u00e9 caf\u00e9 \"quoted\" (parenthetical) text, e.g. 3.14 or 1,000 items; "
             "and/or other things").split()
    out, n = [], 0
    while sum(len(w) + 1 for w in out) < 5000:
        out.append(words[(n * 7 + n // 3) % len(words)])
        n += 1
    return ' '.join(out)


def main():
    from calibre.constants import numeric_version
    from calibre_extensions.icu import icu_version, unicode_version
    from calibre_extensions.sqlite_extension import (
        FTS5_TOKENIZE_DOCUMENT, FTS5_TOKENIZE_QUERY, set_ui_language, tokenize)

    set_ui_language('en')
    extra = []
    args = sys.argv[1:]
    if args:
        with open(args[-1], encoding='utf-8') as f:
            paragraphs = [p.strip() for p in f.read().split('\n\n') if len(p.strip()) > 200]
        extra = [p[:5000] for p in paragraphs[:4]]

    result = {
        'meta': {
            'icu_version': icu_version,
            'unicode_version': unicode_version,
            'calibre_version': '.'.join(map(str, numeric_version)),
        },
        'cases': [],
    }
    for text in corpus(extra):
        normalized = unicodedata.normalize('NFKC', text)
        for mode, flags in (('document', FTS5_TOKENIZE_DOCUMENT), ('query', FTS5_TOKENIZE_QUERY)):
            tokens = tokenize(normalized, True, flags)
            result['cases'].append({
                'text': normalized,
                'mode': mode,
                'remove_diacritics': True,
                'tokens': [{'text': t['text'], 'start': t['start'], 'end': t['end'], 'flags': t['flags']} for t in tokens],
            })
    json.dump(result, sys.stdout, ensure_ascii=False, indent=1)
    sys.stdout.write('\n')


if __name__ == '__main__':
    main()
