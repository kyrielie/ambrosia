# Ambrosia: List/Email Page-Result Caching — Implementation Plan

## Context

`LibraryRootView` (list surface) and `EmailLibraryViewController` (email surface)
are two independent presentations of the same underlying Calibre data. Today,
switching between them re-fetches everything from `metadata.db` from scratch —
confirmed from `ambrosialog.txt`, where an identical filter/sort/page produced
identical `pageBookIDs` on both surfaces, fetched via two separate round trips.
Goal: cache page results once, shared between both surfaces, invalidated
correctly.

This plan assumes the flicker bug (stale torn-down `EmailLibraryViewController`/
`LibraryRootView` instances racing shared `toolbarState.activeFilterResult`) has
already been fixed separately — see `stopObserving()`, the `isTornDown`/
`isListSurfaceTornDown` guards on `loadPage`/`applyFilterRules`/deferred-count
completions in both files. That fix is a prerequisite in the sense that caching
work should land on top of a codebase that isn't still racing itself, but it is
tracked and delivered separately from this plan.

**Status of this plan: not started. No code written.**

---

## Scope decision

Your `ambrosia_cleanup_plan.md` already documents **Finding 2**: `LibraryRootView`
and `EmailLibraryViewController` duplicate ~17 methods (`applyFilterRules`,
`loadPage`, `visibleBooks`, `visibleIDs`, `scheduleDeferredSQLFilterCount`, etc.)
almost line-for-line, and proposes extracting a UI-agnostic `LibraryQueryController`
to own all of it. That fix is explicitly scoped as a **multi-day, phased refactor**
in the existing plan — "do not attempt as a single change."

This caching plan does **not** require that full refactor. It only requires the
six visibility-affecting ID sets (`skippedIDs`, `seriesOrMergedIDs`,
`ao3PublisherIDs`, `anthologyIDs`, `likedIDs`, `readLaterIDs`) to have one
writer instead of two, so the new cache's key can use a cheap version counter
instead of hashing large `Set<Int>`s. That's a small, self-contained slice of
Finding 2's target shape (`LibrarySession` as source of truth) — not the whole
`LibraryQueryController` extraction. The rest of Finding 2 (paging/filter logic
duplication) is unaffected by this plan and should be scheduled separately.

**Decision: implement the scoped-down centralization (Phase 1 below) as a
prerequisite, then the cache itself (Phase 2), in one PR.** If you'd rather do
full Finding 2 first, stop here and revisit — that changes Phase 1 substantially
and should not be decided implicitly by an engineer mid-implementation.

---

## Phase 1 — Prerequisite: centralize visibility ID-set ownership

**Problem:** `session.cachedSkippedIDs`/`cachedSeriesOrMergedIDs`/
`cachedAO3PublisherIDs`/`cachedReadLaterIDs`/`cachedLikedIDs`/`cachedAnthologyIDs`
exist on `LibrarySession` but are barely written to from there — each UI surface
keeps its own private copy, refreshed independently via its own
`refreshCollectionSnapshots()`. `EmailLibraryViewController`'s copy currently
only writes `cachedAnthologyIDs` back to session (confirmed by grep — the other
five writes only exist in `LibraryRootView`). Neither refresh is tied to
`session.membershipVersion`. This means: (a) session's cached sets are
unreliable today, and (b) there's no cheap, correct signal a new cache could use
to know "is this visibility snapshot still current."

**Changes:**

1. Add `func refreshCollectionSnapshots() async` to `LibrarySession`, moving the
   logic currently duplicated in both UI files' private methods of the same
   name (they're ~90% identical already per Finding 2's own diff in the cleanup
   plan — start from `LibraryRootView`'s version since it has the `#if DEBUG`
   diagnostic block Email's is missing; port that block over rather than
   dropping it).
2. This function writes all six `session.cachedX` sets, diffs against the
   previous values (reuse the existing `shouldReloadPage`-style comparison
   logic already present in both files), and calls `session.bumpMembershipVersion()`
   exactly when something actually changed — one writer, one moment of truth,
   no interleaving between two independent refreshes to worry about.
3. `LibraryRootView.currentVisibilityPolicy` and
   `EmailLibraryViewController.currentVisibilityPolicy` read `session.cachedX`
   directly. Delete both files' private `skippedIDs`/`seriesOrMergedIDs`/
   `ao3PublisherIDs`/`anthologyIDs`/`likedIDs`/`readLaterIDs` vars and their
   private `refreshCollectionSnapshots()` bodies.
4. Every existing call site of the old per-surface `refreshCollectionSnapshots()`
   (context menu actions, viewDidLoad, Combine sinks, etc. — grep both files)
   now calls `session.refreshCollectionSnapshots()` instead.
5. Verify: `session.close()`/library switch already resets all six `cachedX`
   sets to `[]` (existing code, `LibrarySession.swift:138-143` / `:213-219`) —
   confirm this still runs before Phase 1's new single-writer function could
   repopulate them from a stale library.

**Effort:** ~1 day. Mechanical — move one function, delete two, redirect reads.

---

## Phase 2 — The page cache

**Where:** actor-private state on `CalibreLibrary`, not `LibrarySession`. Reason:
`CalibreLibrary` is already the single shared instance both surfaces call into
(per Invariant 17), and it's "replaced wholesale on library switch" — so a cache
stored there is invalidated for free on library switch/close, unlike
`LibrarySession`'s `filterResultCache`, which needs manual `.removeAll()` calls
at three call sites today.

**What to add:**

```swift
// Declared with default (internal) visibility, NOT private — bookCount(query:filter:)
// lives in an extension in FilterDrawer/FilterBuilder.swift, a different file.
// `private` here would make it invisible there. See Invariant 16 — this project
// has been bitten by exactly this mistake once already.
private var pageCache: LRUCache<PageCacheKey, (page: [CalibreBook], hasMore: Bool)>
    = LRUCache(limit: 48)
private var countCache: LRUCache<CountCacheKey, Int> = LRUCache(limit: 48)
```

`PageCacheKey` / `CountCacheKey`: build from —

- `querySignature`: `LibraryFilterDebug.summary(query:)` — already exists, reuse it.
- `filterSignature`: `LibraryFilterDebug.summary(expression:)` — already exists, reuse it.
- `tagExpansionsDigest`: cheap stable string from the `filterTagExpansions`
  dictionary (sorted `key:[values]` pairs joined) — this already varies per
  call per Invariant 17, so it must be part of the key, not assumed constant.
- `visibilityVersion`: `session.membershipVersion`, now trustworthy after Phase 1.
  (`CalibreLibrary` doesn't currently know about `LibrarySession` — this needs
  to be passed as a parameter into the paging methods, the same way `visibility:`
  already is. Do not have `CalibreLibrary` reach into `LibrarySession` directly —
  that inverts the existing dependency direction and risks a retain cycle.)
- `sortField` + `ascending`.
- `randomSeed` (`CalibreLibrary.randomSeed`, only relevant when `sortField == .random`)
  — include it rather than excluding random sort from caching; it's already a
  cheap readable actor property, bumped by `reshuffleRandom()`.
- Page-cache only: `offset`, `limit`.

**Cache at the actor method level, keyed on raw `(offset, limit)`,** not on
"page number." Under series grouping, `rawSQLOffset` bookkeeping is stateful and
per-surface (`LibraryRootView` and `EmailLibraryViewController` can be at
different raw offsets for the same nominal "page" due to independent overflow
history) — keying on the actual `(offset, limit)` tuple issued to the actor
sidesteps that; it's a pure function of its own inputs regardless of which
surface's pagination logic produced them.

**Where to check/populate:** inside `wordCountSortedPage`, `randomSortedPage`,
both `books(...)` overloads, `fetchAllMatchingIDs`, and
`bookCount(query:filter:filterTagExpansions:)`. All are synchronous actor
methods (no internal `await`) — actor isolation alone makes cache reads/writes
safe with no additional token/generation guard needed (unlike Invariant 23's
concern, which is specifically about work that suspends mid-write).

**No UI-layer changes required** beyond threading `session.membershipVersion`
into the existing `visibility:`/`filterTagExpansions:` parameter lists these
methods already take.

**Effort:** ~1-2 days including the digest helpers and cache-key plumbing.

---

## Invalidation checklist

| Source of change | Handling |
|---|---|
| Library switch/close | Free — new `CalibreLibrary` instance, cache doesn't survive. |
| Like/skip/read-later/collection membership | Covered by `visibilityVersion` (= `membershipVersion`), now correctly bumped by Phase 1's single writer. |
| AO3 extraction batch completes | `updateAO3MetaCaches(...)` runs on the same actor — have it call `pageCache.removeAll()` / `countCache.removeAll()` directly. No versioning needed; it's the same actor reaching into its own state. |
| Random reshuffle | Covered by including `randomSeed` in the key — no special-casing needed. |
| Tag synonym re-import | Self-invalidates as long as `tagExpansionsDigest` is computed from the *resolved* expansion dictionary contents, not just the raw term list. |
| Full-text search | Out of scope — already has its own cache (`cachedFulltextIDs`), leave it alone. |

---

## Residual risk, stated plainly

Phase 1 closes the specific race that would otherwise make the cache wrong
(two independent refreshes disagreeing about visibility with no shared
signal). It does not eliminate every theoretical interleaving — if a
membership-version bump and an in-flight fetch computed just before it land in
an unlucky order, a page could in principle be cached one version "early."
This is the same class of residual risk "Option A" (a smaller version-counter
patch without full centralization) would have left wide open; Phase 1's
single-writer design narrows it to a much smaller window. Closing it
completely would require the full Finding 2 `LibraryQueryController`
extraction, which is out of scope here by decision.

---

## Testing plan

- New `CalibreLibraryPageCacheTests.swift` (model it on the existing
  `AmbrosiaTests/LibraryVisibilityPolicyTests.swift`): cache hit on identical
  params; miss on each single param changing independently (offset, filter,
  query, sort, ascending, tagExpansions digest, visibility version, random
  seed); cache cleared by `updateAO3MetaCaches`; cache bounded at the LRU limit
  under repeated scrolling.
- New `LibrarySessionSnapshotTests.swift` for Phase 1: `refreshCollectionSnapshots()`
  bumps `membershipVersion` exactly once per real change, zero times when
  nothing changed; all six `cachedX` sets are written; sets are cleared on
  `close()`.
- Manual repro, using the same log instrumentation that diagnosed the original
  bug: filter, switch list→email→list on an active filter. Post-fix, the
  second and later switches should show cache-hit log lines and zero new
  `books.end`/`visibleBooks.fetch` entries.
- Build gate per Invariant 21: `xcodebuild build` clean before merge — this
  touches `CalibreLibrary.swift`, `FilterBuilder.swift`, `LibrarySession.swift`,
  `LibraryRootView.swift`, and `EmailLibraryViewController.swift`, five files
  in one PR, exactly the kind of change Invariant 21 exists for.

---

## Open questions before starting

1. Confirm Phase 1 scope (scoped-down centralization) vs. deferring to full
   Finding 2 — this plan assumes scoped-down, decided above, but flagging once
   more since it changes Phase 1 substantially.
2. LRU limit of 48 for both caches is a guess, not measured — worth a memory
   profile pass after initial implementation, particularly under heavy
   infinite-scroll usage (each page-cache entry holds up to `limit` hydrated
   `CalibreBook` structs, cheap individually but unbounded scrolling could grow
   the *number* of distinct offset entries fast).
3. Should the flicker-bug fix (already implemented, unverified by build) land
   as its own PR ahead of this, or bundled together? Recommend ahead — it's
   already done and unrelated in mechanism to the caching work.
