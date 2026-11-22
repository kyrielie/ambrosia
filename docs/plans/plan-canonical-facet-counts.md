# Plan: canonical-deduped facet counts via `tag_canonical_map`

Audience: another AI engineer implementing in passes. Status: in progress.

## Problem (Verified from code)

- `AmbrosiaMetaDB.topFacets` / `topFacetsUnconstrained` run `COUNT(*)` over
  `json_each(ao3_metadata.<field>_json)` grouped by raw tag value, with `LIMIT ?` applied to the RAW rows.
- `AO3FilterFacetController.topFacets` then calls `AmbrosiaMetaDB.canonicalize`, which sums raw counts per
  canonical name in Swift. A book carrying N synonyms of one canonical tag is counted N times, so the badge
  exceeds the filtered work count (documented in `search-and-filter.md`, "Why Facet Counts Can Exceed...").
  *Empirically measured on real library (73k works)*: overcounts hit top tags heavily (e.g. The Avengers has 443 overcount,
  James Bond 46% inflation; total 5,230 overcounts across 599 canonical tags).
- Second defect, same cause: the `LIMIT` is applied before merging. A canonical tag whose synonyms are each
  below the raw top-N cutoff but whose merged count would rank can be missing or mis-ranked.
- Filtering is already correct: `book_tags` matching with synonym expansion returns each book once.

## Goal

Facet badge for a canonical tag = number of distinct books in scope carrying any synonym of it, equal to the
result count after checking the box. Top-N selected after merging.

## Non-goals

- No hierarchy / meta-tag inheritance (separate plan; `tag_parent_links` is unused today).
- No change to filter matching, `CalibreLibrarySearch`, or the two-SQL-path issue.
- No bulky schema additions to `book_tags`. (Adding a `canonical_name` column and index to `book_tags` was measured
  to add +110–150 MB / +37% file bloat to a 73k library and require updating 1.78M rows; rejected in favor of
  the lightweight `tag_canonical_map` table).

## Design

### 1. Schema: `tag_canonical_map`
In `AmbrosiaMetaDB.createBookTags` (called from `runMigrations`):
```sql
CREATE TABLE IF NOT EXISTS tag_canonical_map (
    tag_name        TEXT NOT NULL PRIMARY KEY,
    canonical_name  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tag_canonical_map_name ON tag_canonical_map(canonical_name);
```
Additive, zero-risk. For a 73k library, holds ~9k–50k rows (~0.3–3 MB total) instead of expanding `book_tags` by 150 MB.

### 2. State Marker & Synchronization
- `LibraryStateKey.tagCanonicalSeedIdentity`: stores `AO3TagSeedDatabaseConfig.identity(for: url)` of the
  seed used for current values, or `"off"` when disabled.
- Method `AmbrosiaMetaDB.syncTagCanonicalMapIfNeeded()`:
  - If current seed identity matches stored marker: no-op (0 ms).
  - If seed disabled: `DELETE FROM tag_canonical_map;` set marker to `"off"`.
  - If seed enabled:
    - Attach seed DB or read seed synonyms/canonicals.
    - Populate `tag_canonical_map` with library tags matching seed synonyms and canonicals.
    - In SQLite on real 73k library, sync takes ~0.25–1.0s.
    - Update marker to current seed identity.
- Triggers:
  - Library open in `LibrarySession` (background task alongside `importConfiguredAO3TagSeedsIfNeeded`).
  - Seed toggle/change in Preferences (`AO3TagSeedDatabaseConfig.shared`).
  - After extraction run finishes in `LibrarySession.extractionFinished`.

### 3. Facet Queries
In `AmbrosiaMetaDB`:
- Scoped facet query:
  ```sql
  SELECT COALESCE(m.canonical_name, bt.tag_name) AS name, COUNT(DISTINCT bt.calibre_id) AS cnt
  FROM json_each(?) j
  JOIN book_tags bt ON bt.calibre_id = j.value AND bt.tag_type = ?
  LEFT JOIN tag_canonical_map m ON m.tag_name = bt.tag_name
  GROUP BY name
  ORDER BY cnt DESC
  LIMIT ?
  ```
  *Measured on 73k library*: 1 ms for 200 books, 19 ms for 2,600 books.
- Unconstrained (whole library) facet query:
  ```sql
  SELECT COALESCE(m.canonical_name, bt.tag_name) AS name, COUNT(DISTINCT bt.calibre_id) AS cnt
  FROM book_tags bt
  LEFT JOIN tag_canonical_map m ON m.tag_name = bt.tag_name
  WHERE bt.tag_type = ?
  GROUP BY name
  ORDER BY cnt DESC
  LIMIT ?
  ```
- Distinct book count: `COUNT(DISTINCT bt.calibre_id)` ensures works with multiple synonyms are counted strictly once.
- Top-N evaluated after merge: `ORDER BY cnt DESC LIMIT ?` operates on the grouped canonical `name`.
- Graceful fallback: If seed is disabled, `tag_canonical_map` is empty, so `COALESCE(m.canonical_name, bt.tag_name)`
  returns `bt.tag_name` with no code branching.
- Author facet: `.author` has no `tag_type`, so it routes to the existing `author_names_json` query.

### 4. Cache Key Invalidation
Include `seedIdentity` in `AO3FilterFacetController.wholeLibraryFacetCache` key:
`(field, visibilityVersion, seedIdentity)` so toggling the seed DB or changing files immediately invalidates
the whole-library facet cache.

## Passes

- **Pass 1: Docs-only Known Limitations correction** (Shipped).
- **Pass 2: Characterization tests** (Shipped in `AmbrosiaTests/FacetCharacterizationTests.swift`).
  Pins legacy behavior (raw counts, unconstrained vs scoped, limit, rating facets, synonym inflation defect, LIMIT-before-merge defect).
- **Pass 3: Schema, Marker, and Synchronization**:
  - `tag_canonical_map` table in `createBookTags`.
  - `LibraryStateKey.tagCanonicalSeedIdentity`.
  - `AmbrosiaMetaDB.syncTagCanonicalMapIfNeeded()` and `clearTagCanonicalMap()`.
  - Wire sync into `LibrarySession` open and `extractionFinished`.
  - Tests for sync: population, case normalization, seed toggle to "off", idempotency.
- **Pass 4: Facet Query Implementation & Routing**:
  - `canonicalFacets(for:scopedTo:limit:)` and `canonicalFacetsUnconstrained(for:limit:)` in `AmbrosiaMetaDB`.
  - `AO3FacetField.tagType` mapping.
  - Route tag fields in `AO3FilterFacetController.topFacets` to canonical methods without calling `canonicalize`.
  - Update `wholeLibraryFacetCache` key with seed identity.
- **Pass 5: Integration & Verification**:
  - Unit and integration tests verifying 0 overcounts, Top-N after merge, seed disabled fallback, cache bust on seed swap.
  - Performance benchmarks on large libraries.
- **Pass 6: Documentation Updates**:
  - Update `docs/search-and-filter.md`, `docs/caching.md`, `docs/metadb-and-migrations.md`, and `docs/testing.md`.
