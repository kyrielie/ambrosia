#!/usr/bin/env python3
"""
fix_tag_types.py
================
Reads a text file of AO3 tag URLs and sets tag_type = 'additional'
for each matching tag in the database.

Usage:
    python3 fix_tag_types.py tags.txt
    python3 fix_tag_types.py tags.txt --db /path/to/ao3_tag_seeds.db
"""

import argparse
import sqlite3
import sys
from pathlib import Path
from urllib.parse import unquote

AO3_DECODE = {"*s*": "/", "*a*": "&", "*d*": ".", "*q*": "?", "*h*": "#"}

def ao3_decode(s: str) -> str:
    s = unquote(s)
    for enc, dec in AO3_DECODE.items():
        s = s.replace(enc, dec)
    return s

def url_to_tag_name(url: str) -> str:
    path = url.strip().split("/tags/", 1)[-1].split("?")[0].split("/")[0]
    return ao3_decode(path)

def main():
    parser = argparse.ArgumentParser(description="Fix tag_type to 'additional' for a list of tag URLs")
    parser.add_argument("input", help="Text file with one AO3 tag URL per line")
    parser.add_argument("--db", default="./output/ao3_tag_seeds.db", help="Path to SQLite DB")
    parser.add_argument("--dry-run", action="store_true", help="Print changes without writing")
    args = parser.parse_args()

    lines = Path(args.input).read_text(encoding="utf-8").splitlines()
    tag_names = [
        url_to_tag_name(line)
        for line in lines
        if line.strip() and not line.strip().startswith("#")
    ]

    if not tag_names:
        print("No URLs found in input file.")
        sys.exit(1)

    conn = sqlite3.connect(args.db)

    fixed, not_found, already_correct = [], [], []

    for name in tag_names:
        row = conn.execute(
            "SELECT id, tag_type FROM canonical_tags WHERE name=?", (name,)
        ).fetchone()
        if row is None:
            not_found.append(name)
        elif row[1] == "additional":
            already_correct.append(name)
        else:
            if not args.dry_run:
                conn.execute(
                    "UPDATE canonical_tags SET tag_type='additional' WHERE id=?", (row[0],)
                )
            fixed.append((name, row[1]))

    if not args.dry_run:
        conn.commit()
    conn.close()

    prefix = "[DRY RUN] " if args.dry_run else ""

    for name, old_type in fixed:
        print(f"{prefix}FIXED:   {name!r}  ({old_type} → additional)")
    for name in already_correct:
        print(f"OK:      {name!r}  (already additional)")
    for name in not_found:
        print(f"MISSING: {name!r}  (not in database)")

    print(f"\n{prefix}{len(fixed)} fixed, {len(already_correct)} already correct, {len(not_found)} not found.")

if __name__ == "__main__":
    main()
