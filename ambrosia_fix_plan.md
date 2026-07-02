# Ambrosia Implementation Plan
**Status:** Supersedes all prior planning documents (`ambrosia_audit.md`,
`ambrosia-unified-rules-and-compliance.md`, `ambrosia-vibecoding-remediation-phases.md`,
`calibrelibrary-actor-migration-plan.md`, `ambrosia-search-filter-remediation-plan.md`).
Discard those — this document is the sole source of truth going forward.

**Provenance:** Every item below was independently re-verified against the current
source tree (not assumed from prior documents) before being included. Items from prior
docs that did not survive verification are listed in "Discarded claims" at the end, so
they are not silently lost or accidentally re-derived later.

**Audience:** An AI coding agent (or human engineer) with repo access, no conversation
history, and working Swift/SwiftUI/AppKit/actor-isolation knowledge.

---

## Ground rules

1. **Read every file in full immediately before editing it.** Line numbers below are
   accurate as of this writing but will drift the moment any phase lands. Never edit
   from a cached mental model of a file — `view` it first, every time.
2. **One phase per branch/PR.** Phases are ordered by dependency; do not combine two
   phases in one diff even if they touch overlapping files.
3. **Every commit touching `.swift` files must pass a full `xcodebuild build` before
   merge.** This project currently has zero test targets and zero CI. Phase 0 exists to
   fix that; do not skip it or treat it as optional.
4. **Do not guess APIs, versions, or signatures.** Confirm method signatures by reading
   the actual declaration before calling it from new code.
5. **No behavior change without a verification step.** Every phase has a "Verify"
   section — do not consider a phase done until you've actually performed it, not just
   made the code compile.
6. **Package versions in use (confirmed in `Package.resolved`/imports):** SQLite.swift
   0.15.3, ZIPFoundation 0.9.19, SwiftSoup 2.13.5, FlyingFox 0.26.2. Do not upgrade any
   of these as a side effect of this plan.

---

## Phase 0 — Add a build gate

### Why first
Every phase after this one is a multi-file mechanical change (actor conversion,
call-site sweeps across 10+ files). This codebase has a documented history of exactly
this kind of change shipping with double-digit compile errors because nothing forced a
green build before merge (see the "LibraryUI Row Split" incident referenced in
`ambrosia_architecture.md`'s Key Invariant 21). Confirmed in this pass: **no test
targets, no test directories, no CI config, no `.yml`/`.yaml` files anywhere in the
repo.** This is not a stale claim — it was checked directly.

### What to do
1. Identify the actual scheme name from `Ambrosia.xcodeproj/project.pbxproj` — do not
   assume it's literally `Ambrosia`.
2. Add a minimal CI workflow (GitHub Actions, if the repo is hosted on GitHub — check
   for a `.git/config` remote pointing at github.com to confirm) that runs:
   ```
   xcodebuild build -project Ambrosia.xcodeproj -scheme <ACTUAL_SCHEME_NAME> -destination 'platform=macOS'
   ```
   on every push and PR.
3. If CI infrastructure isn't available in this environment, fall back to a checked-in
   pre-commit or pre-push git hook running the same command locally, and say explicitly
   in the PR description which of the two you implemented.
4. Do not attempt to backfill a test suite in this phase. The build gate alone is the
   deliverable — it mechanically catches the class of bug (renamed types, deleted
   declarations whose bodies survived, stale `private` scoping, missing `await`) that
   has caused real incidents in this codebase, for free, on every future PR.

### Verify
- Deliberately introduce a one-line compile error on a throwaway branch, confirm the
  gate blocks it, then revert.

---

## Phase 1 — `CalibreLibrary` / `CalibreFTSLibrary` actor conversion

### Why this is the highest-priority code fix
`CalibreLibrary` wraps a single SQLite.swift `Connection` with no internal
synchronization. It has an explicit doc-comment contract (top of
`Database/CalibreLibrary.swift`, ~lines 44-58) stating every method must be called from
the main thread only, and that violating this surfaces as an uncatchable `fatalError`
inside SQLite.swift's `FailableIterator.next()` (`SQLITE_BUSY` / "database is locked").
This has already caused production crashes, patched piecemeal with `assertMainThread()`
tripwires and `MainActor.run` wrappers at two sites. Two more violations were confirmed
**live and unfixed** in this pass:

**Confirmed violation sites (verified this pass, not from memory of prior docs):**

1. `LibraryUI/FilterDrawer/FilterBuilder.swift`, `matchingIDs(expression:...)` async
   entry point (~line 132-156): wraps the synchronous `matchingIDs(...)` call — which
   calls into `library.*` methods deep in the same file's `CalibreLibrary` extension —
   inside `Task.detached(priority: .userInitiated) { ... }.value`.
2. `LibraryUI/LibraryRootView.swift`, inside the filter-application `Task { }` block,
   three separate direct calls into `CalibreLibrary` from `Task.detached`:
   - line ~1141-1143: `crossoverMap = await Task.detached(priority: .userInitiated) { library.crossoverBookIDs() }.value`
   - line ~1194-1196: `let fallbackMap = await Task.detached(priority: .userInitiated) { library.ao3WordCounts(ids: candidateIDs) }.value`
   - line ~1233-1235: `let publisherIDs = await Task.detached(priority: .userInitiated) { capturedLibrary2?.ao3PublisherBookIDs() ?? [] }.value`
3. **Contrast/proof the hazard is known:** `Database/LibrarySession.swift`,
   `seedCalibreSeriesCache()` (~line 485-500) already does
   `let entries = await MainActor.run { library.allCalibreSeriesEntries() }`
   specifically to work around this exact issue, with an explanatory comment. The
   filter path (items 1-2 above) is where this fix was never applied.
4. `Networking/LocalFeedServer.swift` is itself `actor LocalFeedServer` (confirmed line
   76). It calls `library.allBookIDs()` (line 345) and `library.books(ids:...)` (line
   444) directly from its own actor executor — a thread relationship with zero overlap
   with the `Task.detached` pattern above. This needs its own fix, not something a
   blanket `MainActor.run` sweep would catch.

**`assertMainThread()` inventory (verify this exact list before deleting anything —
prior docs undercounted this):** the tripwire is declared once (~line 70) and called
from **six** sites, guarding these methods: `bookCount()`, `allBookIDs()`,
`allCalibreSeriesEntries()`, `anthologyBookIDs()`, `books(...)` (two overloads),
`booksForIDs(_:)`. Confirm this list with `grep -n "assertMainThread" Database/CalibreLibrary.swift`
before starting — do not assume the list above is exhaustive if the file has changed
since this was written.

### Decision: convert both `CalibreLibrary` and `CalibreFTSLibrary` to actors, in the same phase

`CalibreFTSLibrary` (`Database/CalibreFTSLibrary.swift`) has the identical shape — plain
`class`, single unguarded `Connection` — and is called from the exact same filter/search
code paths (`fulltextIDs(for:)` in `FilterBuilder.swift`, `session.cachedFulltextIDs` in
view-controller filter-application blocks). It carries no documented threading contract,
which is an omission, not evidence of safety. Convert it in this same phase so you don't
ship a second, un-flagged instance of the same bug class. (Note: this explicitly
resolves a contradiction found across prior planning docs — one said convert it, another
listed it as an out-of-scope non-goal. This plan's decision is final: convert it.)

**Rejected alternative:** wrapping `db` in a private serial `DispatchQueue` with a
synchronous `read { queue.sync { ... } }` shim. Rejected because it gives no compiler
enforcement — a future call site can bypass the queue and nothing catches it — and
because the worst violation (item 1 above, `Task.detached` calling deep into private
synchronous helpers) would need the same file-by-file audit as the actor conversion
anyway, for a weaker guarantee. Actor conversion means the compiler generates the
checklist: every call site that needs a fix becomes a build error.

### Steps

**1.1 — Convert the type declarations.**
```swift
// Database/CalibreLibrary.swift
actor CalibreLibrary {
    let root: URL
    internal let db: Connection
    ...
}
```
```swift
// Database/CalibreFTSLibrary.swift
actor CalibreFTSLibrary {
    ...
}
```
Remove `assertMainThread()`, its declaration, and all six call sites in
`CalibreLibrary.swift` — actor isolation replaces it structurally. Remove the
threading-contract doc comment at the top of the class and replace with:
`// Actor-isolated: all queries serialize automatically. See AmbrosiaMetaDB for the
// equivalent pattern (Database/AmbrosiaMetaDB.swift).`

**1.2 — Build and let the compiler drive the call-site fixes.**
```
xcodebuild build -project Ambrosia.xcodeproj -scheme <SCHEME> 2>&1 | grep "error:"
```
This will not succeed on the first pass — every synchronous call site becomes a
compiler error. This error list is your task list. Do not pre-enumerate call sites by
hand. Keep a running note of file:line as you fix each one; fixing one error sometimes
reveals another on the same line (e.g. a `let x = library.foo()` inside a non-async
function needs the *containing* function made `async` too, propagating to its own
callers).

Known call-site clusters to expect (approximate counts from this pass, re-derive exact
counts with the compiler, don't trust these as final):
- `LibraryUI/Email/EmailLibraryViewController.swift` (~11-14 sites)
- `LibraryUI/LibraryRootView.swift` (~11-13 sites)
- `LibraryUI/SearchSuggestionsView.swift` (~8 sites)
- `Database/LibrarySession.swift` (~7 sites)
- `LibraryUI/FilterDrawer/FilterBuilder.swift` (~6 sites)
- `LibraryUI/FilterDrawer/FilterValueTextField.swift` (~3 sites)
- `Preferences/PreferencesWindowController.swift`, `Networking/LocalFeedServer.swift`,
  `Utilities/ExportManager.swift`, `LibraryUI/ActivityFeedView.swift`,
  `Database/CustomColumnConfig.swift` (1-2 sites each)

**1.3 — Simplify the two existing `MainActor.run` workarounds in `LibrarySession.swift`.**
Do not just leave them wrapped in `await` — remove the now-redundant hop entirely:
- `seedCalibreSeriesCache()`: replace
  `let entries = await MainActor.run { library.allCalibreSeriesEntries() }`
  with `let entries = await library.allCalibreSeriesEntries()`. Delete the workaround
  comment; leave a one-line note that actor isolation now handles this.
- `syncSeriesOrMergedCollection()`: apply the same treatment to its
  `MainActor.run { library.anthologyBookIDs() / library.bookCount() }` block.

**1.4 — Collapse `FilterBuilder`'s manual `Task.detached` wrapper.**
In `LibraryUI/FilterDrawer/FilterBuilder.swift`, the async `matchingIDs(expression:...)`
entry point no longer needs manual off-main dispatch — the actor provides it. Collapse:
```swift
func matchingIDs(
    expression: FilterExpression,
    likedIDs: Set<Int>,
    collectionMap: [String: Set<Int>] = [:],
    statusMap: [AO3CompletionStatus: Set<Int>] = [:],
    fulltextMap: [String: Set<Int>] = [:],
    crossoverMap: Set<Int> = [],
    wordCountFallbackMap: [Int: Int]? = nil
) async -> FilterResult {
    // rename the old synchronous overload (e.g. matchingIDsSync) and call it directly;
    // every call inside it against `library`/`ftsLibrary` now needs `await`, which
    // requires threading `async` through matchingIDsForGroup and its SQL-fragment
    // helpers in the `extension CalibreLibrary` block at the bottom of this file
    // (~lines 427-843 as of this writing — re-check the range, it will have moved).
    await matchingIDsSync(...)
}
```
Delete the three `Task.detached { library.crossoverBookIDs() }` /
`library.ao3WordCounts(ids:)` / `capturedLibrary2?.ao3PublisherBookIDs()` wrappers in
`LibraryRootView.swift` the same way — replace with plain `await library.xxx()` calls.

**1.5 — Fix `LocalFeedServer.swift`.**
Both `library.allBookIDs()` (line 345) and `library.books(ids:...)` (line 444) need
`await` now that `CalibreLibrary` is an actor. `LocalFeedServer` is already `actor`, so
this is a straightforward `await` insertion — confirm the calling route handlers are
already `async` (they call into `AmbrosiaMetaDB`, also an actor, so they should be) and
propagate `await` if not.

**1.6 — Apply the `async let` / `Task.detached` interaction rule while doing all of
this.** Combining `async let` with a `Task.detached { }.value` initializer that captures
a non-`Sendable` reference type fails Swift 6 strict-concurrency checking even where the
identical `Task.detached(...).value` pattern compiles fine as a plain assignment
elsewhere. Since `CalibreLibrary` becomes `Sendable` automatically once it's an actor,
this changes which combinations compile — re-check any `async let` you touch in this
phase rather than assuming a pattern that worked before the conversion still does.

**1.7 — Group D (hardest, do last): SwiftUI views with no natural async context.**
`LibraryUI/FilterDrawer/FilterValueTextField.swift` (live-typing autocomplete calling
`tagSuggestions`/`authorSuggestions`/etc.) and `LibraryUI/SearchSuggestionsView.swift`
call `library.*` directly from body-adjacent methods (an `onChange`/keystroke handler),
not already wrapped in a `Task`. You cannot make `View.body` itself `async`. Instead use
a `.task(id: searchText) { suggestions = await library.tagSuggestions(prefix: searchText) }`
pattern storing results in `@State`. Check `Utilities/DebounceTimer.swift` and its
existing usage (`ReaderViewController.swift`, `LibraryWindowController.swift`,
`EmailLibraryViewController.swift`, `LibraryRootView.swift` — confirmed delays: 0.3s,
0.2s, 0.4s, 0.4s respectively) before introducing a second, different debounce
mechanism — if a `.task(id:)`'s built-in auto-cancel-on-id-change makes a
`DebounceTimer` instance redundant at one of these specific call sites, you may remove
it there, but do not delete `DebounceTimer` itself — it's used at the four sites above
and is not otherwise dead code.

### Verify
- Concurrent-access stress test: two `Task`s hammering `bookCount()` and
  `calibreIDs(matchingRules:)` on the same instance in a loop under Thread Sanitizer —
  no crash.
- Enable strict concurrency checking for the target if not already on
  (`SWIFT_STRICT_CONCURRENCY = complete` or `-strict-concurrency=complete` in Other
  Swift Flags) and confirm a clean build under it.
- Manual: apply a filter-drawer rule (e.g. `tag:`) while simultaneously triggering
  `rebuildItems()` (scroll to trigger series-grouping's async fetch); type a plain-text
  search query while background AO3 tag-seed import is still running (the original
  crash log showed a search overlapping `"AO3 tag seeds ready: ..."` completing);
  repeat 20+ times. Pre-fix this was intermittently crash-prone; post-fix it should not
  crash across all repetitions.
- `grep -rn "assertMainThread" Ambrosia/` returns zero results.
- `grep -rn "MainActor.run" Ambrosia/ --include=*.swift`, manually confirm every
  remaining hit is a genuine UI-state requirement (`@Published`/`@Observable` mutation),
  not a leftover `CalibreLibrary`-access hop that's now redundant.

### Rollback plan
This is mechanical but wide-reaching. Land it as its own PR with nothing else in the
diff so it can be reverted in one step if it destabilizes something unrelated.

---

## Phase 2 — Fix the AND-logic filter bug for `authorName`/`series`

### Why this is next
This produces **silently wrong query results**, not crashes — arguably worse, since
nothing signals to the user that their filter is broken. It's localized to SQL-fragment
construction in one file. Do it after Phase 1 so you're editing an already-actor-safe
file rather than adding sync/async churn on top of a correctness fix.

### The defect, precisely (confirmed this pass)
`LibraryUI/FilterDrawer/FilterBuilder.swift`, `sqlFragment(for rule:)` (~line 612-670)
builds SQL differently depending on field:

- `.tag`, `.rating`, `.warning`, `.category` → routed through `expandedTagFragment` /
  `ao3TagFragment`, which emit correlated `EXISTS`/`NOT EXISTS` subqueries against
  `books_tags_link`/`tags`. Each rule independently asks "does this book have *a* tag
  matching X" — ANDing several such rules is a true logical AND.
- `.authorName` (line 629-630) and `.series` (line 621-622) → routed through
  `textFragment`, which emits a plain column comparison (`a.name LIKE ?`, `s.name LIKE
  ?`) against a **single-alias** `LEFT JOIN` set up in `calibreIDs(matchingRules:
  conjunction:...)` (~lines 465-481, confirmed):
  ```swift
  let needsAuthorJoin  = rules.contains { $0.field == .authorName }
  ...
  if needsAuthorJoin {
      joins.append("LEFT JOIN books_authors_link bal ON bal.book = b.id")
      joins.append("LEFT JOIN authors a ON a.id = bal.author")
  }
  ```
  There is exactly one join alias (`a`) per query, and a book can have multiple
  authors. Each joined row carries only one author name. Two ANDed rules like
  `authorName CONTAINS "Smith"` AND `authorName CONTAINS "Jones"` are evaluated against
  the *same row*, which cannot simultaneously satisfy both — even for a book that
  genuinely has both authors, just on different rows. The `WHERE` clause becomes
  unsatisfiable for exactly the multi-value case it should support. `.series` has the
  identical shape and risk, just lower real-world frequency. `.comment` is genuinely
  single-valued per book (Calibre has one description per book) — leave it on
  `textFragment`, it is not affected by this bug.

**Confirmed this is not how the free-text search path works** — `Database/CalibreLibrarySearch.swift`,
`whereClause(for query:)` (~lines 12-86) already uses correlated `EXISTS` for
tag/author/series matching, correctly. This fix brings `FilterBuilder` in line with a
pattern that already exists correctly elsewhere in the same codebase, not a novel
approach.

### The fix

**2.1 — Add `authorFragment`, parallel to the existing `tagMembershipFragment`-style
helpers (~near line 735-749 as of this writing):**
```swift
private func authorFragment(op: FilterOperator, value: String) -> (String, [Binding?])? {
    let matcher: String
    let args: [Binding?]
    let negated: Bool
    switch op {
    case .contains:
        matcher = "LOWER(a2.name) LIKE ?"; args = ["%\(value.lowercased())%"]; negated = false
    case .notContains:
        matcher = "LOWER(a2.name) LIKE ?"; args = ["%\(value.lowercased())%"]; negated = true
    case .equals:
        matcher = "LOWER(a2.name) = ?"; args = [value.lowercased()]; negated = false
    case .notEquals:
        matcher = "LOWER(a2.name) = ?"; args = [value.lowercased()]; negated = true
    case .startsWith:
        matcher = "LOWER(a2.name) LIKE ?"; args = ["\(value.lowercased())%"]; negated = false
    default:
        return nil // ratingAtMost/ratingAtLeast are not valid operators for authorName;
                    // confirm this against FilterRule.availableOperators before assuming
    }
    let sub = """
        SELECT 1 FROM books_authors_link bal2
        JOIN authors a2 ON a2.id = bal2.author
        WHERE bal2.book = b.id AND \(matcher)
        """
    return (negated ? "NOT EXISTS (\(sub))" : "EXISTS (\(sub))", args)
}
```
Verify `FilterOperator`'s actual case list against `LibraryUI/FilterDrawer/FilterRule.swift`
before writing the `switch` — do not assume the cases above are exhaustive without
checking.

**2.2 — Route `.authorName` through it:**
```swift
case .authorName:
    return authorFragment(op: rule.op, value: v)
```
replacing the current `return textFragment(column: "a.name", op: rule.op, value: v)`.

**2.3 — Do the same for `.series`:** add `seriesFragment` following the identical
pattern against `books_series_link`/`series` (alias `s2`), and route `.series` through
it instead of `textFragment(column: "s.name", ...)`.

**2.4 — Clean up now-dead join machinery, carefully.** After 2.2/2.3 land, check
whether `needsAuthorJoin`/`needsSeriesJoin` and their `LEFT JOIN` lines in
`calibreIDs(matchingRules:conjunction:...)` are still referenced anywhere (grep for
`a.` / `s.` column references in the rest of the file first — do not delete blindly).
`needsCommentJoin`/`c` alias stays; `.comment` is intentionally unaffected by this fix.

### Verify
- Unit test against a fixture library with one book that has two authors (e.g. "Alice
  Smith" and "Bob Jones" as separate `authors` rows joined via `books_authors_link`).
  Build a `FilterExpression` with two ANDed `.authorName .contains` rules ("Smith",
  "Jones"). Before the fix: 0 results. After: 1 result (the book).
- Regression test: single-author-rule filters and OR-conjunction author filters must
  return identical results before and after this change.
- Manual: apply a two-author AND filter in the running app against a real multi-author
  book in a test library; confirm it now appears.

---

## Phase 3 — Batch tag-synonym resolution

### The defect, precisely (confirmed this pass)
`AmbrosiaMetaDB.swift` has `canonicalTerm(for:)` and `expandedTerms(for:)` — both
single-tag, actor-isolated methods. No `canonicalBatch(for:)` or equivalent exists
anywhere in the file (confirmed by grep). Two call sites resolve multiple tags in a
loop, each iteration a separate actor round-trip:
```swift
for value in tagValues {
    filterTagExpansions[value] = await metaDB.expandedTerms(for: value)
}
```
Confirmed duplicated verbatim at:
- `LibraryUI/LibraryRootView.swift` (~line 1171-1173)
- `LibraryUI/Email/EmailLibraryViewController.swift` (~line 677-679)

Since `AmbrosiaMetaDB` is an actor, each loop iteration serializes — a filter with N
distinct tag rules pays N sequential actor round-trips instead of one batched query.
This is a latency issue, not a correctness bug — lower urgency than Phases 1-2, but
cheap to fix and the fix was explicitly designed for in a prior planning pass without
ever being built.

### The fix

**3.1 — Add the batched method to `Database/AmbrosiaMetaDB.swift`.** The existing call
sites use `expandedTerms(for:)` (plural synonym expansions per tag), not
`canonicalTerm(for:)` (single canonical form) — build the batched version of the one
actually used:
```swift
func expandedTermsBatch(for tags: [String]) -> [String: [String]] {
    guard !tags.isEmpty else { return [:] }
    // Model the SQL on whatever expandedTerms(for:) already does per-tag, batched into
    // one query against tag_synonyms/canonical_tags using WHERE synonym IN (...).
    // Read expandedTerms(for:)'s current implementation in full before writing this —
    // do not guess the join shape or NOCASE handling.
}
```
Check realistic tag-filter sizes before assuming a single `IN (...)` clause is
sufficient (it almost certainly is — filter rules are user-typed, not bulk-imported).

**3.2 — Replace both duplicated loops** with a single batched call:
```swift
filterTagExpansions = await metaDB.expandedTermsBatch(for: Array(tagValues))
```
at both `LibraryRootView.swift` and `EmailLibraryViewController.swift`. Consider
extracting this into one shared helper function used by both call sites instead of
duplicating the batched call too — that's the same duplication pattern Phase 2 (and
Rule 16 generally) exists to prevent; don't reintroduce a smaller instance of it while
fixing this one.

### Verify
- Unit test: seed a fixture `ambrosia_meta.db` with synonym rows for 3+ tags, call
  `expandedTermsBatch` with all 3 in one call, confirm the result matches what three
  individual `expandedTerms(for:)` calls would produce.
- Instrument (temporarily) a call counter on the actor method; confirm applying a
  filter with 3 distinct tag rules results in exactly 1 call to the batched method.

---

## Phase 4 — Fix the duplicated force-unwrap in `EmailSidebarViewController`

### The defect, precisely (confirmed this pass)
`Database/Models/CalibreBook.swift` has the *correct*, fixed pattern:
```swift
// line ~185
precondition(!works.isEmpty, "SeriesGroup must be constructed with at least one work")
// line ~290-295, ReadingTarget.primaryBook
var primaryBook: CalibreBook {
    switch self {
    case .series(let series):
        precondition(!series.works.isEmpty, "SeriesGroup invariant violated: works must be non-empty")
        return series.works[0]
    ...
    }
}
```
But `LibraryUI/Email/EmailSidebarViewController.swift` (line ~403-405) reintroduces the
exact crash it fixes:
```swift
private extension SeriesGroup {
    var primaryBook: CalibreBook { works.first! }
}
```
This bare force-unwrap is used live at lines ~140-143, 202, 334, 341, 358, and 551 — cell
configuration, selection restoration, and context-menu construction all route through
it. The same file *already has* a safe `readingTarget` computed property (line ~395-400)
sitting a few lines above this duplicate, which it doesn't use.

Because `SeriesGroup.init` itself carries the `precondition(!works.isEmpty, ...)` guard
(confirmed), this specific force-unwrap is unlikely to be reachable through normal
construction today — but it is a live landmine (any future relaxation of that
precondition, or any other construction path that bypasses `init`, crashes here
immediately), and it is the single clearest instance of Key Invariant 16 being violated
in spirit (a private file-scoped duplicate coexisting with a safe canonical version it
doesn't call).

### The fix

**4.1 — Delete the duplicate entirely:**
```swift
private extension SeriesGroup {
    var primaryBook: CalibreBook { works.first! }
}
```
Remove this block from `EmailSidebarViewController.swift`.

**4.2 — Change `LibraryItem.primaryBook` (same file, ~line 380-386) to delegate to the
already-safe path instead of `series.primaryBook`:**
```swift
private extension LibraryItem {
    var primaryBook: CalibreBook { readingTarget.primaryBook }

    var contextBooks: [CalibreBook] {
        switch self {
        case .book(let book): return [book]
        case .series(let series): return series.works
        }
    }

    var readingTarget: ReadingTarget {
        switch self {
        case .book(let book): return .singleBook(book)
        case .series(let series): return .series(series)
        }
    }
}
```
`readingTarget` is already defined in the same extension block and already produces a
`ReadingTarget`, whose `.primaryBook` already has the `precondition` guard from
`Database/Models/CalibreBook.swift`. This is a one-line delegation change, not a new
implementation.

**4.3 — Project-wide sweep, not just this file.** Run:
```
grep -rn "\.first!" Ambrosia --include=*.swift
grep -rn "works\.first!" Ambrosia --include=*.swift
```
This bug's shape — a private extension on a shared enum, redefining a property that
already exists safely elsewhere — is a pattern that could recur anywhere a feature was
built against a copy of the model types instead of the canonical models. Check the
`Reader/` and `Preferences/` directories specifically, as the next most likely places
given how the codebase has grown by feature-area file, not just the `Email` files
already confirmed. If the grep finds more instances, fix each the same way — delete the
duplicate, delegate to the canonical safe implementation. Do not write a new
`precondition`-guarded copy per file; that reintroduces the exact "second copy to keep
in sync" problem this phase is fixing, just with a safer crash message instead of no
message.

### Verify
- Unit test: construct a `LibraryItem.series` case wrapping a `SeriesGroup` with a
  single work, confirm `.primaryBook` returns it (tests the delegation wiring, not the
  empty-case guard — that's `SeriesGroup.init`'s job and is already covered).
- `grep -rn "works.first!" Ambrosia --include=*.swift` returns zero results project-wide.
  Paste this into the PR description as confirmation.

---

## Phase 5 — Search-string double-prefix silent-swallow (lower priority, UX correctness)

### The defect, precisely (confirmed this pass)
`Database/SearchQueryParser.swift`. The doc comment above `SearchQuery` (line 16) states
the design assumption directly: *"Only ONE prefix token is expected per search
string."* `parse(_:)` (line 145) stops at the first matching prefix and treats
everything after the colon — including any second `prefix:` the user typed — as one
literal value string, with no validation or UI feedback.

### The fix
**Recommendation: implement Option A only.** Detect a second embedded prefix inside the
parsed value and surface a warning rather than silently discarding it.

In `parse(_:)`, after computing `value`, check whether it starts with (or contains,
after a space) another known prefix (`tag:`, `author:`, `title:`, `series:`, `status:`,
`fulltext:` — confirm the full current prefix list against the parser's own switch/dict
before hardcoding this list, it may have grown since this was written). If so, add a
`hasTrailingPrefixWarning: Bool` field to `SearchQuery` that
`SearchSuggestionsView.swift` / `LibraryToolbarState.swift` can use to show a small
inline hint ("Only one search filter at a time"). Do not silently discard the trailing
text — that is worse UX than telling the user.

Do not implement multi-token support (parsing `tag:horror author:smith` into multiple
`FilterRule`s) as part of this phase — that is a larger, separate scope change to
`asSingleFilterRule()` and every consumer of it. Leave a `// TODO` comment pointing at
this document if a future phase wants to revisit it, but do not start it here.

### Verify
- Unit test: `SearchQueryParser.parse("tag:horror author:smith")` → confirm parsing
  behavior is unchanged (still one `tagTerms` entry containing the literal trailing
  text) but the new warning flag is `true`.
- Unit test: `SearchQueryParser.parse("tag:horror")` → warning flag `false`.

---

## Phase 6 — Query efficiency and error handling (lower priority, do after correctness fixes)

Do this after Phases 1-5 so you're optimizing already-correct queries.

### 6.1 — Uncapped fuzzy-title trigram generation
**Confirmed:** `Database/CalibreLibrary.swift`, `fuzzyTitleCondition(for:)` (line 891)
and `trigrams(for:)` (line 921). Every word ≥5 characters generates
`(length - 2)` trigram OR-clauses with **no cap**, repeated per word in a multi-word
query. Clause count grows roughly linearly with total query length; each clause is an
unindexable `LIKE '%...%'` scan.

**Fix:** cap the number of trigram clauses generated per word:
```swift
let allTrigrams = Self.trigrams(for: word)
let trigrams = allTrigrams.count > 6
    ? Array(stride(from: 0, to: allTrigrams.count, by: max(1, allTrigrams.count / 6))).map { allTrigrams[$0] }
    : allTrigrams
```
Pick N empirically (start at 5-6), confirm it doesn't visibly degrade fuzzy-match
quality against a real test library, and comment why the cap exists. Consider also
short-circuiting fuzzy matching entirely above ~5 words (long queries are closer to
exact-phrase searches and gain little from trigram fuzziness) — fall back to a plain
multi-word `AND`-of-`LIKE` without trigram expansion above that threshold.

### 6.2 — Silent error swallowing
**Confirmed pattern**, present pervasively, e.g.
`Database/CalibreLibrarySearch.swift`, `bookCount(query:)` (line ~89-94):
```swift
func bookCount(query: SearchQuery) -> Int {
    do {
        return try _bookCount(query: query)
    } catch {
        print("[CalibreLibrary] bookCount(query:) error: \(error)")
        return 0
    }
}
```
A real query error is indistinguishable from "zero matches" to the user. `LibrarySession`
already has a `lastError: String?` property (confirmed, line 57) used for open failures
— reuse this mechanism rather than adding a new one.

**Minimum viable fix (do this, not a full refactor, unless separately scoped):** keep
`try?`/return-0 behavior for now, but make the failure observable — increment a
counter/flag surfaced through the existing `LibraryFilterDebug` mechanism (or
`lastError`) instead of only `print`-ing, so a real error is distinguishable from "no
matches" during development and in the field. Treat full error-propagation (making
these functions `throws` and updating every UI call site to handle it) as a larger,
separately-scoped follow-up — say so explicitly in the PR description if you stop at
the minimum viable version.

### Verify
- Benchmark test (`measure { }`) running a representative multi-word fuzzy search
  against a fixture library of ~2,000 books, before and after the trigram cap — confirm
  a measurable improvement with no crash and no obviously-worse match quality on a
  handful of manually checked typo/partial-title cases.

---

## Sequencing summary

| Phase | What | Depends on | Risk if skipped |
|---|---|---|---|
| 0 | Build gate | — | Every later phase repeats the exact class of mechanical error this codebase has already shipped once |
| 1 | `CalibreLibrary`/`CalibreFTSLibrary` actor conversion | Phase 0 | Live, intermittent `SQLITE_BUSY` crash risk — highest severity item in this plan |
| 2 | AND-logic authorName/series filter fix | Phase 1 (edit an already-actor-safe file) | Silently wrong filter results for any multi-author AND query — currently live and undetectable to the user |
| 3 | Batched tag-synonym resolution | Phase 1 (touches the same actor) | Latency only, no correctness/crash risk |
| 4 | Force-unwrap duplicate fix | Phase 0 | Live crash risk if `SeriesGroup`'s `init` precondition is ever relaxed or bypassed; also the clearest live example of Rule-16-style code drift |
| 5 | Search double-prefix warning | none | UX-only; no correctness or crash risk |
| 6 | Trigram cap + error surfacing | Phases 1-2 (optimize correct queries, not queries about to change) | Performance/observability only |

Recommended order for one engineer working sequentially: **0 → 1 → 2 → 4 → 3 → 5 → 6.**
(4 is pulled ahead of 3 relative to a pure dependency reading because it's a
higher-severity, lower-effort fix — do the cheap high-value fix before the
lower-urgency latency optimization.) Phases 5 and 6 can run in parallel with anything
after Phase 1 lands, since they share no files with 2-4.

## Definition of done

- `xcodebuild build` is green on every phase's final commit, under
  `SWIFT_STRICT_CONCURRENCY = complete`.
- `grep -rn "assertMainThread"` and `grep -rn "works.first!"` both return zero results
  project-wide.
- A fixture-library-backed multi-author AND filter test passes.
- `expandedTermsBatch(for:)` exists and both former per-tag loops call it.
- No `Task.detached`/unstructured `Task { }` anywhere calls a `CalibreLibrary` or
  `CalibreFTSLibrary` method without going through actor isolation.

---

## Discarded claims (verified false or already fixed — do not re-derive or act on these)

These appeared in prior planning documents and were checked directly against the
current source in this pass. Listed here explicitly so a future session doesn't
re-investigate settled questions:

- **"`CalibreLibrary` opens its own connection to `ambrosia_meta.db`"** — false.
  Already fixed; `ao3WordCounts`/`ao3Dates`/`crossoverBookIDs` all read from in-memory
  caches populated by `AmbrosiaMetaDB`. No independent connection exists.
- **"`AO3TagSearchResolver` opens a rogue connection per keystroke"** — false. That type
  and file no longer exist in the codebase at all.
- **"`FilterValueTextField.swift`'s seven `[FilterSuggestions]` prints are unconditional
  in production"** — false. All seven are already wrapped in `#if DEBUG`.
- **"A `print(\"[PaginationKey] keyDown ...\")` fires on every keypress in the reader,
  unguarded"** — false. No such print statement exists anywhere in the reader's key
  handler or anywhere else in the project. This claim did not correspond to any code
  found by direct search and should be treated as fabricated.
- **`[StarDiag]`/`[FlashDiag]` prints in the old `BookGridItem.swift`** — correctly
  reported as already removed in the most recent prior doc; confirmed still true.
