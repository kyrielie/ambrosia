# Search and filter

Scope: the search-bar parser, the drawer/popup filter engines, and their SQL
generation. For the LRU caches these paths populate, see `caching.md`. For
the app-structure/UI shell these run inside, see `library-ui.md`.

---

Search:

- Raw text is parsed by `SearchQueryParser`.
- Prefixes: `tag:`, `author:`, `title:`, `series:`, `status:`, `fulltext:`.
- Only one scoped prefix token is recognised per search string — parsing is not compositional (`"tag:x author:y"` becomes a single `tag:` token whose value is the literal string `"x author:y"`, not two rules). `SearchQuery.hasTrailingPrefixWarning` flags this case so the UI can warn the user, but does not change parsing behavior. Compound quick-searches must go through the drawer/popup instead of the search bar. See "Known Limitations" below.
- Single committed prefix tokens become `FilterRule`s via `SearchQuery.asSingleFilterRule(resolvedTagTerm:)`.
- Plain terms prefer `CalibreFTSLibrary` (`full-text-search.db`, FTS5) when available, otherwise fall back to fuzzy title LIKE.
- Suggestions query Calibre authors/tags/titles/series directly.
- `SearchActivityLog` (`@MainActor` singleton) keeps an in-memory ring buffer (200 entries) of committed search/filter operations for the current session, persisted per-library-hash to a JSON file in Application Support on `close()` and reloaded on `open()`. It dedupes only against the single most recent entry (not the whole window), and is not saved on crash/unclean shutdown — only on the `close()` path.

Filters — two front ends, one engine:

- The **drawer** (`FilterDrawer/FilterRule.swift`, `FilterBuilder.swift`, `FilterDrawerView.swift`) is a generic rule builder: `FilterExpression` is a list of `FilterGroup`s (rules ANDed/ORed within a group), groups joined by one top-level conjunction, across sixteen `FilterField` cases.
- The **AO3-style popup** (`FilterPopup/AO3Filter*.swift`) mirrors AO3's own facet browser (fandom/relationship/character/freeform/warning/category, plus rating/crossover/completion) with checkboxes instead of free-form rules. It has no SQL layer of its own: `AO3FilterPopupState.buildExpression()` converts checkbox state into an ordinary `FilterExpression` only on Apply, and `AO3FilterFacetController` builds throwaway `FilterExpression`s (excluding one field at a time, AO3's "ignoring: type" scoping behavior) purely to call the same `FilterBuilder.matchingIDs` the drawer uses. Every SQL/cache characteristic below applies to both menus identically; the popup adds its own facet-count query load on top (see "Facet counts" under Caching, below).
- SQL-evaluable rule fields (title, comment, author, series, tag/rating/warning/category, word count/kudos when a custom column is configured) are compiled by `FilterBuilder.sqlFragment(for:)` into correlated `EXISTS`/`NOT EXISTS` subqueries (aliased `btl2`/`t2`, `bal2`/`a2`, `bsl2`/`s2`) rather than outer joins — see Invariant 24.
- App-owned/in-memory-only fields (`isLiked`, `collection`, `status`, `crossover`, and `wordCount`/`kudos` when no custom column exists) never produce SQL; they are resolved as `Set<Int>` intersections against caller-supplied membership maps (`likedIDs`, `collectionMap`, `statusMap`, `crossoverMap`) inside `matchingIDsForGroup`, applied as a post-filter over whatever the SQL-backed rules in the same group already returned. This composition is correct only because of that specific evaluation order; see Invariant 25 before adding a new in-memory field type.
- Filter results are cached in `filterResultCache`, an 8-entry LRU keyed on a digest of `FilterExpression` (group index + sorted per-group rules) plus `membershipVersion`, a counter bumped after any liked/skipped/status change. Page and count results have their own, larger (48-entry) LRU caches (`pageCache`, `countCache`, `groupAwareCountCache`) on `CalibreLibrary`, keyed similarly plus sort/offset/visibility/random-seed fields — see "Caching", below.
- Tag-value synonym expansion (canonical tag -> synonym set, via `AmbrosiaMetaDB.expandedTermsBatch`) is resolved per filter application by `TagExpansionResolver.filterTagExpansions(for:metaDB:)`, which returns a small dictionary scoped to only the tag values present in the *current* filter expression — not the full synonym table, and not stable across filter changes. `FilterBuilder` stores its own copy as `let tagExpansions`, set once at `init`, since a `FilterBuilder` instance is fresh per call and safe to own state on. `CalibreLibrary` is a long-lived `actor` shared across both surfaces and across overlapping in-flight queries; `sqlFilterClause`, `sqlFragment`, `calibreIDs(matchingRules:)`, `bookCount`, `wordCountSortedPage`, `randomSortedPage`, and `fetchAllMatchingIDs` all live on `CalibreLibrary` (some called only through `FilterBuilder`, some called directly from `LibraryRootView`/`EmailLibraryViewController`), so `tagExpansions`/`filterTagExpansions` is threaded through as an explicit parameter on all six rather than cached as actor state — caching it there would let one surface's synonym lookup silently overwrite another's mid-query. See Invariant 17.
- The visibility rules that were previously scattered as bool + cached-`Set<Int>` pairs (skipped, series-or-merged grouping, AO3-publisher allow-list, anthology deny-list) are consolidated into `LibraryVisibilityPolicy`, a value type built fresh per surface as `currentVisibilityPolicy` and passed into `CalibreLibrary.wordCountSortedPage`/`randomSortedPage` as `visibility:`, replacing the old `excludeIDs:` parameter and the per-branch AO3-only-random patches. See Invariant 22.

---

### Known Limitations (Filter/Search)

- **Two independent SQL-generation paths** exist for the same tag/author/series matching logic: `FilterBuilder.sqlFragment(for:)` (drawer/popup path) and `CalibreLibrarySearch.whereClause(for:)` (search-bar path). A correctness or performance fix to one (e.g. the NOT EXISTS rewrite, Invariant 24) does not automatically apply to the other — confirmed drifted out of sync: `CalibreLibrarySearch._bookCount(query:)` still carries the outer `LEFT JOIN books_authors_link/authors/books_series_link/series` that `FilterBuilder` deliberately removed (see Invariant 24) because its own `EXISTS` subqueries are self-contained and never reference the outer join aliases. This is dead weight causing the same row-fan-out cost the removed join caused elsewhere, just on the plain-search count path.
- `SearchQueryParser` only parses one scoped prefix token per string (see Search, above) — no compound quick-search syntax.
- AO3 popup facet counts (`topFacets`) are uncached and unde-bounced; see Caching, above.
- `crossoverBookIDs()`/`allCrossoverBookIDs()` (a full-table `json_array_length(fandoms_json) > 1` scan over `ao3_metadata`) is recomputed on every `AO3FilterFacetController.make` call (i.e. every popup open) with no cache, even though it only actually changes after an AO3 extraction batch.
- `AO3FilterFacetController.make` builds `statusMap` by looping every `AO3CompletionStatus` case and issuing one query per case whenever *any* status rule is present, rather than a single query covering all needed statuses at once.
- No index is created (or verified) on `books_tags_link`/`books_authors_link`/`books_series_link` by Ambrosia itself — these tables belong to Calibre's own `metadata.db` schema, and Calibre normally indexes them, but nothing here defensively creates a fallback index (`CREATE INDEX IF NOT EXISTS` is idempotent even against a foreign schema) for libraries where that index is missing or was stripped.

---


---

## Random sort

Seeded random sort with Xorshift64 (`SeededRNG`), stable within a session. Used by `CalibreLibrary.randomSortedPage` (see `visibility:` handling in Invariant 22 above) and the local feed server's opt-in random-daily route (`local-feed-server.md`).

---

## Key invariants

17. `tagExpansions`/`filterTagExpansions` are threaded as explicit parameters through `sqlFilterClause`, `sqlFragment`, `calibreIDs(matchingRules:)`, `bookCount`, `wordCountSortedPage`, `randomSortedPage`, and `fetchAllMatchingIDs` rather than cached as `CalibreLibrary` actor state, because `CalibreLibrary` is a long-lived actor shared across overlapping in-flight queries. Full rule and rationale in `concurrency-invariants.md`.

22. Library visibility rules (skip/show-skipped, series-or-merged grouping, AO3-publisher-only, anthology-hiding) live in one value type, `LibraryVisibilityPolicy`, built fresh per surface (`currentVisibilityPolicy`) and passed as `visibility:` into `CalibreLibrary.wordCountSortedPage`/`randomSortedPage`. Do not reintroduce a bool + cached-`Set<Int>` pair wired independently through call sites for a new visibility toggle — add a field to `LibraryVisibilityPolicy` instead. The old `LibraryQueryHelpers.visibleIDs`/`.visibleBooks` free functions and the `excludeIDs:` parameter they fed are retired; do not resurrect either.

24. Negated many-to-many filter conditions (tag/rating/warning/category/author/series `notEquals`/`notContains`) must be built as a correlated `NOT EXISTS (... WHERE btl2.book = b.id AND ...)` subquery, never as `b.id NOT IN (SELECT book FROM ... WHERE ...)`. The `NOT IN` shape forces SQLite to materialise the entire matching-book set and anti-join it against all of `books`, and a leading-wildcard `LIKE` inside that subquery can't use any index — a full scan of `tags` per evaluation. `NOT EXISTS` correlates on the outer book id, letting SQLite seek the `books_tags_link(book)` index per book instead. Relatedly: never add an outer `LEFT JOIN books_tags_link/tags` (or the authors/series equivalents) "to support" these fields — every one of them is already a self-contained correlated subquery aliased `btl2/t2` (or `bal2/a2`, `bsl2/s2`); an outer join with unused outer aliases only fans every book out to one row per tag before `SELECT DISTINCT` collapses it back down, multiplying the cost of every `NOT EXISTS` re-evaluation for no benefit. `FilterBuilder.swift` had this outer join removed already (see §9 in that file's comments); `CalibreLibrarySearch._bookCount(query:)` still has the equivalent dead join as of this writing — fix it the same way rather than treating the two files' SQL as independent.

25. In-memory-only filter fields (`isLiked`, `collection`, `status`, `crossover`, and `wordCount`/`kudos` without a configured custom column) are applied in `FilterBuilder.matchingIDsForGroup` as a post-filter over the SQL-backed rules' result *within the same group*, not recomputed from the full library. This is correct only because the code always computes SQL-backed-rule matches first (or falls back to `allCalibreIDs()` when a group has no SQL-backed rules) before intersecting/subtracting the in-memory rule's membership set. If you add a new in-memory-only `FilterField`, follow this same order — SQL rules (or the full-library set) first, in-memory rules second, applied per the group's own conjunction — rather than assuming in-memory rules can be evaluated independently and combined afterward; the existing OR-group union logic in particular depends on each in-memory branch reusing the same pre-narrowed `idSet`, not the raw membership map.
