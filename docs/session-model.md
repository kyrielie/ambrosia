# Session model

Scope: `LibrarySession`, the top-level `@Observable` singleton that owns the
open library's connections and caches, plus registry/preferences state that
exists before a library is opened. For the caches it maintains during
search/filter, see `caching.md`.

---

### Registry and Preferences

`LibraryRegistry` stores known library paths and the active path in `UserDefaults`; it is available before SwiftData is initialized.

`ReaderPreferences` is an `ObservableObject` singleton backed by `UserDefaults`. It controls reader typography, spacing, colors, default reading mode, library appearance, reader window sizing, context-menu preferences, and custom Calibre column labels.

The Preferences window (Reader, Library, Window, Data tabs) is the UI for reader defaults, library appearance, custom Calibre column labels, AO3 extraction, and tag seed configuration — i.e. the front end for `ReaderPreferences` plus AO3 tag seed import described in `ao3-metadata-extraction.md`.

---


## Session Model

`LibrarySession` is an `@Observable @MainActor` singleton injected into the SwiftUI environment.

It owns:

- `library: CalibreLibrary?`
- `ftsLibrary: CalibreFTSLibrary?`
- `metaDB: AmbrosiaMetaDB?`
- `collectionStore: CollectionStore?`
- `extractionProgress`
- active path, total count, collection membership caches, filter result LRU cache, FTS LRU cache

On library open it:

1. Opens `metadata.db` read-only.
2. Opens/creates per-library `ambrosia_meta.db`.
3. Opens optional `full-text-search.db` (`CalibreFTSLibrary`, native or `likeFallback` mode; see `calibre-fts.md`).
4. Registers the library path and index record.
5. Imports configured AO3 tag seeds into `ambrosia_meta.db`.
6. Starts background AO3 metadata extraction from EPUB prefaces.
7. Seeds Calibre series fallback data and syncs `Series or Merged`.

`fulltext:` resolution: `resolveFulltextIDs(for:)` builds an `FTSQuery`, returns a cached result if there is one, otherwise calls `beginSearch()` on the FTS backend and awaits `searchBooks` inside `withTaskCancellationHandler`, so cancelling the calling task interrupts the running statement. After a `Task.isCancelled` check it compares the result's index stamp with the last one seen (clearing the cache on a change), then stores the ids. Failures and cancellations return `[]` and are never cached; failures set `lastFulltextError`. `resolvedQuery(_:)` is a thin wrapper that attaches the ids to a `SearchQuery`. `fulltextSearcherOverride` is a test seam (`FulltextSearching`). See `caching.md` and `calibre-fts.md`.

Collection membership sets (`cachedLikedIDs`, `cachedSkippedIDs`, `cachedSeriesOrMergedIDs`, `cachedAO3PublisherIDs`, `cachedReadLaterIDs`) are cleared on open and on close. `close()` now resets all five, including `cachedReadLaterIDs`.

---

