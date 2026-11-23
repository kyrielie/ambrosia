# Caching

Scope: the LRU caches in the search/filter pipeline, and the cross-surface
reload-trigger coordination between list and email modes. For the queries
that populate these caches, see `search-and-filter.md`.

---

### Caching

Four LRU caches (`LRUCache<Key, Value>`, a bounded dictionary + insertion-order eviction list, not thread-safe on its own — safe here because every instance lives on an actor or `@MainActor` type) cover the filter/search pipeline:

| Cache | Owner | Key | Limit | Cleared by |
|---|---|---|---|---|
| `filterResultCache` | `LibrarySession` | `FilterResultCacheKey` (expression digest + `visibilityVersion` + pinned collection version + visibility signature + `bookTagsRevision`) | 8 | library open/close; old results stop matching when visibility or the query’s collection pin changes |
| `pageCache` | `CalibreLibrary` | `PageCacheKey` (a `SortedIDsCacheKey` plus offset and limit; includes `visibilityVersion` and pinned collection version) | 48 | `updateAO3MetaCaches` (after every AO3 extraction batch); implicitly stale once visibility, the query pin, or `randomSeed` changes |
| `countCache` / `groupAwareCountCache` | `CalibreLibrary` | analogous to `PageCacheKey`, minus offset/limit/sort; grouped counts also carry both versions | 48 each | same as `pageCache` |
| `sortedIDsCache` | `CalibreLibrary` | `SortedIDsCacheKey` (queryDigest including relevance targets and ranked ordering flag, query+filter+tagExpansion digests, `visibilityVersion`, pinned collection version, `visibilitySignature`, sort, ascending, `randomSeed`; i.e. `PageCacheKey` minus offset and limit) | 8 | `updateAO3MetaCaches` via `invalidateSortedIDs()`; implicitly stale once visibility, the query pin, `visibilitySignature`, or `randomSeed` changes |

`LibrarySession.visibilityVersion` tracks Skip, series-or-merged, publisher,
anthology, and duplicate-loser visibility sets. `collectionVersion` tracks
Like, Read Later, and collection assignment changes. `LibraryDisplayController`
captures both `pinnedCollectionVersion` and the collection membership map when
the user changes the query, search, sort, or grouping. The version remains a
cache-key accelerator; the captured map is the data snapshot used by visible
collection-rule evaluation. A membership press updates session-backed icons
but leaves the active result IDs, page, and scroll in place; the next query
application pins the latest map and version. `refreshCollectionSnapshots` also bumps
`collectionVersion` when `collectionMembershipByName` changes, so a custom
collection edit from a path that does not call `bumpCollectionVersion()` is
still detected. Skip and other visibility refreshes re-apply the filter and
therefore also re-pin the collection version; this is accepted because Skip is
rare. Filter popup facets: the whole-library baseline queries are unscoped and
keyed on `(visibilityVersion, seedIdentity)`; scoped facets are uncached and read collection
membership live when the popup loads, so they are not reloaded on a Like.

`sortedIDsCache` holds the full sorted id list across all sort modes (`wordCount`, `kudos`, `random`, `relevance`, and `groupAwareTitle`), so paging within a view costs a slice plus `booksForIDs` instead of a fresh materialize-and-sort. It is read through `LRUCache.get`, which refreshes recency (the subscript does not). A same-key sort already running is joined through `sortedIDsInFlight` rather than started twice, and `sortedIDsGeneration` stops a sort that began before `invalidateSortedIDs()` from storing a stale result.

`CalibreLibrary.clearQueryCaches()` empties `pageCache`, `countCache`, `groupAwareCountCache` and `sortedIDsCache` together; `updateAO3MetaCaches` and the app-activation change check (`session-model.md`) both call it. The same check clears `filterResultCache` and `ruleMatchCache` on the session.

## Page-load measurement

The app emits `page.query` for the foreground page request, `page.rebuildMetadata`
for row/group hydration, `pageCache.hit` for page-cache hits, and separate
`collection.*.effectiveView` / `collection.*.explicitRows` intervals for
effective versus explicit collection reads. Use these in Instruments Points of
Interest before adding adjacent-page preloading. Page turns currently wait for
row metadata hydration, so ID-only preloading is not assumed to improve the
visible latency. Preloading remains unimplemented until a profile shows that
neighbor-page fetch time is a material part of the wait.

Notes and known rough edges:

- Cache keys are built from `LibraryFilterDebug.summary(expression:)`/`summary(query:)`, a function whose primary purpose is debug logging, repurposed as the cache-key digest. Any change to that formatting silently changes cache-key identity; treat it as cache-critical, not just cosmetic, when editing.
- `FilterResultCacheKey`'s digest encodes each group by positional index (`g0`, `g1`, ...) without sorting groups themselves, so two expressions with reordered-but-equivalent groups (e.g. under an `OR` top-level conjunction, where order is semantically irrelevant) produce different keys and miss the cache. Harmless (over-invalidation, not incorrectness) but worth knowing if cache-hit-rate work happens here.
- Facet counts in the AO3 filter sidebar/popup (`AmbrosiaMetaDB.canonicalFacets(for:scopedTo:limit:)` and `canonicalFacetsUnconstrained`, backed by `book_tags` joined with `tag_canonical_map`) are scoped to current candidate IDs with zero inflation (each book counts strictly once per canonical tag). In Phase 5, rapid checkbox toggling is debounced via `DebounceTimer(delay: 0.15)` in `AO3FilterPopupView` / `AO3FilterSidebarView`, and queries bind candidate IDs efficiently via `SQLIDList.clause(column:)` using single-bound `json_each(?)`, eliminating parameter explosion (`SQLITE_LIMIT_VARIABLE_NUMBER`). Whole-library unconstrained counts are cached by `(visibilityVersion, seedIdentity)` in `AO3FilterFacetController.wholeLibraryFacetCache`.


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

---

## Universal Sorted-ID Cache (`sortedIDsCache`)

Added in Pass 2 of `database-performance-and-query-pipeline-plan.md`.

- **Purpose**: Full sorted ID list per view (capacity: 8 entries). When paging through `.wordCount`, `.kudos`, `.random`, `.relevance`, or `.groupAwareTitle`, the expensive materialize-expand-filter-sort pipeline runs once per view on page 1. Subsequent page requests (page 2, page 3, etc.) reuse the cached sorted array, paying only for slicing + `orderedBooks(for:)` page hydration (< 6 ms).
- **Key**: `SortedIDsCacheKey`
  - `queryDigest`: A 12-byte SHA256 hex digest precomputed by `QueryDigestBuilder` from all query inputs (plain, title, tag, author, series terms with match modes, `expandedTagTerms`, `filterTagExpansions`, `ftsMatchedIDs`, `restrictIDs`, `filter`, `rankedIDs`, `relevanceTargets`, and `rankedIDsAreOrdered`). Carried as a token in `PageQuery` so it is never re-hashed per page turn.
  - `querySignature`, `filterSignature`, `tagExpansionsDigest`
  - `visibilityVersion`, `pinnedCollectionVersion`, `visibilitySignature`
  - `sortField`, `ascending`
  - `randomSeed`: Set to `0` for all non-random sorts (seed zeroing). Shuffling random mode never invalidates or strands numeric or title sorted-ID entries.
- **Generation Guard**: `sortedIDsGeneration` increments on `invalidateSortedIDs()` and `clearQueryCaches()`. A background sort that finishes after an invalidation does not store its stale array into `sortedIDsCache`. Similarly, `pageCache.set` checks `sortedIDsGeneration == generation` before storing.
- **D4 Total Order Tie-Breaking**: Numeric sorts (word count, kudos) break ties by title NOCASE ASC, then `calibre_id` ASC. Books with missing (nil) values always sort last in both ascending and descending directions, ordered among themselves by title NOCASE ASC, then ID ASC. Matches Calibre's `title COLLATE NOCASE` schema.
- **Relevance Sort Tie-Breaking**: With semantic search active, semantic similarity rank is strictly primary; tag position (`TagPosition`) acts as a tie-breaker. With `fulltext:` only, FTS hits are unranked, ordered primarily by tag position. Ties after tag position (or when no rank/tag targets are present) break deterministically by the existing list order (title NOCASE ASC, then ID ASC via `tieBreak`). Books without matched tag positions sort last.

---

## Query Pipeline Performance: Before vs. After (Pass 0 Baseline vs. Pass 3 Optimized)

Measured via `CalibreQueryBenchmarkTests` on a synthetic 100,000-book Calibre dataset with multi-author, multi-series, and tagged works on Apple Silicon:

| Operation | Pass 0 Baseline | Pass 3 Optimized | Improvement | Notes |
| :--- | :--- | :--- | :--- | :--- |
| `fetchAllMatchingIDs` (Cold, Unfiltered) | **202.37 ms** | **139.05 ms** | **-31.3% (-63.3 ms)** | Outer `bal`, `a`, `bsl`, `s` joins eliminated; `GROUP BY b.id` dropped |
| `fetchAllMatchingIDs` (Warm, Unfiltered) | **204.92 ms** | **134.08 ms** | **-34.6% (-70.8 ms)** | Deterministic `ORDER BY b.title ASC, b.id ASC` |
| `fetchAllMatchingIDs` (Filtered `"Tag 1"`) | **90.62 ms** | **75.15 ms** | **-17.1% (-15.5 ms)** | Evaluates 11,200 matching IDs |
| `SeriesMatchExpansion.expand` | **0.02 ms** | **0.03 ms** | — | Fast in-memory series mapping |
| `LibraryVisibilityPolicy.filter` | **33.18 ms** | **31.45 ms** | **-5.2%** | Set filtering across 100k IDs |
| Bulk In-Memory Value Lookup (100k) | **9.09 ms** | **7.75 ms** | **-14.7%** | Dictionary lookup across 100k IDs |
| Swift Sort (100k items) | **14.43 ms** | **12.24 ms** | **-15.2%** | $O(N \log N)$ sort of 100,000 integer IDs |
| `orderedBooks` (50-item Page Hydration) | **6.06 ms** | **5.93 ms** | — | Hydrates authors, tags, and comments for 50 IDs |
| **Page 2+ Navigation (Warm)** | ~265 ms | **< 6 ms** | **> 97% reduction** | Served from `sortedIDsCache` slice without running SQL or re-sorting |

### Gate D5 Confirmation
The total in-memory numeric sort compute (bulk value lookup + Swift sort) is **19.99 ms**, well below the **100 ms** gate threshold specified in D5. Therefore, Pass 4 composite indexes in Calibre are unnecessary and formally bypassed.

---

## Invariant 30: Cache Token Completeness

Every `FilterRule` property that can alter match sets (`field`, `op`, `value`, `limit`, `matchVariants`) MUST participate in `FilterRule.cacheToken`. 
All production cache digests (`RuleMatchKey`, `FilterResultCacheKey`, and `LibraryFilterDebug.summary(expression:)` which forms `PageCacheKey.filterSignature` and `CountCacheKey.filterSignature`) evaluate `rule.cacheToken` rather than raw field/op/value strings. This guarantees that rules differing only in position window (`limit`) or variant matching (`matchVariants`) never collide or serve stale match sets.

In `AmbrosiaMetaDB`, name indices (Level 0 and Level 1 tag mappings) and role coverage sets are cached in-memory and invalidated whenever `bookTagsRevision` changes.


