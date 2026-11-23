# `ambrosia_meta.db` and migrations

Scope: the per-library, app-owned SQLite database — its owner, schema, and
migration rules. For the read-only Calibre database, see
`calibre-library.md`. For the deprecated SwiftData store consolidation,
see `swiftdata-store.md`.

---

### Per-Library `ambrosia_meta.db`

`AmbrosiaMetaDB` is an actor-backed writable SQLite DB scoped by a hash of the Calibre library path. It stores:

- `book_state` — reading progress (`total_read_percent`), reading position (`last_spine_index`, `last_character_offset`, `last_scroll_offset`), `last_opened_date`, `total_reading_time_seconds`, and ELO fields.
- `reading_goals` — reading targets (`target_books_count`, `period_start`, `period_end`).
- `collections`, `collection_members`.
- `annotations`.
- `ao3_metadata`, `ao3_extraction_diagnostics` (`allAO3Diagnostics(failedOnly:)` performs pure reads; resolved records are pruned via `pruneResolvedDiagnostics()` on library session open and extraction completion, preventing read-that-writes).
- `series` (stable series identity), `series_cache` (book membership),
  `series_collection_members`, `series_collection_exclusions`,
  `effective_collection_members`, and `series_placeholders`.
- `canonical_tags`, `tag_synonyms`, `tag_parent_links`, `tag_subtag_sections`.
- `reading_history`, `book_opens` (write path wired up: `startReadingSession`, `updateReadingSession`, `closeZombieReadingSessions` are called from the reader session lifecycle).
- `error_log` — a general-purpose, prunable failure trail (`logError`/`recentErrors`/`pruneErrorLog`/`clearErrorLog`), viewable via `ErrorLogView` (Export menu → "Error Log…"). Complements, not replaces, `ao3_extraction_diagnostics`'s scoped-per-subsystem diagnostics.

### Lock Contention & Busy Timeout

`AmbrosiaMetaDB` configures `db.busyTimeout = 5.0` and `readDB.busyTimeout = 5.0` (as well as WAL journal mode). This gives writers and concurrent readers up to 5 seconds to wait for transient SQLite locks to clear, preventing immediate `SQLITE_BUSY` (code 5) runtime exceptions under concurrent reader progress updates and background extraction passes. Calibre library connections also configure `connection.busyTimeout = 5.0` and execute `PRAGMA busy_timeout = 5000`.

### Legacy SwiftData Migration (Retired)

The one-time `migrate_legacy_swiftdata_to_sqlite` migration previously consolidated `ZBOOKSTATE` and `ZREADINGGOAL` records from legacy SwiftData stores (`default.store` / `Ambrosia.store`) into `book_state` and `reading_goals`. All existing libraries have been migrated and this migration shim has been retired to eliminate cross-library collision hazards.

`CollectionStore` wraps collection operations. Bootstrapped system collections:

- Read Later
- Liked
- Skipped
- Finished
- In Progress
- Has Annotations
- Series or Merged

Annotation inserts/deletes maintain `Has Annotations` membership. Series/anthology sync maintains `Series or Merged` membership for collapsed non-leading series members and anthology-style merged works.

**Series schema reset:** Series identity is stored in `series.series_key`; `series_cache` contains only `(calibre_id, series_id, series_index, is_anthology)`. The effective membership view combines explicit collection rows with series-derived rows and exclusions. The view is dropped and recreated on every open so its definition stays current. There is no automatic migration for the old `series_cache` format: after installing the schema-changing build, quit Ambrosia, run `DROP TABLE IF EXISTS series_cache;` against that library's `ambrosia_meta.db`, relaunch, then run Re-extract in Preferences. This drops only derived series membership; do not delete the database or `series_placeholders`. Do not open the new build against the old `series_cache` shape before doing this reset.

Series identities survive extraction rewrites: AO3 IDs resolve to `ao3:<id>`, Calibre IDs to `calibre:<id>`, and name-only rows to a creation-time `calibre-name:<name>` key. Name-only resolution trims, case-folds, and collapses whitespace. If a Calibre series later becomes AO3-sourced, its old flag remains dormant on the Calibre series row; there is no Calibre-to-AO3 flag transfer. `series_placeholders` is a retired feature; the table definition is retained for backwards compatibility, but active read/write APIs and in-memory models have been removed.


---

## Memory-Mapped I/O (`PRAGMA mmap_size`)

In Pass 3 (Decision D2) of `database-performance-and-query-pipeline-plan.md`, memory-mapped I/O is enabled on `ambrosia_meta.db` connections (`db` writer and `readDB` reader):

```sql
PRAGMA mmap_size = 268435456; -- 256 MB cap
```

- **Scope**: Applied strictly to `ambrosia_meta.db` (which Ambrosia owns and writes in WAL mode).
- **Calibre Exclusion**: Invariant 1 / Decision D2 prohibits `mmap_size` on Calibre's `metadata.db` or external databases. Calibre is an external system with its own concurrency model; memory mapping third-party databases is unsafe.
- **Verification**: Read back via `PRAGMA mmap_size` scalar query during initialization and logged in `DEBUG` builds.

---

## Key invariants

10. `AmbrosiaMetaDB` is the sole owner of `ambrosia_meta.db`. All reads and writes go through the actor, accessed via `LibrarySession.metaDB`. `CalibreLibrary` and the former `AO3TagSearchResolver` previously opened independent `Connection` objects to the same file, violating write-lock coordination; both have been fixed (`CalibreLibrary` now reads from caches pushed in via `updateAO3MetaCaches`, and tag resolution moved onto the `AmbrosiaMetaDB` actor). Do not reintroduce a third connection to this file.

26. Array order in `ao3_metadata.*_json` (`relationships_json`, `characters_json`, `fandoms_json`, `additional_tags_json`) is semantic: author tag ordering reflects relevance. The `book_tags` table contains no position column; tag positions are preserved directly in `*_json`. Do not sort, `Set`-dedupe, or reorder these arrays in extractors or writers.

11. All destructive schema migrations (DROP, ALTER with data movement) must be wrapped in `db.transaction` and gated on `PRAGMA user_version`, not on table existence. `IF NOT EXISTS` guards cannot prevent a migration from re-running on subsequent launches.

## `bookTagsRevision`

`AmbrosiaMetaDB.bookTagsRevision` increments in `writeBookTags`, called only from
`insertBatch`. It keys the filter-result and rule-match caches so cached tag results
do not outlive an extraction pass. See `caching.md`.


### `library_state` (derived scan markers)

`library_state(key TEXT PRIMARY KEY, value TEXT NOT NULL)` is created by `createLibraryState` in `runMigrations` with `CREATE TABLE IF NOT EXISTS` (additive and idempotent, so no `schema_migrations` entry). It holds markers of the form "this scan already completed for library fingerprint X" (`LibraryFingerprint`, JSON). Keys are in `LibraryStateKey`:

- `series_seed_fingerprint`: the Calibre series cache seed completed for that fingerprint. Dropped by `invalidateSeriesSeedMarker()`, which `writeAO3Metadata` and `clearAO3Metadata` call, because replacing a book's `series_cache` rows deletes its Calibre fallback row and only a re-seed restores it. `markSeriesSeeded(_:ifRewriteCountIs:)` refuses to record when a rewrite landed after the seed started (`seriesRewriteCount`).
- `extraction_scan_fingerprint`: an extraction run finished with nothing left to extract for that fingerprint. Not stored for a cancelled or partially flushed run. Dropped by `clearAO3Metadata`.
- `tag_canonical_seed_identity`: the seed database identity string (`AO3TagSeedDatabaseConfig.identity(for:)`, or `"off"`) for which `tag_canonical_map` was last populated. Rebuilding is synchronized by `AmbrosiaMetaDB.syncTagCanonicalMapIfNeeded()`.

### `tag_canonical_map` (canonical tag lookup table)

`tag_canonical_map(tag_name TEXT PRIMARY KEY, canonical_name TEXT NOT NULL)` is created by `createBookTags` in `runMigrations` with `CREATE TABLE IF NOT EXISTS` (additive, no `schema_migrations` entry). It maps raw tag names present in `book_tags` to their canonical tag names as defined in `ao3_tag_seeds.db`. Used by `canonicalFacets` to aggregate distinct book counts per canonical tag without duplicating or inflating counts.

Safe to delete: a missing marker only means the next launch rescans. Failed extractions are not retried (they are in `ao3_extraction_diagnostics`, which the scan excludes), so skipping the scan does not change retry behavior.
