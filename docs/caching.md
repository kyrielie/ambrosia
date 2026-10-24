# Caching

Scope: the LRU caches in the search/filter pipeline, and the cross-surface
reload-trigger coordination between list and email modes. For the queries
that populate these caches, see `search-and-filter.md`.

---

### Caching

Four LRU caches (`LRUCache<Key, Value>`, a bounded dictionary + insertion-order eviction list, not thread-safe on its own — safe here because every instance lives on an actor or `@MainActor` type) cover the filter/search pipeline:

| Cache | Owner | Key | Limit | Cleared by |
|---|---|---|---|---|
| `filterResultCache` | `LibrarySession` | `FilterResultCacheKey` (expression digest + `membershipVersion` + visibility signature + `bookTagsRevision`) | 8 | library open/close; implicitly stale once `membershipVersion` moves on |
| `pageCache` | `CalibreLibrary` | `PageCacheKey` (a `SortedIDsCacheKey` plus offset and limit) | 48 | `updateAO3MetaCaches` (after every AO3 extraction batch); implicitly stale once `visibilityVersion`/`randomSeed` move on |
| `countCache` / `groupAwareCountCache` | `CalibreLibrary` | analogous to `PageCacheKey`, minus offset/limit/sort | 48 each | same as `pageCache` |
| `sortedIDsCache` | `CalibreLibrary` | `SortedIDsCacheKey` (query+filter+tagExpansion digests, `visibilityVersion`, `visibilitySignature`, sort, ascending, `randomSeed`; i.e. `PageCacheKey` minus offset and limit) | 4 | `updateAO3MetaCaches` via `invalidateSortedIDs()`; implicitly stale once `visibilityVersion`/`visibilitySignature`/`randomSeed` move on |

`sortedIDsCache` holds the full sorted id list for one grouped title-sorted view (`groupAwareTitleSortedPage`), so paging within a view costs a slice plus `booksForIDs` instead of a fresh materialize-and-sort. It is read through `LRUCache.get`, which refreshes recency (the subscript does not). A same-key sort already running is joined through `sortedIDsInFlight` rather than started twice, and `sortedIDsGeneration` stops a sort that began before `invalidateSortedIDs()` from storing a stale result. `wordCountSortedPage`, `kudosSortedPage` and `randomSortedPage` are not split yet.

`CalibreLibrary.clearQueryCaches()` empties `pageCache`, `countCache`, `groupAwareCountCache` and `sortedIDsCache` together; `updateAO3MetaCaches` and the app-activation change check (`session-model.md`) both call it. The same check clears `filterResultCache` and `ruleMatchCache` on the session.

Notes and known rough edges:

- Cache keys are built from `LibraryFilterDebug.summary(expression:)`/`summary(query:)`, a function whose primary purpose is debug logging, repurposed as the cache-key digest. Any change to that formatting silently changes cache-key identity; treat it as cache-critical, not just cosmetic, when editing.
- `FilterResultCacheKey`'s digest encodes each group by positional index (`g0`, `g1`, ...) without sorting groups themselves, so two expressions with reordered-but-equivalent groups (e.g. under an `OR` top-level conjunction, where order is semantically irrelevant) produce different keys and miss the cache. Harmless (over-invalidation, not incorrectness) but worth knowing if cache-hit-rate work happens here.
- Facet counts in the AO3 filter sidebar/popup (`AmbrosiaMetaDB.topFacets(for:scopedTo:limit:)`, one `json_each` aggregation query per of the 6 `AO3FacetField` cases, run concurrently via `withTaskGroup`, plus one rating query) are scoped to current candidate IDs. In Phase 5, rapid checkbox toggling is debounced via `DebounceTimer(delay: 0.15)` in `AO3FilterPopupView` / `AO3FilterSidebarView`, and queries bind candidate IDs efficiently via `SQLIDList.clause(column:)` using single-bound `json_each(?)`, eliminating parameter explosion (`SQLITE_LIMIT_VARIABLE_NUMBER`). `canonicalize(_:)` resolves synonyms for facet entries.


---

### Reload triggers (Unified LibraryDisplayController)

Prior to Phase 2, both surfaces reloaded independently from multiple uncoordinated observers, requiring fragile `suppressNextReloadToken` flags and teardown guards to mitigate races.

In Phase 2, all query planning, 3-branch filter execution (`sqlFilterClause`, LRU cached, full compute), and pagination reload triggers were consolidated into `LibraryDisplayController.swift`. A single observation loop tracks toolbar state mutations, preference updates, and notifications centrally. Both `LibraryRootView` and `EmailLibraryViewController` bind directly to `displayController.items`, `displayController.books`, and `displayController.offsetState`, completely eliminating cross-surface reload races and `suppressNextReloadToken` workarounds. Mode switching in `LibraryViewController` toggles `.isHidden` on cached views with zero reload delay.

Collections:

- System collections live in `ambrosia_meta.db`.
- `Series or Merged` is system-maintained from `series_cache` and anthology detection.
- Series grouping uses representative grouped rows for collapsed series.


---

### Full-text result cache

`LibrarySession.resolvedFulltextCache` maps a `fulltext:` phrase to the matching Calibre book ids (insertion-order LRU).

- Key: `FTSQuery.cacheKey`, which is the trimmed, NFKC-normalized phrase with a `u|` prefix (`s|` for the stemmed table, unused until stemming exists). It is not case- or diacritic-folded, because `resume` and `résumé` are different queries. Every site that derives a key (`LibrarySession`, `FilterBuilder`, and `LibraryQueryHelpers.fulltextMap`, which `LibraryRootView` and `EmailLibraryViewController` use) goes through `FTSQuery.make(...)?.cacheKey`.
- Only a successful search is cached, including a successful search with zero matches. A busy, syntax, missing-file or cancelled search returns no ids for that call and caches nothing; `LibrarySession.lastFulltextError` records the failure (not for cancellations).
- Invalidation: each result carries an `FTSIndexStamp` (device and inode of `full-text-search.db`, plus `PRAGMA data_version` on the connection). When a later successful search reports a different stamp, the whole cache is cleared before the new entry is stored. This is checked only when a search runs, so a cache hit does not revalidate. The cache is also cleared on library open and close.
- Whether `data_version` changes on a read-only connection (gate G5) is exercised by `CalibreFTSLibraryTests.testDataVersionChangesWhenAnotherConnectionCommits`; that test has not been run on macOS yet. File replacement is detected independently through the inode, so the cache does not depend on `data_version` alone.

---

## Key invariants

23. Async work that writes to shared or cached state on behalf of a UI surface must gate *every* one of its writes behind the same staleness check (task-cancellation or a generation/token guard) as its other results — not just the ones that are obviously part of the "final" result. A guard that protects some writes but not others is worse than no guard: code that reads the guarded writes assumes the whole function is safe, so the unguarded write's staleness is invisible on read. Full rule in `concurrency-invariants.md`. Found in `applyFilterRules()`: `cachedFilterTagExpansions` was written several `await` points before the existing `libraryFilterApplicationToken` guard, so a superseded filter-application task could overwrite a newer task's tag-synonym expansions after the fact, even though the token guard correctly protected `activeFilterResult` and the other post-guard writes. Fixed by moving the write to after the guard, alongside the other post-guard writes, in both `LibraryRootView` and `EmailLibraryViewController`.

27. Prior to Phase 2, any UI surface that (a) could trigger `toolbarState.activeFilterResult` to change, and (b) also observed that property to reload, had to guard against double-triggering its own reload with a one-shot suppression flag (`suppressNextReloadToken`). In Phase 2, this cross-surface reload coordination was eliminated at the root by consolidating query planning, filter execution, and paging into `LibraryDisplayController.swift`. Both `LibraryRootView` and `EmailLibraryViewController` bind directly to the display controller's output without maintaining independent observation loops or reload suppression tokens.

## Visibility signatures in cache keys

- `PageCacheKey.visibilitySignature` is `LibraryVisibilityPolicy.cacheSignature` (the four hide/show prefs plus `shouldGroupSeriesRows`) for `wordCountSortedPage`, `kudosSortedPage`, `groupAwareTitleSortedPage` and `randomSortedPage`, which apply the policy inside `CalibreLibrary`. The raw `books(...)` overload passes an empty signature because the view filters its page.
- `FilterResultCacheKey.visibilitySignature` is `LibraryVisibilityPolicy.signature(...)` for the four preferences baked into cached filter-result ID lists. `LibrarySession.cachedFilterResult` and `rememberFilterResult` require it; callers capture it next to the preference reads that filter the IDs.
- `CountCacheKey` is unchanged: its counts do not depend on visibility. `GroupAwareCountCacheKey` already carried the prefs.

## Incremental filter evaluation (subset lookup and rule cache)

- `LibrarySession.narrowingBase(for:visibilitySignature:)` splits a new expression
  into (base, one added rule) pairs via `IncrementalFilterPlanner` and looks each
  base up in `filterResultCache`, keeping the smallest hit. Only complete
  explicit-ID results are ever stored there, so a hit is always a valid base.
- `ruleMatchCache` (`RuleMatchCache`, 24 entries) holds GLOBAL per-rule tag match
  sets keyed by `RuleMatchKey` + `bookTagsRevision`. A candidate-restricted set is
  a subset and is never stored: `store(..., isGlobal: false)` returns false.
- `bookTagsRevision` is incremented by `AmbrosiaMetaDB.writeBookTags` (the only
  `book_tags` writer) and mirrored on the session after each successful extraction
  flush. Evaluations capture it before starting and file results under that value.
- Both caches are cleared on library open and close.
