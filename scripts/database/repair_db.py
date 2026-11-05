#!/usr/bin/env python3
"""
repair_db.py
============
Fixes canonical_tags rows whose names contain undecoded AO3 escape sequences
(e.g. "Hurt*s*Comfort" instead of "Hurt/Comfort").

For each polluted row the script either:
  - MERGES it into the existing decoded row (re-pointing all FK references),
  - or RENAMES it in-place if no decoded counterpart exists yet.

Synonyms, parent links, and subtag-section edges are all re-wired so that
nothing points at a deleted row.  A dry-run mode prints what would happen
without touching the database.

Usage:
    python3 repair_db.py [--db ./output/ao3_tag_seeds.db] [--dry-run]
"""

import argparse
import sqlite3
from pathlib import Path
from urllib.parse import unquote

# ---------------------------------------------------------------------------
# AO3 decode (unquote-first order — matches the fixed scraper)
# ---------------------------------------------------------------------------

AO3_DECODE = {"*s*": "/", "*a*": "&", "*d*": ".", "*q*": "?", "*h*": "#"}

def ao3_decode(s: str) -> str:
    s = unquote(s)
    for enc, dec in AO3_DECODE.items():
        s = s.replace(enc, dec)
    return s

def needs_decode(name: str) -> bool:
    return any(esc in name for esc in AO3_DECODE)

# ---------------------------------------------------------------------------
# Merge helpers
# ---------------------------------------------------------------------------

def _retarget_synonyms(conn, old_id: int, new_id: int, dry: bool):
    """Point tag_synonyms.canonical_id from old_id → new_id."""
    rows = conn.execute(
        "SELECT synonym FROM tag_synonyms WHERE canonical_id = ?", (old_id,)
    ).fetchall()
    for (syn,) in rows:
        # Check for a conflict (synonym already mapped to new_id)
        exists = conn.execute(
            "SELECT 1 FROM tag_synonyms WHERE synonym = ? AND canonical_id = ?",
            (syn, new_id),
        ).fetchone()
        if exists:
            print(f"    [synonym] DROP duplicate: {syn!r} already → {new_id}")
            if not dry:
                conn.execute(
                    "DELETE FROM tag_synonyms WHERE synonym = ? AND canonical_id = ?",
                    (syn, old_id),
                )
        else:
            print(f"    [synonym] RETARGET: {syn!r} → canonical_id {new_id}")
            if not dry:
                conn.execute(
                    "UPDATE tag_synonyms SET canonical_id = ? "
                    "WHERE synonym = ? AND canonical_id = ?",
                    (new_id, syn, old_id),
                )


def _retarget_parent_links(conn, old_id: int, new_id: int, dry: bool):
    """Re-wire tag_parent_links edges that reference old_id on either end."""
    # child side
    for (parent_id,) in conn.execute(
        "SELECT parent_id FROM tag_parent_links WHERE child_id = ?", (old_id,)
    ).fetchall():
        target_parent = new_id if parent_id != old_id else new_id  # self-loop guard
        exists = conn.execute(
            "SELECT 1 FROM tag_parent_links WHERE child_id = ? AND parent_id = ?",
            (new_id, parent_id),
        ).fetchone()
        if exists or new_id == parent_id:
            print(f"    [parent_link child] DROP: child={new_id} parent={parent_id}")
            if not dry:
                conn.execute(
                    "DELETE FROM tag_parent_links WHERE child_id = ? AND parent_id = ?",
                    (old_id, parent_id),
                )
        else:
            print(f"    [parent_link child] RETARGET: child {old_id}→{new_id}, parent={parent_id}")
            if not dry:
                conn.execute(
                    "UPDATE tag_parent_links SET child_id = ? "
                    "WHERE child_id = ? AND parent_id = ?",
                    (new_id, old_id, parent_id),
                )

    # parent side
    for (child_id,) in conn.execute(
        "SELECT child_id FROM tag_parent_links WHERE parent_id = ?", (old_id,)
    ).fetchall():
        exists = conn.execute(
            "SELECT 1 FROM tag_parent_links WHERE child_id = ? AND parent_id = ?",
            (child_id, new_id),
        ).fetchone()
        if exists or child_id == new_id:
            print(f"    [parent_link parent] DROP: child={child_id} parent={new_id}")
            if not dry:
                conn.execute(
                    "DELETE FROM tag_parent_links WHERE child_id = ? AND parent_id = ?",
                    (child_id, old_id),
                )
        else:
            print(f"    [parent_link parent] RETARGET: child={child_id}, parent {old_id}→{new_id}")
            if not dry:
                conn.execute(
                    "UPDATE tag_parent_links SET parent_id = ? "
                    "WHERE child_id = ? AND parent_id = ?",
                    (new_id, child_id, old_id),
                )


def _retarget_subtag_sections(conn, old_id: int, new_id: int, dry: bool):
    """Re-wire tag_subtag_sections edges that reference old_id."""
    # child side
    for (parent_id, section) in conn.execute(
        "SELECT parent_id, section FROM tag_subtag_sections WHERE child_id = ?", (old_id,)
    ).fetchall():
        exists = conn.execute(
            "SELECT 1 FROM tag_subtag_sections WHERE child_id = ? AND parent_id = ?",
            (new_id, parent_id),
        ).fetchone()
        if exists or new_id == parent_id:
            if not dry:
                conn.execute(
                    "DELETE FROM tag_subtag_sections WHERE child_id = ? AND parent_id = ?",
                    (old_id, parent_id),
                )
        else:
            if not dry:
                conn.execute(
                    "UPDATE tag_subtag_sections SET child_id = ? "
                    "WHERE child_id = ? AND parent_id = ?",
                    (new_id, old_id, parent_id),
                )

    # parent side
    for (child_id, section) in conn.execute(
        "SELECT child_id, section FROM tag_subtag_sections WHERE parent_id = ?", (old_id,)
    ).fetchall():
        exists = conn.execute(
            "SELECT 1 FROM tag_subtag_sections WHERE child_id = ? AND parent_id = ?",
            (child_id, new_id),
        ).fetchone()
        if exists or child_id == new_id:
            if not dry:
                conn.execute(
                    "DELETE FROM tag_subtag_sections WHERE child_id = ? AND parent_id = ?",
                    (child_id, old_id),
                )
        else:
            if not dry:
                conn.execute(
                    "UPDATE tag_subtag_sections SET parent_id = ? "
                    "WHERE child_id = ? AND parent_id = ?",
                    (new_id, child_id, old_id),
                )

# ---------------------------------------------------------------------------
# Main repair logic
# ---------------------------------------------------------------------------

def repair(conn: sqlite3.Connection, dry: bool):
    polluted = conn.execute(
        "SELECT id, name, tag_type FROM canonical_tags ORDER BY id"
    ).fetchall()
    polluted = [(id_, name, tt) for id_, name, tt in polluted if needs_decode(name)]

    fixed = 0
    if not polluted:
        print("No undecoded canonical tag names found — skipping Pass 1.")
    else:
        print(f"Found {len(polluted)} undecoded canonical tag(s):\n")
    for old_id, raw_name, raw_type in polluted:
        decoded_name = ao3_decode(raw_name)
        print(f"  [{old_id}] {raw_name!r}  →  {decoded_name!r}  (type={raw_type!r})")

        # Does a decoded row already exist?
        existing = conn.execute(
            "SELECT id, tag_type FROM canonical_tags WHERE name = ?", (decoded_name,)
        ).fetchone()

        if existing:
            new_id, new_type = existing
            # Always keep the decoded row's type unchanged.
            # The raw row's type came from a mis-stored tag and is not reliable —
            # e.g. a Fandom-category tag stored without decoding would wrongly
            # brand the surviving additional-tag row as 'fandom'.
            print(f"    MERGE into existing id={new_id} (keeping type={new_type!r}, discarding raw type={raw_type!r})")

            _retarget_synonyms(conn, old_id, new_id, dry)
            _retarget_parent_links(conn, old_id, new_id, dry)
            _retarget_subtag_sections(conn, old_id, new_id, dry)

            print(f"    DELETE canonical_tags id={old_id} ({raw_name!r})")
            if not dry:
                conn.execute("DELETE FROM canonical_tags WHERE id = ?", (old_id,))

        else:
            # No decoded counterpart — just rename in-place.
            print(f"    RENAME in-place (no existing decoded row)")
            if not dry:
                conn.execute(
                    "UPDATE canonical_tags SET name = ? WHERE id = ?",
                    (decoded_name, old_id),
                )

        fixed += 1
        print()

    if not dry:
        conn.commit()

    # ── Pass 2: decode synonym names ─────────────────────────────────────────
    # Synonyms can also have been stored with raw *s* / *a* etc. in their names
    # (either pre-existing, or added by a previous run of this script).
    # Decode each one in-place; drop if the decoded form already exists.
    print("\nDecoding synonym names...")
    syn_rows = conn.execute(
        "SELECT synonym, canonical_id FROM tag_synonyms"
    ).fetchall()
    syn_fixed = 0
    for raw_syn, cid in syn_rows:
        if not needs_decode(raw_syn):
            continue
        decoded_syn = ao3_decode(raw_syn)
        print(f"  synonym {raw_syn!r}  →  {decoded_syn!r}")
        existing = conn.execute(
            "SELECT 1 FROM tag_synonyms WHERE synonym = ?", (decoded_syn,)
        ).fetchone()
        if existing:
            print(f"    DROP (decoded form already present)")
            if not dry:
                conn.execute(
                    "DELETE FROM tag_synonyms WHERE synonym = ?", (raw_syn,)
                )
        else:
            print(f"    RENAME in-place")
            if not dry:
                conn.execute(
                    "UPDATE tag_synonyms SET synonym = ? WHERE synonym = ?",
                    (decoded_syn, raw_syn),
                )
        syn_fixed += 1

    # ── Pass 3: reset tag_type='fandom' on tags never directly scraped ─────────
    # A previous repair run may have propagated a fandom type from a polluted raw
    # row onto a surviving decoded row (e.g. Hurt/Comfort).  Any canonical whose
    # type is 'fandom' but that has no successful scrape_log entry got its type
    # from a merge, not from an actual AO3 page — reset it to 'unknown'.
    print("\nChecking for type pollution from previous repair runs...")
    type_rows = conn.execute("""
        SELECT c.id, c.name
        FROM canonical_tags c
        LEFT JOIN scrape_log l ON l.tag_name = c.name AND l.status = 'ok'
        WHERE c.tag_type = 'fandom'
          AND l.tag_name IS NULL
    """).fetchall()
    type_fixed = 0
    for tid, tname in type_rows:
        print(f"  RESET type: [{tid}] {tname!r}  fandom → unknown")
        if not dry:
            conn.execute(
                "UPDATE canonical_tags SET tag_type = 'unknown' WHERE id = ?", (tid,)
            )
        type_fixed += 1

    if not dry:
        conn.commit()
        print(f"\nRepaired {fixed} canonical tag(s), {syn_fixed} synonym(s), {type_fixed} type(s).")
        print("Run `pytest test_ao3_scraper.py --db <path>` to verify.")
    else:
        print(f"\nDry run — {fixed} canonical(s), {syn_fixed} synonym(s), {type_fixed} type(s) would be repaired.")
        print("Re-run without --dry-run to apply.")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Repair undecoded AO3 tag names in ao3_tag_seeds.db")
    parser.add_argument("--db", default="./output/ao3_tag_seeds.db", metavar="PATH")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print what would change without modifying the database")
    args = parser.parse_args()

    db_path = Path(args.db)
    if not db_path.exists():
        print(f"Error: database not found at {db_path}")
        raise SystemExit(1)

    conn = sqlite3.connect(str(db_path))
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA journal_mode=WAL")

    try:
        repair(conn, dry=args.dry_run)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
