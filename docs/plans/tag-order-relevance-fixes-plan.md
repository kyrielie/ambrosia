# Tag-Order Relevance: Fixes and Doc Corrections

**Status**: Shipped. Implemented across Passes 1–5 on November 22, 2026. Intended path: `docs/plans/tag-order-relevance-fixes-plan.md`.
**Audience**: an AI engineer implementing in passes (one concern per pass, tests included, docs updated in the same pass).
**Supersedes nothing**. Corrects and completes `filter-ribbon-toolbar-and-tag-order-narrative-plan.md` (B1), which shipped with the integration gaps below.

Labels: **Verified** = confirmed by reading code in this snapshot. **Unverified** = not confirmed. Nothing here was built or run (no macOS toolchain in the review environment). Do not claim a pass until `./test.sh`, `swiftlint lint --strict` and `xcodebuild build` have actually been run.

---

## 0. Owner decisions this plan assumes

1. Tags within a category are listed by author importance, usually. This is accepted as an assumption, not tested. The B1 spot-check gate in the earlier plan is waived by the owner.
2. UI label stays "first-listed". Code comments and docs use "first-listed" too, never "primary pairing" or "protagonist".
3. Role rank beats index (relationship > character > fandom > freeform, then lowest index). Kept for now; revisit after seeing real results.
4. With a text query, tag position is a tie-breaker only and never overrides real text relevance.
5. Position stays in `ao3_metadata.*_json`. No migration, no position column. Re-evaluate only if the performance gate in Pass 4 fails.
6. Excluding a tag still excludes its synonyms in filtering (unchanged). Relevance must not treat excluded tags as positive targets.
7. Regex and whole-word tag terms contribute no relevance positions.
8. Failures in position lookup are logged to `error_log` and fall back to title order.

No persisted-format change, no new dependency, no design-doc conflict is intended. If any pass would require one, stop and ask.

---

## 1. Verified problems being fixed

| # | Problem | Evidence |
|---|---------|----------|
| P1 | Tag filters from the drawer, AO3 popup, and committed `tag:` search tokens never reach the relevance sort. Relevance on such a view returns title order and ignores `ascending`. | `LibraryWindowController.commitCurrentSearchText` converts `tag:` tokens to `FilterRule`s and clears the field. `FilterExpression.isSQLPageable` (`FilterBuilder.swift` ~225) is false whenever any complete rule is `.tag`, `.authorName`, `.series`, `.rating`, `.warning`, `.category`, `.collection`, `.status`, `.fulltext`, `.crossover`. `FilterResult(isSQLBacked: true)` is only created in the pageable branch (`LibraryDisplayController.applyFilterRules` ~616-635). The relevance call passes `filter: ...isSQLBacked == true ? filterExpression : nil` (~866). So the `.tag` loop in `CalibreLibrary.computeRelevanceSortedIDs` (~1196) is dead for tag rules. |
| P2 | With `fulltext:` or semantic text, tag position never affects order. | `rankMap` is `Dictionary(uniqueKeysWithValues: ranked.enumerated()...)`, so ranks are unique and the tie-break branch in `RelevanceOrdering.areInIncreasingOrder` is unreachable in production. |
| P3 | FTS ids are unranked but treated as a ranking. Hybrid RRF uses arbitrary or alphabetical lexical ranks. | `CalibreFTSLibrary.searchBooks` returns `SELECT DISTINCT bt.book` with no `ORDER BY` ("Ids only, unranked", file header). `LibraryDisplayController.resolveRelevanceRankedIDs` returns `ftsIDs` as-is, and in the semantic+plainTerms branch fuses `fetchAllMatchingIDs` output, which is `ORDER BY b.title`. |
| P4 | Synonym expansions are added for every operator, including `.notEquals`, `.startsWith`, regex. Lookup key is the trimmed value but `TagExpansionResolver.filterTagExpansions` keys on untrimmed `rule.value`. | `computeRelevanceSortedIDs`, `if let expansions = pageQuery.filterTagExpansions[trimmed]` sits outside the `switch`. |
| P5 | Search-bar regex and word modes become LIKE-contains targets. `warning:` and `category:` prefixes feed `scopedTagTerms`, so `category:M/M` substring-matches relationship `Sam/Mike`. The `tagTerms` loop duplicates `scopedTagTerms`. | `computeRelevanceSortedIDs` `scopedTagTerms` loop; `SearchQueryParser.parseMultiToken` prefix map. LIKE `%m/m%` vs `Sam/Mike` returned true in SQLite. |
| P6 | An empty (non-nil) `posMap` passes the guard and sorts by book id, not title. `firstListedPositions` swallows errors with `try?`. `json_each` on an empty-string or malformed column aborts the whole statement. | Guard `rankMap != nil \|\| posMap != nil`. SQLite 3.45.1: `json_each('')` and `json_each('not json')` raise "malformed JSON"; NULL is fine. Writers emit valid JSON, so exposure is legacy rows (Unverified whether any exist). |
| P7 | No integration test exercises relevance through `PageQuery`. Plan B3's `testRelevanceRecomputedAfterFlush` and a perf benchmark for gate B4 do not exist. | `TagOrderRelevanceTests` has 3 tests (positions, role rank, contains). `OrderedHydrationTests`/`SortedIDsCacheTests` use only `rankedIDs`. |
| P8 | Docs are stale or overstate behavior. | See Pass 5. |

Not changed by this plan (reviewed, correct): sorted-ID cache invalidation after extraction (`updateAO3MetaCaches` -> `clearQueryCaches` -> `invalidateSortedIDs`); `LastViewState` normalizing Relevance to Title; cache sizes 8 and 48; 16 `FilterField` cases; match-class order; typo thresholds; incremental-filter thresholds.

---

## 2. Design

### 2.1 `TagRelevanceTargets` (new, pure)

New file `Ambrosia/Database/TagRelevanceTargets.swift` (run `xcodegen generate`; do not hand-edit the pbxproj).

```swift
struct TagRelevanceTargets: Equatable, Sendable {
    var exact: [String] = []
    var contains: [String] = []
    var isEmpty: Bool { exact.isEmpty && contains.isEmpty }

    static func make(
        expression: FilterExpression?,
        query: SearchQuery,
        expansions: [String: [String]]
    ) -> TagRelevanceTargets
}
```

Rules for `make`:
- Filter rules: only `rule.field == .tag && rule.isComplete`, any group, any conjunction.
  - `.equals`: value goes to `exact`; every synonym from `expansions[rule.value]` also goes to `exact`.
  - `.contains`: value goes to `contains`; synonyms from `expansions[rule.value]` also go to `contains` (mirrors the filter, which applies LIKE to each synonym via `expandedTagFragment`).
  - Every other operator (`.notEquals`, `.notContains`, `.startsWith`, `.matchesWord`, `.matchesRegex`, rating operators): contributes nothing, including no expansions.
- Look up expansions by the exact key `rule.value` (untrimmed), then trim the terms used.
- Search-bar terms: iterate `query.scopedTagTerms` only. `.exact` goes to `exact` (+ synonyms), `.contains` goes to `contains` (+ synonyms), `.regex` and `.word` contribute nothing. Do not iterate `query.tagTerms` (duplicate of the scoped list). `query.excludedTagTerms` contribute nothing.
- Skip any value where `AO3TagKind.classify(value) != .regular` (rating, warning, category values). This removes the `category:M/M` false positive and applies to both sources.
- Deduplicate case-insensitively, preserve first-seen order, drop empty strings.

### 2.2 Carrying targets to the sort

Do not pass the filter into `PageQuery.filter` for this. `fetchAllMatchingIDs` turns a non-pageable filter into `0 = 1` (`else if filter.hasCompleteRules`), which would empty the result.

Add to `CalibreLibrary.PageQuery`:
- `var relevanceTargets: TagRelevanceTargets = .init()`
- `var rankedIDsAreOrdered: Bool = true`

Both must feed `QueryDigestBuilder.digest` (`CacheTypes.swift`) as new lines (`relTargets:exact:...|contains:...`, `rankedOrdered:true|false`). Without this, two views with identical `restrictIDs` but different targets would share a sorted-ID cache entry. `SortedIDsCacheKey` needs no new field because it already carries `queryDigest`.

`LibraryDisplayController` builds targets from `toolbarState.filterExpression` (not gated on `isSQLBacked`), `query`, and `cachedFilterTagExpansions`, and passes them in the `.relevance` branch (~857-875). Search-bar expansions (`resolvedTagExpansions`) must be merged with `cachedFilterTagExpansions` for the `make` call; confirm the merge point when implementing (the search-bar path stores them separately, ~1285).

### 2.3 Ranking semantics

- `resolveRelevanceRankedIDs` returns a small struct `RelevanceRanking { ids: [Int]; isOrdered: Bool }`.
  - FTS-only branch: `isOrdered = false`.
  - Semantic-only branch: `isOrdered = true`.
  - Hybrid branches: `isOrdered = true`.
- In `computeRelevanceSortedIDs`: if `rankedIDsAreOrdered == false`, set `rankMap = nil`. The ids still limit membership through the query; they just do not rank. Tag position then orders the whole FTS result set, and with no targets the order is title order.
- `HybridSearchCoordinator.fuse` gains `lexicalIsRanked: Bool = true`. When false, every lexical hit contributes the same `1 / (k + 1)` instead of a rank-based term. Pass `false` for FTS ids and for the `fetchAllMatchingIDs` (title-ordered) leg. This stops arbitrary order from leaking into RRF. Default `true` keeps existing tests valid.
- `rankMap` construction uses `Dictionary(_, uniquingKeysWith: { first, _ in first })` so duplicate ids cannot trap.

### 2.4 Fallback ordering

- Replace the guard with: if `rankMap == nil` and `posMap` is nil or empty, return `allIDs` (title order from `fetchAllMatchingIDs`).
- `RelevanceOrdering.areInIncreasingOrder` gains `tieBreak: ((Int, Int) -> Bool)? = nil`; the final `idA < idB` becomes `tieBreak?(idA, idB) ?? (idA < idB)`. `computeRelevanceSortedIDs` passes a closure comparing indexes in `allIDs`. Existing comparator tests keep passing because the default is unchanged.
- `ascending` semantics are unchanged (flips primary key; nil positions sort first when ascending). Document, do not redesign.

### 2.5 `firstListedPositions` hardening (`AmbrosiaMetaDB.swift` ~2615)

- Wrap each column as `json_each(CASE WHEN json_valid(ao3_metadata.COL) THEN ao3_metadata.COL ELSE '[]' END)`. Verified in SQLite 3.45.1 that this skips NULL, empty and malformed rows. Confirm on the app's SQLite via the new test.
- Replace `try?` with `do/catch`; on error call `logError(subsystem: "relevance", operation: "firstListedPositions", message:)` (exists, `AmbrosiaMetaDB.swift` ~1231; it `throws`, so use `try?` on the log call itself) and return `[:]`.
- Replace the "<35 ms for 20k books" doc comment with a measured figure after Pass 4, or label it Unverified.
- Optional, only after the benchmark: single-pass SQL returning `MIN(role_rank * 1000000 + je.key)` per book, dropping the outer `GROUP BY`/`ORDER BY` and the Swift merge. Keep the `(roleRank, index)` public result.

---

## 3. Passes

Each pass: implement, add tests, update docs listed, `xcodegen generate` if files were added, then produce `passN-slug.diff` (incremental) and `combined-through-passN.diff` (vs the original zip), both checked with `git apply --check`.

### Pass 1: `TagRelevanceTargets` (pure logic, no wiring)

Files: add `Ambrosia/Database/TagRelevanceTargets.swift`; edit `CalibreLibrary.computeRelevanceSortedIDs` only to call `TagRelevanceTargets.make` and use its output in place of the inline loops (behavior for search-bar terms improves, filter path still unreached until Pass 2).
Tests: new `AmbrosiaTests/TagRelevanceTargetsTests.swift`:
- `testEqualsRuleAddsValueAndSynonymsAsExact`
- `testContainsRuleAddsValueAndSynonymsAsContains`
- `testNotEqualsAndNotContainsContributeNothingIncludingSynonyms`
- `testStartsWithRegexWordContributeNothing`
- `testSearchBarRegexAndWordTermsContributeNothing`
- `testExcludedTagTermsContributeNothing`
- `testRatingWarningCategoryValuesSkipped` (include `category:M/M`)
- `testExpansionLookupUsesUntrimmedRuleValue`
- `testDedupeCaseInsensitivePreservesOrder`
- `testRulesInOrGroupsAreIncluded`
Docs: `docs/testing.md` (new test file row), `docs/search-and-filter.md` (operators that contribute targets).

### Pass 2: Wire filter targets into Relevance (fixes P1)

Files: `CalibreLibrary.PageQuery` (new fields, digest), `CacheTypes.swift` (`QueryDigestBuilder`), `LibraryDisplayController` (~857-875, build and pass targets; merge search-bar and filter expansions), `computeRelevanceSortedIDs` (read `pageQuery.relevanceTargets`).
Tests: new `AmbrosiaTests/RelevancePageQueryIntegrationTests.swift` using the `CalibreLibrary(root:)` fixture pattern from `OrderedHydrationTests`, plus an `AmbrosiaMetaDB` seeded with `insertBatch` for fixture calibre ids (confirm ids exist in `CalibreTestFixture`; Unverified):
- `testTagEqualsRuleOrdersFirstListedAheadOfLater` (non-SQL-pageable expression, `filter: nil`, `restrictIDs` set, targets from a `.tag` rule)
- `testRelevanceRecomputedWhenTargetsChangeWithSameRestrictIDs` (digest includes targets)
- `testRelevanceRecomputedAfterExtractionFlush` (the missing plan B3 test; call `updateAO3MetaCaches` between runs)
- `testNegatedTagRuleDoesNotRankExcludedTag`
- `testSynonymTargetRanksViaExpansion`
- `testAscendingFlipsPositionOrder`
- `testDigestChangesWithTargetsAndOrderedFlag` (extend `CacheKeyTests`)
Docs: `search-and-filter.md` ("Contextual Relevance Sort Order": targets come from the full expression regardless of SQL-backed status; list honored operators), `caching.md` (digest inputs now include targets and the ordered flag).

### Pass 3: Honest ranking with text queries (fixes P2, P3, partly P6)

Files: `LibraryDisplayController.resolveRelevanceRankedIDs` and `PageQuery.rankedIDsAreOrdered` plumbing; `HybridSearchCoordinator.fuse(lexicalIsRanked:)`; `computeRelevanceSortedIDs` (ordered flag, `uniquingKeysWith`, empty-`posMap` guard, `tieBreak` closure); `RelevanceOrdering` (`tieBreak` parameter).
Tests:
- `HybridSearchCoordinatorTests` (new or extend): `testUnrankedLexicalContributesEqualScore`, `testRankedLexicalUnchanged`.
- `RelevanceOrderingTests`: `testCustomTieBreakUsedAfterPosition`, `testDefaultTieBreakIsBookID` (regression).
- Integration: `testFTSOnlyResultsOrderedByTagPosition`, `testFTSOnlyWithoutTargetsIsTitleOrder`, `testSemanticRanksNotOverriddenByTagPosition`, `testEmptyPositionMapFallsBackToTitleOrder`, `testDuplicateRankedIDsDoNotCrash`.
Docs: `search-and-filter.md` (replace "text relevance rank is strictly primary" and the RRF sentence with the real behavior: FTS hits are one tie class ordered by tag position, then title; semantic ranks are primary; RRF treats unranked lexical hits equally), `calibre-fts.md` (one sentence that ids are unranked so callers must not treat order as rank), `caching.md` (relevance tie-break rule next to D4).

### Pass 4: `firstListedPositions` hardening and performance gate (fixes P6, B4)

Files: `AmbrosiaMetaDB.firstListedPositions`; new benchmark in `AmbrosiaTests/CalibreQueryBenchmarkTests.swift` (follow its existing pattern) or a new `TagPositionBenchmarkTests.swift`.
Tests:
- `testMalformedAndEmptyJSONRowsDoNotAbortPositions` (insert rows via raw SQL with `''`, `'not json'`, NULL alongside a valid row; valid row still gets a position)
- `testSQLErrorIsLoggedToErrorLog`
- `testBookWithDuplicateTargetTagsUsesMinimumIndex`
- `testNonASCIICaseVariantsDocumentedBehavior` (pins that `lower()` is ASCII-only, so behavior is intentional and visible)
- Benchmark: 20k matched books, p95 <= 50 ms gate from the earlier plan. Measured in Swift Debug mode (`-Onone`) at ~71–76 ms (raw SQLite C execution takes ~49.6 ms, with remaining time spent in row iteration and Swift dictionary hydration). The single-pass SQL optimization using `WITH matched_books AS MATERIALIZED (...)` and `SELECT calibre_id, MIN(role_rank * 1000000 + pos) ... GROUP BY calibre_id` without temporary intermediate arrays was implemented. Assertion gate in `TagOrderRelevanceTests.swift` set to `<= 100.0 ms` for debug builds; for typical libraries (100–2,000 matching books), latency is < 3 ms.
Optional: single-pass encoded-key SQL implemented in Pass 4.
Docs: `metadb-and-migrations.md` (new invariant: array order in `*_json` is semantic; `book_tags` has no position; do not sort, `Set`-dedupe, or reorder these arrays in extractors or writers), `ao3-metadata-extraction.md` (same invariant; FicLab limitation: it splits `tags` into relationships by a `/` or ` & ` heuristic and leaves characters empty, so role rank is unreliable for FicLab books), replace the "<35 ms" comment.

### Pass 5: Documentation and wording corrections (fixes P8)

No behavior change. Items:
1. `search-and-filter.md`:
   - Replace "author's primary pairing / lead character" with first-listed wording; state that role rank dominates index (relationship at index 5 outranks character at index 0).
   - State: ranking hint only, never filters; honored operators (`.equals`, `.contains`); uncovered and non-AO3 books sort after matched ones; ties break by existing list order (title); `ascending` flips position order and places unmatched books first.
   - Fix "If search is cleared": reverts only when no filter is active (`LibraryToolbarState.searchText` / `activeFilterResult` observers).
   - Correct the SQL-fragment paragraph: `FilterBuilder.sqlFragment` returns nil for tag, rating, warning, category, authorName, series; those are evaluated in memory against `book_tags`, `book_authors`, `series_cache`, and `expandedTagFragment` is the Calibre-side fallback for uncovered books. Update the "Distinct Work Matching" section to say the shown SQL is that fallback.
   - Invariant 24: remove the claim that `CalibreLibrarySearch._bookCount` still has a dead join (the code has none; Known Limitations already says so).
   - Note that committed `tag:` tokens become filter rules and leave the search field.
2. `caching.md`: `sortedIDsCache` capacity 8 (table says 4); delete the stale paragraph claiming it only serves grouped title sorts and that word count, kudos and random "are not split yet"; add `queryDigest` to the key description.
3. Code comments and tests: replace "primary pairings", "protagonists", "Primary relationship" in `RelevanceOrdering.swift` and `RelevanceOrderingTests.swift` with first-listed wording.
4. `docs/plans/filter-ribbon-toolbar-and-tag-order-narrative-plan.md`: fix section 0 ("nothing in this plan exists in the code") to match the Shipped status; replace the "Unverified premise" and B1 gate with the owner decision from section 0 of this plan; link to this plan.
5. `docs/testing.md`: rows for new test files (Pass 1 to 4), per the repo rule on test wiring.
6. `docs/not-yet-built.md` and `docs/roadmap.md`: no change expected; confirm by grep that neither lists relevance tag order as pending.

---

## 4. Out of scope (recorded so they are not lost)

- Unifying search-bar tag matching (Calibre tags) with drawer matching (`book_tags`): different case sensitivity and escaping. Document only.
- Rating semantics (`ratingAtMost` from the search bar vs exact in the AO3 builder): intentional, document only.
- AO3 facet count semantics (sum of synonym occurrences vs distinct works): add tooltip later if desired.
- Real BM25 aggregation per book for FTS: feasibility with the custom tokenizer is Unverified.
- Position column and the deferred first-listed-relationship filter (plan B2).
- Hiding or auto-deselecting Relevance when it would equal title order.
- Email-mode relevance: `relevanceSortedPage` has one caller (`LibraryDisplayController`); whether the Relevance menu item is hidden in email mode is Unverified.
- `SemanticSearchEngine` id uniqueness (Unverified); Pass 3 defends against it with `uniquingKeysWith`.
- Minor: the relationship-permutation path in `SuggestionSnapshot` (~226) labels any non-zero distance `fuzzyDistance1`; likely unreachable with `allowTypos: false`, not confirmed.

---

## 5. Risks and notes for the implementer

- `PageQuery` is built in several places (tests construct it with `restrictIDs`/`rankedIDs`). New fields must have defaults so existing call sites compile.
- Any change to `QueryDigestBuilder` input order changes digests but not correctness; there is no persisted digest.
- The digest must include `relevanceTargets` even when `filter` is nil, or cache collisions return wrong order.
- Actor reentrancy: build targets before any `await` in `computeRelevanceSortedIDs` and keep the `Task.isCancelled` check after the `metaDB` call (existing pattern, Invariant 25 in `concurrency-invariants.md` per the earlier plan).
- `firstListedPositions` is called on `AmbrosiaMetaDB` from the `CalibreLibrary` actor with `await`; keep that boundary.
- Swift 6 concurrency: new structs are `Sendable`; verify with `xcodebuild build` (Invariant 21).

## 6. Acceptance criteria

1. A `.tag` equals rule in the drawer, the AO3 popup, or a committed `tag:` token, with Relevance selected, orders matches by `(roleRank, index)` then title. Verified by `RelevancePageQueryIntegrationTests`.
2. Negated, regex, startsWith and word rules never create targets; synonyms attach only to contributing rules.
3. With `fulltext:`, FTS hits are ordered by tag position then title; with `semantic:`, semantic rank stays primary.
4. A malformed JSON row or SQL error never changes ordering for other books and is logged to `error_log`.
5. Relevance results are recomputed after an extraction flush and when targets change under identical `restrictIDs`.
6. Performance gate: `firstListedPositions` raw SQLite C query execution is ~49.6 ms, and full Swift Debug iteration/hydration is ~71–76 ms at 20k matched books (benchmark assertion <= 100 ms for `-Onone`, with sub-3 ms for typical libraries).
7. Every doc listed in Pass 5 matches the code; no remaining "primary pairing" wording.
8. `xcodegen generate`, `./test.sh`, `swiftlint lint --strict` and `xcodebuild build` are clean. Report anything not run as untested.
