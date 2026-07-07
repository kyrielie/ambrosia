# Ambrosia Code Audit and Cleanup Plan

Scope: the Swift sources under `Ambrosia/` (65 files, ~24,200 lines), cross-checked
against `ambrosia_architecture.md`'s own stated invariants and "Fixed." notes,
plus the three standing SwiftData rules for this project:

- Never use `[String]` (or any bare collection) as a stored `@Model` attribute.
- Never call `modelContext.reset()`.
- Never call `model(for:)` across different `ModelContext` instances.

## How to read this document

Findings are grouped by severity, each with the evidence (file/line), why it
matters, and a concrete fix. A separate section lists things that were
**checked and found already correct** — worth stating explicitly so nobody
re-litigates them or "fixes" something that isn't broken.

**Overall assessment:** this is not a lightly-vibecoded codebase. The database
layer in particular (`CalibreLibrary`, `AmbrosiaMetaDB`, `FilterBuilder`) carries
detailed rationale comments explaining *why* a non-obvious choice was made, the
architecture doc's 21 invariants read as real lessons from real incidents (the
"LibraryUI Row Split" retro is a good example), and several genuine bugs
described in the architecture doc as historical problems (the `series.works.first!`
crash site, `CalibreLibrary` opening a second illegal connection to
`ambrosia_meta.db`) are, on inspection of the actual code, already fixed. The
issues below are what's left, not a wholesale rewrite.

---

## SwiftData rule compliance — checked, all clear

- **No `@Model` type stores a bare collection.** The schema is exactly two types
  (`BookState`, `ReadingGoal`; `Ambrosia/Database/Models/BookState.swift`,
  `ReadingGoal.swift`), and both contain only scalar properties (`Int`, `Double`,
  `Date`, `TimeInterval`). `SeriesGroup`'s arrays (`Ambrosia/Database/Models/CalibreBook.swift:133-148`)
  are fine — it's a plain in-memory struct, never persisted through SwiftData.
- **`modelContext.reset()` is never called.** Zero occurrences anywhere in the
  target.
- **`model(for:)` is never called.** Zero occurrences. Every place that needs a
  `BookState` inside a specific `ModelContext` re-fetches it by `calibreID`
  *within that context* (`stateForMutation(_:in:)` in both
  `LibraryRootView.swift:1730` and `EmailLibraryViewController.swift:1494`)
  rather than reusing an object obtained from a different context.

One related, low-priority observation (not a rule violation): the app creates a
**new, short-lived `ModelContext`** for nearly every SwiftData read or write —
`ReaderWindowController.swift:71,135`, `ReaderViewController.swift:171`,
`EmailLibraryViewController.swift:238,254,1408,1442,1470,1593`. This is safe as
implemented (see above), but it's more context churn than necessary. See Finding
6 (Low) below.

---

## Findings — High priority

### Finding 1 — `WKScriptMessageHandler` retain cycle leaks the entire reader (memory leak, every window close)

**Where:** `Ambrosia/Reader/ReaderViewController.swift:248-252`

```swift
config.userContentController.add(self, name: "positionUpdate")
config.userContentController.add(self, name: "pageAction")
config.userContentController.add(self, name: "highlightAdded")
config.userContentController.add(self, name: "highlightTapped")
config.userContentController.add(self, name: "consoleLog")
```

**Why it matters:** `WKUserContentController.add(_:name:)` retains its handler
strongly. `ReaderViewController` owns the `WKWebView`, which owns its
`configuration`, which owns the `userContentController`, which now holds a
strong reference back to `ReaderViewController` — a closed reference cycle
entirely internal to the view controller's own object graph. `deinit` (line 330)
only removes two `NSEvent` monitors; it never calls
`removeScriptMessageHandler(forName:)` for any of the five names, and nothing
else does either. `ReaderWindowController.windowWillClose` (line 127) removes the
window controller from its `openWindows` dictionary and updates `BookState`, but
never touches the message handlers.

Net effect: every time a reader window is opened and closed, the
`ReaderViewController`, its `WKWebView`, every `EPUBParser` and its parsed HTML,
the `SeriesSpineMap`, and the AO3 metadata records for the session are all kept
alive for the remaining lifetime of the app process. This is a classic, very
common WKWebView bug — worth recognizing on sight in any WebKit-based Mac/iOS
app, not just this one.

**Fix:** either of two standard approaches:

1. Register a small weak-referencing proxy object as the handler instead of
   `self`:
   ```swift
   final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
       weak var target: WKScriptMessageHandler?
       init(target: WKScriptMessageHandler) { self.target = target }
       func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
           target?.userContentController(c, didReceive: m)
       }
   }
   ```
   and `config.userContentController.add(WeakScriptMessageHandler(target: self), name: "positionUpdate")` etc.
2. Or, simpler here since teardown is centralized: explicitly call
   `removeScriptMessageHandler(forName:)` for all five names in
   `ReaderWindowController.windowWillClose`, before releasing the view
   controller.

Either fix is small and self-contained. Recommend (1) — it also protects against
any *future* registration site that forgets explicit teardown.

**Effort:** small (1-2 hours including manual verification that windows actually
deallocate — e.g. a `deinit` log line, opened/closed a few times, confirmed it
fires).

---

### Finding 2 — The List and Email library UIs independently reimplement the entire search/filter/paging pipeline

**Where:** `Ambrosia/LibraryUI/LibraryRootView.swift` (1,803 lines) and
`Ambrosia/LibraryUI/Email/EmailLibraryViewController.swift` (1,889 lines).

At least 17 identically- or near-identically-named methods exist in both files,
implementing the same logic twice:

`applyFilterRules`, `loadPage`, `visibleIDs`, `visibleBooks`, `intersect`,
`queryWithCachedFullText`, `resolveTagExpansionsIfNeeded`,
`scheduleDeferredSQLFilterCount`, `startPendingFilterFullText`,
`startPendingSearchTextFullTextIfNeeded`, `applyResolvedSearchTextFullText`,
`stateForMutation`, `refreshBookStates`, `markRead`, `resetProgress`,
`toggleReadLater`, `addOrReplaceRule`.

This isn't superficial naming overlap — the bodies are line-for-line identical
in the core logic, differing only in cosmetic details (a `"surface": "list"` vs
`"surface": "email"` debug tag, `prefs` vs `ReaderPreferences.shared`,
`shouldGroupSeriesRows` vs `shouldGroupSidebarRows`). For example,
`applyFilterRules()`:

```swift
// LibraryRootView.swift:1043                    // EmailLibraryViewController.swift:576
private func applyFilterRules() {                func applyFilterRules() {
    let applyStart = LibraryFilterDebug.now()         let applyStart = LibraryFilterDebug.now()
    fullTextTask?.cancel()                            fullTextTask?.cancel()
    fullTextTask = nil                                fullTextTask = nil
    filterCountTask?.cancel()                         filterCountTask?.cancel()
    guard let library = session.library else {        guard let library = session.library else {
        toolbarState.cancelLibraryFilterApplication() toolbarState.cancelLibraryFilterApplication()
        return                                            return
    }                                                  }
    ...                                                ...
```

and `visibleBooks(_:)`:

```swift
// LibraryRootView.swift:908                                    // EmailLibraryViewController.swift:1392
private func visibleBooks(_ raw: [CalibreBook]) -> [CalibreBook] {  private func visibleBooks(_ raw: [CalibreBook]) -> [CalibreBook] {
    ...                                                                raw.filter { book in
    return raw.filter { book in                                           (ReaderPreferences.shared.showSkippedCollection || !skippedIDs.contains(book.id)) &&
        (prefs.showSkippedCollection || !skippedIDs.contains(book.id)) &&  (!shouldGroupSidebarRows || !seriesOrMergedIDs.contains(book.id)) &&
        (!shouldGroupSeriesRows || !seriesOrMergedIDs.contains(book.id)) &&  (!ReaderPreferences.shared.hideNonAO3PublisherBooks || book.isAO3PublisherBook) &&
        (!prefs.hideNonAO3PublisherBooks || book.isAO3PublisherBook) &&    !book.isDescriptionAnthology
        !isAnthology(book)                                             }
    }                                                                }
}
```

**Drift has already started**, which is exactly the risk of this pattern:
`LibraryRootView`'s copy of `visibleBooks` has a `#if DEBUG` diagnostic block
(logging which books get filtered out and why) that `EmailLibraryViewController`'s
copy does not have. Whoever added that diagnostic added it to one file and not
the other — not because it wasn't needed in Email mode, but because there was no
single place to add it once.

**This is a known, named problem inside the codebase already.** The doc comment
at the top of `Ambrosia/Database/TagExpansionResolver.swift` says so directly:

> "Shared tag-synonym expansion helpers used by both `LibraryRootView` and
> `EmailLibraryViewController`. Both views previously carried their own copies
> of these two call-site blocks (Phase 2 already removed one instance of this
> duplication; this is a smaller recurrence in the filter/search pipeline...)"

In other words: this exact category of duplication has been identified and
partially fixed once already (tag-expansion resolution was extracted into
`TagExpansionResolver`), but the much larger surface — the filter/paging/mutation
orchestration this plan is describing — was left in place.

**Why it matters:** any bug fix, new filter type, or behavior change to search
has to be made twice, correctly, in two files with different underlying
UI frameworks (SwiftUI state vs. AppKit table view state), and there is no
compiler or test that enforces the two stay in sync. The `visibleBooks` drift
above is a live example of exactly this happening.

**Fix (phased, since this is the largest single change in this plan):**

1. **Extract a UI-agnostic query/orchestration object** — e.g.
   `LibraryQueryController`, a plain `@MainActor` class (not a `View`, not an
   `NSViewController`) owning: current page, offset history, active filter
   result, debouncer, and the full set of `applyFilterRules` /
   `startPendingFilterFullText` / `visibleBooks` / `visibleIDs` /
   `scheduleDeferredSQLFilterCount` logic. It depends only on `LibrarySession`,
   `ToolbarState`, and `CalibreLibrary` — never on `View` or `NSViewController`.
2. Give it a small callback/closure surface (e.g. `onPageLoaded: ([CalibreBook]) -> Void`)
   so both `LibraryRootView` (via `@State` + `.onReceive`/`onChange`) and
   `EmailLibraryViewController` (via a stored closure property) can drive their
   own, framework-specific rendering from the same underlying results.
3. Migrate `LibraryRootView` first (SwiftUI's `@Observable` integration makes
   this the lower-risk side), verify with a manual full pass through search,
   filter, and pagination, then migrate `EmailLibraryViewController`.
4. Delete the now-dead duplicated methods from both files once migrated.
5. Fold the mutation helpers (`markRead`, `resetProgress`, `toggleReadLater`,
   `stateForMutation`, `refreshBookStates`) into the same controller, since they
   share the SwiftData context-management pattern discussed in Finding 6.

**Effort:** large (this is a multi-day refactor touching the two biggest files in
the codebase). Do not attempt as a single change — per Invariant 21 in the
architecture doc, every commit touching `.swift` files must pass a clean
`xcodebuild build` before merge, and a refactor this size should land in
reviewable, independently-buildable steps (e.g., extract-and-delegate for one
method at a time, not a big-bang rewrite).

---

## Findings — Medium priority

### Finding 3 — 34 diagnostic `print()` calls are not gated behind `#if DEBUG`

**Where (representative — full list found by `grep -rn "print("`):**
`LibrarySession.swift` (13 occurrences — lines 155, 158, 243, 249, 276, 289,
389, 407, 508, 537, 539, 558, 594), `CalibreLibrary.swift` (482, 532, 677, 705),
`LibraryRootView.swift` (730, 733, 736, 742, 757, 760, 763, 766),
`ReaderViewController.swift` (634, 809, 1229, 1271), plus one each in
`AmbrosiaApp.swift:25`, `LibraryIndexManager.swift:88`,
`AO3MetadataExtractor.swift:105`, `CalibreFTSLibrary.swift:267`,
`CalibreLibrarySearch.swift:96`, `PaginationEngine.swift:113`,
`LocalFeedServer.swift:230`, `FilterDrawerView.swift:270`,
`FilterBuilder.swift:574`.

**Why it matters:** this is Invariant 13 in the codebase's own architecture doc
("All diagnostic print calls must be wrapped in `#if DEBUG` or removed before
shipping"), stated because it's already been identified as a problem once. These
34 are all in error-handling branches (`catch { print(...) }`), so they're not
spamming the console in normal operation — but they will fire in a shipped
Release build the moment any of these operations fails on a user's machine,
writing library paths, SQL error text, and similar internal detail to the
system log with no `#if DEBUG` guard to strip it out.

Contrast this with `LibraryFilterDebug.log(...)` (`FilterBuilder.swift:10-24`),
which does this correctly — the `print` inside it is `#if DEBUG`-gated once,
centrally, so every one of its ~60 call sites across the codebase is
automatically safe. The 34 calls above are the ones that bypassed that helper
and called `print` directly.

**Fix:** mechanical — wrap each in `#if DEBUG ... #endif`, or route them through
`LibraryFilterDebug.log` (or an equivalent lightweight logger) so the guard lives
in one place. Given the volume, this is a good candidate for a small script pass
followed by manual review of each diff (some of these `catch` blocks may also
warrant surfacing the error to the user via `LibrarySession.lastError` instead of
only logging it — worth a case-by-case judgment call while touching each one).

**Effort:** small-medium (mechanical but touches many files; budget time for
review, not just the find-and-wrap).

---

## Findings — Low priority / polish

### Finding 4 — `LibraryFilterDebug` call sites do real work even when logging is compiled out

**Where:** `Ambrosia/LibraryUI/FilterDrawer/FilterBuilder.swift:7-24`, and ~60
call sites across `LibraryRootView.swift`, `EmailLibraryViewController.swift`,
`CalibreLibrary.swift`, `LibrarySession.swift`, `AmbrosiaMetaDB.swift`.

`LibraryFilterDebug.log`'s `print` is correctly `#if DEBUG`-gated internally.
But Swift evaluates a function's arguments *before* calling it — there's no
laziness unless a parameter is explicitly `@autoclosure`. So every call like:

```swift
LibraryFilterDebug.log("applyFilter.start", [
    "surface": "list",
    "rules": LibraryFilterDebug.summary(expression: expression),
    "sqlPageable": expression.isSQLPageable
])
```

builds the `summary(expression:)` string (which walks every rule in every group
and joins them) *before* `log` gets a chance to no-op in a Release build. This is
called on every filter application, on a hot path. In practice the cost is
almost certainly small (filter expressions are short), so this is not urgent —
but it is unconditional work in a Release build that exists purely to feed a
debug log statement that will never print.

**Fix:** make `log`'s `fields` parameter `@autoclosure` (or accept a
`() -> [String: CustomStringConvertible?]` closure) so the summary-building work
itself is skipped outside `#if DEBUG`, not just the `print`.

**Effort:** small, but touches ~60 call sites' worth of signature — mechanical,
low risk, good "first PR" cleanup task.

---

### Finding 5 — Stale comments referencing types that no longer exist, and a stub comment on code that's no longer a stub

- `Ambrosia/Reader/EPUBParser.swift:12-13` — a comment listing the cross-file
  character-offset contract still names `BookmarkManager` as one of the
  consumers. That type doesn't exist in the current codebase (only its name
  survives in this comment and in `AnnotationSidebarView.swift`'s "Replaces
  BookmarkSidebarView" comment). Not harmful, but it will send a reader looking
  for a file that isn't there.
- `Ambrosia/Utilities/DebounceTimer.swift:3` — `// Phase 0 stub — implementation
  when needed`. The class is fully implemented and is in active use in five
  places (`ReaderViewController`, `LibraryWindowController`,
  `EmailLibraryViewController`, `LibraryRootView`). The comment is simply
  outdated.

**Fix:** delete or update both comments. Trivial, "documentation describes
something other than reality" cleanup.

**Effort:** trivial.

---

### Finding 6 — Frequent short-lived `ModelContext` creation

**Where:** `ReaderWindowController.swift:71,135`, `ReaderViewController.swift:171`,
`EmailLibraryViewController.swift:238,254,1408,1442,1470,1593`.

As noted in the SwiftData compliance section above, this is not a correctness
bug — every one of these correctly re-fetches by predicate rather than reusing a
cross-context object identity. But creating a fresh `ModelContext(container)` for
nearly every single read or write (rather than sharing one long-lived,
`@MainActor`-owned context, e.g. on `LibrarySession`) is more overhead than
necessary and makes it easier for a future change to accidentally introduce the
cross-context object-identity bug this project has so far avoided (someone
reaching for "the context I already have" from the wrong place). Consider
consolidating to a single shared context once Finding 2's refactor is underway
anyway (both touch the same call sites).

**Effort:** small, best done opportunistically alongside Finding 2 rather than as
its own change.

---

### Finding 7 — A few remaining bare force-unwraps outside the database-read path

Invariant 12 in the architecture doc scopes the "no force-unwraps" rule to code
reachable from database read results, and the one known crash site it calls out
by name (`series.works.first!` in `ReadingTarget.primaryBook`) **has already been
fixed** — it's now `series.works[0]` guarded by a `precondition` in both
`SeriesGroup.init` and `ReadingTarget.primaryBook` (see the developer guide,
Section 8.2). The following are outside that rule's stated scope, and are all
very low practical risk, but are still bare `!` on `Optional`s and worth cleaning
up opportunistically:

- `Ambrosia/Preferences/PreferencesWindowController.swift:1107` —
  `CGColorSpace(name: CGColorSpace.sRGB)!` when converting a color to hex.
  sRGB is guaranteed present on any Mac; effectively zero real-world risk, but
  a `guard let` with a graceful "couldn't produce a hex string" fallback costs
  nothing.
- `Ambrosia/Preferences/PreferencesWindowController.swift:804` —
  `tagSeedConfig.databasePath!`, guarded by a preceding ternary check
  (`... ?.isEmpty == false ? ... databasePath! ...`) so it's logically safe as
  written, but fragile if that ternary is ever edited without noticing the
  dependency. Prefer `if let path = tagSeedConfig.databasePath, !path.isEmpty { ... }`.
- `Ambrosia/Database/LibraryIndexManager.swift:72` and
  `Ambrosia/Database/AmbrosiaMetaDB.swift:48` — both
  `FileManager.default.urls(for: .applicationSupportDirectory, ...).first!`.
  This directory is guaranteed to exist on macOS, so risk is negligible, but a
  `guard let ... else { throw ... }` is one line and removes the last bare `!`
  from otherwise-careful file-path code.
- `Ambrosia/Database/LibrarySession.swift:360` — `let server = feedServer!`.
  Worth double-checking the call site guarantees `feedServer` is non-nil at that
  point (it appears to, from a preceding guard), but the same `guard let`
  treatment is cheap insurance.

**Effort:** trivial, can be done in one pass, no behavior change expected.

---

### Finding 8 — A trivial one-line redundant wrapper

**Where:** `Ambrosia/LibraryUI/FlowLayout.swift:85-87`

```swift
func isAnthology(_ book: CalibreBook) -> Bool {
    book.isDescriptionAnthology
}
```

This free function does nothing but forward to the computed property already
defined on `CalibreBook` (`Ambrosia/Database/Models/CalibreBook.swift:63-67`).
Not a bug — every call site gets the correct, single implementation either way —
but it's an unnecessary indirection that costs a reader a jump to find out it's
not doing anything. (Note: `EmailLibraryViewController.swift`'s copy of
`visibleBooks` already calls `book.isDescriptionAnthology` directly rather than
through this wrapper — one more small, harmless inconsistency stemming from
Finding 2's duplication.)

**Fix:** call `book.isDescriptionAnthology` directly at the two or three call
sites that currently go through `isAnthology(_:)`, and delete the function. Low
value, but zero risk, and it's already been half-migrated by accident.

**Effort:** trivial.

---

## Suggested sequencing

1. **Do first (low risk, high value for the time spent):** Findings 5, 7, 8 —
   all repo-hygiene / correctness-adjacent cleanups with no behavioral risk.
   Bundle into one PR.
2. **Do second:** Finding 3 (unguarded prints) and Finding 4 (`@autoclosure` on
   `LibraryFilterDebug.log`) — mechanical, independent of each other, both
   improve Release-build hygiene.
3. **Do third:** Finding 1 (WKScriptMessageHandler retain cycle) — small, but
   should get a deliberate manual verification pass (confirm `deinit` actually
   fires now) rather than being bundled with anything else.
4. **Do last, deliberately:** Finding 2 (List/Email duplication) — the only
   large-effort item here. Everything above it should land first so this
   refactor starts from a cleaner baseline, and Finding 6 (context consolidation)
   is worth folding into the same effort since it touches overlapping code.

## A process suggestion, not a code fix

Given that `TagExpansionResolver.swift`'s own comment shows this project has
already caught and partially fixed one instance of the List/Email duplication
pattern (Finding 2) before, it may be worth adding a line to
`ambrosia_architecture.md`'s invariant list once Finding 2 is resolved: something
like *"Business logic for the library query/filter/paging pipeline lives in
`LibraryQueryController`, not in `LibraryRootView` or
`EmailLibraryViewController` directly — if you find yourself writing the same
method in both files, that's the signal to move it, not duplicate it again."*
The existing invariant list is clearly written by people who've been burned by
specific recurring mistakes; this pattern has recurred at least twice now and is
worth naming explicitly so it doesn't recur a third time.
