# Calibre library (`metadata.db`)

Scope: how Ambrosia opens, reads, and never modifies Calibre's own
`metadata.db`. For the separate Ambrosia-owned database, see
`metadb-and-migrations.md`. For search/filter query generation against this
database, see `search-and-filter.md`.

---

### Calibre `metadata.db`

`CalibreLibrary` owns a read-only SQLite connection to a selected library root. It is created by `LibrarySession.open(url:)` and replaced wholesale on library switch.

Important schema facts:

- `books` has no `series` column. Series requires `books_series_link -> series`.
- Authors/tags/publishers are normalized through link tables.
- Comments/descriptions live in `comments`.
- Custom columns are discovered from `custom_columns`; runtime labels come from `CustomColumnConfig.shared`.
- Every `db.prepare(sql, args)` call must use `[Binding?]`.

`CalibreLibrary.books(...)` fetches a page of rows, then bulk-loads authors, tags, and comments with page-level JOIN queries. The `comments` join on the main fetch is omitted unless a filter rule references the comment field (performance optimization: comment blobs are large).

**Fixed.** `CalibreLibrary` no longer holds its own `Connection` to `ambrosia_meta.db`. `ao3WordCounts(ids:)`, `ao3Dates(ids:)`, and `crossoverBookIDs()` now read from in-memory caches (`ao3WordCountCache`, `ao3DateCache`, `crossoverIDCache`) populated by `CalibreLibrary.updateAO3MetaCaches(...)`, which `LibrarySession.refreshAO3MetaCaches()` calls after bulk-fetching from `AmbrosiaMetaDB` on open and after each AO3 extraction batch. `AmbrosiaMetaDB` remains the sole connection owner; `CalibreLibrary` only ever sees pushed-in results.


---

## Full-text search

Optional FTS search through Calibre's `full-text-search.db` (FTS5), via `CalibreFTSLibrary`. Search-bar plain-text terms prefer this when available; see `search-and-filter.md` for how terms fall back to fuzzy title `LIKE` when it isn't.

---

## Key invariants

1. Calibre DB connections are read-only. Never issue DDL, DML, or file-modifying PRAGMAs (`journal_mode`, `wal_checkpoint`, `user_version`). Session-scoped performance PRAGMAs (`cache_size`, `temp_store`) are safe and permitted.

2. `books.series` does not exist. Always join through `books_series_link -> series`.

3. SQLite.swift SQL bindings always use `[Binding?]`.

12. Force-unwraps are prohibited in any code path reachable from database read results. Use `guard let` with a logged fallback or propagate the error. The `series.works.first!` in `ReadingTarget.primaryBook` is a known crash site.
