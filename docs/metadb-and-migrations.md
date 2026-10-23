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
- `ao3_metadata`, `ao3_extraction_diagnostics`.
- `series_cache`, `series_placeholders`.
- `canonical_tags`, `tag_synonyms`, `tag_parent_links`, `tag_subtag_sections`.
- `reading_history`, `book_opens` (write path wired up: `startReadingSession`, `updateReadingSession`, `closeZombieReadingSessions` are called from the reader session lifecycle).
- `error_log` — a general-purpose, prunable failure trail (`logError`/`recentErrors`/`pruneErrorLog`/`clearErrorLog`), viewable via `ErrorLogView` (Export menu → "Error Log…"). Complements, not replaces, `ao3_extraction_diagnostics`'s scoped-per-subsystem diagnostics.

### Lock Contention & Busy Timeout

`AmbrosiaMetaDB` configures `db.busyTimeout = 5.0` and `readDB.busyTimeout = 5.0` (as well as WAL journal mode). This gives writers and concurrent readers up to 5 seconds to wait for transient SQLite locks to clear, preventing immediate `SQLITE_BUSY` (code 5) runtime exceptions under concurrent reader progress updates and background extraction passes. Calibre library connections also configure `connection.busyTimeout = 5.0` and execute `PRAGMA busy_timeout = 5000`.

### Legacy SwiftData Migration

`migrate_legacy_swiftdata_to_sqlite` is recorded in `schema_migrations`. It checks for legacy `default.store` / `Ambrosia.store` SQLite files from early SwiftData versions and migrates `ZBOOKSTATE` and `ZREADINGGOAL` records into `book_state` and `reading_goals`. CoreData timestamps (measured in seconds since Jan 1, 2001) are converted to Unix epoch timestamps by adding `+ 978307200.0`.

`CollectionStore` wraps collection operations. Bootstrapped system collections:

- Read Later
- Liked
- Skipped
- Finished
- In Progress
- Has Annotations
- Series or Merged

Annotation inserts/deletes maintain `Has Annotations` membership. Series/anthology sync maintains `Series or Merged` membership for collapsed non-leading series members and anthology-style merged works.

**Migration note:** Most migrations in `runMigrations` are still gated with `CREATE TABLE IF NOT EXISTS` and `ALTER TABLE ... ADD COLUMN` wrapped in `try?`, which is fine for additive, idempotent changes. The destructive `series_placeholders` -> `series_placeholders_keyed` migration in `createAO3Metadata` is now gated on `PRAGMA user_version` and wrapped in a transaction, so it runs exactly once and a crash mid-migration can't strand the table. Use this migration as the template for any future destructive schema change; do not revert to `IF NOT EXISTS`-only gating for anything that drops or renames a table.


---

## Key invariants

10. `AmbrosiaMetaDB` is the sole owner of `ambrosia_meta.db`. All reads and writes go through the actor, accessed via `LibrarySession.metaDB`. `CalibreLibrary` and the former `AO3TagSearchResolver` previously opened independent `Connection` objects to the same file, violating write-lock coordination; both have been fixed (`CalibreLibrary` now reads from caches pushed in via `updateAO3MetaCaches`, and tag resolution moved onto the `AmbrosiaMetaDB` actor). Do not reintroduce a third connection to this file.

11. All destructive schema migrations (DROP, ALTER with data movement) must be wrapped in `db.transaction` and gated on `PRAGMA user_version`, not on table existence. `IF NOT EXISTS` guards cannot prevent a migration from re-running on subsequent launches.

## `bookTagsRevision`

`AmbrosiaMetaDB.bookTagsRevision` increments in `writeBookTags`, called only from
`insertBatch`. It keys the filter-result and rule-match caches so cached tag results
do not outlive an extraction pass. See `caching.md`.


### `library_state` (derived scan markers)

`library_state(key TEXT PRIMARY KEY, value TEXT NOT NULL)` is created by `createLibraryState` in `runMigrations` with `CREATE TABLE IF NOT EXISTS` (additive and idempotent, so no `schema_migrations` entry). It holds markers of the form "this scan already completed for library fingerprint X" (`LibraryFingerprint`, JSON). Keys are in `LibraryStateKey`:

- `series_seed_fingerprint`: the Calibre series cache seed completed for that fingerprint. Dropped by `invalidateSeriesSeedMarker()`, which `writeAO3Metadata` and `clearAO3Metadata` call, because replacing a book's `series_cache` rows deletes its Calibre fallback row and only a re-seed restores it. `markSeriesSeeded(_:ifRewriteCountIs:)` refuses to record when a rewrite landed after the seed started (`seriesRewriteCount`).
- `extraction_scan_fingerprint`: an extraction run finished with nothing left to extract for that fingerprint. Not stored for a cancelled or partially flushed run. Dropped by `clearAO3Metadata`.

Safe to delete: a missing marker only means the next launch rescans. Failed extractions are not retried (they are in `ao3_extraction_diagnostics`, which the scan excludes), so skipping the scan does not change retry behavior.
