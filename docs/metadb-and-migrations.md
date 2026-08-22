# `ambrosia_meta.db` and migrations

Scope: the per-library, app-owned SQLite database — its owner, schema, and
migration rules. For the read-only Calibre database, see
`calibre-library.md`. For the SwiftData store (`BookState`/`ReadingGoal`),
see `swiftdata-store.md`.

---

### Per-Library `ambrosia_meta.db`

`AmbrosiaMetaDB` is an actor-backed writable SQLite DB scoped by a hash of the Calibre library path. It stores:

- `collections`, `collection_members`.
- `annotations`.
- `ao3_metadata`, `ao3_extraction_diagnostics`.
- `series_cache`, `series_placeholders`.
- `canonical_tags`, `tag_synonyms`, `tag_parent_links`, `tag_subtag_sections`.
- `reading_history`, `book_opens` (write path wired up: `startReadingSession`, `updateReadingSession`, `closeZombieReadingSessions` are called from the reader session lifecycle).
- `error_log` — a general-purpose, prunable failure trail (`logError`/`recentErrors`/`pruneErrorLog`/`clearErrorLog`), viewable via `ErrorLogView` (Export menu → "Error Log…"). Complements, not replaces, `ao3_extraction_diagnostics`'s scoped-per-subsystem diagnostics.

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
