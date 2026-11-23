# Search and filter

Scope: the search-bar parser, the drawer/popup filter engines, and their SQL
generation. For the LRU caches these paths populate, see `caching.md`. For
the app-structure/UI shell these run inside, see `library-ui.md`.

---

Search:

- Nonempty text in the toolbar field remains a draft while the user types. It is committed to `LibraryToolbarState.searchText` only on Return or when an autocomplete suggestion is selected; those commits start result loading. Clearing the field immediately clears the committed query.
- Raw text is parsed by `SearchQueryParser`.
- Prefixes: `tag:`, `author:`, `title:`, `series:`, `status:`, `warning:`, `category:`, `fulltext:`, `words:`, `semantic:`.
- Precision matching operators (Calibre search-bar syntax parity):
  - Exact match (`=`): `tag:=value`, `title:="Exact Title"`, `author:="Exact Author"`, `series:="Exact Series"`. Compares field equality (`field = ?` in SQL, `.equals` operator).
  - Regex match (`~`): `tag:~"pattern"`, `title:~"^The "`, `author:~"Surname, [A-Z]"`, `series:~"pattern"`. Evaluates SQLite `REGEXP ?` pattern matching (`.matchesRegex` operator).
  - Whole-word match (`""`): `tag:"Fluff"`, `author:"Alice"`. Word-bounded search (`.matchesWord` operator) enforcing `\b` boundaries.
  - Negation with precision operators: `-tag:=`, `-tag:~`, `-author:=`, `-author:~`, `-series:=`, `-series:~`, `-title:=`, `-title:~`.
- SQLite `REGEXP` support (`SQLiteRegexRegistration`):
  - Registers custom SQLite scalar `regexp(pattern, text)` using `sqlite3_create_function_v2` and a thread-safe LRU `RegexCache` (caching compiled `NSRegularExpression` with `.caseInsensitive`).
  - Active across all read/write connections in `CalibreLibrary` and `AmbrosiaMetaDB`.
- Local Semantic & Hybrid Search:
  - `semantic:"phrase"` queries Apple's built-in on-device sentence embeddings (`NLEmbedding.sentenceEmbedding(for: .english)` via `SemanticSearchEngine`).
  - Work profile text is synthesized via `WorkEmbeddingSynthesizer` combining title, author, fandoms, relationships, characters, freeforms, ratings, language, status, and stripped summary (clamped to 600 chars).
  - Embeddings are persisted in memory-mapped binary format (`VectorStore`, magic `0x4C465631`) and scanned using Apple `Accelerate` BLAS SIMD (`cblas_sgemv`) for high-speed cosine similarity.
  - `HybridSearchCoordinator` blends lexical (Calibre/FTS) and semantic candidate ranks using Reciprocal Rank Fusion ($k=60$).
- Scoped search supports compositional multi-token input via `SearchQueryParser.parseMultiToken(_:)` (e.g. `author:Alice tag:"Slow Burn" -tag:Angst words:>50k`).
  - Supports quote-pairing preserving spaces.
  - Supports negation prefixes (`-tag:`, `-author:`, `-series:`, `-title:`, `-warning:`, `-category:`) producing `.notEquals` / `.notContains` rules.
  - Supports word count bounds: `words:>50k` (`wordCountGT`), `words:<20k` (`wordCountLT`), and `words:10k-50k`.
  - Scoped tokens convert to `[FilterRule]` via `SearchQuery.asFilterRules()`.
- Single committed prefix tokens also become `FilterRule`s via `SearchQuery.asSingleFilterRule(resolvedTagTerm:)`.
- Plain terms use fuzzy title LIKE (`CalibreLibrary.fuzzyTitleCondition`). Only an explicit `fulltext:` prefix reaches `CalibreFTSLibrary`.
- `fulltext:` semantics (native mode, see `calibre-fts.md`): the text is NFKC-normalized and tried as raw FTS5 syntax first (`AND`, `OR`, `NEAR(...)`, `prefix*`, `^`). If FTS5 rejects the syntax (for example `C++`), it is retried once as an AND of quoted terms. Bare multi-word input is therefore AND, not an exact phrase; quote it (`"once upon a time"`) for a phrase. Matching is by token: `cat` does not match `category`. Accents: `resume` matches documents containing either `resume` or `résumé`, while `résumé` matches only the accented form. In `likeFallback` mode the text is matched literally as a substring instead.
- Dedicated Full-Text Search Window (`FTSSearchResultsWindowController`, shortcut `⇧⌘F`, menu **Edit ▸ Search Library Body Text…**, or the toolbar magnifying glass): Opens a dedicated typographic multi-snippet search surface allowing users to search book body text across either the **Current Filter** or **All Books**, view highlighted passage cards, and jump directly to occurrences in the Reader. Snippet extraction (`FTSOccurrenceExtractor`) uses regex word boundaries (`\b`) around alphanumeric search tokens to prevent false-positive highlights ("love" inside "gloves"/"inlove"). The toolbar button is hidden by default and menu items disabled whenever FTS is turned off in settings or `full-text-search.db` is unavailable. Building the FTS database is strictly opt-in from Preferences ▸ Data.
- Semantic Passage Search Mode: Inside `FTSSearchResultsWindowController`, users can toggle between **Exact (FTS5)** and **Semantic (Passages)**. Powered by `PassageDatabase` (reading `ambrosia_semantic_passages.db` with 2GB `mmap_size` and packed FP16 vectors) and `PassageQueryEmbedder` (CoreML inference on Apple Neural Engine / GPU). Returns ranked narrative scenes and conceptual tropes with match confidence percentages (e.g. `94% Match`). Cards lazily stream full ~400-word paragraph excerpts directly from local EPUB files via `PassageSnippetExtractor`. Clicking "Jump to Scene ↗" invokes `ReaderViewController.jumpToPassage` to jump directly to the target spine item and offset with a transient decaying glow highlight. For external headless indexing instructions, see `docs/guides/external-semantic-indexing-walkthrough.md`.
- Suggestions query an immutable, in-memory `SuggestionSnapshot` owned by `CalibreLibrary.suggestionStore` off-actor, with fallback to escaped SQLite LIKE queries (`ESCAPE '\\'`) during initial warm-up.
  - **Tag Types & Coloring**: Calibre tags are layered with `book_tags.tag_type` classifications from `AmbrosiaMetaDB` (`relationship`, `character`, `fandom`, `freeform`, `rating`, `warning`, `category`). Tag icons in the Search Bar suggestions and Filter Drawer are tinted by tag type (`Color.pink` for relationships, `Color.blue` for characters, `Color.indigo` for fandoms, `Color.orange` for ratings, `Color.red` for warnings, `Color.purple` for categories, neutral/secondary for freeforms and unknown).
  - **Relationship Order Invariance**: Queries containing explicit separators (`/`, `&`, `+`, `|`, `,`, or standalone `x`) or multiple name tokens match constituent character entities in any order (e.g. `steve/tony` and `tony / steve` match `Tony Stark/Steve Rogers`), supporting surname omission and first-name prefix matching.
  - **Typo Tolerance**: Fast, prefix-tolerant Damerau-Levenshtein / Optimal String Alignment (OSA) matching over distinct token vocabularies with length-adaptive edit distance ($\le 3 \to 0$, $4–6 \to 1$, $\ge 7 \to 2$).
  - **Strict Match Ranking**: Candidates are ranked strictly by match class (`exact > prefix > wordPrefix > substring > relationshipPermuted > acronym > fuzzyDistance1 > fuzzyDistance2`), with link usage frequency acting strictly as a tie-breaker within the same match class.
  - **Concurrency & UI Safety**: Keystroke queries in `LibraryWindowController` track active tasks, cancel previous in-flight tasks, and verify generation tokens to prevent stale completions from overwriting newer queries. Suggestions only offer `fulltext:` search when FTS is enabled and available, and `semantic:` search only when `enableSemanticSearch` is true and `hasSemanticIndex` confirms `semantic_vectors.bin` exists for the current library. Empty filter/search restriction ID sets fail closed with `0 = 1` SQL clauses to prevent fallback to unconstrained library queries.
- Search Field & In-App Documentation:
  - Search field uses clean macOS-standard `"Search"` placeholder to avoid text truncation on narrower window sizes.
  - Full syntax reference and shortcut guide is accessible in-app via **Preferences ▸ Documentation** (`⌘,`).
- Search Preferences & Feature Toggles (**Preferences ▸ Data**):
  - **Full-Text Search (FTS)**: Toggle `enableFullTextSearch` enables or bypasses Calibre FTS5 queries; displays availability of `full-text-search.db`; includes opt-in action buttons to "Build Full-Text Search Index" / "Index Unindexed Works" and "Clear Index"; toggle `autoOpenFindBarForFullTextSearch` controls whether opening a book from full-text search automatically launches the reader find bar.
  - **Local Semantic Search**: Toggle `enableSemanticSearch` enables or disables on-device Apple sentence embeddings (`semantic:`); includes index status and interactive buttons to Rebuild or Clear the vector store.
- Contextual Relevance Sort Order:
  - When search or filtering is active, the toolbar Sort menu exposes a **Relevance** option (`SortField.relevance`).
  - When Relevance sort is selected:
    - **Tag-Only Filters**: Candidate works are sorted primarily by **first-listed tag order** (`AmbrosiaMetaDB.firstListedPositions` using SQLite JSON1 `json_each` pushdown over `relationships_json`, `characters_json`, `fandoms_json`, `additional_tags_json`). Tag position is a ranking hint only and never filters out works. Works where the target tag is first-listed within its category (index 0) rank ahead of later-listed tags (index 1+). Role rank strictly dominates index (e.g. a relationship at index 5 outranks a character at index 0). Priority across roles: relationships (0) > characters (1) > fandoms (2) > freeform tags (3). Uncovered / non-AO3 books sort after matched ones. Ties break by existing list order (title). Only positive tag operators (`.equals`, `.contains`) and positive search-bar terms (`.exact`, `.contains`) contribute positive ranking targets along with their resolved synonyms (`TagRelevanceTargets`); negative, regex, starts-with, whole-word, rating, warning, and category rules contribute no targets. Committed `tag:` tokens become filter rules and leave the search field. `ascending: true` flips position order and places unmatched books first.
    - **Text Query Present (FTS / Semantic)**: With `fulltext:` only, FTS hits are unranked by SQLite, forming a single tie class ordered by tag position then title. With semantic search active, semantic vector similarity ranks are strictly primary and are never overridden by tag position (tag position acts strictly as a tie-breaker).
    - In-memory Reciprocal Rank Fusion (`HybridSearchCoordinator.fuse(lexicalIsRanked:)`) fuses lexical/FTS hit sets with Apple NaturalLanguage semantic vector similarity scores; unranked lexical hits (FTS and title-ordered lexical matches) contribute an equal `1 / (k + 1)` score rather than an arbitrary positional rank.
  - If search is cleared while sorting by Relevance, the sort field automatically returns to the user's previously selected sort order (e.g. Title, Word Count, Kudos) only when no filter is active (`LibraryToolbarState.searchText` and `activeFilterResult` observers).
  - On app launch/library switch, `LastViewState` safely normalizes any transient Relevance state to default Title sort, preventing invalid persisted sort order when no query is active.
- Active Filter Ribbon Toolbar:
  - Displays tokenized pills in `activeFilterChip` (`FilterRulePillView`, `FullTextPillView`, `PendingFullTextPillView`).
  - **1-Click Dismissal**: Each pill carries a 16pt trailing `xmark` button for instant removal.
  - **Context Menu Actions**: Right-clicking any pill displays contextual actions:
    - *Remove Filter*: Dismisses the token and re-evaluates filters (calls `clearAllFilters()` when no complete rules remain).
    - *Exclude/Include This Filter*: Toggles between `.contains` $\leftrightarrow$ `.notContains` or `.equals` $\leftrightarrow$ `.notEquals` (gated by `FilterRule.canToggleNegation`).
    - *Copy Filter Value / Phrase*: Copies the token's value to the system clipboard (`NSPasteboard`).
    - *Edit in Filter Drawer…*: Opens `FilterDrawerView`.
    - *Clear All Filters*: Resets all filter rules, active filter result, and schedules page reload.
  - **Full-Text Token Stripping**: Removing a fulltext pill calls `SearchQueryParser.removingFulltext(from:)` to strip the `fulltext:...` token while preserving any concurrent search text tokens.
- `SearchActivityLog` (`@MainActor` singleton) keeps an in-memory ring buffer (200 entries) of committed search/filter operations for the current session, persisted per-library-hash to a JSON file in Application Support on `close()` and reloaded on `open()`. It dedupes only against the single most recent entry (not the whole window), and is not saved on crash/unclean shutdown — only on the `close()` path.

Filters — two front ends, one engine:

- The **drawer** (`FilterDrawer/FilterRule.swift`, `FilterBuilder.swift`, `FilterDrawerView.swift`) is a generic rule builder: `FilterExpression` is a list of `FilterGroup`s (rules ANDed/ORed within a group), groups joined by one top-level conjunction, across sixteen `FilterField` cases. The sheet uses a clean draft lifecycle (edits only commit on Apply) with macOS card-style boolean group visuals and fast indexed tag autocompletion via `AmbrosiaMetaDB.searchTags`.
- The **AO3-style filter** (`FilterPopup/AO3Filter*.swift`, `AO3FilterSidebarView.swift`) sits directly in the main library window as an in-window collapsible sidebar (default), with an optional detach button to pop out into a floating window. It reproduces AO3's web facet browser (`_filters.html.erb` layout): top submit/sort controls, separate top-level Include and Exclude sections with accordions for rating, warnings, categories, fandoms, characters, relationships, freeforms, and authors with checkboxes and count badges, authentic inline tag autocomplete search boxes inside tag accordions, and authentic "Word Count: From / To" numeric range inputs under More Options. Drawer rules (e.g. collection, title) are preserved losslessly across AO3 filter applications via `passthroughRules`. Facet queries are debounced with `DebounceTimer(delay: 0.15)` and bind candidate IDs via `SQLIDList`.
- SQL-evaluable rule fields (title, comment, word count/kudos when a custom column is configured) are compiled by `FilterBuilder.sqlFragment(for:)` into SQL clauses. For tag, rating, warning, category, authorName, and series, `sqlFragment` returns nil: these are evaluated in memory against `book_tags`, `book_authors`, and `series_cache`, with `FilterBuilder.expandedTagFragment` providing a correlated `EXISTS`/`NOT EXISTS` Calibre-side fallback only for books uncovered by `book_tags` — see Invariant 24.
- App-owned/in-memory-only fields (`isLiked`, `collection`, `status`, `crossover`, and `wordCount`/`kudos` when no custom column exists) never produce SQL; they are resolved as `Set<Int>` intersections against caller-supplied membership maps (`likedIDs`, `collectionMap`, `statusMap`, `crossoverMap`) inside `matchingIDsForGroup`, applied as a post-filter over whatever the SQL-backed rules in the same group already returned. This composition is correct only because of that specific evaluation order; see Invariant 25 before adding a new in-memory field type.
- Visible-view collection rules receive the collection membership map captured by `LibraryDisplayController` when the query is pinned. Filter-cache eviction therefore cannot cause an unchanged visible query to reevaluate against newer membership data under its old pin. The live Series or Merged and Failed Extraction maps remain refreshed from their visibility/diagnostic sources.
- Filter results are cached in `filterResultCache`, an 8-entry LRU keyed on a digest of `FilterExpression` (group index + sorted per-group rules) plus `visibilityVersion` and `pinnedCollectionVersion` (counters bumped after visibility or collection membership changes). Page and count results have their own, larger (48-entry) LRU caches (`pageCache`, `countCache`, `groupAwareCountCache`) on `CalibreLibrary`, keyed similarly plus sort/offset/visibility/random-seed fields — see "Caching", below.
- Tag-value synonym expansion (canonical tag -> synonym set, via `AmbrosiaMetaDB.expandedTermsBatch`) is resolved per filter application by `TagExpansionResolver.filterTagExpansions(for:metaDB:)`, which returns a small dictionary scoped to only the tag values present in the *current* filter expression — not the full synonym table, and not stable across filter changes. `FilterBuilder` stores its own copy as `let tagExpansions`, set once at `init`, since a `FilterBuilder` instance is fresh per call and safe to own state on. `CalibreLibrary` is a long-lived `actor` shared across both surfaces and across overlapping in-flight queries; `sqlFilterClause`, `sqlFragment`, `calibreIDs(matchingRules:)`, `bookCount`, `wordCountSortedPage`, `randomSortedPage`, and `fetchAllMatchingIDs` all live on `CalibreLibrary` (some called only through `FilterBuilder`, some called directly from `LibraryRootView`/`EmailLibraryViewController`), so `tagExpansions`/`filterTagExpansions` is threaded through as an explicit parameter on all six rather than cached as actor state — caching it there would let one surface's synonym lookup silently overwrite another's mid-query. See Invariant 17.
- The visibility rules that were previously scattered as bool + cached-`Set<Int>` pairs (skipped, series-or-merged grouping, AO3-publisher allow-list, anthology deny-list) are consolidated into `LibraryVisibilityPolicy`, a value type built fresh per surface as `currentVisibilityPolicy` and passed into `CalibreLibrary.wordCountSortedPage`/`randomSortedPage` as `visibility:`, replacing the old `excludeIDs:` parameter and the per-branch AO3-only-random patches. See Invariant 22.

---

## Tag Synonyms and Facet Counts

### 1. Synonym Resolution vs Filtering
- **Synonym Database**: When enabled (`AO3TagSeedDatabaseConfig`), Ambrosia loads canonical tags and synonym mappings (`canonical_tags` and `tag_synonyms` in `ambrosia_meta.db`).
- **Tag Expansion at Filter Time**: When filtering on a tag rule (e.g. `.tag == "Marvel - All Media Types"`), `TagExpansionResolver.filterTagExpansions` queries `AmbrosiaMetaDB.expandedTermsBatch` to look up all synonyms belonging to that canonical cluster.
- **Distinct Work Matching (Calibre-Side Fallback)**: For books uncovered by `book_tags`, `FilterBuilder.expandedTagFragment` generates a correlated subquery fallback:
  ```sql
  EXISTS (
      SELECT 1 FROM books_tags_link btl2
      JOIN tags t2 ON t2.id = btl2.tag
      WHERE btl2.book = b.id AND (t2.name = ? OR t2.name = ? ...)
  )
  ```
  Because the check operates at the book level (`b.id`), every book containing **at least one** synonym in that cluster is matched and returned **exactly once**. If 2,000 distinct books match, the filtered view displays 2,000 works.

### 2. Canonical-Deduped Facet Counts (Zero Inflation)
In the AO3-style filter sidebar/popup, each tag facet displays a count badge. In earlier builds, this number could be significantly higher than the number of works returned when applying the filter due to raw occurrence summing across synonyms (`canonicalize`).

To eliminate this discrepancy:
- **Canonical Facet Query**: `AmbrosiaMetaDB.canonicalFacets(for:scopedTo:limit:)` (and `canonicalFacetsUnconstrained`) queries `book_tags` joined with `tag_canonical_map`:
  ```sql
  SELECT COALESCE(m.canonical_name, bt.tag_name) AS name, COUNT(DISTINCT bt.calibre_id) AS cnt
  FROM json_each(?) j
  JOIN book_tags bt ON bt.calibre_id = j.value AND bt.tag_type = ?
  LEFT JOIN tag_canonical_map m ON m.tag_name = bt.tag_name
  GROUP BY name
  ORDER BY cnt DESC
  LIMIT ?
  ```
- **Zero Inflation**: Because SQLite aggregates `COUNT(DISTINCT bt.calibre_id)` grouped by canonical tag name, a work carrying multiple synonyms for the same canonical tag (e.g. *"Stucky"* and *"Steve Rogers/Bucky Barnes"*) is counted **strictly once**. The facet badge matches the work count returned after checking the filter box.
- **Post-Merge Top-N Ranking**: The `LIMIT ?` cutoff is applied in SQL *after* grouping by canonical name, ensuring popular canonical tags split across multiple low-frequency synonyms are ranked accurately.
- **Legacy Fallback**: `AmbrosiaMetaDB.topFacets(for:scopedTo:limit:)` and `topFacetsUnconstrained` remain for non-tag facets (such as author facets from `ao3_metadata.author_names_json`) or when tag-type mapping is not applicable.

### 3. Effect of Series Grouping
When `toolbarState.groupBySeries` is enabled (active only when sorted by Title), `SeriesGroupBuilder` and `LibraryVisibilityPolicy.filter` collapse books belonging to the same series into a single representative series row (`visibleTotalCount`). This can reduce the visible item count on a page if multi-work series are present.

---

### Known Limitations (Filter/Search)

- **Two independent SQL-generation paths** exist for the same tag/author/series matching logic: `FilterBuilder.sqlFragment(for:)` (drawer/popup path) and `CalibreLibrarySearch.whereClause(for:)` (search-bar path). A correctness or performance fix to one (e.g. the NOT EXISTS rewrite, Invariant 24) does not automatically apply to the other, so treat them as needing separate verification when either changes. As of this writing `CalibreLibrarySearch._bookCount(query:)` does not carry an outer `LEFT JOIN` — it already routes every tag/author/series condition through the same self-contained `EXISTS`/`NOT EXISTS` shape `FilterBuilder` uses (see Invariant 24); this is now pinned by `CalibreLibrarySearchTests.swift`.
- `SearchQueryParser.parseMultiToken` provides compositional quick-search syntax (multiple scoped tokens, quote-preserving values, negation, and word count ranges).
- AO3 popup facet counts (`canonicalFacets`) are debounced with `DebounceTimer(delay: 0.15)` and single-bound via `SQLIDList`.
- Crossover membership is cached: `AmbrosiaMetaDB.allCrossoverBookIDs()` (a `json_array_length(fandoms_json) > 1` scan over `ao3_metadata`) runs in `LibrarySession`'s AO3 cache refresh (library open and after extraction batches) and is stored in `CalibreLibrary.crossoverIDCache` via `updateAO3MetaCaches`. `crossoverBookIDs()` returns that cache, so `AO3FilterFacetController.make` does not rescan on popup open. Remaining limitation: the test counts raw `fandoms_json` entries without canonicalization, so a work tagged with two synonymous fandoms (e.g. "Marvel" and "Marvel Cinematic Universe") is treated as a crossover. AO3 itself replaces tags with their canonical merger and ignores meta-tag-related fandoms (`FandomCrossover.check_for_crossover` in otwarchive).
- `AO3FilterFacetController.make` builds `statusMap` for every `AO3CompletionStatus` case unconditionally (the popup's own completion control can narrow facets even when the base expression has no status rule), one indexed query per case. The enum has two cases (`complete`, `workInProgress`), so this is two queries per popup open, not an unbounded N+1. `FilterEvaluator` only queries the statuses referenced by the expression's rules.
- Tag facet badges route through `AmbrosiaMetaDB.canonicalFacets`/`canonicalFacetsUnconstrained` using `book_tags` and `tag_canonical_map`. Author facets continue to tally `ao3_metadata.author_names_json`.
- Tag hierarchy is not used by filtering: `tag_parent_links` in the seed database is counted for validation (`AO3TagSeedDatabaseConfig.counts`) but no filter or facet path consults it, so filtering a parent fandom does not match works tagged only with a sub-fandom.
- No index is created (or verified) on `books_tags_link`/`books_authors_link`/`books_series_link` by Ambrosia itself — these tables belong to Calibre's own `metadata.db` schema, and Calibre normally indexes them, but nothing here defensively creates a fallback index (`CREATE INDEX IF NOT EXISTS` is idempotent even against a foreign schema) for libraries where that index is missing or was stripped.

---


---

## Random sort

Seeded random sort with Xorshift64 (`SeededRNG`), stable within a session. Used by `CalibreLibrary.randomSortedPage` (see `visibility:` handling in Invariant 22 above) and the local feed server's opt-in random-daily route (`local-feed-server.md`).

---

## Key invariants

17. `tagExpansions`/`filterTagExpansions` are threaded as explicit parameters through `sqlFilterClause`, `sqlFragment`, `calibreIDs(matchingRules:)`, `bookCount`, `wordCountSortedPage`, `randomSortedPage`, and `fetchAllMatchingIDs` rather than cached as `CalibreLibrary` actor state, because `CalibreLibrary` is a long-lived actor shared across overlapping in-flight queries. Full rule and rationale in `concurrency-invariants.md`.

22. Library visibility rules (skip/show-skipped, series-or-merged grouping, AO3-publisher-only, anthology-hiding) live in one value type, `LibraryVisibilityPolicy`, built fresh per surface (`currentVisibilityPolicy`) and passed as `visibility:` into `CalibreLibrary.wordCountSortedPage`/`randomSortedPage`. Do not reintroduce a bool + cached-`Set<Int>` pair wired independently through call sites for a new visibility toggle — add a field to `LibraryVisibilityPolicy` instead. The old `LibraryQueryHelpers.visibleIDs`/`.visibleBooks` free functions and the `excludeIDs:` parameter they fed are retired; do not resurrect either.

24. Negated many-to-many filter conditions (tag/rating/warning/category/author/series `notEquals`/`notContains`) must be built as a correlated `NOT EXISTS (... WHERE btl2.book = b.id AND ...)` subquery, never as `b.id NOT IN (SELECT book FROM ... WHERE ...)`. The `NOT IN` shape forces SQLite to materialise the entire matching-book set and anti-join it against all of `books`, and a leading-wildcard `LIKE` inside that subquery can't use any index — a full scan of `tags` per evaluation. `NOT EXISTS` correlates on the outer book id, letting SQLite seek the `books_tags_link(book)` index per book instead. Relatedly: never add an outer `LEFT JOIN books_tags_link/tags` (or the authors/series equivalents) "to support" these fields — every one of them is already a self-contained correlated subquery aliased `btl2/t2` (or `bal2/a2`, `bsl2/s2`); an outer join with unused outer aliases only fans every book out to one row per tag before `SELECT DISTINCT` collapses it back down, multiplying the cost of every `NOT EXISTS` re-evaluation for no benefit. Both `FilterBuilder.swift` and `CalibreLibrarySearch._bookCount(query:)` route tag/author/series conditions without outer joins.

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
