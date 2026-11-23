# Vibe Review and Remediation Plan

Status: Approved by owner (snapshot of November 23, 2026). Decisions D1 to D4 and the R3 test changes are resolved in section 4; implement without further sign-off.
Suggested home: `docs/plans/vibe-review-remediation-plan.md` (add a row to `docs/plans/README.md` in pass R5).
Audience: the AI engineer implementing this, working from the repo zip, in passes (one concern per pass, tests included, docs updated in the same pass).
Related plans, not duplicated here: `docs/plans/codebase-cleanup-plan.md`, `docs/plans/test-gap-closure-plan.md`. Section 2 says which of their passes have already landed.

## 0. How to use this plan

- Read the zip's `CLAUDE.md` (a docs index) first, then only the topic docs named per pass.
- Labels: **Verified** = read in code or measured by script at this snapshot. **Unverified** = inference; confirm before acting.
- Line numbers are approximate. Re-locate every symbol by name before editing.
- No macOS toolchain is assumed. Nothing in this review was compiled, linted or run. Never claim a build, lint or test passed unless you ran it. List `./test.sh`, `swiftlint lint --strict` and `xcodegen generate` (after adding or removing any `.swift` file) as owner commands.
- Per pass deliver `passN-slug.diff` (incremental) and `combined-through-passN.diff` (relative to the zip), both checked with `git apply --check`. Note which hunks touch gitignored paths (`docs/plans/`, `samples/`, `Ambrosia.xcodeproj/`).
- Do not hand-edit `project.pbxproj`. Do not add dependencies. Do not change persisted formats.

## 1. Verdict

The app is in better shape than its origin suggests. The vibecoding damage is concentrated in five places, none of which needs a rewrite:

1. Nothing enforces the rules. No workflow runs tests or lint (section 3, F1).
2. Failures on user data are swallowed (F3), and one "read" function deletes rows (F4).
3. The most important regression gates are vacuous on a fresh clone (F6).
4. Docs and metadata drift from the code, with process documents far larger than living docs (F8).
5. Hidden global dependencies and a few 3000-line types block testability (F5, F7).

### What is already good (do not "fix")

| Area | Evidence (Verified) |
|---|---|
| Force-unwrap discipline | 4 hits in 57k LOC: two `URL(string: "https://archiveofourown.org")!` constant fallbacks in `BookInfoViewController` (~491, ~497) and two `WKNavigation!` delegate signatures. Zero `as!`, two `try!` mentions that are comments. |
| No debug litter | `print(` outside `#if DEBUG`: exactly one (`FeedBuilderTypes.swift` ~73). Zero TODO/FIXME, zero `NSLog`, zero `Thread.callStackSymbols`, zero empty `catch {}`. |
| SQL safety | All 11 interpolations into SQL are constants or pre-escaped (table names, fixed predicates, `ATTACH` path with quote doubling). User values are bound. Residual: `matchesRegex` passes a user regex to `REGEXP` (`AmbrosiaMetaDB` ~1436), a ReDoS-by-self risk only. |
| Test breadth | 111 files, 922 `func test` (script count), 2.8 assertions per test, 4 `XCTSkip` total, 0 `sleep`, tests use disposable temp libraries. |
| Real-schema fixtures | `CalibreTestFixture`, `FTSTestFixture`, SQL fixture files. Tests exercise actors and SQL for real instead of mocking. |

## 2. Status of the two existing plans against the tree (Verified by symbol grep)

| Plan | Landed | Outstanding |
|---|---|---|
| `codebase-cleanup-plan.md` Pass 1 (dead code, `SortField` cases, `resolvedQuery`) | All named symbols return zero hits in `Ambrosia/` and `AmbrosiaTests/`. | Plan header still says "Proposed". |
| Same, Pass 2 (legacy migrations, error-log prune) | Migration symbols gone. `pruneErrorLog` now called from `LibrarySession` ~700 with `AmbrosiaMetaDB.errorLogRetention`. | Confirm `docs/metadb-and-migrations.md` and `docs/swiftdata-store.md` were updated (not checked). |
| Same, Pass 3 (doc drift), Pass 4 (placeholders), "Later" flag removal | `upsertPlaceholder` is gone (grep 0). `IncrementalFilterFlag` still present (owner gate G3). | Pass 3 status unknown. Run the checker from R5 to find out. |
| `test-gap-closure-plan.md` T2 (relevance planner), T4 (`testCurrentExactWordCountIsLowerBound`), T5 (facets) | Files present. | Plan README still lists it Active. |
| Same, T1 (suggestion tests), T3 (`FanfictionFrontmatterParserTests`), T7.2 (`scripts/check_docs.py`) | None present. `XCTExpectFailure` has 0 uses. | Still open. Do them as written there. This plan does not restate them. |
| Same, T7.3 (CI) | Not done. Deferred pending owner. | Folded into R1 below. |

## 3. Findings

### F1. No CI runs tests or lint (new emphasis; test-gap plan T7.3 deferred it)

Verified: `.github/workflows/` holds `build-dmg.yml`, `build-release.yml`, `pages.yml`. None runs `xcodebuild test` or `swiftlint`. `docs/testing.md` ("CI test-completeness gap"), `test.sh` (header), `scripts/git-hooks/pre-commit` and the README badge all name `.github/workflows/swift.yml` and a `macos-tests` job that does not exist. The pre-commit hook is opt-in (`core.hooksPath`). Consequence: Invariant 12 ("enforced by CI's `swiftlint lint --strict`") and Invariant 21 (build gate) are honor-system only. `swiftlint` has possibly never run against this tree in CI, so expect a first-run violation list (Unverified).

### F2. Dependency versions are not reproducible, and docs disagree

Verified:
- `Ambrosia.xcodeproj/` is gitignored (`.gitignore` line 36) and the only `Package.resolved` lives inside it, so no resolved pins are tracked.
- `project.yml` uses `from:` minimums: SQLite.swift 0.14.1, ZIPFoundation 0.9.0, SwiftSoup 2.6.0, FlyingFox 0.26.2.
- The on-disk resolved versions are 0.16.0, 0.9.20, 2.13.6, 0.27.0.
- `docs/overview.md` states 0.15.3, 0.9.19, 2.13.5, 0.26.2 (all stale), and Invariant 14 says to add packages "through the Xcode/SPM workflow", which conflicts with the xcodegen flow.
- A fresh `xcodegen generate` in CI therefore resolves whatever is newest. The code comments about SQLite.swift's `try!`-based iterator (`CalibreLibrary` ~1632, `CalibreFTSLibrary` ~398) show behavior that depends on the library version.

### F3. Silent failure on user data (new)

Verified: 511 `try?` in `Ambrosia/`; 61 on write-like calls. Triage:

| Class | Sites | Why it matters |
|---|---|---|
| A. User data, UI updated optimistically | `ReaderViewController` ~1965 and ~2021 (`insertAnnotation`), ~2605 (`deleteAnnotation`); `ReadingGoalView` ~1018 (`saveReadingGoal`), ~1035 (`deleteReadingGoal`); `CollectionsView` ~90 (`deleteCollection`) | The UI shows a saved annotation or goal that may not exist after relaunch. The annotation path mutates `annotations`, `annotationCalibreID`, calls `onAnnotationsChanged` and the JS highlight before the `Task { try? ... }` runs. |
| B. User-initiated file write | `SeriesListRow` ~248 (`content.write`), `SearchActivityLog` ~81 | An export that silently produces no file. |
| C. Import writes | `CalibreLibraryWriter` ~83-186 and ~386-420 (covers, author/series/publisher/tag links, comments, all `_ = try? conn.run`); `CalibreFTSWriter` ~167 | Standalone import can report success while dropping links. |
| D. Best-effort reads | `CalibreLibrarySearch` ~179, ~196, ~215, ~234: four near-identical `(try? db.prepare(...)) ?? []` blocks | Suggestion queries hide database errors. Acceptable to stay best-effort, but should be one helper with a debug log. |
| E. Benign | PRAGMA tuning (`CalibreLibrary` ~96, `AmbrosiaMetaDB` ~93), temp/WAL/SHM file removal, `DETACH`, FTS `optimize`, checkpoint calls in `SQLiteFileMaintenance`/`CalibreFTSWriter` | Leave. Add a one-line reason comment only where the intent is not obvious. |

Infrastructure already exists: `AmbrosiaMetaDB.logError(subsystem:operation:...)` (~1172), `ErrorLogEntry`, `ErrorLogView`, retention pruning, and `NSAlert` helpers in `AppDelegate`, `PreferencesWindowController`, `ExportManager` (reuse; do not invent a new error system).

### F4. A read that deletes (new)

Verified: `AmbrosiaMetaDB.allAO3Diagnostics(failedOnly:)` (~1601) first runs `try? run("DELETE FROM ao3_extraction_diagnostics WHERE calibre_id IN (SELECT calibre_id FROM ao3_metadata)")`, then reads. It is called from `FilterEvaluator` (~104, inside filter computation) and `PreferencesWindowController` (~2462). A getter on the filter hot path writes to the DB, ignores failure, and relies on call order for correctness. `failedOnly` also matches free text: `reason LIKE '%error%'`. Test: `BookStateMetaDBTests` ~165.

### F5. Hidden global dependencies (new)

Verified counts: `ReaderPreferences.shared` 151 uses, `AppDelegate.shared` 129 uses across 15 files (`AmbrosiaApp` 32, `PreferencesWindowController` 22, `ReaderViewController` 19, `ReaderWindowController` 12), plus `LibraryRegistry.shared` 26, `CustomColumnConfig.shared` 23, `DatabaseMaintenanceCoordinator.shared` 21. The reader reaches the database through `AppDelegate.shared?.session.metaDB?` inline. `PreferencesWindowController.init` calls `fatalError` if `AppDelegate.shared.session` is unset (~35). This is why `docs/testing.md` has to declare 20+ files out of scope. Do not attempt a general DI rewrite (see section 6). Introduce narrow seams only where R2 and R4 need them.

### F6. Vacuous or weak tests (new)

Verified unless marked:
- `ExtractionRawReadTests.testRawPrefaceExtractionMatchesSanitisedExtractionOnSamples` reads `samples/prefaces/` (21 real-work preface files) via `#filePath`. `samples/` is gitignored (`.gitignore` line 111), so on CI or a fresh clone the test hits `XCTSkipIf(files.isEmpty)` and passes vacuously. It is described as the equivalence gate for the raw-read switch. The files also look like real-work prefaces (title, author and fandom in the markup), which conflicts with the zip `CLAUDE.md` rule that tests use synthetic fixtures. They are not tracked, so there is no leak, but the test depends on them.
- `CalibreTokenizerTests` golden-corpus test skips because `calibre_tokenizer_golden.json` exists nowhere in the tree. `docs/testing.md` lists the C port of Calibre's tokenizer as covered. The port's agreement with real Calibre is unproven.
- `CalibreFTSLibraryTests` ~237 skips when "scan finished before the interrupt landed": a race-dependent skip, so the cancellation path may never execute (Unverified how often).
- Timing: 10 `Task.sleep` calls (`CollectionAssignmentTests` 7, `LibraryDisplayControllerTests` 2, `CalibreFTSLibraryTests` 1). Flake risk (Unverified: read each to see whether it waits on a condition).
- `VolumeMonitorTests.testVolumeMonitorStartMonitoring` has no assertion and starts the real `VolumeMonitor.shared`.
- False alarm to avoid: a regex scan found 7 tests with zero assertions; 6 are false positives (`GzipEncoderTests` use `assertRoundTrips`, `IncrementalEquivalenceTests` use `assertNarrowedEqualsFull`). Only the `VolumeMonitor` one is real.
- Coverage has never been measured (existing plan T7.1).

### F7. Concurrency posture is softer than the docs imply (new)

Verified: `project.yml` sets `SWIFT_VERSION: 5.0` and `SWIFT_STRICT_CONCURRENCY: targeted` for both targets. Docs and `CLAUDE.md` talk about "Swift 6" compile errors and `roadmap.md` says "Swift 6 Concurrency: Completed". Language mode 5 reports most isolation problems as warnings or not at all. Escape hatches: 7 `@unchecked Sendable` (`CustomColumnConfig` has a rationale comment; `SearchControl`, `RuleMatchCache`, `RegexCache`, `DestinationPlanner`, `IngestionCancellation` need reading), 3 `nonisolated(unsafe)` (`LocalFeedServer` `_isRunning`, `_port`, with a rationale comment that admits UI reads may lag), 1 `MainActor.assumeIsolated` (`AppDelegate` ~724), 16 `Task.detached`, 39 `DispatchQueue.main.async` (`ReaderViewController` 7, `EmailLibraryViewController` 7). Not a bug list. The risk is unmeasured. Measure before changing anything.

### F8. Docs and metadata drift, and process bloat

Verified:
- `docs/testing.md`: says 112 source files and 108 test files; actual 166 and 111. Hard-coded LOC are wrong: `AmbrosiaMetaDB` 2482 (actual 3230), `LocalFeedServer` 2543 (actual 1901), `LibrarySession` 1058 (actual 1715). It says feed XML, JSON and OPML output is untested, but `FeedBuilderTests` has 6 tests covering `OPMLFeedBuilder`, `RSSFeedBuilder` and `JSONFeedBuilder`. `TransferDatabaseBuilder.build` (196 LOC) still has no test.
- `docs/overview.md`: package versions (F2); Invariant 14 wording.
- README badge points at the missing `swift.yml` (F1).
- Plans README statuses (section 2).
- Size signal: roughly 19,600 lines under `docs/plans/` against roughly 3,300 lines of living docs for 57k LOC. The plans are gitignored, so most of that history is unrecoverable and invisible to a fresh clone.
- Code comments: 14 cite a plan file by name (10 cite `ambrosia_series_fix_plan.md`; all exist under `docs/plans/finished/`, which is gitignored). The zip `CLAUDE.md` says to fold the decision into a tracked doc instead of citing a scratch file. About 65 comments narrate history ("no longer", "previously", "legacy", "used to"); sample-review before bulk edits (Unverified how many are noise).

### F9. Size and duplication

Verified: `PreferencesWindowController` is one class from line 24 to ~2627 and then five leaf helper types to line 3246 (`ShortcutRecorderView`, `Color` extension, `TypographyValueFormat`, `NativeNumericTextField`, `NativeStepperView`, `TypographySliderControl`). `ReaderViewController` 3148, `AmbrosiaMetaDB` 3230, `CalibreLibrary` 1923, `LocalFeedServer` 1901. `.swiftlint.yml` disables length rules on purpose; keep that. Duplicate 10-line windows (script): `FTSTypographicCardView` vs `PassageTypographicCardView` (23 windows, 294 and 249 LOC), `AmbrosiaMetaDB` internal 23, `CalibreLibrary` internal 21, `EmailLibraryViewController` vs `LibraryRootView` 6, `JSONFeedBuilder` vs `LocalFeedServer` 4, `BookListRow` vs `SeriesListRow` 4.

### F10. Coverage gaps ranked by risk (heuristic: type-name grep, not line coverage)

52 of 166 source files (19,802 LOC) have no type-name reference in tests. Most are UI, which policy excludes. `EPUBParser+Rendering` and `+XMLDelegates` are false positives (extension-only files; `EPUBParser` appears in 4 test files). Real candidates, highest risk first:

| # | Area | Evidence | Note |
|---|---|---|---|
| 1 | UTF-16 offset contract (annotations depend on it) | `docs/testing.md` calls it the highest-risk untested behavior. Swift-side offset code: `FTSOccurrenceExtractor` ~151-200 (`utf16Offset`), `PassageSnippetExtractor` ~28-39. The JS side (`PaginationJS`) cannot be unit tested. | Not in either existing plan. |
| 2 | Annotation persistence in `AmbrosiaMetaDB` | `deleteAnnotation`: 0 test files. `insertAnnotation`: 1. | Pairs with F3 class A. |
| 3 | `ReadingGoal` model and `ReadingGoalView` (1045 LOC) math | `ReadingGoal.swift` has no test reference. `saveReadingGoal` and `deleteReadingGoal` have one test file each. | Look for pure progress or pace computations to extract. |
| 4 | `TransferDatabaseBuilder.build` | 196 LOC, no test. | Pure SQLite output, cheap to test with a temp file. |
| 5 | `ExportManager` CSV row building | Only `exportScope(for:)` tested. | Already listed in `testing.md` as thin. |
| 6 | `LibrarySession` open/close lifecycle | Listed as thin in `testing.md`. | Needs F5 seam; defer. |
| 7 | Suggestion engine, frontmatter parsers | Existing plan T1, T3. | Do as written there. |

## 4. Owner decisions (all resolved; do not relitigate)

| ID | Decision | Outcome | Applies to |
|---|---|---|---|
| D1 | Add a test and lint workflow | Approved. Reuse the runner and Xcode selection from `build-dmg.yml` (`macos-26`, `/Applications/Xcode_26.3.app`, both Verified there). The lint step starts as `continue-on-error: true` and is flipped to strict once the backlog is clean. | R1 |
| D2 | Dependency pins | Approved, modest version: raise the `from:` minimums in `project.yml` to the versions the owner actually builds with (read from `Package.resolved` in R0). Do not use exact-version pins; the XcodeGen syntax for them is Unverified and not wanted now. | R1 |
| D3 | Failure behavior for user-data writes | Approved: log to `error_log` via `AmbrosiaMetaDB.logError`, roll back the optimistic UI change, show one `NSAlert` in the existing alert style. | R2 |
| D4 | Synthetic preface fixtures | Approved: replace the `samples/prefaces` dependence with synthetic fixtures; keep the real-sample comparison as an extra local-only test with a loud skip message. | R3 |
| D5 | Test removals and gating | Approved as listed in R3 (delete the `VolumeMonitor` smoke test, gate the 100k-book benchmark, rename one test, relabel the tokenizer golden row). | R3 |
| D6 | R6 mechanical splits | Approved, lowest priority; do last, and skip item 2 if the shared card code does not form a coherent subview. | R6 |
| D7 | DI rewrite of `AppDelegate.shared` and `ReaderPreferences.shared` | Not approved. Stays in section 6. | none |

## 5. Passes

| Pass | Slug | Depends on | Risk | Needs Mac to verify |
|---|---|---|---|---|
| R0 | `owner-measurements` | none | none | yes (owner) |
| R1 | `ci-and-pins` | R0 | Low code, unknown lint backlog | yes |
| R2 | `persistence-errors` | none | Medium (reader and metaDB write paths) | yes |
| R3 | `test-hygiene` | none | Low | yes |
| R4 | `new-coverage` | R2 for item 2 | Low | yes |
| R5 | `docs-and-comments-truth` | R1, R2 | Low | no |
| R6 | `mechanical-splits` (last, lowest priority) | none | Low | yes |

Order: R0 first (the owner runs it; the engineer may start R2, R3 and R5 in parallel since they need no Mac to write). R1 needs the R0 package versions. Existing plan passes T1, T3, T7.2 and the gated `IncrementalFilterFlag` removal run independently; schedule T7.2 before R5, since R5 uses its checker.

### R0. Owner measurements (no code; the engineer writes the command list, the owner runs it)

1. `./test.sh`, and confirm each new test class appears in the output (per `docs/testing.md` step 3).
2. `swiftlint lint --strict`; report the violation count by rule. This sizes the R1 backlog.
3. Coverage baseline, as written in test-gap plan T7.1 (`-enableCodeCoverage YES`, `xcrun xccov view --report --files-for-target ...`; target name Unverified).
4. One-off build with `SWIFT_STRICT_CONCURRENCY=complete` (do not commit): report warning count by file for F7. Also report the resolved package versions for D2.
5. Report how many `XCTSkip` tests actually skipped in step 1 and why.

### R1. CI, lint gate and pins (D1, D2: approved)

Files: `.github/workflows/tests.yml` (new), `project.yml`, `README.md`, `test.sh` (header comment), `scripts/git-hooks/pre-commit` (comment), `docs/testing.md`, `docs/overview.md`.

1. New workflow, `workflow_dispatch` plus `pull_request` and `push` to the default branch: checkout, select Xcode (same line as `build-dmg.yml`), `brew install xcodegen swiftlint xcbeautify`, `xcodegen generate`, `swiftlint lint --strict`, `xcodebuild test` with `-enableCodeCoverage YES` and a result bundle uploaded as an artifact. Name the job `macos-tests` so the existing docs become true, or fix the docs to the new name; pick one.
2. Fix or remove the README badge so it points at the real workflow.
3. Pins per D2: set each `from:` in `project.yml` to the version reported by the owner in R0 step 4, with no other package changes. Update `docs/overview.md` stack versions to the truth and reword Invariant 14 for the xcodegen flow ("change package requirements in `project.yml`, then `xcodegen generate`").
4. Add a step that fails if any `AmbrosiaTests/*Tests.swift` class is absent from the result bundle only after someone has inspected real `xcresulttool` output on a Mac (existing gap in `docs/testing.md`; do not guess the schema).
5. Per D1, the lint step ships with `continue-on-error: true`. Fix mechanical violations in this pass; list the rest by rule and count. Flip to strict in the pass that clears the backlog and record that in `docs/testing.md`.
- Tests added: none. Gate: the owner sees a green run, or a documented lint backlog.

### R2. Persistence errors and the read-that-writes (F3, F4, D3: approved)

Docs to update: `docs/annotations.md`, `docs/reader.md`, `docs/metadb-and-migrations.md`, `docs/testing.md`.

1. Deliverable zero: a table of every `try?` on a write-like call (the 61, found with `grep -rnE 'try\? .*(execute|run\(|insert|update|delete|save|write|removeItem|createDirectory|copyItem|moveItem)'`) with class A to E from F3. Do not touch class E.
2. Class A, annotations: extract a small `@MainActor` helper (for example `AnnotationPersistence`) holding injected closures `insert: (Annotation, Int) async throws -> Void` and `delete: (String, Int) async throws -> Void`. `ReaderViewController` constructs it from `AppDelegate.shared?.session.metaDB` once, replacing the three inline `Task { try? ... }`. On failure: `logError` through the metaDB, roll back `annotations`, `annotationCalibreID`, `onAnnotationsChanged` and `HighlightBridge.removeHighlight`, then alert (D3). Read the surrounding code at ~1940-1970, ~2010-2025 and ~2590-2610 first; the highlight JS call at ~1969 runs unconditionally and must be reconciled.
3. Class A, goals and collections: replace `try?` at `ReadingGoalView` ~1018 and ~1035 and `CollectionsView` ~90 with `do/catch` that logs and alerts; roll back the in-memory change if one was made.
4. Class B: `SeriesListRow` ~248 and `SearchActivityLog` ~81. The export write should alert on failure; the activity log may log in DEBUG only.
5. Class C: read `CalibreLibraryWriter` and its callers in `ImportProgressWindowController` first. Count failed link or cover inserts into the existing import result, surface the count in the finished-import UI, and do not report a book as fully imported when its author link failed. Keep `INSERT OR IGNORE` semantics.
6. Class D: collapse the four `CalibreLibrarySearch` fallbacks into one private helper that takes the SQL and binds, returns `[]` on error, and logs in `#if DEBUG`. Behavior unchanged.
7. F4: remove the `DELETE` from `allAO3Diagnostics`. Add `pruneResolvedDiagnostics()` and call it where extraction results are written (find the writer of `ao3_extraction_diagnostics` in `AmbrosiaMetaDB`/`LibrarySession` ~1505) and once at library open. Replace the `LIKE '%error%'` match only if a structured status already exists; otherwise leave and report. `FilterEvaluator` ~104 keeps working unchanged.
8. Invariant 13 stray: wrap or remove the `print` at `FeedBuilderTypes.swift` ~73 (use `#if DEBUG`).
- Tests: `AnnotationPersistenceTests` with throwing closures (rollback called, error logged, success path leaves state). `BookStateMetaDBTests`: a diagnostics read does not change row count; prune removes resolved rows only. A writer test for class C that forces a failing link insert (for example a read-only or closed connection; confirm the mechanism in `StandaloneCalibreTests`) and asserts the failure count.
- Untested areas to list in the report: the alert presentation, the `ReaderViewController` wiring.

### R3. Test hygiene (F6, D4, D5: approved)

Docs to update: `docs/testing.md` (coverage table rows and the skip notes).

1. Replace the dependence on `samples/prefaces` in `ExtractionRawReadTests` with 3 to 4 inline synthetic preface fixtures covering the AO3 preface shapes the extractor handles (derive from `AO3MetadataExtractorTests` fixtures and the extractor code; never copy text from `docs/ao3_epub_html_reference.md`). Keep the samples-based test as a second, local-only test whose skip message is explicit.
2. Golden tokenizer: either have the owner generate `calibre_tokenizer_golden.json` via `scripts/gen_calibre_tokenizer_golden.py` (needs Python and Calibre; Unverified on the owner's machine) and add it to the test bundle, or change the `testing.md` row to "not covered" so the table stops overstating. Do not fabricate the JSON.
3. `CalibreFTSLibraryTests` ~237: make the scan deterministically long enough, or add an interrupt hook so the cancel path always runs. Read the test and `FTSSearchControl` usage first; if no deterministic option exists, report it as an open item rather than leaving a silent skip.
4. Read each of the 10 `Task.sleep` calls. Replace any that wait for a condition with awaiting that condition (an `AsyncStream`, a continuation or a polling helper with a bounded timeout). Leave ones that deliberately test debouncing.
5. Delete `VolumeMonitorTests.testVolumeMonitorStartMonitoring` (no assertion; starts the real `VolumeMonitor.shared`). Keep the other three tests in that file.
6. `CalibreQueryBenchmarkTests.testPass0BenchmarkSuite`: it builds a synthetic 100,000-book library in `setUp` on every default run (Verified: `AMBROSIA_BENCH_BOOK_COUNT` only changes the size). Gate it the way `CalibreFTSBenchmarkTests` is gated: skip with `XCTSkip` unless an environment variable such as `AMBROSIA_RUN_BENCHMARKS` is set, and move the fixture build out of the class-level `setUp` (or guard it) so a skipped run builds nothing. Keep `AMBROSIA_BENCH_BOOK_COUNT`. Check `TagOrderRelevanceTests.testBenchmark20kMatchedBooksPositions` the same way and gate it only if it is slow (Unverified; report its runtime from R0).
7. Rename `ErrorLogTests.testPruneErrorLogRetentionConstant` to describe what it checks (for example `testPruneKeepsOnlyNewestUpToRetentionLimit`). No behavior change.
8. Keep `CalibreFTSLibraryTests.testStemmedQueryIsRejectedUntilStemmingExists` unchanged; add a comment that it is a deliberate seam to be rewritten when stemming ships (M6).
9. In `docs/testing.md`, change the `CalibreTokenizer` golden-corpus claim to "not covered" until the JSON exists (see item 2), and add a short "Benchmarks are opt-in" note listing the environment variables.
- Do not touch the Gzip and `IncrementalEquivalence` tests; their assertions live in helpers (`assertRoundTrips`, `assertNarrowedEqualsFull`).
- Gate: new or changed classes appear in `./test.sh` output; the skip count from R0 step 5 drops or each remaining skip is explained in `testing.md`.

### R4. New coverage (F10 items 1 to 5)

New files, each registered in `docs/testing.md`; run `xcodegen generate`.
1. `OffsetContractTests`: Swift-side UTF-16 behavior. Cases: ASCII; astral characters (emoji, 2 UTF-16 units each); combining marks; HTML entities (`&amp;`, `&nbsp;`) before the match; `<br>`; offsets at start and end of text; `PassageSnippetExtractor` clamping (~28-39) with a start past the end. First locate where the Swift side derives plain text from the same HTML the JS walks (read `docs/epub-parsing.md` Invariant 5 and `EPUBParser+Rendering`); report if the contract is split across Swift and JS with no shared fixture. Add a short manual JS-parity checklist to `docs/reader.md` for the part a unit test cannot reach (annotate text after an emoji, reload, confirm the highlight lands).
2. Annotation CRUD in `AmbrosiaMetaDB`: insert, fetch by book, delete (currently 0 files), delete of a missing id, per-book isolation. Use the `CalibreTestFixture` pattern.
3. `ReadingGoal`: find pure computations in `ReadingGoal.swift` and `ReadingGoalView`. If progress or pace math is embedded in the view, extract it to a pure function with an injected `Calendar` and `now` (behavior-preserving), then test boundaries (year rollover, zero target, over target). If nothing pure exists, report and skip.
4. `TransferDatabaseBuilder.build`: build to a temp file from a few rows and a manifest; assert tables, row counts, `PRAGMA user_version` equals `wireFormatVersion`, and an empty-input case.
5. `ExportManager` CSV row building: extract only if the row builder is already a distinct function; otherwise report.
- Do not duplicate T1 or T3.

### R5. Docs and comments tell the truth (F8)

Docs to update: everything touched below. Prerequisite: test-gap plan T7.2 (`scripts/check_docs.py`).

1. `docs/testing.md`: remove hard-coded file and test counts and per-file LOC (they rot); point to the checker or to R0 numbers with a date. Fix the stale "feed output untested" line; keep `TransferDatabaseBuilder` until R4 lands. Replace the "Verified 2026-10-17" header with a real date.
2. `docs/overview.md`: stack versions and Invariant 14 (coordinate with R1).
3. Reword "Swift 6" claims where they mean the Swift 5 language mode with targeted checking, in `CLAUDE.md` (routing line), `docs/concurrency-invariants.md`, `docs/roadmap.md` Phase 4. Do not claim full Swift 6 until R0 step 4 shows zero warnings in `complete` mode.
4. `docs/plans/README.md`: set the cleanup plan and test-gap plan statuses per section 2; add this plan; keep gated items open.
5. Comments: for each of the 14 plan citations, fold the one-sentence decision into the nearest living doc and cite that doc (or an `Invariant N`), or delete the comment. Sample 20 of the ~65 history-narrating comments, remove the ones that describe what the code used to do, keep the ones that explain why the current code is shaped this way. Report counts removed and kept.
6. Extend the checker with: no Swift comment may cite `docs/plans` or `*-plan.md`/`*_plan.md`; no `print(` outside `#if DEBUG` (Invariant 13). Run it in advisory mode first.

### R6. Mechanical splits (D6: approved, do last, zero behavior change)

1. Move the five helper types after line ~2627 of `PreferencesWindowController.swift` into `Ambrosia/Preferences/Controls/` (one file each). Add `TypographyValueFormatTests` (pure: `formatNumber` non-finite gives "0", 0 fraction digits, 2 digits trailing-zero trim). Run `xcodegen generate`. Update `docs/library-ui.md` or the doc that names these types (grep first).
2. Read `FTSTypographicCardView` and `PassageTypographicCardView` side by side. If the shared 23 windows form a coherent subview, extract it into one shared view; otherwise leave and record why. `FTSTypographicCardTests` already covers formatting; keep it green.
3. Do not split `ReaderViewController`, `AmbrosiaMetaDB`, `CalibreLibrary` or `LocalFeedServer` in this plan.

## 6. Explicitly not doing (with reasons)

- No DI rewrite for `AppDelegate.shared` (129 uses) or `ReaderPreferences.shared` (151) (owner decision D7). The cost is high, the risk is real, and the testability gain is mostly for UI types that policy already excludes. Narrow seams (R2) pay for the cases that matter.
- No blanket file splitting and no change to the disabled `file_length` and `type_body_length` rules.
- No UI or `WKWebView` test harness (policy in `docs/testing.md`).
- No Swift 6 language-mode migration. R0 only measures it.
- No change to class E `try?` sites.
- No new dependencies and no persisted-format changes anywhere in this plan.

## 7. Acceptance per pass

- Every removed or replaced `try?` and every removed comment: a grep or list in the report.
- Every migrated or extracted function: one line on what it did before and where the behavior is tested now.
- Report ends with: files changed, tests added, untested areas, commands for the owner (`./test.sh`, `swiftlint lint --strict`, `xcodegen generate` if files were added or removed), next pass.
- Never state that a build, lint or test passed unless it was run.

## 8. Risks and unknowns

- All counts here come from static scripts over the zip. Type-name coverage under-counts extension-only files and over-counts incidental mentions. R0 step 3 replaces it with measured numbers and may reorder R4.
- The first `swiftlint lint --strict` run in CI may expose a large backlog (Unverified).
- Rolling back optimistic reader state (R2 step 2) touches the highlight JS bridge; the existing behavior at ~1969 must be read, not assumed.
- `docs/plans/` and `samples/` are gitignored, so plan and fixture edits have no history. Never delete a plan; move it.
