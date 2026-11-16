#!/usr/bin/env bash
# build_fixtures.sh — pull a small, referentially-closed, randomized fixture
# out of your real metadata.db (and optionally your AO3 tag-seed database)
# for AmbrosiaTests. Requires the `sqlite3` CLI (ships with macOS).
#
# EDIT THE PATHS BELOW, then run: bash build_fixtures.sh
set -euo pipefail

# ---- EDIT THESE -------------------------------------------------------
SRC_CALIBRE_DB="/path/to/your/real/Calibre Library/metadata.db"
SRC_AO3_SEED_DB=""   # optional — path to your AO3 tag-seed .sqlite, or leave empty to skip
TARGET_BOOK_COUNT=20 # total books in the fixture, curated + random padding
TAGS_PER_TYPE=25     # for the AO3 seed fixture, if SRC_AO3_SEED_DB is set
# -------------------------------------------------------------------------

OUT_DIR="./AmbrosiaTests"
mkdir -p "$OUT_DIR"

if [ ! -f "$SRC_CALIBRE_DB" ]; then
  echo "SRC_CALIBRE_DB does not exist: $SRC_CALIBRE_DB" >&2
  exit 1
fi

echo "== Calibre fixture =="

# ---------------------------------------------------------------------------
# 1. Schema — every real table/trigger EXCEPT:
#      - sqlite_sequence: an internal table SQLite auto-creates whenever a
#        table uses AUTOINCREMENT. You can't CREATE it yourself — replaying
#        a raw `.schema` dump that includes it fails with "object name
#        reserved for internal use". It doesn't need to be in the fixture;
#        SQLite recreates it automatically the moment it's needed.
#      - FTS5 virtual tables and their auto-generated shadow tables
#        (_data/_idx/_docsize/_config/_content). Recent Calibre versions add
#        FTS5 tables (e.g. annotations_fts) for its own in-app annotation
#        search — confirmed by reading CalibreFTSLibrary.swift that Ambrosia
#        never touches these; the full-text search Ambrosia actually uses
#        lives in a *separate* full-text-search.db file next to metadata.db,
#        unrelated to this fixture. `.schema` dumps each shadow table's own
#        CREATE TABLE statement, but CREATE VIRTUAL TABLE already creates
#        those shadow tables itself on execution, so replaying the dump
#        verbatim fails with "table already exists" / "reserved for
#        internal use" on the second, redundant CREATE.
#      - Triggers that reference an excluded virtual table anywhere in their
#        body (e.g. Calibre's annotations-sync triggers) — kept, they'd
#        reference a table that no longer exists in the fixture.
#    This was tested against a synthetic AUTOINCREMENT + FTS5 database and
#    confirmed byte-identical to a plain `.schema` dump when no FTS5/
#    AUTOINCREMENT tables are present, so it's a strict superset fix, not a
#    behavior change for simpler libraries.
# ---------------------------------------------------------------------------
sqlite3 "$SRC_CALIBRE_DB" <<'SQL' > "$OUT_DIR/calibre_fixture_schema.sql"
WITH virtual_tables AS (
  SELECT name FROM sqlite_master
  WHERE type='table' AND UPPER(COALESCE(sql,'')) LIKE '%CREATE VIRTUAL TABLE%'
),
shadow_tables AS (
  SELECT sm.name FROM sqlite_master sm, virtual_tables vt
  WHERE sm.type='table'
    AND (
      sm.name = vt.name || '_data' OR
      sm.name = vt.name || '_idx' OR
      sm.name = vt.name || '_docsize' OR
      sm.name = vt.name || '_config' OR
      sm.name = vt.name || '_content'
    )
)
SELECT sql || ';' FROM sqlite_master
WHERE sql IS NOT NULL
  AND name != 'sqlite_sequence'
  AND name NOT LIKE 'sqlite_%'
  AND name NOT IN (SELECT name FROM virtual_tables)
  AND name NOT IN (SELECT name FROM shadow_tables)
  AND NOT (
    type = 'trigger' AND EXISTS (
      SELECT 1 FROM virtual_tables vt WHERE sqlite_master.sql LIKE '%' || vt.name || '%'
    )
  )
ORDER BY rowid;
SQL
echo "wrote $OUT_DIR/calibre_fixture_schema.sql"

# ---------------------------------------------------------------------------
# 2. Data — one sqlite3 session so the TEMP TABLE of chosen book ids persists
#    across every SELECT below. Picks specific edge cases first (each step is
#    best-effort via INSERT OR IGNORE; if your library doesn't have that
#    shape, e.g. no anthology comments, the step just contributes 0 rows),
#    then pads with random books up to TARGET_BOOK_COUNT.
# ---------------------------------------------------------------------------
sqlite3 "$SRC_CALIBRE_DB" <<SQL > "$OUT_DIR/calibre_fixture_data.sql"
CREATE TEMP TABLE fixture_book_ids (id INTEGER PRIMARY KEY);

-- (a) A multi-book series (2-4 books) for SeriesGroupBuilder / series-filter tests
INSERT OR IGNORE INTO fixture_book_ids
SELECT b.id FROM books b
JOIN books_series_link bsl ON bsl.book = b.id
WHERE bsl.series = (
  SELECT series FROM books_series_link
  GROUP BY series HAVING COUNT(*) BETWEEN 2 AND 4
  ORDER BY RANDOM() LIMIT 1
);

-- (b) A second, different multi-book series (so "series A" vs "series B" filter tests have two real options)
INSERT OR IGNORE INTO fixture_book_ids
SELECT b.id FROM books b
JOIN books_series_link bsl ON bsl.book = b.id
WHERE bsl.series = (
  SELECT series FROM books_series_link
  WHERE series NOT IN (
    SELECT bsl2.series FROM books_series_link bsl2
    WHERE bsl2.book IN (SELECT id FROM fixture_book_ids)
  )
  GROUP BY series HAVING COUNT(*) BETWEEN 2 AND 4
  ORDER BY RANDOM() LIMIT 1
);

-- (c) A solo book that is the only member of its series (singleton-series edge case)
INSERT OR IGNORE INTO fixture_book_ids
SELECT b.id FROM books b
JOIN books_series_link bsl ON bsl.book = b.id
WHERE bsl.series IN (SELECT series FROM books_series_link GROUP BY series HAVING COUNT(*) = 1)
ORDER BY RANDOM() LIMIT 1;

-- (d) A book with multiple authors (co-authorship)
INSERT OR IGNORE INTO fixture_book_ids
SELECT book FROM books_authors_link GROUP BY book HAVING COUNT(*) > 1 ORDER BY RANDOM() LIMIT 1;

-- (e) A book whose comment matches Calibre's epub-merge anthology prefix (AnthologyDetector fixture)
INSERT OR IGNORE INTO fixture_book_ids
SELECT book FROM comments WHERE text LIKE '%Anthology containing:%' ORDER BY RANDOM() LIMIT 1;

-- (f) A book with no series and no tags at all (minimal/empty case)
INSERT OR IGNORE INTO fixture_book_ids
SELECT b.id FROM books b
WHERE b.id NOT IN (SELECT book FROM books_series_link)
  AND b.id NOT IN (SELECT book FROM books_tags_link)
ORDER BY RANDOM() LIMIT 1;

-- (g) A couple of books published by "Archive of Our Own" (isAO3PublisherBook path)
INSERT OR IGNORE INTO fixture_book_ids
SELECT bpl.book FROM books_publishers_link bpl
JOIN publishers p ON p.id = bpl.publisher
WHERE TRIM(p.name) = 'Archive of Our Own'
ORDER BY RANDOM() LIMIT 3;

-- (h) Pad with random books up to TARGET_BOOK_COUNT, never negative
INSERT OR IGNORE INTO fixture_book_ids
SELECT id FROM books
WHERE id NOT IN (SELECT id FROM fixture_book_ids)
ORDER BY RANDOM()
LIMIT (SELECT MAX(${TARGET_BOOK_COUNT} - COUNT(*), 0) FROM fixture_book_ids);

-- Dimension tables, filtered to only rows the chosen books actually reference
.mode insert authors
SELECT * FROM authors WHERE id IN (
  SELECT author FROM books_authors_link WHERE book IN (SELECT id FROM fixture_book_ids)
);

.mode insert series
SELECT * FROM series WHERE id IN (
  SELECT series FROM books_series_link WHERE book IN (SELECT id FROM fixture_book_ids)
);

.mode insert tags
SELECT * FROM tags WHERE id IN (
  SELECT tag FROM books_tags_link WHERE book IN (SELECT id FROM fixture_book_ids)
);

.mode insert publishers
SELECT * FROM publishers WHERE id IN (
  SELECT publisher FROM books_publishers_link WHERE book IN (SELECT id FROM fixture_book_ids)
);

-- custom_columns is a small definitions table (label/datatype), not per-book
-- data — safe to dump in full, feeds CustomColumnConfig.autoDetect tests.
.mode insert custom_columns
SELECT * FROM custom_columns;

-- Fact table
.mode insert books
SELECT * FROM books WHERE id IN (SELECT id FROM fixture_book_ids);

-- Link tables
.mode insert books_authors_link
SELECT * FROM books_authors_link WHERE book IN (SELECT id FROM fixture_book_ids);

.mode insert books_series_link
SELECT * FROM books_series_link WHERE book IN (SELECT id FROM fixture_book_ids);

.mode insert books_tags_link
SELECT * FROM books_tags_link WHERE book IN (SELECT id FROM fixture_book_ids);

.mode insert books_publishers_link
SELECT * FROM books_publishers_link WHERE book IN (SELECT id FROM fixture_book_ids);

.mode insert comments
SELECT * FROM comments WHERE book IN (SELECT id FROM fixture_book_ids);
SQL
echo "wrote $OUT_DIR/calibre_fixture_data.sql"

# ---------------------------------------------------------------------------
# 3. Sanity check: load schema + data into a scratch db and verify no
#    foreign-key violations and no SQL errors. This is the same load path
#    CalibreTestFixture.makeTempLibraryRoot() uses (schema.execute then
#    data.execute), so if this passes, the Swift-side fixture loader will too.
# ---------------------------------------------------------------------------
SCRATCH_DB="$(mktemp -t 'calibre_fixture_check.XXXXXX').db"
rm -f "$SCRATCH_DB"
sqlite3 "$SCRATCH_DB" ".read $OUT_DIR/calibre_fixture_schema.sql"
sqlite3 "$SCRATCH_DB" ".read $OUT_DIR/calibre_fixture_data.sql"
echo "-- foreign_key_check (empty output below = clean):"
sqlite3 "$SCRATCH_DB" "PRAGMA foreign_key_check;"
echo "-- row counts in the fixture:"
sqlite3 "$SCRATCH_DB" "
SELECT 'books', COUNT(*) FROM books
UNION ALL SELECT 'authors', COUNT(*) FROM authors
UNION ALL SELECT 'series', COUNT(*) FROM series
UNION ALL SELECT 'tags', COUNT(*) FROM tags
UNION ALL SELECT 'publishers', COUNT(*) FROM publishers
UNION ALL SELECT 'comments', COUNT(*) FROM comments;
"
rm -f "$SCRATCH_DB"

# ---------------------------------------------------------------------------
# 4. Optional: AO3 tag-seed database fixture (canonical_tags / tag_synonyms /
#    tag_parent_links / tag_subtag_sections), for
#    AO3TagSeedDatabaseConfigValidationTests and for seeding an AmbrosiaMetaDB
#    instance's own tables in TagExpansionResolverTests. Column names below
#    (id/name/tag_type, synonym/canonical_id, child_id/parent_id, section)
#    are exactly what AmbrosiaMetaDB.importConfiguredAO3TagSeedsIfNeeded()
#    selects from this database (AmbrosiaMetaDB.swift:629-654), so they're
#    not guessed — but run the `.schema` line below yourself first and eyeball
#    it, since your seed db may have extra columns (e.g. an autoincrement id
#    on tag_synonyms) that `SELECT *` will faithfully carry over, which is
#    fine as long as the fixture schema dump below matches.
# ---------------------------------------------------------------------------
if [ -n "$SRC_AO3_SEED_DB" ]; then
  if [ ! -f "$SRC_AO3_SEED_DB" ]; then
    echo "SRC_AO3_SEED_DB does not exist: $SRC_AO3_SEED_DB" >&2
    exit 1
  fi

  echo "== AO3 tag-seed fixture =="

  sqlite3 "$SRC_AO3_SEED_DB" \
    ".schema canonical_tags" \
    ".schema tag_synonyms" \
    ".schema tag_parent_links" \
    ".schema tag_subtag_sections" \
    > "$OUT_DIR/ao3_tag_seed_fixture_schema.sql"
  echo "wrote $OUT_DIR/ao3_tag_seed_fixture_schema.sql"

  sqlite3 "$SRC_AO3_SEED_DB" <<SQL > "$OUT_DIR/ao3_tag_seed_fixture_data.sql"
CREATE TEMP TABLE chosen_tag_ids (id INTEGER PRIMARY KEY);

-- Stratified random sample: up to TAGS_PER_TYPE canonical tags per tag_type,
-- so the fixture has real fandom/relationship/character/freeform/etc. coverage
-- rather than whatever one type happens to dominate a random flat sample.
INSERT INTO chosen_tag_ids
SELECT id FROM (
  SELECT id, ROW_NUMBER() OVER (PARTITION BY tag_type ORDER BY RANDOM()) AS rn
  FROM canonical_tags
) WHERE rn <= ${TAGS_PER_TYPE};

-- Single-hop closure: pull in any canonical_tags row referenced as a
-- parent/child of an already-chosen tag via tag_parent_links or
-- tag_subtag_sections, so hierarchy edges in the fixture never dangle.
INSERT OR IGNORE INTO chosen_tag_ids
SELECT parent_id FROM tag_parent_links WHERE child_id IN (SELECT id FROM chosen_tag_ids)
UNION
SELECT child_id FROM tag_parent_links WHERE parent_id IN (SELECT id FROM chosen_tag_ids)
UNION
SELECT parent_id FROM tag_subtag_sections WHERE child_id IN (SELECT id FROM chosen_tag_ids)
UNION
SELECT child_id FROM tag_subtag_sections WHERE parent_id IN (SELECT id FROM chosen_tag_ids);

.mode insert canonical_tags
SELECT * FROM canonical_tags WHERE id IN (SELECT id FROM chosen_tag_ids);

.mode insert tag_synonyms
SELECT * FROM tag_synonyms WHERE canonical_id IN (SELECT id FROM chosen_tag_ids);

.mode insert tag_parent_links
SELECT * FROM tag_parent_links
WHERE child_id IN (SELECT id FROM chosen_tag_ids) AND parent_id IN (SELECT id FROM chosen_tag_ids);

.mode insert tag_subtag_sections
SELECT * FROM tag_subtag_sections
WHERE child_id IN (SELECT id FROM chosen_tag_ids) AND parent_id IN (SELECT id FROM chosen_tag_ids);
SQL
  echo "wrote $OUT_DIR/ao3_tag_seed_fixture_data.sql"

  SCRATCH_DB2="$(mktemp -t 'ao3_seed_fixture_check.XXXXXX').db"
  rm -f "$SCRATCH_DB2"
  sqlite3 "$SCRATCH_DB2" ".read $OUT_DIR/ao3_tag_seed_fixture_schema.sql"
  sqlite3 "$SCRATCH_DB2" ".read $OUT_DIR/ao3_tag_seed_fixture_data.sql"
  echo "-- row counts in the AO3 seed fixture:"
  sqlite3 "$SCRATCH_DB2" "
  SELECT 'canonical_tags', COUNT(*) FROM canonical_tags
  UNION ALL SELECT 'tag_synonyms', COUNT(*) FROM tag_synonyms
  UNION ALL SELECT 'tag_parent_links', COUNT(*) FROM tag_parent_links
  UNION ALL SELECT 'tag_subtag_sections', COUNT(*) FROM tag_subtag_sections;
  "
  rm -f "$SCRATCH_DB2"
fi

echo "== Done =="
echo "Add $OUT_DIR/*.sql to the AmbrosiaTests target's 'Copy Bundle Resources'"
echo "build phase in Xcode (or re-run 'xcodegen generate' if project.yml is"
echo "updated to declare AmbrosiaTests' resources: explicitly), then re-check"
echo "whether XcodeGen already picked them up as resources automatically."
