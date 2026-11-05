#!/usr/bin/env python3
"""
merge_dbs.py
============
Merges ./ao3_tag_seeds.db (old) into ./output/ao3_tag_seeds.db (new).

Rules:
  - New DB wins on all conflicts (tag_type, last_fetched, scrape_log status, etc.)
  - Old DB contributes anything not already present in the new DB.
  - FK integrity is preserved by resolving canonical_tags by NAME, not integer id.

Result: ./output/ao3_tag_seeds.db is updated in place.
        ./ao3_tag_seeds.db is not modified.

Usage:
    python3 merge_dbs.py [--dry-run]
"""

import sqlite3
import argparse
import sys
from pathlib import Path

OLD_DB  = Path("./ao3_tag_seeds.db")
NEW_DB  = Path("./output/ao3_tag_seeds.db")


def merge(old: sqlite3.Connection, new: sqlite3.Connection, dry_run: bool):
    new.execute("PRAGMA foreign_keys=OFF")  # we manage integrity manually during merge
    new.execute("BEGIN")

    # ── 1. canonical_tags ─────────────────────────────────────────────────────
    # New DB wins: DO UPDATE only sets tag_type/last_fetched from old when the
    # new row still has the default/unknown values.
    old_canonicals = old.execute(
        "SELECT name, tag_type, last_fetched FROM canonical_tags"
    ).fetchall()

    inserted_ct = updated_ct = skipped_ct = 0
    for name, tag_type, last_fetched in old_canonicals:
        existing = new.execute(
            "SELECT id, tag_type, last_fetched FROM canonical_tags WHERE name=?", (name,)
        ).fetchone()
        if existing is None:
            new.execute(
                "INSERT INTO canonical_tags(name, tag_type, last_fetched) VALUES (?,?,?)",
                (name, tag_type, last_fetched),
            )
            inserted_ct += 1
        else:
            # New DB wins — only fill in genuinely missing info.
            new_type    = existing[1]
            new_fetched = existing[2]
            update_type    = new_type    in ("unknown", None) and tag_type    not in ("unknown", None)
            update_fetched = new_fetched is None              and last_fetched is not None
            if update_type or update_fetched:
                new.execute(
                    "UPDATE canonical_tags SET tag_type=?, last_fetched=? WHERE id=?",
                    (
                        tag_type    if update_type    else new_type,
                        last_fetched if update_fetched else new_fetched,
                        existing[0],
                    ),
                )
                updated_ct += 1
            else:
                skipped_ct += 1

    print(f"canonical_tags : {inserted_ct} inserted, {updated_ct} updated, {skipped_ct} skipped")

    # ── 2. tag_synonyms ───────────────────────────────────────────────────────
    # synonym PK is the synonym text itself; canonical_id must be remapped to
    # the new DB's id for the same canonical name.
    old_synonyms = old.execute("""
        SELECT s.synonym, c.name
        FROM tag_synonyms s
        JOIN canonical_tags c ON c.id = s.canonical_id
    """).fetchall()

    inserted_syn = skipped_syn = 0
    for synonym, canon_name in old_synonyms:
        new_canon = new.execute(
            "SELECT id FROM canonical_tags WHERE name=?", (canon_name,)
        ).fetchone()
        if new_canon is None:
            # Canonical wasn't merged above somehow — skip (shouldn't happen).
            print(f"  WARNING: canonical not found for synonym {synonym!r} → {canon_name!r}", file=sys.stderr)
            continue
        result = new.execute(
            "INSERT INTO tag_synonyms(synonym, canonical_id) VALUES (?,?) "
            "ON CONFLICT(synonym) DO NOTHING",   # new DB wins — don't overwrite
            (synonym, new_canon[0]),
        )
        if result.rowcount:
            inserted_syn += 1
        else:
            skipped_syn += 1

    print(f"tag_synonyms   : {inserted_syn} inserted, {skipped_syn} skipped (new DB kept)")

    # ── 3. tag_parent_links ───────────────────────────────────────────────────
    # Remap both child_id and parent_id via canonical name.
    old_parents = old.execute("""
        SELECT child.name, parent.name
        FROM tag_parent_links l
        JOIN canonical_tags child  ON child.id  = l.child_id
        JOIN canonical_tags parent ON parent.id = l.parent_id
    """).fetchall()

    inserted_pl = skipped_pl = 0
    for child_name, parent_name in old_parents:
        child_row  = new.execute("SELECT id FROM canonical_tags WHERE name=?", (child_name,)).fetchone()
        parent_row = new.execute("SELECT id FROM canonical_tags WHERE name=?", (parent_name,)).fetchone()
        if not child_row or not parent_row:
            print(f"  WARNING: missing node for parent link {child_name!r} → {parent_name!r}", file=sys.stderr)
            continue
        result = new.execute(
            "INSERT INTO tag_parent_links(child_id, parent_id) VALUES (?,?) "
            "ON CONFLICT DO NOTHING",
            (child_row[0], parent_row[0]),
        )
        if result.rowcount:
            inserted_pl += 1
        else:
            skipped_pl += 1

    print(f"tag_parent_links : {inserted_pl} inserted, {skipped_pl} skipped")

    # ── 4. tag_subtag_sections ────────────────────────────────────────────────
    old_sections = old.execute("""
        SELECT child.name, parent.name, s.section
        FROM tag_subtag_sections s
        JOIN canonical_tags child  ON child.id  = s.child_id
        JOIN canonical_tags parent ON parent.id = s.parent_id
    """).fetchall()

    inserted_ss = skipped_ss = 0
    for child_name, parent_name, section in old_sections:
        child_row  = new.execute("SELECT id FROM canonical_tags WHERE name=?", (child_name,)).fetchone()
        parent_row = new.execute("SELECT id FROM canonical_tags WHERE name=?", (parent_name,)).fetchone()
        if not child_row or not parent_row:
            continue
        result = new.execute(
            "INSERT INTO tag_subtag_sections(child_id, parent_id, section) VALUES (?,?,?) "
            "ON CONFLICT DO NOTHING",
            (child_row[0], parent_row[0], section),
        )
        if result.rowcount:
            inserted_ss += 1
        else:
            skipped_ss += 1

    print(f"tag_subtag_sections : {inserted_ss} inserted, {skipped_ss} skipped")

    # ── 5. scrape_log ─────────────────────────────────────────────────────────
    # New DB wins — only add entries missing from new DB entirely.
    old_log = old.execute(
        "SELECT tag_name, scraped_at, status FROM scrape_log"
    ).fetchall()

    inserted_log = skipped_log = 0
    for tag_name, scraped_at, status in old_log:
        result = new.execute(
            "INSERT INTO scrape_log(tag_name, scraped_at, status) VALUES (?,?,?) "
            "ON CONFLICT DO NOTHING",
            (tag_name, scraped_at, status),
        )
        if result.rowcount:
            inserted_log += 1
        else:
            skipped_log += 1

    print(f"scrape_log     : {inserted_log} inserted, {skipped_log} skipped (new DB kept)")

    # ── Commit or rollback ────────────────────────────────────────────────────
    if dry_run:
        new.execute("ROLLBACK")
        print("\nDry-run — no changes written.")
    else:
        new.execute("COMMIT")
        new.execute("PRAGMA foreign_keys=ON")
        new.execute("PRAGMA integrity_check")
        print("\nMerge complete. New DB updated in place.")


def main():
    parser = argparse.ArgumentParser(description="Merge old ao3_tag_seeds.db into new one.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would change without writing anything.")
    args = parser.parse_args()

    if not OLD_DB.exists():
        print(f"ERROR: old DB not found at {OLD_DB}", file=sys.stderr)
        sys.exit(1)
    if not NEW_DB.exists():
        print(f"ERROR: new DB not found at {NEW_DB}", file=sys.stderr)
        sys.exit(1)

    old = sqlite3.connect(str(OLD_DB))
    new = sqlite3.connect(str(NEW_DB))
    old.row_factory = sqlite3.Row

    try:
        merge(old, new, dry_run=args.dry_run)
    finally:
        old.close()
        new.close()


if __name__ == "__main__":
    main()
