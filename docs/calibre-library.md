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

Optional search through Calibre's `full-text-search.db`, via `CalibreFTSLibrary`, for explicit `fulltext:` queries only (plain terms never reach it; see `search-and-filter.md`). The file is opened read-only and never written. Two modes, chosen when the file is opened:

- `native`: a real FTS5 `MATCH` against `books_fts`. `books_fts` is declared with Calibre's `calibre` tokenizer, so Ambrosia registers a Swift/C port of that tokenizer on its own connection first. Ids only, unranked, `DISTINCT book`, no result cap, no format filter by default. Details, schema and gate results are in `calibre-fts.md`.
- `likeFallback`: a `LIKE` scan over `books_text.searchable_text` with the user's text escaped and matched literally (ASCII case-insensitive, substring, not token-based). Used only when tokenizer registration fails or the file's `PRAGMA user_version` is not 1.

If `books_text` lacks `id, book, format, searchable_text`, `CalibreFTSLibrary.init?` returns nil and `fulltext:` finds nothing. A failed query returns no matches for that call and is never cached.

## Key invariants

1. Calibre DB connections are read-only. Never issue DDL, DML, or file-modifying PRAGMAs (`journal_mode`, `wal_checkpoint`, `user_version`). Session-scoped performance PRAGMAs (`cache_size`, `temp_store`) are safe and permitted.

2. `books.series` does not exist. Always join through `books_series_link -> series`.

3. SQLite.swift SQL bindings always use `[Binding?]`.

See `overview.md`'s Invariant 12 for the repo-wide force-unwrap ban. (`ReadingTarget.primaryBook`'s `series.works.first!` -- previously flagged here as a known crash site -- was already fixed; it now uses `precondition` plus indexed access, not a force-unwrap.)


### Reopen on file replacement

`CalibreLibrary.db` is a `var`, settable only inside `CalibreLibrary.swift`. `reopenIfFileReplaced()` compares `(st_dev, st_ino)` of `metadata.db` (read before opening, so a replacement racing the open is caught next time) with the identity recorded at open, the same approach as `CalibreFTSLibrary`. On a mismatch it opens a new read-only connection with the same session PRAGMAs, clears the query caches and returns true. If the new open fails it keeps the old connection and returns false so the next call retries. In-place writes by Calibre need no reopen, since each new read transaction sees them; that holds for a rollback journal and is not verified for WAL.

### Library fingerprint and chunked series scan

`CalibreLibrary.libraryFingerprint()` runs `SELECT COUNT(*), MAX(id), MAX(last_modified) FROM books` and reads `metadata.db`'s mtime and size. Whether Calibre bumps `last_modified` on every kind of edit is an assumption, not verified. `calibreSeriesEntries(bookIDsAfter:through:)` is the windowed form of `allCalibreSeriesEntries()`, ordered by book id, series name, then series index.
