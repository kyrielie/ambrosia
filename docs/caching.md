# Caching

Scope: the LRU caches in the search/filter pipeline, and the cross-surface
reload-trigger coordination between list and email modes. For the queries
that populate these caches, see `search-and-filter.md`.

---

### Caching

Three LRU caches (`LRUCache<Key, Value>`, a bounded dictionary + insertion-order eviction list, not thread-safe on its own — safe here because every instance lives on an actor or `@MainActor` type) cover the filter/search pipeline:

| Cache | Owner | Key | Limit | Cleared by |
|---|---|---|---|---|
| `filterResultCache` | `LibrarySession` | `FilterResultCacheKey` (expression digest + `membershipVersion`) | 8 | library open/close; implicitly stale once `membershipVersion` moves on |
| `pageCache` | `CalibreLibrary` | `PageCacheKey` (query+filter+tagExpansion digests, `visibilityVersion`, sort, ascending, `randomSeed`, offset, limit) | 48 | `updateAO3MetaCaches` (after every AO3 extraction batch); implicitly stale once `visibilityVersion`/`randomSeed` move on |
| `countCache` / `groupAwareCountCache` | `CalibreLibrary` | analogous to `PageCacheKey`, minus offset/limit/sort | 48 each | same as `pageCache` |

Notes and known rough edges:

- Cache keys are built from `LibraryFilterDebug.summary(expression:)`/`summary(query:)`, a function whose primary purpose is debug logging, repurposed as the cache-key digest. Any change to that formatting silently changes cache-key identity; treat it as cache-critical, not just cosmetic, when editing.
- `FilterResultCacheKey`'s digest encodes each group by positional index (`g0`, `g1`, ...) without sorting groups themselves, so two expressions with reordered-but-equivalent groups (e.g. under an `OR` top-level conjunction, where order is semantically irrelevant) produce different keys and miss the cache. Harmless (over-invalidation, not incorrectness) but worth knowing if cache-hit-rate work happens here.
- Facet counts in the AO3 popup (`AmbrosiaMetaDB.topFacets(for:scopedTo:limit:)`, one `json_each` aggregation query per of the 6 `AO3FacetField` cases, run concurrently via `withTaskGroup`, plus one rating query) are **not cached** and re-run in full on every checkbox toggle in `refreshFacets()`. Each query binds the entire scoped ID set as `IN (?, ?, ...)` parameters, which can be large for a broad selection. There is no debounce wired into `refreshFacets()` at present, so rapid toggling can dispatch bursts of 7 aggregation queries. `canonicalize(_:)` additionally issues one `SELECT` per distinct facet name to resolve synonyms (an N+1 pattern bounded by the small per-field row limit, not batched the way `TagExpansionResolver`/`expandedTermsBatch` batches the equivalent lookup elsewhere).


---

### Reload triggers (List vs Email)

Both surfaces reload from two independent places on every `applyFilterRules()` completion: the explicit `scheduleLoadPage`/`loadPage` call each of its three branches (SQL-pageable, LRU-cached, full compute) makes itself, and a separate observer that exists to reload when *something else* — the other surface, a sort/search change, a preference toggle — changes `toolbarState.activeFilterResult` while this surface is the one onscreen. `LibraryRootView` uses SwiftUI's `.onChange(of: toolbarState.activeFilterResult?.reloadToken)`; `EmailLibraryViewController` uses a hand-rolled `withObservationTracking` observer (`scheduleObservation()` / `toolbarStateDidChange()`), since it's an `NSViewController`, not a SwiftUI view.

Every branch of `applyFilterRules()` on both surfaces sets a one-shot `suppressNextReloadToken` flag immediately before its own reload call, and the observer checks and consumes that flag before reloading — otherwise the filter completion double-fires and races through `scheduleLoadPage`'s non-atomic `loadPageTask?.cancel()`-then-reassign, since the explicit call and the observer-triggered call can run from different execution contexts. See Invariant 27.

Collections:

- System collections live in `ambrosia_meta.db`.
- `Series or Merged` is system-maintained from `series_cache` and anthology detection.
- Series grouping uses representative grouped rows for collapsed series.


---

## Key invariants

23. Async work that writes to shared or cached state on behalf of a UI surface must gate *every* one of its writes behind the same staleness check (task-cancellation or a generation/token guard) as its other results — not just the ones that are obviously part of the "final" result. A guard that protects some writes but not others is worse than no guard: code that reads the guarded writes assumes the whole function is safe, so the unguarded write's staleness is invisible on read. Full rule in `concurrency-invariants.md`. Found in `applyFilterRules()`: `cachedFilterTagExpansions` was written several `await` points before the existing `libraryFilterApplicationToken` guard, so a superseded filter-application task could overwrite a newer task's tag-synonym expansions after the fact, even though the token guard correctly protected `activeFilterResult` and the other post-guard writes. Fixed by moving the write to after the guard, alongside the other post-guard writes, in both `LibraryRootView` and `EmailLibraryViewController`.

27. Any UI surface that (a) can itself trigger `toolbarState.activeFilterResult` to change, and (b) also observes that same property to reload when something *else* changes it, must guard against double-triggering its own reload with a one-shot suppression flag (e.g. `suppressNextReloadToken`), set immediately before the surface's own reload call and consumed by the observer before it reloads. `LibraryRootView` has always done this via SwiftUI's `.onChange` plus a `@State` flag (`suppressNextReloadToken`, set in all three branches of `applyFilterRules()`, consumed in `.onChange(of: toolbarState.activeFilterResult?.reloadToken)`). `EmailLibraryViewController`'s hand-rolled `withObservationTracking` observer (`scheduleObservation()`, `toolbarStateDidChange()`) did not have the equivalent guard until fixed: every `applyFilterRules()` completion fired `scheduleLoadPage` twice — once explicitly, once via the observer — and the two calls raced through `scheduleLoadPage`'s `loadPageTask?.cancel()`-then-reassign, since they could originate from different execution contexts (the full-compute branch's `Task` is not `@MainActor`-isolated). Symptom: switching to email view, or applying a filter while already on it, showed stale/unfiltered sidebar results until a second manual reload. Fixed by adding `suppressNextReloadToken` to `EmailLibraryViewController`, mirroring `LibraryRootView`'s placement, and by writing `activeFilterResult` last (after `skippedIDs`/`seriesOrMergedIDs`/`ao3PublisherIDs`/`anthologyIDs`/`duplicateLoserIDs`/`cachedFilterTagExpansions`) in the full-compute branch, per Invariant 23. When adding a new UI surface that reads or writes `activeFilterResult` (or any other property multiple surfaces both mutate and observe), port this suppression pattern from the start — do not assume `withObservationTracking`/`.onChange` on a shared, multiply-written property is safe without it.
