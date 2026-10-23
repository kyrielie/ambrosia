# Search and filter

Scope: the search-bar parser, the drawer/popup filter engines, and their SQL
generation. For the LRU caches these paths populate, see `caching.md`. For
the app-structure/UI shell these run inside, see `library-ui.md`.

---

Search:

- Raw text is parsed by `SearchQueryParser`.
- Prefixes: `tag:`, `author:`, `title:`, `series:`, `status:`, `warning:`, `category:`, `fulltext:`, `words:`.
- Scoped search supports compositional multi-token input via `SearchQueryParser.parseMultiToken(_:)` (e.g. `author:Alice tag:"Slow Burn" -tag:Angst words:>50k`).
  - Supports quote-pairing preserving spaces.
  - Supports negation prefixes (`-tag:`, `-author:`, `-series:`, `-title:`, `-warning:`, `-category:`) producing `.notEquals` / `.notContains` rules.
  - Supports word count bounds: `words:>50k` (`wordCountGT`), `words:<20k` (`wordCountLT`), and `words:10k-50k`.
  - Scoped tokens convert to `[FilterRule]` via `SearchQuery.asFilterRules()`.
- Single committed prefix tokens also become `FilterRule`s via `SearchQuery.asSingleFilterRule(resolvedTagTerm:)`.
- Plain terms use fuzzy title LIKE (`CalibreLibrary.fuzzyTitleCondition`). Only an explicit `fulltext:` prefix reaches `CalibreFTSLibrary`.
- `fulltext:` semantics (native mode, see `calibre-fts.md`): the text is NFKC-normalized and tried as raw FTS5 syntax first (`AND`, `OR`, `NEAR(...)`, `prefix*`, `^`). If FTS5 rejects the syntax (for example `C++`), it is retried once as an AND of quoted terms. Bare multi-word input is therefore AND, not an exact phrase; quote it (`"once upon a time"`) for a phrase. Matching is by token: `cat` does not match `category`. Accents: `resume` matches documents containing either `resume` or `résumé`, while `résumé` matches only the accented form. In `likeFallback` mode the text is matched literally as a substring instead.
- Suggestions query Calibre authors/tags/titles/series directly.
- `SearchActivityLog` (`@MainActor` singleton) keeps an in-memory ring buffer (200 entries) of committed search/filter operations for the current session, persisted per-library-hash to a JSON file in Application Support on `close()` and reloaded on `open()`. It dedupes only against the single most recent entry (not the whole window), and is not saved on crash/unclean shutdown — only on the `close()` path.

Filters — two front ends, one engine:

- The **drawer** (`FilterDrawer/FilterRule.swift`, `FilterBuilder.swift`, `FilterDrawerView.swift`) is a generic rule builder: `FilterExpression` is a list of `FilterGroup`s (rules ANDed/ORed within a group), groups joined by one top-level conjunction, across sixteen `FilterField` cases. The sheet uses a clean draft lifecycle (edits only commit on Apply) with macOS card-style boolean group visuals and fast indexed tag autocompletion via `AmbrosiaMetaDB.searchTags`.
- The **AO3-style filter** (`FilterPopup/AO3Filter*.swift`, `AO3FilterSidebarView.swift`) sits directly in the main library window as an in-window collapsible sidebar (default), with an optional detach button to pop out into a floating window. It reproduces AO3's web facet browser (`_filters.html.erb` layout): top submit/sort controls, separate top-level Include and Exclude sections with accordions for rating, warnings, categories, fandoms, characters, relationships, freeforms, and authors with checkboxes and count badges, authentic inline tag autocomplete search boxes inside tag accordions, and authentic "Word Count: From / To" numeric range inputs under More Options. Drawer rules (e.g. collection, title) are preserved losslessly across AO3 filter applications via `passthroughRules`. Facet queries are debounced with `DebounceTimer(delay: 0.15)` and bind candidate IDs via `SQLIDList`.
- SQL-evaluable rule fields (title, comment, author, series, tag/rating/warning/category, word count/kudos when a custom column is configured) are compiled by `FilterBuilder.sqlFragment(for:)` into correlated `EXISTS`/`NOT EXISTS` subqueries (aliased `btl2`/`t2`, `bal2`/`a2`, `bsl2`/`s2`) rather than outer joins — see Invariant 24.
- App-owned/in-memory-only fields (`isLiked`, `collection`, `status`, `crossover`, and `wordCount`/`kudos` when no custom column exists) never produce SQL; they are resolved as `Set<Int>` intersections against caller-supplied membership maps (`likedIDs`, `collectionMap`, `statusMap`, `crossoverMap`) inside `matchingIDsForGroup`, applied as a post-filter over whatever the SQL-backed rules in the same group already returned. This composition is correct only because of that specific evaluation order; see Invariant 25 before adding a new in-memory field type.
- Filter results are cached in `filterResultCache`, an 8-entry LRU keyed on a digest of `FilterExpression` (group index + sorted per-group rules) plus `membershipVersion`, a counter bumped after any liked/skipped/status change. Page and count results have their own, larger (48-entry) LRU caches (`pageCache`, `countCache`, `groupAwareCountCache`) on `CalibreLibrary`, keyed similarly plus sort/offset/visibility/random-seed fields — see "Caching", below.
- Tag-value synonym expansion (canonical tag -> synonym set, via `AmbrosiaMetaDB.expandedTermsBatch`) is resolved per filter application by `TagExpansionResolver.filterTagExpansions(for:metaDB:)`, which returns a small dictionary scoped to only the tag values present in the *current* filter expression — not the full synonym table, and not stable across filter changes. `FilterBuilder` stores its own copy as `let tagExpansions`, set once at `init`, since a `FilterBuilder` instance is fresh per call and safe to own state on. `CalibreLibrary` is a long-lived `actor` shared across both surfaces and across overlapping in-flight queries; `sqlFilterClause`, `sqlFragment`, `calibreIDs(matchingRules:)`, `bookCount`, `wordCountSortedPage`, `randomSortedPage`, and `fetchAllMatchingIDs` all live on `CalibreLibrary` (some called only through `FilterBuilder`, some called directly from `LibraryRootView`/`EmailLibraryViewController`), so `tagExpansions`/`filterTagExpansions` is threaded through as an explicit parameter on all six rather than cached as actor state — caching it there would let one surface's synonym lookup silently overwrite another's mid-query. See Invariant 17.
- The visibility rules that were previously scattered as bool + cached-`Set<Int>` pairs (skipped, series-or-merged grouping, AO3-publisher allow-list, anthology deny-list) are consolidated into `LibraryVisibilityPolicy`, a value type built fresh per surface as `currentVisibilityPolicy` and passed into `CalibreLibrary.wordCountSortedPage`/`randomSortedPage` as `visibility:`, replacing the old `excludeIDs:` parameter and the per-branch AO3-only-random patches. See Invariant 22.

---

## Tag Synonyms and Facet Counts

### 1. Synonym Resolution vs Filtering
- **Synonym Database**: When enabled (`AO3TagSeedDatabaseConfig`), Ambrosia loads canonical tags and synonym mappings (`canonical_tags` and `tag_synonyms` in `ambrosia_meta.db`).
- **Tag Expansion at Filter Time**: When filtering on a tag rule (e.g. `.tag == "Marvel - All Media Types"`), `TagExpansionResolver.filterTagExpansions` queries `AmbrosiaMetaDB.expandedTermsBatch` to look up all synonyms belonging to that canonical cluster.
- **Distinct Work Matching**: `FilterBuilder.expandedTagFragment` generates a correlated subquery:
  ```sql
  EXISTS (
      SELECT 1 FROM books_tags_link btl2
      JOIN tags t2 ON t2.id = btl2.tag
      WHERE btl2.book = b.id AND (t2.name = ? OR t2.name = ? ...)
  )
  ```
  Because the check operates at the book level (`b.id`), every book containing **at least one** synonym in that cluster is matched and returned **exactly once**. If 2,000 distinct books match, the filtered view displays 2,000 works.

### 2. Why Facet Counts Can Exceed Filtered Work Counts (e.g. 6,000+ vs 2,000)
In the AO3-style filter sidebar/popup, each tag facet displays a count badge. This number can be significantly higher than the number of works returned when applying the filter:
- **Raw Facet Query**: `AmbrosiaMetaDB.topFacets(for:scopedTo:limit:)` (and `topFacetsUnconstrained`) queries SQLite for tag frequencies across metadata JSON:
  ```sql
  SELECT je.value AS name, COUNT(*) AS cnt
  FROM ao3_metadata, json_each(ao3_metadata.fandoms_json) AS je
  GROUP BY je.value
  ```
  This counts how many times each individual raw tag name appears.
- **Canonical Merging (`AmbrosiaMetaDB.canonicalize`)**: The controller groups these raw tag counts by their canonical name:
  ```swift
  for (name, count) in rawFacets {
      let canonical = canonicalTerm(for: name)
      merged[canonical, default: 0] += count
  }
  ```
- **The Discrepancy**: On AO3, works frequently carry multiple related and synonymous tags on the *same work* (e.g. a single fic tagged with *"Marvel"*, *"Marvel Cinematic Universe"*, and *"The Avengers (Marvel Movies)"*).
  - Each of those 3 raw tags appears ~2,000 times across the library.
  - All 3 map to the single canonical root *"Marvel - All Media Types"*.
  - `canonicalize` sums their raw counts: `2,000 + 2,000 + 2,000 = 6,000+`.
  - The facet badge therefore reflects the **sum of tag occurrences across all synonyms**, whereas applying the filter tests book-level set membership, counting each distinct matching work once (2,000 works).

### 3. Effect of Series Grouping
When `toolbarState.groupBySeries` is enabled (active only when sorted by Title), `SeriesGroupBuilder` and `LibraryVisibilityPolicy.filter` collapse books belonging to the same series into a single representative series row (`visibleTotalCount`). While this can further reduce the visible item count on a page if multi-work series are present, the multi-thousand discrepancy between facet badge count and filtered work count is primarily the result of tag-occurrence summation in `canonicalize`.

---

### Known Limitations (Filter/Search)

- **Two independent SQL-generation paths** exist for the same tag/author/series matching logic: `FilterBuilder.sqlFragment(for:)` (drawer/popup path) and `CalibreLibrarySearch.whereClause(for:)` (search-bar path). A correctness or performance fix to one (e.g. the NOT EXISTS rewrite, Invariant 24) does not automatically apply to the other, so treat them as needing separate verification when either changes. As of this writing `CalibreLibrarySearch._bookCount(query:)` does not carry an outer `LEFT JOIN` — it already routes every tag/author/series condition through the same self-contained `EXISTS`/`NOT EXISTS` shape `FilterBuilder` uses (see Invariant 24); this is now pinned by `CalibreLibrarySearchTests.swift`.
- `SearchQueryParser.parseMultiToken` provides compositional quick-search syntax (multiple scoped tokens, quote-preserving values, negation, and word count ranges).
- AO3 popup facet counts (`topFacets`) are debounced with `DebounceTimer(delay: 0.15)` and single-bound via `SQLIDList`.
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

## Full-text failure state

Filter `fulltext` rules and the search-bar `fulltext:` phrase both consult `LibrarySession.fulltextState(for:)`. A rule whose phrase is `.failed` contributes an empty set rather than triggering another search. See "UI behavior on failure" in `calibre-fts.md`.

## Incremental evaluation (narrowing)

Adding one complete rule to an already-evaluated expression evaluates only that
rule against the cached result (`FilterEvaluator` with `candidates`). Eligible only
when the rule is in an AND group, the top level is a single complete group or AND,
the group keeps at least one other complete rule, and the base was cached under the
same membership version, visibility signature (which includes whether word-count
and kudos are custom columns) and `bookTagsRevision`. Removal, replacement and any
OR are full computes. Narrowed results skip the visibility refetch because the base
is already visibility-filtered. Gated by `IncrementalFilterFlag` (UserDefaults key
`incrementalFilterEvaluation`; default on in debug, off in release until gate G3 of
the plan is run by hand).

Tag rules: `.equals` and rating operators are never candidate-restricted;
`.contains`/`.startsWith` are restricted only when candidates are at most 10 percent
of the books with `book_tags` rows (`TagRuleStrategy`). AND-group tag rules run in
cost order (`AndGroupOrdering`); order never changes the result.

Per `matchingIDs` call, `book_tags` coverage is read once into a `TagCoverage`
(`covered`, `uncovered`, `totalCount`) and shared by every tag-family rule, instead
of once per rule. The Calibre-side fallback `SELECT` for books without `book_tags`
rows answers only for `uncovered`: it is skipped when `uncovered` is empty, limited
to the `uncovered` ids when they are at most half the library
(`TagCoverage.shouldRestrictFallback`), and otherwise runs unrestricted and subtracts
`covered`. A candidate-restricted match set is a subset of the global one and is
never stored in `ruleMatchCache`, which holds global sets only.


### Persisted filter expression

`FilterExpression` is `Codable` and the last-used one is persisted per library as part of `LastViewState` (see `library-ui.md`). On restore, `LastViewValidator.validate` drops rules that name a collection no longer in `collections()`, drops `fulltext` rules (so restore never starts FTS work at launch), and drops incomplete rows. Series and tag rules are not validated, so a stale one shows the existing no-results state; the existing clear-filter control resets the view and, through `LibraryToolbarState`'s recording, the persisted state.
