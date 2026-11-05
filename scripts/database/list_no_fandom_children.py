#!/usr/bin/env python3
"""
list_no_fandom_children.py
==========================
Prints all canonical tags that are direct children of "No Fandom"
in the tag hierarchy, along with their current tag_type.

Usage:
    python3 list_no_fandom_children.py [path/to/ao3_tag_seeds.db]

Defaults to ./ao3_tag_seeds.db if no path is given.
"""

import sqlite3
import sys
from pathlib import Path

db_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("./ao3_tag_seeds.db")

if not db_path.exists():
    print(f"ERROR: DB not found at {db_path}", file=sys.stderr)
    sys.exit(1)

conn = sqlite3.connect(str(db_path))

rows = conn.execute("""
    SELECT c.name, c.tag_type
    FROM canonical_tags c
    JOIN tag_parent_links l  ON l.child_id  = c.id
    JOIN canonical_tags   p  ON p.id        = l.parent_id
    WHERE p.name = 'No Fandom'
    ORDER BY c.tag_type, c.name
""").fetchall()

conn.close()

if not rows:
    print("No children found for 'No Fandom'.")
    sys.exit(0)

print(f"{'NAME':<50}  TYPE")
print("-" * 65)
for name, tag_type in rows:
    print(f"{name:<50}  {tag_type}")
print(f"\nTotal: {len(rows)}")
