# Ambrosia Codebase Health Audit

---

## 1. Dead Code

**`Database/Models/Fandom.swift` — tombstone file with no declarations**
File contains only a comment explaining that the `Fandom` `@Model` was removed. No Swift declarations remain. The comment claims it is kept to avoid breaking the pbxproj reference, which is not a valid reason once there is no type to preserve. Delete the file and remove the pbxproj entry.
Severity: low

**`Database/BookLibrary.swift` — compiled but never referenced**
`BookLibrary` wraps `ModelContext` to fetch and upsert `BookState`. Zero call sites exist outside its own definition. The comment references "Phase 6 (Collections)" as the consumer; collections shipped without wiring this up. Delete.
Severity: medium

**`Database/TagSynonymStore.swift` — compiled but never referenced**
`TagSynonymStore.shared` provides a `UserDefaults`-backed synonym dictionary. No call sites exist. The actual synonym system uses `canonical_tags` / `tag_synonyms` in `ambrosia_meta.db` via `AmbrosiaMetaDB`. This is a parallel orphan. Delete.
Severity: medium

**`Database/EPUBValidator.swift` — compiled but never called**
`EPUBValidator.isValid(at:)` and `EPUBValidator.validate(at:)` have no call sites. EPUB path checking is done inline in `AppDelegate.openReaderWindow` via `FileManager.fileExists`. Delete.
Severity: low

**`Reader/BookmarkManager.swift` — stub with no-op bodies**
`saveBookmark` executes JS to extract preview text and then explicitly discards the result. `deleteBookmark` is two `_ =` discards. These code paths are commented as "no longer called." All current bookmark behavior is handled by the annotation system. Delete.
Severity: medium

**`Reader/BookmarkSidebarView.swift` — compiled but never instantiated**
No call site creates or presents `BookmarkSidebarView`. `AnnotationSidebarView.swift` explicitly states it replaces this file. `ReaderViewController` has no reference to it. Delete.
Severity: medium

**`Bookmark` and `Highlight` structs in `Database/Models/BookState.swift` — safe to delete**
Marked "retained for decode compatibility." Confirmed: `BookState`'s `@Model` class has no stored properties of these types. The `ModelContainer` schema is `[BookState.self, ReadingGoal.self]` and neither references these structs. SwiftData never serialized them. No migration is needed. Delete both structs and their `CodingKeys`.
Severity: low

**`AO3Warning.chooseNotTo` case — never referenced**
`AO3Warning.chooseNotTo = "Choose Not To Use Archive Warnings"` exists as an "alternate AO3 export spelling" but no code path compares against it. The filter UI iterates `AO3Warning.allCases`, so removing it would silently drop a filter option. Confirm intent: if this spelling never appears in practice, remove the case; if it does, add a test.
Severity: low

**`AmbrosiaMetaDB.startReadingSession` / `updateReadingSession` / `closeZombieReadingSessions` — no callers**
These three methods manage `reading_history` row lifecycle. The `reading_history` and `book_opens` tables exist in the schema and `ActivityFeedView` queries `reading_history` via `recentReadingHistory`, but nothing ever writes to these tables during normal use. The write path is unfinished, not dead in the permanent sense. Track this as an incomplete feature rather than delete it, but annotate the methods clearly so they are not mistaken for live code.
Severity: medium (incomplete feature, not a bug)

---

## 2. Stale Comments and Documentation

**`Reader/BookmarkManager.swift` USAGE block contradicts the code**
The USAGE comment describes a live call pattern ("Save (triggered by ⌘D)") but the method body says "This code path is no longer called." Moot once the file is deleted (see Section 1), but if retained for any reason, the USAGE block must be removed.
Severity: medium

**`Database/AmbrosiaMetaDB.swift` — `series_placeholders` migration comment missing**
The `createAO3Metadata` function runs a multi-step DROP + RENAME migration on every cold start with no comment explaining the intent or the re-run behavior. A developer reading this for the first time will not understand why `series_placeholders` is created, immediately dropped, and renamed from a keyed variant. Add a comment before the migration block, and add a schema version gate (see Section 7, Invariant 11).
Severity: medium

**`Database/BookLibrary.swift` — double-stale comment**
The comment says "Does NOT reference the removed Book @Model" and cites "Phase 6 (Collections)" as the consumer. Phase 6 shipped without this file being wired up. Moot once deleted.
Severity: low

**`Database/Models/Fandom.swift` — future tense for completed work**
"Phase 2 will introduce proper tag grouping via synonym tables." Phase 2's synonym tables (`canonical_tags`, `tag_synonyms`) are implemented. Moot once deleted.
Severity: low

**Section markers (`§1`–`§9`, `§perf`) function as inline TODOs with no tracking**
These markers describe partial or iterative changes and are not standard `TODO:` / `FIXME:` markers, so they do not surface in Xcode's issue navigator. Examples: `§5: was .finished` in `AmbrosiaMetaDB.swift`, `§9 / §4` in `LocalFeedServer.swift`, `§2a fix (2)` in `CalibreLibrary.swift`. Consider converting resolved ones to normal comments and open tickets for any that represent outstanding work.
Severity: low

**`Reader/ContextMenuPreferences.swift` — "initial implementation" framing**
The comment "no UserDefaults persistence needed for the initial implementation" implies temporary state. The struct has been in this form since creation. If the lack of persistence is intentional, say so directly.
Severity: low

---

## 3. Debug and Diagnostic Cruft

**`[StarDiag]` print statements in `LibraryUI/BookGridItem.swift` — unconditional, production-shipping**
Lines 96–100, 137, 379, 534, 697, 1265, 1267. Nine unconditional `print("[StarDiag] ...")` calls fire on every page load, sort change, scroll, and toggle. Several include `Thread.callStackSymbols.prefix(6)`, which allocates on every invocation. Not wrapped in `#if DEBUG`. Remove or gate.
Severity: high

**`[FlashDiag]` print statements in `LibraryUI/BookGridItem.swift` — unconditional, with timing arithmetic**
Lines 201, 203, 205, 701, 717, 733, 735. Seven unconditional statements emit timing data (`Int(Date().timeIntervalSince(t0)*1000)ms`) on every `onAppear` and `refreshBookStates()` call. Not `#if DEBUG`-gated. Remove or gate.
Severity: high

**`[FilterSuggestions]` print statements in `LibraryUI/FilterDrawer/FilterValueTextField.swift`**
Three unconditional `print("[FilterSuggestions] ...")` calls fire during every suggestion panel lifecycle event (show, reposition, dismantleNSView), meaning every keystroke in a filter field. Not `#if DEBUG`-gated.
Severity: medium

**`[LibraryFilterDebug]` infrastructure in `LibraryUI/FilterDrawer/FilterBuilder.swift`**
`LibraryFilterDebug.log(...)` checks an `isEnabled` flag at runtime, which is always `false` unless toggled in source. The infrastructure (`Date()` calls, dictionary construction, guard checks) runs on every hot path. The pattern leaves a live switch with no UI surface to enable it. Either expose a debug toggle or replace with `#if DEBUG` compilation.
Severity: low

**`[LibrarySession]` print statements — mix of useful logging and debug noise**
`LibrarySession.swift` lines 122, 126, 142, 175, 188, 195, 214, 217. Most are informational and reasonable. A few (`"fulltext search returned no matches"`) are debug traces that fire on normal user queries. These should be separated by severity or moved behind `#if DEBUG`.
Severity: low

---

## 4. Structural Sprawl

**`LibraryUI/BookGridItem.swift` is 2285 lines with at least five distinct responsibilities**
The file contains: (1) `LibraryRootView` — the full list view with pagination, filtering, and sort logic; (2) `FlowLayout` — a reusable layout primitive; (3) series grouping logic (`rebuildItems`, `SeriesGroup` assembly); (4) FTS orchestration; (5) EPUB export triggering. None of these are independent types with their own file. Suggested split: `FlowLayout.swift`, `SeriesGroupBuilder.swift` (the `rebuildItems` logic and its helpers), `LibraryRootView.swift` (pure SwiftUI view). The `LibraryFilterDebug` type in `FilterBuilder.swift` could also move.
Severity: high

**`CalibreLibrary` holds a second private `Connection` to `ambrosia_meta.db`**
`CalibreLibrary.init(root:metaDBPath:)` opens `Connection(metaDBPath, readonly: true)` and stores it as `private let metaDB`. This gives the app three concurrent connections to `ambrosia_meta.db`: the actor's write connection, the actor's read connection, and this one. Under WAL mode this is safe but architecturally incorrect — `AmbrosiaMetaDB` is the declared owner of that database. The three methods that use this connection (`ao3WordCounts(ids:)`, `ao3Dates(ids:)`, `crossoverBookIDs()`) must move to `AmbrosiaMetaDB`. See Invariant 10.
Severity: medium

**`AO3TagSearchResolver` opens a fresh `Connection` per call**
Both `canonicalTerm(for:)` and `expandedTerms(for:)` construct a path and call `Connection(metaURL.path, readonly: true)` on every invocation. These fire on every keystroke in a tag filter field. No connection is cached. The resolver also bypasses `LibrarySession`, violating Invariant 10. Fix by routing through `LibrarySession.metaDB` or caching a single connection that is invalidated on library switch.
Severity: medium

**`LibrarySession.open()` has a duplicate `cachedReadLaterIDs = []` assignment**
Lines 105–106 contain two assignments to `cachedReadLaterIDs = []`, one with incorrect indentation suggesting a copy-paste merge error. Remove the duplicate.
Severity: low

**`LibrarySession.close()` does not reset `cachedReadLaterIDs`**
`close()` clears `cachedLikedIDs`, `cachedSkippedIDs`, `cachedSeriesOrMergedIDs`, and `cachedAO3PublisherIDs` but omits `cachedReadLaterIDs`. This means switching libraries leaves the previous library's Read Later set visible until the next `refreshBookStates()` completes, which can cause incorrectly highlighted rows on first render. Add `cachedReadLaterIDs = []` to `close()`.
Severity: medium

**Naming variance across `CalibreLibrary` fetch methods**
`books(offset:limit:...)`, `books(ids:offset:limit:...)`, `booksForIDs(_:)`, `_fetchBooks`, and `_fetchBooksQueryIDs` are five entry points for fetching `CalibreBook` arrays with overlapping semantics. `_fetchBooksQueryIDs` is a one-line wrapper that calls `_fetchBooks`. The underscore-prefixed `internal` methods coexist with public non-underscore ones without a consistent access-control convention. Consolidate or document the distinction.
Severity: low

---

## 5. Error Handling Consistency

**`AmbrosiaMetaDB.createAO3Metadata`: DROP + RENAME migration is not transactional**
The migration block that creates `series_placeholders_keyed`, copies data, drops the original, and renames runs as individual SQLite statements via `db.execute()`. SQLite's `execute()` does not wrap multi-statement strings in a transaction. A process kill between the DROP and the RENAME would leave the database without `series_placeholders`. Wrap in `db.transaction` and gate on `user_version` so the migration runs exactly once.
Severity: high

**`ReadingTarget.primaryBook` force-unwrap**
`Database/Models/CalibreBook.swift` line 240:
```swift
case .series(let series): return series.works.first!
```
A `SeriesGroup` with an empty `works` array crashes here. The construction site in `rebuildItems` (`BookGridItem.swift` line 562) guards `works.count > 1` before creating a `SeriesGroup`, so in normal flow `works` is never empty. However, the force-unwrap encodes no such guarantee at the type level. If `rebuildItems` is ever called on a partial result or if data returns unexpectedly empty from `booksForIDs`, this crashes the reader-open path. Replace with `series.works.first ?? fallback` or enforce the non-empty invariant at `SeriesGroup` construction with a `precondition`.
Severity: high

**`LibrarySession.open()`: force-unwrap on `collectionStore`**
Line 120: `let cs = collectionStore!` inside an `if let server = feedServer` branch, immediately after `collectionStore = CollectionStore(db: newMetaDB)`. Safe in current flow because `CollectionStore.init` cannot throw, but fragile if that changes. Replace with `guard let cs = collectionStore else { return }`.
Severity: low

**`AmbrosiaMetaDB.importConfiguredAO3TagSeedsIfNeeded`: DETACH in `defer` swallows errors**
`defer { try? db.execute("DETACH DATABASE ao3_seed") }` discards detach errors silently. A failed DETACH after a partial copy transaction would leave a dangling attachment. Log the error.
Severity: low

**`BookGridItem.rebuildItems()`: broad `try?` discards**
Every `await metaDB.*` call in `rebuildItems()` is wrapped in `(try? await ...) ?? [:]`. Database errors are silently mapped to empty dictionaries. The UI renders as if metadata is absent with no indication of failure. Add error logging at minimum; consider surfacing a transient warning in the UI for repeated failures.
Severity: medium

**Dominant pattern throughout: `try?` with `?? []` fallback**
Database reads broadly use silent fallback rather than error propagation. This is acceptable for read paths where a degraded result is preferable to a crash, but errors should be logged so they are visible during development. The pattern `(try? ...) ?? []` with no `print` or `os_log` is invisible in production.
Severity: low

---

## 6. API / Version Notes

**SQLite.swift 0.15.3 — `db.scalar` return type is `Binding?`**
The pattern `try db.scalar(sql, bindings)` returns `Binding?`, then cast as `Int64` or `Int`. SQLite integers always return as `Int64` on this version. Existing code handles both with dual `if let` chains, which is defensive and correct.

**FlyingFox pinned at 0.26.2 (revision `de38230`)**
`LocalFeedServer` wraps FlyingFox heavily. FlyingFox has no stable ABI guarantee. Verify call sites against 0.26.2's public API before any dependency update.

**ZIPFoundation 0.9.19 — throwing initializer form**
`Archive(url:accessMode:)` (the non-deprecated throwing form) is used correctly in `EPUBParser`. `EPUBValidator` also uses it but `EPUBValidator` is dead code (see Section 1).

---

## 7. Invariant Violations

The following cross-references the invariants stated in the architecture document.

**Invariant 1 — Session PRAGMAs on the Calibre connection**
`CalibreLibrary.swift` lines 59–61 issue `PRAGMA cache_size = -32768` and `PRAGMA temp_store = MEMORY`. These are session-scoped and do not modify the database file. The old invariant's wording ("never issue write PRAGMAs") was imprecise. The rewritten invariant explicitly permits these. No code change needed.

**Invariant 2 — `books.series` join**
No violation. All series access uses `books_series_link -> series`.

**Invariant 3 — `[Binding?]`**
No violation in main paths.

**Invariant 4 — SwiftData schema**
No violation. `BookState` stores only scalar properties.

**Invariant 5 — UTF-16 offsets**
No violation. JS TreeWalker uses `node.length` (UTF-16 code units on Text nodes), consistent with the contract.

**Invariant 6 — `WKWebViewConfiguration` before init**
No violation. Handlers are registered on the configuration before `WKWebView` is constructed.

**Invariant 7 — Full reload on style changes**
Currently respected (all preference changes trigger `reloadHTML`). The architecture document clarifies this is not a permanent requirement for style-only changes; see the CSS pipeline note in that document.

**Invariant 8 — `evaluateJavaScript` completionHandler**
No violation. Calls that capture return values use `[weak self]` closures with result handling. Fire-and-forget calls pass `completionHandler: nil`.

**Invariant 9 — `NSHostingView sizingOptions = []`**
`LibraryViewController.swift` and `ReaderViewController.swift` (annotation sidebar) set `sizingOptions = []` correctly. `PreferencesWindowController.swift` line 24 uses `NSHostingView(rootView:)` without setting `sizingOptions`. This is a fixed-size preferences window where the `NSWindow` sets an explicit content rect; SwiftUI's intrinsic size is not the layout driver, so this divergence is lower risk than a full-pane case. Leaving it unsized is acceptable here. The updated invariant adds a scope condition that covers this case.

**Invariant 10 (new) — `AmbrosiaMetaDB` sole ownership — VIOLATED**
Two violation sites:

1. `CalibreLibrary` opens its own `Connection` to `ambrosia_meta.db` for `ao3WordCounts`, `ao3Dates`, and `crossoverBookIDs`. Fix: move these three methods to `AmbrosiaMetaDB` as actor-isolated reads and remove `metaDB: Connection` from `CalibreLibrary.init`.

2. `AO3TagSearchResolver.activeMetaDatabaseURL()` + `Connection(metaURL.path, readonly: true)` opens a fresh connection per keystroke from a non-actor context. Fix: route through `LibrarySession.metaDB` or cache a single connection invalidated on library switch.

Severity: medium

**Invariant 11 (new) — Migration must use `user_version` — VIOLATED**
`ambrosia_meta.db` has no `PRAGMA user_version` usage anywhere. All migrations run on every launch gated only by `IF NOT EXISTS`. The `series_placeholders` migration in `createAO3Metadata` runs a full copy-drop-rename cycle of the live table on every cold start. While data survives because the copy precedes the drop, this is crash-risky (no transaction) and wasteful. Fix: add `PRAGMA user_version` checks; each destructive migration runs once and increments the version.

Severity: high

**Invariant 12 (new) — No force-unwraps in data paths — VIOLATED**
`ReadingTarget.primaryBook` (`CalibreBook.swift` line 240): `series.works.first!`. The construction site guards `works.count > 1`, but the type carries no such guarantee and the force-unwrap is reachable via any path that constructs a `SeriesGroup` and then calls `primaryBook`. Fix: replace with `series.works.first ?? series.works[0]` (unreachable after the count guard) or enforce non-emptiness at construction with a `precondition` that surfaces the invariant explicitly.

Severity: high

**Invariant 13 (new) — Diagnostic prints must be `#if DEBUG` — VIOLATED**
`[StarDiag]` and `[FlashDiag]` blocks in `BookGridItem.swift` are unconditional. Several `[StarDiag]` calls include `Thread.callStackSymbols`, which allocates on every invocation in production. Fix: wrap all diagnostic `print` calls in `#if DEBUG` or remove them.

Severity: high

---

## 8. Test Coverage

No test targets, test directories, or test files of any kind exist in this codebase. No `XCTestCase` subclasses, no `*Tests` directory, no test scheme entries in `project.pbxproj`.

The highest-risk untested paths:

- `AmbrosiaMetaDB` migration logic — runs on every launch, contains a destructive DROP + RENAME cycle.
- `FilterBuilder.matchingIDs` — complex multi-pass filter logic; silent fallbacks make failures invisible.
- `AO3MetadataExtractor.extract` — parses HTML from external files; error modes are diverse.
- `EPUBParser` — file parsing with multiple failure modes and a zip layer.
- `SearchQueryParser.parse` — tokenization with edge cases around prefix handling.

---

## 9. Prioritized Fix List

The following is ordered by risk reduction per effort, not by category.

**1. Remove `[StarDiag]` and `[FlashDiag]` diagnostics from `BookGridItem.swift`**
Roughly 16 line deletions. These fire in production on every page load, sort change, and `onAppear`, several with `Thread.callStackSymbols` allocations. Zero user-visible impact from removing them.

**2. Fix `ReadingTarget.primaryBook` force-unwrap**
Replace `series.works.first!` with a `precondition(!series.works.isEmpty, ...)` plus `series.works[0]`, or enforce the invariant at the `SeriesGroup` construction site in `rebuildItems`. A `SeriesGroup` with zero works crashes the reader-open path.

**3. Fix `LibrarySession.close()` missing `cachedReadLaterIDs` reset**
Add `cachedReadLaterIDs = []` alongside the other four cache resets in `close()`. Without it, switching libraries can show the previous library's Read Later highlights until the next refresh cycle completes. Also remove the duplicate assignment in `open()`.

**4. Wrap the `series_placeholders` migration in a transaction and add `user_version` gating**
The current migration runs DROP + RENAME on every launch outside a transaction. A crash between those two statements would corrupt `ambrosia_meta.db`. Add `PRAGMA user_version` reads and writes; gate the migration to run exactly once. This is the entry point for adding proper versioned migration infrastructure.

**5. Eliminate the rogue `ambrosia_meta.db` connections**
Move `ao3WordCounts(ids:)`, `ao3Dates(ids:)`, and `crossoverBookIDs()` from `CalibreLibrary` to `AmbrosiaMetaDB` as actor-isolated reads. Fix `AO3TagSearchResolver` to route through `LibrarySession.metaDB` or cache a single connection. This removes the third concurrent connection to `ambrosia_meta.db`, eliminates a whole category of potential WAL read/write ordering bugs, and enforces the ownership boundary stated in Invariant 10.

**6. Delete confirmed dead code**
`BookmarkManager.swift`, `BookmarkSidebarView.swift`, `BookLibrary.swift`, `TagSynonymStore.swift`, `EPUBValidator.swift`, `Fandom.swift`, and the `Bookmark`/`Highlight` structs in `BookState.swift`. These files compile, pass type-checking, and contribute nothing. Deleting them reduces the surface area that must be read to understand the codebase.
