# Filter Ribbon Interactions & First-Listed Tag Order

**Status**: Shipped (Tracks A, C, B1), verified against test suite November 22, 2026. Supersedes revision 2, the revision 1 narrative plan (`-old`) and `filter-pills-context-menu-and-tag-order-relevance-plan.md`.
**Target subsystems**: `Ambrosia/LibraryUI/`, `Ambrosia/Database/`, `AmbrosiaTests/`
**Related docs**: `docs/search-and-filter.md`, `docs/library-ui.md`, `docs/caching.md`, `docs/concurrency-invariants.md`, `docs/metadb-and-migrations.md`, `CLAUDE.md`
**Related plans**: `docs/plans/search-suggestions-fuzzy-and-relationship-overhaul-plan.md` (shares the tag-role vocabulary; see section 8)

Evidence labels: **Verified** = read in the repo at this snapshot, or reproduced by a script in an earlier review sandbox. **Unverified** = estimate or reasoning to confirm at implementation. No macOS toolchain was available; nothing here was compiled or run in Swift.

---

## 0. Consolidation: what happened to each earlier draft

Implementation state: **Tracks A, C, and B1 are shipped in the code** (`removeRule`, `negatedCounterpart`, `FilterRibbonPills`, `firstListedPositions`, `RelevanceOrdering`, `isFirstListed`). Completed fixes, hardening, and integration corrections are detailed in `docs/plans/tag-order-relevance-fixes-plan.md`.

| Idea | Pills plan | Revision 1 | Revision 3 (this document) |
|------|-----------|-----------|----------------------------|
| Remove pill (xmark and context menu), copy value, edit in drawer, clear all | yes | yes | **Kept** (Track A) |
| Include/Exclude via `FilterOperator.inverted` with 6-case switch | yes | yes | **Replaced** by `negatedCounterpart` plus `FilterRule.canToggleNegation` (old switch did not compile: `FilterOperator` has 9 cases; mapping `startsWith`/`matchesWord` to `notContains` changed meaning and was not reversible) |
| Full-text pill menu (Remove, Copy phrase) and pending pill cancel | yes | partly | **Kept** (Track A), removal goes through `SearchQueryParser`, not a regex |
| `isPrimaryOnly: Bool` on `FilterRule` and star on pill | no | yes | **Dropped**. It changed no filtering, and `book_tags` has no position column. Replaced by the optional `FilterField.firstRelationship` (B2) |
| `earliestTagPositions` with `+100/+200/+300` offsets, strict tag-position-first comparator | yes | yes | **Replaced** by `firstListedPositions` with a typed `(roleRank, index)` key and text-relevance-first ordering (B1) |
| Row markers `heart.fill` / `person.fill` on first relationship and character | no | yes | **Kept** as Track C, computed from the record, not the filtered pill list |
| Front-load "Main Pairing" in `WorkEmbeddingSynthesizer` | no | yes | **Dropped**. `summaryLimit = 600` limits only the summary, the profile already lists `Relationships:` and `Characters:` in AO3 order, and changing the text would mix old and new stored vectors (`VectorStore`, magic `0x4C465631`, no versioning found). Needs evidence first |
| `TagPillDisplay.capped` change | no | yes | **Dropped**. It already preserves order |
| `<1.2 ms` claim for position lookup | no | yes | **Dropped**. The sort runs over the whole matched set (page size is irrelevant); measured on a synthetic 74k-row table, 20k matched books: fetch and decode four JSON columns 118 ms, SQLite `json_each(...).key` with `MIN` 32 ms (Python, a lower bound for Swift) |

Findings from review of revision 1 that remain in force: the `isRelationship` guess `rule.field == .tag && value.contains("/") || value.contains("&")` has an operator-precedence bug and misclassifies `Hurt/Comfort`, `F/M` and `Cuddling & Snuggling`, so role must come from data, never from delimiters; `removeFullTextFilter` plus a second `scheduleLoadPage()` could double-load because `applyFilterRules()` already schedules a page load in its no-rules branch.

Changes since revision 2 (all Verified in this snapshot):
- `RelationshipQuery` now exists at `Ambrosia/Database/Suggestions/RelationshipQuery.swift`, but its API differs from the one revision 1 assumed: `RelationshipQuery.parse(_:)` is non-optional and returns an enum, and matching is `matches(candidateName:allowTypos:) -> (matches, maxTypoDistance)`. There is no `matches(tag:)`.
- `book_tags` has `idx_book_tags_name ON book_tags(tag_name)` (`AmbrosiaMetaDB.swift`), which resolves the open "confirm an index on `tag_name`" item in B2.
- A third tag-role vocabulary now exists: `SuggestionTagType` (8 cases, `Database/Suggestions/SuggestionScorer.swift`), beside `TagPillDisplay.Role` (7 cases, `BookListRow.swift`). See section 8.
- `updateAO3MetaCaches` calls `clearQueryCaches()`, which calls `invalidateSortedIDs()` (`CalibreLibrary.swift`), so the sorted-ID cache is cleared when AO3 caches are refreshed. The single call site found is `LibrarySession.swift:668` (hydration). Whether the extraction-flush path reaches it is still Unverified (the comment at `CalibreLibrary.swift:190` says it does).

---

## 1. Verified premises

- Pills in `activeFilterChip` (`LibraryRootView.swift`, around line 168) have no gesture, button or context menu. The Clear button resets state inline: `filterExpression = FilterExpression()`, `activeFilterResult = nil`, `cancelLibraryFilterApplication()`, `scheduleLoadPage()`. The Edit button sets `toolbarState.showFilterDrawer = true`.
- `applyFilterRules()` (`LibraryDisplayController.swift:548`) already handles "no complete rules left": clears `activeFilterResult`, resets paging, calls `scheduleLoadPage()`, and cancels `fullTextTask`.
- `activeFullTextPhrase` (`LibraryDisplayController.swift:515`) is derived from the parsed `searchText`. `LibraryToolbarState.clearPendingFullTextSearch()` sets `shouldSuppressNextSearchTextReload`.
- `computeRelevanceSortedIDs` (`CalibreLibrary.swift:1173`) returns `allIDs` unsorted when there is no ranked list (`guard let ranked = candidateRanked, !ranked.isEmpty else { return allIDs }`). That is the gap this plan addresses for tag-only filters.
- `SortedIDsCacheKey` (`CacheTypes.swift:114`) has no `bookTagsRevision` field. `PageCacheKey` and `RuleMatchCacheKey` do carry it.
- `PageQuery` (`CalibreLibrary.swift` around line 694) carries `filterTagExpansions`, `metaDB` and `rankedIDs`. `SearchQuery.tagTerms` exists (`SearchQueryParser.swift:21`).
- Tag rules are evaluated by `CalibreLibrary.tagFamilyMatchIDs(field:op:value:tagExpansions:...)` via `FilterBuilder.tagRuleMembers` (`FilterBuilder.swift:846`), not as SQL against `metadata.db`.
- `book_tags` primary key is `(calibre_id, tag_name, tag_type)`; there is no position column. Order exists only in `ao3_metadata.*_json`.
- `AO3MetadataExtractor` records tags in page order with no sort or dedupe, and `relationships_json` keeps that order. Calibre's own `tags` carry no order.
- Row pills color by `TagPillDisplay.Role`: rating, fandom, relationship, character, category, warning, regular.
- `FilterOperator` has 9 cases. `availableOperators` (`FilterRule.swift:188`): `.warning/.category/.collection/.status/.crossover` offer `[.equals, .notEquals]`; `.tag` and `.authorName` offer `textOperators + [.notEquals]`; `.fulltext` offers `[.contains, .notContains]`; other text fields offer `textOperators` (no `.notEquals`).

Owner decision: Tags within a category are assumed to be listed by author importance; the B1 spot-check gate was formally waived by the owner. The feature and UI terminology remains "first-listed" throughout code, comments, and documentation.

---

## 2. Scope and sequencing

| Track | Content | Persisted-format change | Risk |
|-------|---------|-------------------------|------|
| **A** | Ribbon interactions: remove, include/exclude, copy, edit, clear, full-text removal, pending cancel, accessibility | None | Low |
| **B** | First-listed tag order in Relevance sort (B1). B2 (first-listed-relationship filter) is **deferred** | B1 none (JSON pushdown, decided) | Medium |
| **C** | Row markers for first-listed relationship and character | None | Low |

Order: A, then C, then B1 (after the spot-check in section 6, item 3). B2 is deferred and not scheduled. A and C do not depend on B. Track A can start immediately, in parallel with suggestions M0 and M1 (different files).

---

## 3. Track A: ribbon interactions

### A1. Pure logic (`Ambrosia/Database/LibraryQueryHelpers.swift`, existing `enum LibraryQueryHelpers`)

```swift
extension FilterOperator {
    /// The negation counterpart, or nil when the operator has none.
    var negatedCounterpart: FilterOperator? {
        switch self {
        case .contains:    return .notContains
        case .notContains: return .contains
        case .equals:      return .notEquals
        case .notEquals:   return .equals
        case .startsWith, .matchesWord, .matchesRegex, .ratingAtMost, .ratingAtLeast:
            return nil
        }
    }
}

extension FilterRule {
    /// True only when the counterpart exists AND this rule's field offers it.
    var canToggleNegation: Bool {
        guard let other = op.negatedCounterpart else { return false }
        return availableOperators.contains(other)
    }
}
```

The switch is exhaustive without `default`, so a new operator forces a decision at compile time. Helpers are pure and operate on `inout FilterExpression`:
- `removeRule(id:in:)`: remove by id, prune empty groups only when more than one group exists, always leave at least one group.
- `toggleNegation(id:in:)`: no-op unless `canToggleNegation`.

No change to `FilterRule` or its `Codable` shape in this track.

### A2. Controller (`LibraryDisplayController.swift`)

- `removeRule(id:)` and `toggleNegation(id:)`: mutate `toolbarState.filterExpression` through the helpers; return if the expression is unchanged; otherwise call `applyFilterRules()` (which already schedules the page load when no complete rules remain, so do not add a second `scheduleLoadPage()`).
- `clearAllFilters()`: extract the existing inline Clear-button body verbatim and call it from both the toolbar button and the context menu so they cannot diverge.
- `removeFullTextPhrase()`: remove the `fulltext:` token through the parser. Add a pure function on `SearchQueryParser` (for example `removingFulltext(from:)`) using the same tokenization and quoting rules as `parse`; the implementer confirms whether the parser already exposes token ranges. Then follow the same reload path as a user edit of `searchText` (see `shouldSuppressNextSearchTextReload`; exact behavior Unverified, check before writing). Also call `fullTextTask?.cancel()` and `toolbarState.clearPendingFullTextSearch()`.
- Pending pill: a remove button that performs the same cancel.

### A3. Views (`LibraryRootView.swift`, new file `LibraryUI/FilterRibbonPills.swift`)

Extract `FilterRulePillView`, `FullTextPillView`, `PendingFullTextPillView` from `activeFilterChip`. They take callbacks, not controller references, so previews and tests stay simple.

- Trailing `xmark` button with a 16 pt hit target (`.frame(width: 16, height: 16).contentShape(Rectangle())`; the glyph may stay small).
- `.contentShape(Capsule())` and `.contextMenu` on the whole capsule.
- Rule pill menu: Remove Filter (destructive, `trash`); Exclude This Filter or Include This Filter (`minus.circle` / `plus.circle`, only when `rule.canToggleNegation`); Copy Filter Value (`NSPasteboard`, only when value non-empty); Edit in Filter Drawer (sets `toolbarState.showFilterDrawer = true`, same as the Edit button; focusing the specific rule is a non-goal); Clear All Filters (`clearAllFilters()`).
- Full-text pill: xmark and menu with Remove Full-Text Filter and Copy Search Phrase.
- Pending full-text pill: spinner, phrase, cancel button; menu with Cancel Search.
- No relationship-specific menu item in this track (see B2).
- Negated pill keeps the existing `NOT` badge styling.
- Accessibility: `.accessibilityElement(children: .combine)`, a label such as "Tag Slow Burn, excluded", `.accessibilityAction(named:)` for Remove and Exclude/Include, `.help` on the xmark.

### A4. Tests (`LibraryQueryHelpersTests`, `SearchQueryParserTests`)

- `testRemoveRuleSingleGroup`, `testRemoveRulePrunesEmptyGroupsWhenMultipleExist`, `testRemoveRuleLeavesOneGroup`, `testRemoveRuleUnknownIDIsNoOp`.
- `testNegatedCounterpartIsInvolutionForAllCases`: iterate `FilterOperator.allCases`; for every non-nil counterpart, its counterpart equals the original.
- `testCanToggleNegationPerField`: `.tag contains` true; `.tag startsWith` false; `.tag equals` true; `.warning equals` true; `.title equals` false (field does not offer `notEquals`); `.rating ratingAtMost` false; `.fulltext contains` true.
- `testToggleNegationLeavesOtherRulesUntouched`.
- `testRemovingFulltextToken`: `tag:x fulltext:"a b" y` -> `tag:x y`; quoted with escaped quotes; unquoted single word; token at start and at end; text without a fulltext token unchanged.
- Existing `FilterRule` Codable round-trip tests stay green (shape unchanged).

---

## 4. Track B: first-listed tag order in Relevance sort

### B0. Where position lives (DECIDED: Option 2, JSON pushdown, no migration)

| Option | Change | Pros | Cons |
|--------|--------|------|------|
| **1. Position column** | `ALTER TABLE book_tags ADD COLUMN position INTEGER NOT NULL DEFAULT 0`; `writeBookTags` (the `INSERT OR REPLACE INTO book_tags` at `AmbrosiaMetaDB.swift` around line 1874) writes the array index, a name repeated within one array keeps the minimum; backfill from `ao3_metadata` with set-based SQL per type using `json_each(...).key` (measure on the real library; fall back to re-extraction); index on `(tag_type, tag_name, position)` or equivalent | Indexed lookups; enables B2 | Persisted-format change: `CLAUDE.md` requires stopping to ask; follow `docs/metadb-and-migrations.md` |
| **2. JSON pushdown** | None. Query `ao3_metadata` with `json_each` over the relevant column, `MIN(j.key)` per book, restricted by `SQLIDList.clause(column: "m.calibre_id")` | No migration; 32 ms for 20k books (synthetic, Python) | Not indexed; poor fit for a filter predicate across all books |

Decision: ship B1 with Option 2. Option 1 is taken only if B2 is later revived; do not add the column speculatively.

### B1. Relevance comparator

New `AmbrosiaMetaDB.firstListedPositions(targets:bookIDs:) async -> [Int: TagPosition]` with `TagPosition { roleRank: Int, index: Int }`; `roleRank` orders relationship, character, fandom, freeform. No magic offsets.

Targets:
- From `pageQuery.filter`: complete `.tag` rules with positive operators (`.contains`, `.equals`); skip negated, regex and startsWith rules.
- From `pageQuery.query.tagTerms`.
- Synonyms from `pageQuery.filterTagExpansions`.
- Matching mirrors the rule's operator as evaluated by `tagFamilyMatchIDs` (case-insensitive substring for `.contains`, equality for `.equals`); the implementer confirms the exact folding there so ranking agrees with what the filter matched. Relationship permutation via the existing `RelationshipQuery` is optional and not needed for rules built from suggestion values.
- Per book, the key is the best (lowest) `(roleRank, index)` among matched targets, so a multi-tag AND filter ranks by the strongest match.
- Books without `ao3_metadata` (uncovered, or non-AO3) have no position and sort after matched books. Document this.

Comparator, a pure function `RelevanceOrdering.areInIncreasingOrder(...)` testable without a database:
- **No ranked list** (tag-only filters): `(position key ascending, book id)`; unmatched books last.
- **Ranked list present** (FTS or semantic): `(rank, position key, book id)`. Position is a tie-breaker and never overrides text relevance. Whether it should ever outrank text relevance is an owner question (section 6). Reason: strict position strata would let a weak hit at index 0 beat a strong `semantic:` hit with the pairing at index 1.
- Direction handling mirrors the existing code (`ascending` flips the comparison; relevance normally runs descending).

Integration in `CalibreLibrary.computeRelevanceSortedIDs`:
- Compute targets before any `await` and capture what is needed. An `await` on `metaDB` inside an actor method is a reentrancy point, and per Invariant 25 actor calls do not observe cancellation, so check `Task.isCancelled` after it.
- Call `metaDB` only when targets exist (always when there is no ranked list; with a ranked list only if ties are plausible).
- Sorted-ID cache: `SortedIDsCacheKey` carries no `bookTagsRevision`. Either confirm that every extraction flush reaches `updateAO3MetaCaches` (which clears sorted caches), or add the revision to the key. A test must prove a relevance result is recomputed after a flush.

### B2. DEFERRED: first-listed-relationship filter (requires B0 Option 1)

Not part of the current implementation scope. Kept as a design sketch; revisit after B1 has been used on the real library.

Do not add a Bool to `FilterRule`. Add `FilterField.firstRelationship`:
- Cache identity is automatic: `LibraryFilterDebug.summary` and `RuleMatchKey` both include `field.rawValue`.
- Pill label comes for free ("First relationship").
- `availableOperators`: `.equals`, `.notEquals` only.
- Evaluation: `book_tags` where `tag_type = 'relationship'`, `tag_name = ?`, `position = 0`, for covered books; uncovered books never match (Calibre tags have no order). Document this.
- Ribbon menu: "Match as First-Listed Relationship" (converts a `.tag` rule to `.firstRelationship`) and "Match Anywhere" (converts back), shown only when the rule's tag role is relationship. The role comes from a name-to-role lookup (the suggestion snapshot, or an indexed `book_tags` query using `idx_book_tags_name`), cached in the ribbon's `@State` per rule value and resolved off the menu path.
- Open: adding a case to a persisted `FilterField` raises forward-compatibility questions for saved filters opened by an older build (decode-failure handling is Unverified).

### B3. Tests

- `testRelevanceOrderingNoRankedListSortsByPosition`, `testRelevanceOrderingRankedListUsesPositionAsTieBreak`, `testUnmatchedBooksSortLast`, `testDirectionFlip`.
- `testFirstListedPositionsRelationshipIndex`: `insertBatch` records (pattern from `TagAutocompleteTests`) with relationships `["Thor/Loki", "Tony Stark/Steve Rogers"]` and `["Tony Stark/Steve Rogers"]`; positions 1 and 0.
- `testFirstListedPositionsRoleRankBeatsIndex`: a relationship at index 5 ranks ahead of a character at index 0.
- `testSynonymExpansionMatches`, `testContainsAndEqualsFollowRuleOperator`.
- `testRelevanceRecomputedAfterFlush`: sorted-ID cache invalidation.
- If Option 1: migration is idempotent; backfilled positions equal JSON indexes; `writeBookTags` writes positions; duplicate names keep the minimum index.
- If B2: `.firstRelationship` evaluation, uncovered books excluded, cache identity changes when the field changes.

### B4. Performance gate

At 20k matched books, `firstListedPositions` p95 <= 50 ms in Swift with Option 2 (synthetic Python SQLite measured 32 ms; the Swift figure is Unverified). Measure on the scale fixture from the suggestions plan (M0). Note that `CalibreTestFixture` still caps tags at `min(1_000, count / 10)`, so that fixture work is shared.

---

## 5. Track C: row markers

In `TagPillDisplay.make` (single-book rows) and `EmailDetailView`:
- Compute from the **record**, not from the filtered pill list: the first element of `ao3Metadata.relationships` and `ao3Metadata.characters`, then match it to the appended pill by label. (`append` filters through `shouldShow` and dedupes with `seen`, so `.first` of the pill array can differ.)
- Add `isFirstListed: Bool` to `TagPillDisplay`; keep `id` (`"\(role)-\(label)"`) unchanged.
- Rendering: a small leading symbol and semibold weight; color stays from the role. Accessibility label "First-listed relationship" or "First-listed character".
- Series rows (`makeForSeries`, a union across works) get no marker.
- Tests: pill-model tests for record-first versus hidden-first, dedupe, and no marker on series rows.

---

## 6. Owner decisions (approved November 22, 2026)

1. B0: JSON pushdown only, no migration. Position column deferred with B2.
2. First-listed position never outranks text relevance when a text query exists; it is a tie-breaker only.
3. The "first-listed" wording is accepted. **Gate for B1**: the owner spot-checks about 20 real works for the AO3 entry-order convention before B1 ships. Until then do not use the words "main" or "primary" in UI or docs.
4. B2 is deferred, including the new `FilterField` case and the saved-filter forward-compatibility question.
5. Include/Exclude stays unavailable from the pill menu for `.startsWith`, `.matchesWord` and regex rules.

No open owner questions remain for Tracks A, C and B1.

## 7. Acceptance criteria

1. Track A: every pill can be removed with one click or from its context menu; Include/Exclude appears only where the counterpart operator is valid for the field and round-trips exactly; Clear and the menu share one implementation; no `FilterRule` shape change; helper tests green including the exhaustive operator test.
2. Track B (B1 only): Relevance sort for a tag-only filter orders first-listed matches ahead of later ones; with a text query, text relevance is never overridden; results recompute after extraction flushes; B4 gate met.
3. Track C: markers derived from the record; no marker on series rows.
4. `xcodegen generate`, `./test.sh`, `swiftlint lint --strict` clean; `xcodebuild build` clean (Invariant 21).

## 8. Cross-plan notes

- Role vocabulary: the repo now has `TagPillDisplay.Role` (rows) and `SuggestionTagType` (suggestions, 1-byte raw values). The suggestions plan (section D10 there) unifies them into one `AO3TagRole`. Land that first if B2 is pursued; the ribbon's role-gated menu item uses it.
- If Option 1 adds `book_tags.position`, the suggestions vocabulary query (group by name and type) is unaffected.
- Both plans need the M0 scale fixture; build it once.

## 9. Docs to update

`docs/search-and-filter.md` (ribbon actions; relevance ordering rules; first-listed semantics and the uncovered-book caveat), `docs/library-ui.md` (pill components, accessibility), `docs/caching.md` (sorted-ID cache and `bookTagsRevision`), `docs/metadb-and-migrations.md` (only if Option 1), `docs/testing.md`, `docs/plans/README.md`.
