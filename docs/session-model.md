# Session model

Scope: `LibrarySession`, the top-level `@Observable` singleton that owns the
open library's connections and caches, plus registry/preferences state that
exists before a library is opened. For the caches it maintains during
search/filter, see `caching.md`.

---

### Registry and Preferences

`LibraryRegistry` stores known library paths and the active path in `UserDefaults`; it is available immediately on launch.

`ReaderPreferences` is an `@Observable` singleton backed by `UserDefaults` (migrated from Combine `ObservableObject` in Phase 4). It controls reader typography, themes, layout order, spacing, colors, preferred reader app, library appearance, reader window sizing, context-menu preferences, and custom Calibre column labels.

The Preferences window (Reader, Library, Data, RSS, Shortcuts tabs) is the UI for reader defaults, library appearance, custom Calibre column labels, AO3 extraction, RSS options, keyboard shortcuts, and tag seed configuration — i.e. the front end for `ReaderPreferences` plus AO3 tag seed import described in `ao3-metadata-extraction.md`.

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

1. Clears `snapshotsReady` (before `library` is assigned, because `isOpen` turning true is what schedules the list's first load).
2. Opens `metadata.db` read-only.
3. Opens/creates per-library `ambrosia_meta.db`.
4. Opens optional `full-text-search.db` (`CalibreFTSLibrary`, native or `likeFallback` mode; see `calibre-fts.md`).
5. Registers the library path and index record, loads search history, repoints feed prefs and the feed server.
6. **Hydrates snapshots** (`hydrateSnapshots`): bulk-loads the five AO3 maps from `AmbrosiaMetaDB` and pushes them into `CalibreLibrary` (which recomputes the duplicate-loser set from them), then runs `refreshCollectionSnapshots()` to load the persisted Series or Merged, skipped, anthology, publisher, liked and read-later sets. Order matters because duplicate losers derive from the AO3 caches.
7. Sets `snapshotsReady = true` and posts `.librarySnapshotsDidBecomeReady`. `LibraryRootView` and `EmailLibraryViewController` hold their first `loadPage` until then, then seed their local sets from the session and load once.
8. Starts the background work (`startBackgroundWork`): AO3 tag seed import, AO3 extraction, and the Calibre series seed. These start after hydration so they cannot queue ahead of the first page on the `AmbrosiaMetaDB` and `CalibreLibrary` actors.

The Series or Merged sync is gated only by the series seed (`SeriesSyncCoordinator`, `awaiting: 1`). Extraction follows it: if extraction flushed any data it runs one more sync when it finishes, otherwise it never triggers one. Re-extract (`reextractAO3Metadata`) still awaits both seed and extraction. The sync reads the persisted members, computes a `MembershipDelta` against the freshly computed set and writes only the difference (`CollectionStore.applyMemberDelta`). `.seriesOrMergedCollectionDidChange` is posted only when the delta is non-empty, because the surfaces already loaded with the persisted sets. If `open` fails, `snapshotsReady` is restored to whether a previous library is still open.

`fulltext:` resolution: `resolveFulltextIDs(for:)` builds an `FTSQuery`, returns a cached result if there is one, otherwise calls `beginSearch()` on the FTS backend and awaits `searchBooks` inside `withTaskCancellationHandler`, so cancelling the calling task interrupts the running statement. After a `Task.isCancelled` check it compares the result's index stamp with the last one seen (clearing the cache on a change), then stores the ids. Failures and cancellations return `[]` and are never cached; failures set `lastFulltextError`. `resolvedQuery(_:)` is a thin wrapper that attaches the ids to a `SearchQuery`. `fulltextSearcherOverride` is a test seam (`FulltextSearching`). See `caching.md` and `calibre-fts.md`.

Collection membership sets (`cachedLikedIDs`, `cachedSkippedIDs`, `cachedSeriesOrMergedIDs`, `cachedAO3PublisherIDs`, `cachedReadLaterIDs`) are cleared on open and on close. `close()` now resets all five, including `cachedReadLaterIDs`.

---


## Launch signposts

`Ambrosia/Utilities/LaunchSignposts.swift` wraps `OSSignposter` (subsystem "Ambrosia", category "Launch") so launch and page-load timing can be measured in a **Release** build, where `LibraryFilterDebug.log` is compiled out. Open Instruments with the os_signpost instrument and filter on category "Launch".

Intervals: `LibrarySession.open`, `refreshCollectionSnapshots`, `refreshAO3MetaCaches.bulkLoads`, `refreshAO3MetaCaches.pushToLibrary`, `extraction.scan`, `importAO3TagSeeds`, `seed.allCalibreSeriesEntries`, `seed.insertCalibreSeriesFallback`, `syncSeriesOrMerged`, `syncSeriesOrMerged.readCurrent`, `syncSeriesOrMerged.applyDelta`, `hydrateSnapshots`, `groupAwareTitleSortedPage.compute`, `loadPage`. Events: `membershipVersionBump` (the caller is also logged through `Logger`) and `firstListRebuild`.

Rules: pair `begin` and `end` with the same literal name; do not use a `defer` inside a closure that goes on to run unrelated work after the measured step (it would inflate the interval); keep signposts out of per-row loops.


### Fingerprint-gated background scans

On open, the series seed and the extraction scan each read `CalibreLibrary.libraryFingerprint()` (`metadata.db` mtime and size, book count, max book id, max `last_modified`) and compare it with the marker stored in `library_state` (see `metadb-and-migrations.md`). Unchanged means skip: the seed still completes its coordinated-sync slot, and the extraction scan reports finished without fetching ids or the three exclusion sets. `forceAll` re-extraction always scans. The seed computes the fingerprint before scanning and stores it only after a clean pass with no series-rewriting write in between. When it does run, the seed walks book-id windows of 5,000 (`calibreSeriesEntries(bookIDsAfter:through:)`) with a `Task.yield()` between windows, so page fetches queued on the `CalibreLibrary` actor run between windows instead of after the whole scan.

### New works without a restart

`LibrarySession` observes `NSApplication.didBecomeActiveNotification` (installed once, on the first `open`) and calls `checkForLibraryChanges()`. It does nothing until `snapshotsReady`, skips a check within 2 seconds of the previous one, and allows one check at a time. Steps: `CalibreLibrary.reopenIfFileReplaced()` (see `calibre-library.md`), then `libraryFingerprint()`, then `LibraryChange.classify(known:current:)` against the fingerprint this session last saw. The baseline is filled by the open-time series seed (or adopted silently by the first check); `none` also covers "no baseline yet", because the launch scans compare with the persisted markers themselves.

- `none`: nothing happens and nothing is posted.
- `fileOnly` (mtime or size moved, book count, max id and max `last_modified` did not): caches are dropped and both scans re-run, but no reload is requested.
- `content` (count, max id or max `last_modified` moved, or the file was replaced): additionally posts `.libraryContentsDidChange`.

On any change the session clears `filterResultCache` and `ruleMatchCache`, calls `CalibreLibrary.clearQueryCaches()` (`pageCache`, `countCache`, `groupAwareCountCache`, `sortedIDsCache`), refreshes `totalCount`, then starts a new coordinated sync generation and re-runs extraction and the series seed exactly as `startBackgroundWork` does (both are fingerprint-gated and the stored markers now differ, so both scan). A run already in progress is superseded; extraction recomputes its missing set, so nothing is lost. The check and each scan compute the fingerprint separately, so a change costs three `MAX(last_modified)` passes; measure before optimizing.

Unverified: which Calibre edits bump `books.last_modified` (an edit that changes only a series assignment may not), and `MAX(last_modified)` is probably an unindexed pass over `books`; time `fingerprint.compute` in a Release build.
