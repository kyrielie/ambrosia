# Ambrosia Developer Guide

A ground-up explanation of the codebase for someone who can write Swift but hasn't
worked in a native macOS app before. Every code example below is copied from the
actual repository, not invented, so you can find it and read it in context.

Companion documents:
- `ambrosia_architecture.md` — the terse, current-state technical reference. Read
  it after this guide; it will make a lot more sense once you've seen the "why."
- `ambrosia_cleanup_plan.md` — an audit of what's left to fix, written after this
  guide, using the vocabulary this guide introduces.

---

## 1. What Ambrosia Is

Ambrosia is a macOS desktop app (not iOS, not a web app) that reads EPUB e-books.
It is purpose-built for people who read fan fiction downloaded from Archive of Our
Own (AO3) and organized with Calibre, the open-source e-book manager.

Two existing pieces of software it depends on, but never modifies:

- **Calibre** owns your book library: the files on disk, and a SQLite database
  called `metadata.db` that records titles, authors, tags, series, etc. Ambrosia
  opens this database **read-only** and never writes to it. If Calibre is the
  landlord, Ambrosia is a tenant who is not allowed to touch the plumbing.
- **AO3** is the fan fiction site whose EPUB exports have a predictable structure
  (a "preface" page with fandom/rating/word-count metadata) that Ambrosia knows
  how to parse.

Everything Ambrosia itself needs to remember — reading progress, highlights,
collections like "Liked" or "Read Later", extracted AO3 metadata — is stored in
its own separate SQLite file per library, plus a small SwiftData store for
reading-position bookkeeping. None of that lives inside Calibre's database.

---

## 2. The Big Picture

```
AmbrosiaApp (SwiftUI @main)
└── AppDelegate (AppKit)
    └── LibraryWindowController
        └── LibraryViewController
            ├── LibraryRootView              (SwiftUI — "List" mode)
            ├── EmailLibraryViewController    (AppKit — "Email" mode)
            └── (Ranking mode — placeholder, not built yet)

ReaderWindowController (one per open book, opened on demand)
└── ReaderViewController → WKWebView
```

Two things jump out immediately if you're used to typical SwiftUI-only apps:

1. **AppKit is in charge, not SwiftUI.** `AppDelegate`, `NSWindowController`, and
   `NSViewController` own the app's structure. SwiftUI views are embedded *inside*
   that AppKit structure via `NSHostingView`/`NSHostingController`, not the other
   way around. This is a deliberate, older-style pattern, common in apps that
   started before SwiftUI could do everything a Mac app needs (custom toolbars,
   fine window-sizing control, etc.).
2. **There are two parallel library UIs.** "List" mode is pure SwiftUI
   (`LibraryRootView`). "Email" mode is a classic AppKit split view with a table
   sidebar (`EmailLibraryViewController`). Both show the same books, filtered and
   sorted the same way — they are just different visual presentations. This
   matters a lot for Section 8 and for the cleanup plan, because both files
   independently implement the same search/filter/paging logic.

---

## 3. Swift Language Concepts You'll See Everywhere

This section explains *why* the code is shaped the way it is, using real examples.
Skip anything you already know.

### 3.1 `struct` vs `class` vs `actor` — picking the right tool

Swift gives you three ways to define a custom type, and Ambrosia uses all three
deliberately, not interchangeably:

| Kind | Copied or shared? | Used in Ambrosia for | Example |
|---|---|---|---|
| `struct` | **Copied** on assignment (value type) | Plain data — a book, a series, a search query | `CalibreBook`, `SeriesGroup`, `Annotation` |
| `class` | **Shared** via reference (multiple variables can point at the same instance) | Long-lived objects with identity and lifecycle — windows, view controllers | `ReaderViewController`, `ReaderWindowController` |
| `actor` | Shared, but access is **serialized** (only one task touches it at a time) | Anything that owns a database connection and must never run two queries concurrently in a way that corrupts state | `CalibreLibrary`, `AmbrosiaMetaDB` |

Look at `CalibreBook` — it's declared `struct`, because a book is just data. If you
copy a `CalibreBook` into a new variable and change a field, the original is
untouched. That's exactly what you want for something you pass around and display;
there's no dangerous shared mutable state to worry about.

Compare that to `CalibreLibrary`:

```swift
actor CalibreLibrary {
    let root: URL
    internal let db: Connection
    ...
}
```

This is an `actor`, not a `class`. An `actor` looks like a class (reference type,
has identity) but the compiler enforces that only one piece of code can be
"inside" it at a time — every method call from outside has to `await`. Why does
that matter here? Because `db` is a SQLite connection. If two parts of the app
tried to run queries against the same `Connection` at literally the same instant
from two threads, you'd get corrupted reads or crashes. Making `CalibreLibrary` an
actor means the Swift compiler — not careful programming discipline — guarantees
that can't happen. This is called **data-race safety**, and it's one of Swift's
newer, most important features (Swift Concurrency).

`AmbrosiaMetaDB` (the app's own writable database) is an actor for the same
reason, and the architecture doc's Invariant 10 exists specifically because,
historically, a second piece of code opened its *own* separate `Connection` to
that same file, sidestepping the actor's protection. That's the kind of bug
actors are designed to prevent, and it happened anyway because someone bypassed
the actor boundary rather than going through it. (This has since been fixed —
see the cleanup plan for the historical note.)

### 3.2 `async`/`await` — reading concurrent code

Any time you see `await`, it means "this call might suspend here and let other
work happen, then come back." You'll see it constantly when calling into
`CalibreLibrary` or `AmbrosiaMetaDB`, because every actor method call from outside
the actor is implicitly asynchronous:

```swift
Task { await session.open(url: url) }
```

`Task { ... }` starts a new unit of asynchronous work. Inside a SwiftUI `Button`
action or an AppKit `@objc` method — neither of which can be `async` themselves —
wrapping the async call in `Task { }` is the standard bridge.

### 3.3 `@MainActor` — the UI thread, made explicit

AppKit and SwiftUI must only be touched from the main thread. Rather than trusting
every developer to remember that, Swift lets you annotate a type or function with
`@MainActor`:

```swift
@Observable
@MainActor
final class LibrarySession {
```

This means: every property and method on `LibrarySession` can only be
accessed while already running on the main thread. If some background code tried
to touch it directly, the compiler would refuse to build until you added an
`await` and hopped over to the main actor. It's the same idea as the `actor`
keyword in Section 3.1, but pinned specifically to "the UI thread" rather than
"its own private serial queue."

### 3.4 `@Observable` vs `ObservableObject` — two ways to make SwiftUI watch a class

You'll see both patterns in this codebase, and it's worth knowing why:

```swift
@Observable
@MainActor
final class LibrarySession { ... }
```

```swift
final class ReaderPreferences: ObservableObject {
    @Published var fontSize: CGFloat = 18
    ...
}
```

`@Observable` (from the newer `Observation` framework, macOS 14+) is simpler:
SwiftUI automatically figures out which properties a view actually reads and only
re-renders when *those* change. `ObservableObject` with `@Published` is the older
Combine-based mechanism: any `@Published` change fires `objectWillChange`, and any
view observing the object re-renders, whether it used that particular property or
not.

Why does `ReaderPreferences` still use the older style? Because it's also
consumed from AppKit code via Combine directly:

```swift
prefsCancellable = ReaderPreferences.shared.objectWillChange
    .sink { [weak self] _ in ... }
```

`@Observable` types don't expose an easy Combine publisher the same way, so a
singleton that needs to be watched from both SwiftUI *and* plain AppKit code
(the reader's `WKWebView` controller isn't a SwiftUI view) keeps the
`ObservableObject`/Combine style. `LibrarySession`, by contrast, is only ever
read from SwiftUI, so it gets the newer, cheaper `@Observable`.

**Takeaway:** picking one or the other isn't arbitrary — it follows from *who
needs to observe the object* and *from which framework*.

### 3.5 SwiftData: `@Model`, containers, and contexts

SwiftData is Apple's persistence framework (the modern replacement for Core Data)
built on top of SQLite. Ambrosia uses it for exactly two things:

```swift
@Model
final class BookState {
    var calibreID: Int
    var lastOpenedDate: Date = Date(timeIntervalSince1970: 0)
    var totalReadPercent: Double = 0
    ...
    init(calibreID: Int) { self.calibreID = calibreID }
}
```

- `@Model` turns a plain class into a persisted, database-backed object. Every
  stored property becomes a column.
- A `ModelContainer` is the database file itself, opened once at launch:

  ```swift
  let schema = Schema([BookState.self, ReadingGoal.self])
  let config = ModelConfiguration("Ambrosia", schema: schema, isStoredInMemoryOnly: false)
  let container = try ModelContainer(for: schema, configurations: [config])
  ```

- A `ModelContext` is a working area you fetch, insert, and save through. Contexts
  are cheap to create, but **objects fetched from one context are not the same
  object as the "same" row fetched from a different context** — they're separate
  in-memory representations of the same underlying row. This is exactly why
  SwiftData disallows taking an object's identity (`persistentModelID`) from one
  context and asking a *different* context to resolve it via `model(for:)` — the
  two contexts don't share object identity, only the underlying store. Ambrosia's
  own code respects this: every place that needs a `BookState` inside a given
  context re-fetches it by `calibreID` in *that* context rather than reusing an
  instance obtained elsewhere:

  ```swift
  private func stateForMutation(_ calibreID: Int, in ctx: ModelContext) -> BookState {
      var desc = FetchDescriptor<BookState>(predicate: #Predicate { $0.calibreID == calibreID })
      desc.fetchLimit = 1
      let state = (try? ctx.fetch(desc).first) ?? BookState(calibreID: calibreID)
      if state.modelContext == nil { ctx.insert(state) }
      return state
  }
  ```

  Notice this function never calls `.reset()` on the context either — it simply
  fetches fresh from whichever `ctx` it was given. That's the safe pattern.

**A hard rule worth internalizing:** don't put a Swift `Array` or `Dictionary`
directly on an `@Model` class as a *stored* property. SwiftData has to translate
every property into a SQLite column, and collections don't map cleanly — you'd
either lose type safety or silently get something you didn't expect (and
historically, arrays-on-`@Model` have been a common source of subtle SwiftData
bugs and migration pain). If you need a list of values on a model, store it as a
JSON-encoded `Data`/`String` column and decode it in a computed property instead.
This is why `BookState` and `ReadingGoal` only ever contain scalars (`Int`,
`Double`, `Date`, `TimeInterval`) — there isn't a single array or dictionary on
either one. This is a deliberate rule (see Invariant 4 in the architecture doc),
not an accident.

Note this restriction is specifically about **persisted `@Model` classes**. Plain
in-memory structs like `SeriesGroup` (which is never saved to disk — it's
assembled on the fly from Calibre query results) are free to hold arrays:

```swift
struct SeriesGroup: Identifiable, Hashable {
    let works: [CalibreBook]
    let allFandoms: [String]
    ...
}
```

That's fine, because `SeriesGroup` is never handed to SwiftData.

**The SwiftData schema in this app is intentionally tiny** — just `BookState`
and `ReadingGoal`. Everything else (collections, annotations, AO3 metadata,
series cache) lives in the app's own hand-written SQLite database
(`AmbrosiaMetaDB`, see Section 8.3), specifically so it can use plain SQL tables,
JOINs, and full manual control over migrations, rather than fighting SwiftData's
schema-migration model for things that don't fit its "small object graph" sweet
spot.

### 3.6 SQLite.swift and the `Binding?` convention

Calibre's database and Ambrosia's own database are both accessed through the
`SQLite.swift` package, a thin, type-safe wrapper over raw SQLite. You'll see
code like this constantly:

```swift
let sql = "SELECT path FROM books WHERE id = ? LIMIT 1"
guard let rows = try? db.prepare(sql, [calibreID as Binding?]).map({ $0 }),
      let row = rows.first,
      let relativePath = row[0] as? String else { return nil }
```

`Binding?` is SQLite.swift's protocol for "a value that can be bound into a `?`
placeholder in a SQL statement" (integers, strings, doubles, `nil`, etc). Every
argument array passed to `db.prepare(sql, args)` has to be typed `[Binding?]`,
which is why you'll see `as Binding?` casts sprinkled through the query-building
code — it's satisfying the compiler, not doing anything at runtime. This is
called out explicitly as Invariant 3 in the architecture doc because it's easy to
forget and the compiler error you get when you do is not always obvious about
what's wrong.

Always using `?` placeholders (rather than string-interpolating a value directly
into the SQL) is what prevents SQL injection — the same reason you parameterize
queries in any language. The one place raw string interpolation *is* used for a
table/column name (e.g. `"SELECT value FROM \(tableName) WHERE book = ?"` in
`CalibreLibrary.customColumnInt`) is safe specifically because `tableName` always
comes from Ambrosia's own internally generated `"custom_column_\(id)"` string,
never from free-form user input.

### 3.7 Protocols and the delegate pattern

Cocoa (AppKit's underlying framework) is built heavily around **protocols** and
**delegation**: instead of subclassing a big base class and overriding methods,
you adopt a protocol and the framework calls your methods when something happens.
`ReaderViewController` adopts three protocols:

```swift
class ReaderViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {
```

- `WKNavigationDelegate` — WebKit calls methods on this when a page starts/finishes
  loading, so `ReaderViewController` can react (e.g. run JS to restore scroll
  position once the EPUB HTML has loaded).
- `WKScriptMessageHandler` — has exactly one required method,
  `userContentController(_:didReceive:)`. It's how JavaScript running *inside*
  the `WKWebView` sends structured messages *out* to Swift code. This is the
  bridge that lets the JS pagination engine tell Swift "the user scrolled to
  character offset 4213" or "the user tapped an existing highlight."

Registering as a message handler looks like this:

```swift
config.userContentController.add(self, name: "positionUpdate")
config.userContentController.add(self, name: "pageAction")
config.userContentController.add(self, name: "highlightAdded")
config.userContentController.add(self, name: "highlightTapped")
config.userContentController.add(self, name: "consoleLog")
```

**This is also the site of a real bug — see the cleanup plan, Finding 1.**
`add(_:name:)` keeps a *strong* reference to whatever handler you pass it. Passing
`self` here means the web view's own configuration object ends up holding a
strong reference back to the view controller that owns that web view — a
reference cycle. The fix (a small "weak proxy" object, or explicitly calling
`removeScriptMessageHandler(forName:)` when the window closes) is a very common
pattern in WKWebView-based Mac and iOS apps; it's worth understanding even
outside this codebase, because it's one of the most frequently-hit memory leaks
in WebKit-based apps in general.

### 3.8 Closures, `[weak self]`, and why it matters

A **closure** is Swift's anonymous function value — the `{ ... }` blocks passed
to `Task`, `.sink`, `Timer.scheduledTimer`, button actions, etc. Closures capture
(hold onto) any variable they reference from the surrounding scope. If a closure
captures `self` and is itself stored *by* `self` (directly, or transitively
through some object `self` owns), you get a **retain cycle**: `self` keeps the
closure alive, the closure keeps `self` alive, neither is ever freed.

The fix is to capture `self` weakly:

```swift
saveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
    guard let self else { return }
    ...
}
```

`[weak self]` means "hold a weak reference — if `self` has already been
deallocated by the time this closure runs, `self` inside the closure body is
`nil`, not a dangling pointer." The `guard let self else { return }` pattern
immediately after is idiomatic Swift: it unwraps the optional weak reference into
a strong local `self` for the rest of the closure body, and bails out cleanly if
the object is already gone.

Ambrosia gets this right in most places — the periodic auto-save timer above, the
Combine preferences sink in Section 3.4, and every `NotificationCenter`
block-based observer all correctly use `[weak self]` and remove themselves in
`deinit`. The `WKScriptMessageHandler` registration in Section 3.7 is the one
place this pattern wasn't applied (a plain protocol conformance can't take
`[weak self]` the way a closure can — the fix has to be structural, i.e. a weak
proxy object).

### 3.9 Access control: `private`, `internal`, `fileprivate`

Swift's access levels aren't just "public vs. not" — the default (no keyword,
called `internal`) means "visible anywhere in this module/target," while
`private` means "visible only in this **file**" (technically: this
declaration's lexical scope, which in practice means the file, unless you
nest declarations). This distinction bit this project once, badly enough that
it's now Invariant 16 in the architecture doc: when a big SwiftUI view file
(`LibraryRootView.swift`) was split into per-row files
(`BookListRow.swift`, `SeriesListRow.swift`, `FlowLayout.swift`), some shared
helper functions had been marked `private` in the original file. Once split
across multiple files, `private` helpers became invisible to the very files
that were split out to use them — a wall of "Cannot find X in scope" errors that
have nothing to do with logic bugs, only visibility.

The rule of thumb this project has settled on: **before marking a top-level type
or free function `private`, grep the rest of the target for other usages.** If
more than one file needs it, it's `internal` (i.e., no modifier at all) — not
`private`, and definitely not a second copy pasted into the new file (which
creates an "Invalid redeclaration" error the moment someone widens the original
back to `internal`).

### 3.10 Error handling: `throws`, `try?`, and custom error enums

Ambrosia mostly uses Swift's native `throws`/`try` mechanism rather than
`Result<Success, Failure>` or completion-handler-with-error-parameter styles.
Custom errors are plain enums conforming to `Error` (and often
`LocalizedError`, which adds a human-readable `errorDescription`):

```swift
enum EPUBError: Error, LocalizedError {
    case cannotOpenArchive
    case missingContainerXML
    case missingOPF(String)
    case emptySpine
    case missingSpineItem(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpenArchive:        return "Could not open EPUB archive."
        case .missingContainerXML:      return "Missing META-INF/container.xml."
        case .missingOPF(let p):        return "OPF not found at \(p)."
        case .emptySpine:               return "EPUB spine is empty."
        case .missingSpineItem(let h):  return "Spine item not found: \(h)."
        }
    }
}
```

Associated values (`case missingOPF(String)`) let an error case carry extra
context — here, *which* path was missing — without needing a separate struct.

You'll also see `try?` a lot, which converts a throwing call into an `Optional`
(nil on failure, discarding the actual error):

```swift
try? db.execute("PRAGMA cache_size = -32768")
```

This is a deliberate choice at call sites where failure is genuinely fine to
ignore (a performance PRAGMA that just won't take effect if it fails is harmless).
It becomes a problem when it's used to silently swallow errors that a user
actually needed to know about — see the cleanup plan's discussion of
unguarded `print()` calls, several of which exist specifically because a
`catch { print(...) }` block was the chosen way to surface a `try?`-adjacent
failure during development and was never revisited.

### 3.11 Extensions and `// MARK: -` organization

Swift lets you split a type's implementation across multiple `extension` blocks,
even across files. Ambrosia uses this constantly to keep single-responsibility
chunks of a large type physically separated and independently readable — e.g.
`CalibreLibrary`'s EPUB-path lookup, fuzzy search, and custom-column logic are
each in their own `extension CalibreLibrary { ... }` block near the bottom of the
file, well after the actor's core query methods. `// MARK: - Some Section` comments
are Xcode-specific: they show up as jump-to navigation markers in the source
editor's function list, which is why you'll see them liberally used as a kind of
in-file table of contents.

---

## 4. Project Layout Tour

```
Ambrosia/
├── App/                 Bootstrap: @main entry point, NSApplicationDelegate
├── Database/            Everything that talks to SQLite or SwiftData
│   └── Models/          Plain data types + the two SwiftData @Model classes
├── LibraryUI/            The two library browsing UIs (List + Email) and shared bits
│   ├── Email/           AppKit "Email mode" — split view, table sidebar
│   └── FilterDrawer/     The advanced filter-rule builder UI
├── Networking/          The optional local RSS feed server
├── Preferences/         The Preferences window (Reader/Library/Window/Data tabs)
├── Reader/              EPUB parsing, pagination, the WKWebView bridge, annotations
├── Resources/            CSS, Info.plist
└── Utilities/           Small, dependency-free helpers (debouncing, HTML stripping, CSV export)
```

Two folders deserve a specific mental model before you go further:

- **`Database/` is the only code allowed to know SQL.** Everything above it
  (views, view controllers) calls into `CalibreLibrary`, `AmbrosiaMetaDB`,
  `CollectionStore`, etc., and gets back Swift values (`CalibreBook`,
  `SeriesGroup`, dictionaries of IDs). No view file writes a SQL string.
- **`Reader/` is a mostly self-contained subsystem.** It has its own parser
  (`EPUBParser`), its own JS-generation code (`PaginationJS`), and its own
  bridge types (`HighlightBridge`). Aside from reading/writing `BookState` and
  talking to `AmbrosiaMetaDB` for annotations, it doesn't reach back into
  `LibraryUI/`.

---

## 5. Data Flow: Opening a Library

Walking one real user action through the whole stack is the fastest way to see
how the pieces fit:

1. User picks **File → Open Calibre Library…**. `AppDelegate.chooseLibraryFolder()`
   shows an `NSOpenPanel`, validates that the chosen folder contains a readable
   `metadata.db`, then calls `session.open(url:)`.
2. `LibrarySession.open(url:)` (an `@MainActor` method, so this all runs on the
   main thread, hopping to background actors as needed):
   - Creates a `CalibreLibrary(root: url)` — this actor's `init` opens the
     read-only SQLite connection.
   - Opens or creates the per-library `AmbrosiaMetaDB` (a writable, actor-isolated
     SQLite database under Application Support, keyed by a hash of the library
     path — see Section 8.3).
   - Optionally opens a `CalibreFTSLibrary` if Calibre's own
     `full-text-search.db` exists.
   - Registers the library path in `LibraryRegistry` (so it shows up in "Recent
     Libraries") and `LibraryIndexManager`.
   - Kicks off background AO3 metadata extraction (Section 8.4) and series-cache
     seeding — these run as detached background work; the UI doesn't block on
     them.
3. `LibraryWindowController`/`LibraryViewController` observe `session` (it's
   `@Observable`) and rebuild their book list once `session.library` becomes
   non-nil.
4. The active mode (List or Email) calls into `CalibreLibrary.books(...)` with
   the current search/filter/sort state and renders whatever comes back.

---

## 6. Data Flow: Opening a Book to Read

1. User double-clicks a book row. This ends up at
   `AppDelegate.openReaderWindow(book:modelContext:)` (or the `target:`
   overload, for a series).
2. That method resolves the actual `.epub` file path on disk via
   `CalibreBook.epubURL(libraryRoot:)`, shows an error alert if it's missing, and
   otherwise calls `ReaderWindowController.open(book:modelContainer:)`.
3. `ReaderWindowController.open` checks a static dictionary,
   `openWindows: [String: ReaderWindowController]`, keyed by
   `target.windowKey` (basically `"book-<id>"` or `"series-<id>"`). If a window
   for this book is already open, it's brought to the front instead of opening a
   second one — that's the "one reader window per book" de-duplication the
   architecture doc refers to.
4. A new window is created, and a `ReaderViewController` becomes its
   `contentViewController`. The view controller's `viewDidLoad` (not shown in
   this guide, see the source) builds the `WKWebViewConfiguration`, registers the
   five message handlers (Section 3.7), *then* creates the `WKWebView` itself —
   this ordering (configuration fully set up before the web view exists) is
   Invariant 6 in the architecture doc, and getting it backwards means messages
   sent early can be silently dropped.
5. `EPUBParser` opens the `.epub` (which is just a ZIP file) via ZIPFoundation,
   parses `META-INF/container.xml` to find the OPF manifest, parses the OPF with
   `NSXMLParser` (Apple's SAX-style streaming XML parser) to get the spine order
   and title, and produces sanitized HTML with publisher CSS stripped out.
6. The HTML is loaded into the `WKWebView`. From here on, the reading experience
   (scrolling, pagination, highlighting) is a two-way conversation between Swift
   and injected JavaScript (Section 8.5).

---

## 7. Data Flow: Searching and Filtering the Library

This is the most elaborate pipeline in the app, and also the one with the most
duplicated code (see the cleanup plan), so it's worth understanding well.

- **Free text** the user types is parsed by `SearchQueryParser` into a
  `SearchQuery` struct with recognized prefixes (`tag:`, `author:`, `title:`,
  `series:`) split out from plain terms.
- **Plain terms** prefer Calibre's FTS5 full-text index
  (`CalibreFTSLibrary`) when available; otherwise they fall back to a
  hand-rolled fuzzy `LIKE`-based title match (`CalibreLibrary.fuzzyTitleCondition`,
  which breaks longer words into trigrams to tolerate typos — see the extensive
  comment in `CalibreLibrary.swift` explaining why 6 trigrams and 5 words are the
  chosen caps).
- **Structured filters** (rating, tags, collection membership, etc.) are built
  through `FilterDrawerView`/`FilterBuilder` into a `FilterExpression` — a tree
  of `FilterRule`s grouped with AND/OR logic.
- Rules that can be expressed in SQL run directly against Calibre.
  Rules based on Ambrosia's own state (collection membership, "Liked", "Skipped")
  are resolved against `CollectionStore`/`AmbrosiaMetaDB` and intersected with
  the SQL results in Swift.
- Results are cached in a small hand-written LRU cache (`LRUCache` in
  `CacheTypes.swift`), keyed on both the filter expression *and* a
  `membershipVersion` counter that's bumped any time something like "liked"
  status changes — so a cached result from before a like/skip toggle is never
  served stale.

Both `LibraryRootView` (SwiftUI) and `EmailLibraryViewController` (AppKit) drive
this same pipeline independently, with their own copies of the orchestration
code around it (paging state, debouncing, deferred counts). See the cleanup
plan for why that's the single biggest opportunity for simplification in this
codebase.

---

## 8. Subsystem Tour

### 8.1 `CalibreLibrary` — the read-only Calibre gateway

An `actor` (Section 3.1) wrapping a read-only `SQLite.swift` `Connection` to
`metadata.db`. Its job is entirely translation: take Swift-typed requests
(`SortField`, `SearchQuery`, `FilterExpression`, IDs), build parameterized SQL,
and return Swift structs (`CalibreBook`). It never returns raw rows to callers.

A schema quirk worth knowing if you touch this file: **`books` has no `series`
column.** Series membership is normalized through a link table:
`books_series_link` joins `books` to `series`. Every query that needs series
data joins through that link table — there is no shortcut.

Sorting is a mix of SQL and in-memory Swift. Some sort fields (title, author,
publish date) map directly to an `ORDER BY` clause. Others — word count, AO3
published/updated dates, and the seeded-random shuffle — can't be expressed in
SQL at all (word count often lives in a *different* database, AO3 dates same,
and "random" needs a stable per-session seed), so the actor fetches a full ID
list, sorts it in Swift, and slices out the requested page:

```swift
func wordCountSortedPage(offset: Int, limit: Int, ascending: Bool, ...) -> (page: [CalibreBook], hasMore: Bool) {
    let allIDs = fetchAllMatchingIDs(...)
    let wordCounts = ...
    let sortedIDs = allIDs.sorted { a, b in compareNilsLast(wordCounts[a], wordCounts[b], ascending: ascending) }
    let pageIDs = Array(sortedIDs[start..<end])
    return (booksForIDs(pageIDs), end < sortedIDs.count)
}
```

`compareNilsLast` is a small, reused comparator: books with no known value for
the sort key always sort to the end, regardless of ascending/descending — there's
no sensible "low" or "high" position for "unknown."

### 8.2 `CalibreBook` and `SeriesGroup` — the shared vocabulary

`CalibreBook` is the one struct every UI surface renders. It's deliberately
plain: computed properties like `displayTitle`, `displayAuthors`, and
`isDescriptionAnthology` derive presentation strings from raw fields, so that
logic lives in one place instead of being re-implemented per view.

`ReadingTarget` is a small enum that unifies "open this one book" and "open this
whole series" into a single type the reader window code can accept:

```swift
enum ReadingTarget: Hashable {
    case singleBook(CalibreBook)
    case series(SeriesGroup)

    var primaryBook: CalibreBook {
        switch self {
        case .singleBook(let book): return book
        case .series(let series):
            precondition(!series.works.isEmpty, "SeriesGroup invariant violated: works must be non-empty")
            return series.works[0]
        }
    }
}
```

The `precondition` is worth understanding: it's not a `guard`/optional — it's an
assertion that crashes immediately, with a clear message, if the invariant it
names is ever violated. That's a deliberate choice here: `SeriesGroup` is
*supposed* to be impossible to construct with zero works (its own `init` enforces
the same precondition), so if this one ever fires, it means something upstream
broke that guarantee, and the message tells you exactly which guarantee. This is
strictly better than a silent, wrong default *or* an unlabeled force-unwrap
crash — it converts "why did this crash" into "which invariant did I break,"
which is a much faster debugging starting point.

### 8.3 `AmbrosiaMetaDB` — the app's own writable database

An `actor` (same motivation as `CalibreLibrary`: serialize all access to one
SQLite file) that owns a *writable* SQLite database, one per Calibre library,
stored under
`~/Library/Application Support/Ambrosia/libraries/<hash-of-library-path>/ambrosia_meta.db`.
It holds everything Ambrosia needs to remember that Calibre doesn't: collections,
annotations, extracted AO3 metadata, series cache, canonical tag data, and
reading history.

Two migration patterns coexist here, and the difference matters:

- Most tables are created with `CREATE TABLE IF NOT EXISTS` and columns added
  with `ALTER TABLE ... ADD COLUMN` wrapped in `try?`. This is safe *only*
  because these changes are additive and idempotent — running them again does
  nothing harmful.
- One migration actually restructures a table (`series_placeholders` →
  a differently-keyed version). Because `IF NOT EXISTS` can't protect a
  *destructive* change (a change that drops or renames something) from running
  twice, that migration instead checks `PRAGMA user_version` — a single integer
  counter SQLite keeps for exactly this purpose — before running, and bumps it
  inside the same transaction as the migration itself:

  ```swift
  let version = (try? db.scalar("PRAGMA user_version")) as? Int64 ?? 0
  guard version < seriesPlaceholdersKeyedMigrationVersion else { return }
  try db.transaction {
      ... // the actual DROP/RENAME work
  }
  try db.run("PRAGMA user_version = \(seriesPlaceholdersKeyedMigrationVersion)")
  ```

  Wrapping it in `db.transaction { }` means if the app crashes partway through,
  SQLite rolls the whole thing back — you never end up with half a migration
  applied and a `user_version` that claims otherwise.

If you ever need to add a new destructive migration, this is the template to
copy, not the `IF NOT EXISTS` pattern above it.

### 8.4 AO3 metadata extraction

`AO3MetadataExtractor` uses SwiftSoup (a Swift port of the popular Java HTML
parser jsoup) to parse the AO3-specific "preface" page that AO3's own EPUB
exporter puts at the start of every downloaded work — a predictable block of
HTML containing fandom, rating, warnings, word count, kudos, and so on.
`LibrarySession` checks the first five spine items of each newly-opened book for
this preface (AO3 sometimes puts a cover image or title page before it), stores
a successful parse into `ao3_metadata`, and records *why* an attempt failed into
`ao3_extraction_diagnostics` — so a failed extraction is diagnosable later rather
than silently invisible.

Extraction runs in batches of 50 with `Task.yield()` between batches — this
voluntarily gives up its turn on the cooperative thread pool so that a user's
search query issued mid-extraction isn't stuck waiting behind the whole
extraction job.

### 8.5 The Reader: EPUB parsing and the JS bridge

An EPUB file is a ZIP archive with a specific internal structure:
`META-INF/container.xml` points to an OPF file, which lists every content file
(the "manifest") and the order to read them in (the "spine"). `EPUBParser`
(Section 6, step 5) reads all of this, strips publisher CSS (Ambrosia wants full
control over presentation), and produces one merged HTML document per book (or,
for a series, effectively one continuous document spanning every work — see
`SeriesSpineMap` below).

**The character-offset contract** is the single most important cross-cutting
rule in the reader, called out at the top of `EPUBParser.swift` and repeated as
Invariant 5 in the architecture doc: every position in the book — where a
highlight starts, where the user left off reading — is expressed as a **UTF-16
code-unit offset into the visible text only** (no HTML tags counted). This
number is computed by both Swift (`EPUBParser`) and injected JavaScript
(`PaginationJS`, `HighlightBridge`), and the two *must* count identically, or a
highlight saved while reading will restore in the wrong place. There's no
compiler check for this — it's a contract enforced entirely by comments and
discipline, which is exactly why the comment exists in three separate files
saying so.

`SeriesSpineMap` solves a specific problem: when reading a series, each
individual EPUB has its own 0-based spine (chapter 1, 2, 3, ...), but the reader
needs one continuous global position so "next page" can cross from the end of
book 1 into the start of book 2 seamlessly. It's a small, pure translation
layer — `GlobalSpineRef { workIndex, localIndex }` — built once per `loadEPUB()`
call and never mutated afterward, specifically so nothing downstream has to
worry about it changing mid-read.

### 8.6 Annotations and highlights

`Annotation` (in `BookState.swift`, despite the filename — it's a plain
`Codable` struct, not a SwiftData model) unifies what used to be two separate
concepts, bookmarks and highlights, into one:

```swift
struct Annotation: Codable, Identifiable {
    var id: UUID = UUID()
    var spineIndex: Int
    var startChar: Int
    var endChar: Int          // == startChar for a point annotation (old "bookmark")
    var selectedText: String
    var note: String?
    var colorHex: String
    var isPointAnnotation: Bool { startChar == endChar }
    var createdDate: Date = Date()
}
```

If `startChar == endChar`, it's a point annotation (what used to be a
"bookmark" — a marker with no range). If they differ, it's a ranged highlight.
One type, one code path, instead of two similar-but-separate features to
maintain. These are persisted in `AmbrosiaMetaDB`'s `annotations` table, not
SwiftData — annotations are Ambrosia-owned, per-library data, which is exactly
what `AmbrosiaMetaDB` is for.

### 8.7 Preferences

`ReaderPreferences` is a `ObservableObject` singleton (Section 3.4) backed
directly by `UserDefaults` — every property's getter/setter reads/writes
`UserDefaults.standard` directly, so there's no separate "load/save" step to
forget. It controls a wide surface: typography, spacing, color scheme, default
reading mode, library appearance, window sizing, context-menu behavior, and
custom Calibre column labels.

The reader's CSS is generated by interpolating these preference values directly
into a Swift string of CSS:

```swift
var css: String {
    """
    body {
        font-size: \(fontSize)px;
        line-height: \(lineHeight);
        ...
    }
    """
}
```

Every single preference change — even something as small as nudging the font
size — currently triggers a full `reloadHTML()`, i.e. the entire EPUB is
re-parsed and the web view reloads from scratch. This works, but it's
noticeably more than necessary for a pure style tweak; the architecture doc
(Invariant 7) already identifies the improvement path — inject preferences as
CSS custom properties (`var(--ambrosia-font-size)`) in a `:root` block once, then
push style-only changes with a single `evaluateJavaScript` call instead of a
full reload — but that migration hasn't happened yet.

### 8.8 The local RSS feed server

`LocalFeedServer`, built on the third-party `FlyingFox` package, is an optional,
off-by-default HTTP server that serves read-only RSS/OPML feeds representing
your collections (e.g. "everything in my Liked collection" as an RSS feed you
could subscribe to in another app). It binds to `127.0.0.1` (loopback) only by
default — it's not reachable from other devices on your network unless you
explicitly change that — and every route is `GET`-only; there's no way for an
external feed reader to write anything back into Ambrosia.

---

## 9. Glossary

- **AO3** — Archive of Our Own, a fan-fiction hosting site. Its EPUB exports have
  a very regular structure Ambrosia specifically knows how to parse.
- **Calibre** — third-party, open-source e-book library manager. Owns your actual
  book files and `metadata.db`.
- **EPUB** — the e-book file format Ambrosia reads. Internally, a ZIP file
  containing XHTML content files plus an OPF manifest/spine.
- **OPF / spine / manifest** — the OPF file inside an EPUB lists every content
  file (manifest) and the order to display them in (spine).
- **FTS / FTS5** — SQLite's Full-Text Search extension; Calibre optionally builds
  a `full-text-search.db` that Ambrosia can query for fast, ranked plain-text
  search, falling back to fuzzy `LIKE` matching when it's absent.
- **Collection** — an Ambrosia-owned tag-like grouping (Liked, Read Later,
  Skipped, a user-created one, etc.), stored in `AmbrosiaMetaDB`, unrelated to
  Calibre's own tags.
- **ELO** — the chess/competitive-ranking rating algorithm; `BookState` reserves
  fields for a future head-to-head book-ranking feature that isn't built yet.
- **Actor** — a Swift reference type whose access is serialized by the compiler;
  see Section 3.1.
- **Retain cycle** — two or more objects holding strong references to each other,
  none of which can ever be deallocated as a result; see Section 3.8.

---

## 10. Where to Go Next

Read `ambrosia_architecture.md` now — its terse "Fixed." notes and 21 numbered
invariants will read as concrete lessons-learned rather than dry rules, now that
you've seen the code and the reasoning behind it. Then read
`ambrosia_cleanup_plan.md` for what's left to do.
