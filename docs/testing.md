# Testing conventions

Scope: how `AmbrosiaTests/` is organized and what belongs in it. See
`docs/metadb-and-migrations.md` for `AmbrosiaMetaDB`-specific migration test
conventions (already established by `AmbrosiaMetaDBMigrationTests.swift`)
rather than duplicating them here.

## Wiring a new test file into the build

`Ambrosia.xcodeproj` is generated from `project.yml` via `xcodegen generate`
(see `CLAUDE.md`'s "Keeping this current" section). `project.yml`'s
`AmbrosiaTests` target uses a folder-based `sources: - path: AmbrosiaTests`,
so any `.swift` file physically present under `AmbrosiaTests/` is picked up
automatically the next time someone runs `xcodegen generate` — there is no
per-file list to remember to update. Adding a test file therefore means:

1. Add the file under `AmbrosiaTests/`.
2. Run `xcodegen generate` (regenerates `Ambrosia.xcodeproj`, which is
   gitignored — do not hand-edit `project.pbxproj`).
3. Run `./test.sh` and confirm the new file's test class actually appears
   in the output, not just that the suite as a whole passed.

Step 3 matters: this is exactly how 8 of 11 `AmbrosiaTests/` files went
unnoticed for a period — the suite reported green because the 3 files that
were wired in passed, while the other 8 silently never compiled. A green
`./test.sh` run only tells you the wired-in tests passed, not that every
file on disk is wired in.

## What to unit test directly vs. what needs a fixture

Two patterns already exist in this codebase; extend the matching one rather
than inventing a third:

- **Pure logic, no actor/AppKit/WebKit dependency** — drive it directly, no
  fixture needed. `PagingOffsetStateNavigationIntentTests.swift` is the
  template: its own header comment notes `PagingOffsetState` "has no
  SwiftUI/actor dependency, so these tests drive it directly rather than
  standing up `LibraryRootView`." `KeyBinding.swift`'s `validate(_:for:against:)`
  makes the same claim explicitly in its doc comment ("Pure, UI/NSEvent-free
  so it's unit-testable alongside `LibraryVisibilityPolicyTests`") — that
  claim didn't have a test file to back it up until this pass; see
  `KeyBindingValidationTests.swift`.
- **Needs a real `AmbrosiaMetaDB`/`CalibreLibrary`** — use
  `CalibreTestFixture.swift`'s pattern: a real actor instance against a
  disposable temp-directory library path, exercised through the actor
  rather than mocked, since the actor boundary and the SQL are usually
  exactly what's under test. `CollectionStoreTests.swift` and
  `ErrorLogTests.swift` both follow this.

Views (`LibraryRootView`, `ReaderViewController`, etc.) and anything that
needs a live `WKWebView` (`PaginationEngine`, `HighlightBridge`) are out of
scope for unit tests here — no test infrastructure in this repo stands up a
window or a web view, and adding one is a bigger decision than a single test
file. If a bug lives in one of those, look for a pure sub-piece that can be
pulled out and tested the way `SeriesSpineMap` and `PagingOffsetState`
already were.

## Coverage map

Verified 2026-10-17 by listing `AmbrosiaTests/` and grepping it for each
source file's type name. This is a name-based heuristic, not line coverage: a
type defined in a differently named file can be undercounted, and a reference
in a test does not mean the type is well covered. Real line coverage is
collected in CI (`-enableCodeCoverage YES`) but is not reported anywhere yet.

Current size: 72 test files, 593+ test functions, all `XCTestCase` (no Swift
Testing), against 112 source files (updated October 2026 after Phases 1–6).

### Covered by a dedicated test file

| Source | Test file(s) |
| --- | --- |
| `SearchQueryParser` | `SearchQueryParserTests` |
| `AO3MetadataExtractor`, `+Authors` | `AO3MetadataExtractorTests`, `AO3MetadataExtractorAuthorsTests`, `AO3RatingHighestTests` |
| `LRUCache` (`CacheTypes.swift`) | `LRUCacheTests`, `SortedIDsCacheKeyTests` (`get` recency) |
| `SortedIDsCacheKey` and its relation to `PageCacheKey` | `SortedIDsCacheKeyTests` |
| `GroupAwareSorter` ordering | `GroupAwareSortOrderTests` |
| `LibraryFingerprint` comparison and encoding | `LibraryFingerprintTests` |
| `LastViewState`, `LastViewValidator`, `LastViewStore` | `LastViewStateTests` |
| `library_state` table, series-seed marker rules | `LibraryStateTests` |
| Windowed series scan equals whole-library scan, fingerprint of a real library | `CalibreSeriesChunkTests` |
| `LibraryChange.classify` (none, file-only, content) | `LibraryFingerprintTests` |
| `reopenIfFileReplaced`, in-place write seen without reopen | `CalibreLibraryReopenTests` (in `CalibreSeriesChunkTests.swift`) |
| Cache key shaping (`tagExpansionsDigest`, `FilterResultCacheKey`) and visibility-pref sensitivity of `PageCacheKey`/`FilterResultCacheKey` | `CacheTypesKeyShapeTests` (in `LRUCacheTests.swift`), `CacheKeyTests` |
| `TagExpansionResolver` | `TagExpansionResolverTests` |
| `MatchingSubqueryBuilder` (`FilterBuilder.swift`) | `MatchingSubqueryBuilderTests` |
| `GzipEncoder` | `GzipEncoderTests` |
| `HTMLStripper` | `HTMLStripperTests` |
| `RowDescriptionLimit` (`BookListRow.swift`) | `RowDescriptionLimitTests` |
| `TagPillDisplay.capped` (`BookListRow.swift`) | `TagPillCapTests` |
| `SeriesSpineMap` | `SeriesSpineMapTests` |
| `SeriesMatchExpansion`, `SeriesGroupBuilder` | `SeriesMatchExpansionTests`, `SeriesGroupBuilderTests` (plus `SeriesHelpersTests`) |
| `DebounceTimer` | `DebounceTimerTests` |
| `CustomColumnConfig` | `CustomColumnConfigTests` |
| `LibraryIndexManager` | `LibraryIndexManagerTests` |
| `AO3TagSeedDatabaseConfig` | `AO3TagSeedDatabaseConfigValidationTests`, `AO3TagSeedDatabaseConfigInstanceTests` |
| `ExtractionProgress` | `ExtractionProgressTests` |
| `LibraryQueryHelpers`, `LibraryVisibilityPolicy`, `DuplicateBookDetector` | `LibraryQueryHelpersTests`, `LibraryVisibilityPolicyTests`, `DuplicateBookDetectorTests` |
| `KeyBinding.validate` | `KeyBindingValidationTests` |
| `CollectionStore`, `ErrorLogEntry` storage | `CollectionStoreTests`, `ErrorLogTests` |
| `MembershipDelta`, `CollectionStore.applyMemberDelta` | `MembershipDeltaTests`, `CollectionStoreDeltaTests` |
| `SeriesSyncCoordinator` | `SeriesSyncCoordinatorTests` |
| `AnnotationExportManager` | `AnnotationExportManagerTests` |
| `CalibreLibrary` search | `CalibreLibrarySearchTests` |
| EPUB image reference rewriting | `EPUBImageReferenceRewriteTests` |
| `PagingOffsetState` | `PagingOffsetStateNavigationIntentTests`, `PagingOffsetStateTests` (idempotent `commitNewPage`) |
| `ExportManager.exportScope(for:)` | `ExportScopeTests` |
| `LibraryQueryHelpers.indexed` (duplicate keys do not trap) | `IndexedHelperTests` |
| Tag coverage hoisting and the `uncovered` fallback restriction (`FilterBuilder`) | `TagCoverageTests` |
| `TagRuleStrategy`, `AndGroupOrdering`, candidate-restricted tag rules | `TagRuleStrategyTests`, `TagCandidateRestrictionTests` |
| `IncrementalFilterPlanner`, `LibrarySession.narrowingBase`, narrowed vs full-compute equivalence | `IncrementalFilterPlannerTests`, `NarrowingBaseTests`, `IncrementalEquivalenceTests` |
| `RuleMatchCache` | `RuleMatchCacheTests` |
| `LibraryFilterDebug` | `LibraryFilterDebugSummaryTests` |
| `AmbrosiaMetaDB` migrations | `AmbrosiaMetaDBMigrationTests` |
| `LocalFeedServer` walk cache | `LocalFeedServerWalkCacheTests` |
| `LibraryQueryHelpers` full-text cache key and `fulltextMap` | `FulltextCacheKeyTests` |
| `FTSQuery` normalization, cache key, sanitized expression | `FTSQueryTests` |
| `SearchControl` generation and cancel semantics | `SearchControlTests` |
| `SQLIDList` single-binding id sets (40,000 ids) | `SQLIDListTests` |
| `CalibreFTSLibrary` against a Calibre-shaped fixture | `CalibreFTSLibraryTests` |
| `LibrarySession` fulltext cache rules, via the `FulltextSearching` seam | `LibrarySessionFulltextTests` |
| Real-library FTS timings (skipped unless `AMBROSIA_FTS_BENCH_LIBRARY` is set to a library folder) | `CalibreFTSBenchmarkTests` |
| `CalibreTokenizer` (C port of Calibre's FTS5 tokenizer, `Database/CalibreFTS`) | `CalibreTokenizerTests`; the golden-corpus test skips until `AmbrosiaTests/calibre_tokenizer_golden.json` is generated (see `calibre-fts.md`) |
| `CalibreTokenizerRegistration` against a Calibre-shaped fixture (`FTSTestFixture`, `calibre_fts_schema.sql`) | `CalibreTokenizerRegistrationTests` |

Note on `LRUCache`: eviction is insertion-order, not access-order. Reading a
key via the `subscript` getter does not move it to the back of `order`; only
`set(_:for:)` does. `LRUCacheTests` is the place that behavior is pinned. `get(_:)` does refresh recency and is what `sortedIDsCache` uses; `SortedIDsCacheKeyTests` pins it.

### Thin relative to size (logic worth testing)

Lines are source LOC. "Tests" is what exists today.

| Source | LOC | Tests today |
| --- | --- | --- |
| `AmbrosiaMetaDB.swift` | 2482 | migrations and `CollectionStore`; tag queries indirectly through `TagCoverageTests` and `TagCandidateRestrictionTests` |
| `LocalFeedServer.swift` | 2543 | walk cache only (4 tests); feed XML, JSON feed and OPML output untested |
| `LibrarySession.swift` | 1058 | full-text cache and failure rules (`LibrarySessionFulltextTests`), filter cache keys and `narrowingBase` (`CacheKeyTests`, `NarrowingBaseTests`, `RuleMatchCacheTests`); open/close lifecycle and collection snapshots untested |
| `EPUBParser` and extensions (spine, OPF, merged HTML, offsets, `parseTOC`) | about 900 | image reference rewrite only |
| `ExportManager.swift` | 543 | `exportScope(for:)` only (`ExportScopeTests`); CSV row building and the export panels untested (`AnnotationExportManagerTests` covers a different type) |
| `CalibreFTSLibrary.swift` | about 380 | `CalibreFTSLibraryTests` (modes, phase 1 and 2, cancellation, busy, file replacement, error mapping) |
| `TransferDatabaseBuilder.swift` | 196 | none |

The UTF-16 offset contract in `epub-parsing.md` (Invariant 5) is the
highest-risk untested behavior, because annotations depend on it.

### Out of scope for unit tests (UI and web view)

No file below has a test, and per the rule above none is expected to until a
pure piece is extracted from it: `ReaderViewController`,
`PreferencesWindowController`, `LibraryWindowController`,
`EmailLibraryViewController`, `EmailSidebarViewController`, `LibraryRootView`,
`BookListRow`, `FilterDrawerView`, `AO3FilterPopupView`, `ActivityFeedView`,
`PaginationJS`/`PaginationEngine` and `HighlightBridge` (both need a live
`WKWebView`).

### Keeping this table current

When you add a test file, add or update its row here in the same change.
When a "thin" entry gains meaningful tests, move it up a section.

## Fixture HTML and local-only references

Tests that need AO3 preface HTML must use synthetic fixtures written for this
repo. `docs/ao3_epub_html_reference.md` is gitignored because it contains
non-open-source material (see `CLAUDE.md`, "Local-only files"), so it is not
available in CI or fresh clones and its text must not be copied into test
files. `AO3MetadataExtractorTests.swift` currently cites that file in its
header comment and states its fixture HTML was built from that file's
templates and example tables. The fixtures are inline in the test file and are
tracked in git, so the maintainer should confirm they contain no material from
the reference that the exclusion was meant to keep out.

## CI test-completeness gap

CI's `macos-tests` job (`.github/workflows/swift.yml`) runs `xcodebuild test`
and uploads the `.xcresult` bundle on failure, but nothing currently parses
that bundle to confirm every `.swift` file under `AmbrosiaTests/` that
defines an `XCTestCase` subclass actually produced a result. The "sanity
check file count" step added alongside this doc is a weak placeholder (it
only confirms files exist on disk, not that they ran) — a real check needs
someone to inspect `xcrun xcresulttool get --format json --path
<bundle>`'s actual schema on a real Xcode install first, since that schema
isn't something to guess at. Until that lands, step 3 above (read the
`./test.sh` output, don't just check its exit code) is the only guard.

## Local git hooks

A pre-commit hook (SwiftLint only, not the full suite — see the file's own
comment for why) lives at `scripts/git-hooks/pre-commit` but is not wired in
by default. Opt in once per clone:

```
git config core.hooksPath scripts/git-hooks
```
