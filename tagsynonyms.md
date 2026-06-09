# Phase 11 — Tag Seeds Handoff
## For the Swift engineer implementing `TagSynonymResolver`

---

## What the scraper produced

Running `ao3_seed_scraper.py` against your library's tag URLs produces two files:

```
output/
  ao3_tag_seeds.db     ← SQLite, use for inspection and for generating Swift
  AO3TagSeeds.swift    ← drop into the Xcode project, never edit by hand
```

Regenerate `AO3TagSeeds.swift` from an existing DB at any time without re-scraping:

```bash
python3 ao3_seed_scraper.py --swift-only --output-dir ./output
```

---

## Database schema

Five tables. Three are yours to use at runtime; two are scraper bookkeeping only.

### `canonical_tags` — one row per authoritative tag name

```sql
id           INTEGER PRIMARY KEY
name         TEXT UNIQUE          -- display name, e.g. "Hurt/Comfort"
tag_type     TEXT                 -- 'fandom'|'relationship'|'character'|'additional'|'unknown'
last_fetched TEXT                 -- ISO-8601 or NULL (NULL = came from seed, never live-fetched)
```

This is the lookup target. When you resolve a tag, you end up here.

### `tag_synonyms` — many-to-one from variant names to a canonical

```sql
synonym      TEXT PRIMARY KEY     -- the variant, e.g. "H/C", "hurt and comfort"
canonical_id INTEGER → canonical_tags.id
```

Every merged tag on AO3 ("X has been made a synonym of Y") produces a row here.
Every alternate spelling that wranglers have joined also produces a row here.
The synonym text itself does **not** have a row in `canonical_tags` — it exists
only in this table.

**Key invariant:** `synonym` is never equal to the canonical's `name`. You will
never find `"Hurt/Comfort"` as both a synonym row and a canonical row — it is
one or the other. If a tag appears in `canonical_tags.name`, it is canonical. If
it appears only in `tag_synonyms.synonym`, it maps to something else.

### `tag_parent_links` — the wrangling hierarchy

```sql
child_id   INTEGER → canonical_tags.id   -- more specific tag
parent_id  INTEGER → canonical_tags.id   -- more general tag
PRIMARY KEY (child_id, parent_id)
```

A directed edge meaning "child is a sub-type of parent." Both directions of
information from AO3 are stored here:

- From a canonical tag's **"Parent tags (more general):"** section →
  `(this tag, parent)` edge.
- From a canonical tag's **"Sub-tags:"** section →
  `(subtag, this tag)` edge.

So for `Marvel Cinematic Universe → Marvel`, the row is
`child_id = MCU, parent_id = Marvel`.

Subtag trees are fully flattened into individual edges.
`Young Justice (Cartoon)` → `Young Justice - All Media Types` → `DCU` produces
two separate rows, not one.

### `tag_subtag_sections` — informational category labels *(optional use)*

```sql
child_id  INTEGER → canonical_tags.id
parent_id INTEGER → canonical_tags.id
section   TEXT    -- "Relationships", "Characters", "Additional Tags", "Fandoms", or ""
PRIMARY KEY (child_id, parent_id)
```

Every row here has a corresponding row in `tag_parent_links` with the same
`(child_id, parent_id)`. The only new information is the section label — the
category heading under which AO3 listed this child on the parent's tag page.

**You do not need this table for `TagSynonymResolver`.** It is useful if you ever
want to display "these are relationship tags under MCU" in the UI, or let the
user filter the fandom-hierarchy tree by category. The phase guide's
fandom-hierarchy toggle (default off) is a good candidate.

### `scrape_log` — scraper bookkeeping, do not use at runtime

```sql
tag_name   TEXT PRIMARY KEY
scraped_at TEXT   -- ISO-8601
status     TEXT   -- 'ok'|'not_canonical'|'merged'|'error'
```

Only the Python scraper reads this. You can ignore it in Swift.

---

## What `AO3TagSeeds.swift` contains

Two static arrays and a loader:

```swift
struct AO3TagSeeds {

    /// (synonym, canonicalName, tagType)
    /// Every entry: synonym != canonical (they are never the same string)
    static let synonyms: [(synonym: String, canonical: String, tagType: String)]

    /// (childName, parentName) — full wrangling hierarchy, all levels
    static let parentLinks: [(child: String, parent: String)]

    /// Call once on first launch, gated by UserDefaults "tagSeedLoaded".
    /// Single SQLite transaction. Safe to call again — INSERT OR IGNORE.
    static func loadIfNeeded(db: OpaquePointer) throws
}
```

`loadIfNeeded` targets the raw SQLite pointer for `ambrosia_meta.db`.
It inserts into `canonical_tags`, `tag_synonyms`, and `tag_parent_links`
with `last_fetched = NULL` for all seed rows, matching the spec.

---

## Schema delta from the phase guide

The guide's DDL specifies `fandom_hierarchy(child_id, parent_id)`.
The scraper uses `tag_parent_links(child_id, parent_id)` instead — same
structure, different name, plus the addition of `tag_subtag_sections`.

**When you write the `ambrosia_meta.db` DDL in Swift, use `tag_parent_links`
and `tag_subtag_sections`, not `fandom_hierarchy`.** The seed loader in
`AO3TagSeeds.swift` already targets `tag_parent_links`.

The `canonical_tags` and `tag_synonyms` tables match the guide exactly.

---

## Implementing `TagSynonymResolver`

The spec says:

```swift
final class TagSynonymResolver {
    func canonical(for inputTag: String) async -> String {
        // 1. Check canonical_tags.name — return as-is if found
        // 2. Check tag_synonyms.synonym — return canonical if found
        // 3. Unknown → queue background fetch, return inputTag unchanged
        return inputTag
    }
}
```

The two queries you need, in order:

```sql
-- Step 1: is it already canonical?
SELECT id FROM canonical_tags WHERE name = ?

-- Step 2: is it a known synonym?
SELECT c.name
FROM tag_synonyms s
JOIN canonical_tags c ON c.id = s.canonical_id
WHERE s.synonym = ?
```

If step 1 returns a row, return the input unchanged — it's already canonical.
If step 2 returns a row, return that `c.name`.
Otherwise: queue a background live fetch (step 3).

Both queries run on a **read-only** `Connection` — the resolver never writes.
`AmbrosiaMetaDB.shared` holds the write actor; reads can use their own
separate `Connection(path, readonly: true)` per the architecture doc.

---

## Using the hierarchy (fandom-hierarchy toggle)

When the Preferences toggle is on, a search for `Marvel` should also match
works tagged `Marvel Cinematic Universe`, `MCU`, `Avengers (Movies)`, etc. —
i.e., any tag that is a descendant of `Marvel` in `tag_parent_links`.

Descendants query (iterative BFS/DFS in Swift, or recursive CTE):

```sql
-- All canonical tags that are descendants of a given parent
WITH RECURSIVE descendants(id) AS (
    SELECT child_id FROM tag_parent_links WHERE parent_id = (
        SELECT id FROM canonical_tags WHERE name = ?
    )
    UNION
    SELECT tpl.child_id FROM tag_parent_links tpl
    JOIN descendants d ON tpl.parent_id = d.id
)
SELECT name FROM canonical_tags WHERE id IN (SELECT id FROM descendants);
```

The phase guide says this toggle defaults **off**. Wire it up to
`UserDefaults` / `ReaderPreferences` accordingly and only run the CTE when on.

---

## Seed freshness and the "Clear synonym cache" button

Seed rows have `last_fetched = NULL`. Live-fetched rows get a real timestamp.

The "Clear synonym cache" button in Preferences → Library should:

```sql
-- Delete everything that was live-fetched (keep seeds)
DELETE FROM tag_synonyms
  WHERE canonical_id IN (
      SELECT id FROM canonical_tags WHERE last_fetched IS NOT NULL
  );
DELETE FROM tag_parent_links
  WHERE child_id IN (
      SELECT id FROM canonical_tags WHERE last_fetched IS NOT NULL
  )
     OR parent_id IN (
      SELECT id FROM canonical_tags WHERE last_fetched IS NOT NULL
  );
DELETE FROM canonical_tags WHERE last_fetched IS NOT NULL;

-- Reset the seed flag so loadIfNeeded re-runs
-- (seeds use INSERT OR IGNORE so re-running is safe)
UserDefaults.standard.removeObject(forKey: "tagSeedLoaded")
```

Then call `AO3TagSeeds.loadIfNeeded(db:)` again.

---

## Quick inspection queries

Paste these into any SQLite client (e.g. DB Browser for SQLite) against
`ao3_tag_seeds.db` to sanity-check the data before integrating:

```sql
-- How many of each type?
SELECT tag_type, COUNT(*) FROM canonical_tags GROUP BY tag_type;

-- What does "Hurt/Comfort" resolve from?
SELECT synonym FROM tag_synonyms
WHERE canonical_id = (SELECT id FROM canonical_tags WHERE name = 'Hurt/Comfort');

-- What are the parents of MCU?
SELECT p.name FROM tag_parent_links l
JOIN canonical_tags p ON p.id = l.parent_id
WHERE l.child_id = (SELECT id FROM canonical_tags WHERE name = 'Marvel Cinematic Universe');

-- Show the subtag section breakdown for MCU
SELECT c.name, s.section FROM tag_subtag_sections s
JOIN canonical_tags c ON c.id = s.child_id
WHERE s.parent_id = (SELECT id FROM canonical_tags WHERE name = 'Marvel Cinematic Universe')
ORDER BY s.section, c.name;

-- Tags that were merged (came in as synonyms from merger pages)
SELECT s.synonym, c.name AS canonical
FROM tag_synonyms s
JOIN canonical_tags c ON c.id = s.canonical_id
ORDER BY c.name LIMIT 50;
```
