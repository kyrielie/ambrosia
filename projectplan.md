# Project Ambrosia: Implementation Plan for AI Engineer

---

## How to Use This Document

This plan is structured for an AI engineer working under **context window and token constraints**. Each phase is designed to be completable in a single focused conversation. Do not attempt to implement across phases in one session — you will lose context of earlier decisions.

**Rules for every session:**
- Begin each new conversation by stating the phase number and pasting the "Session Handoff" block from the end of the previous phase.
- Do not write code for a later phase to "save time." Later phases depend on decisions made in earlier ones.
- When you reach ~70% of your context window, stop writing code. Write the Session Handoff block and end the session.
- If a build error cannot be resolved in 3 attempts, escalate to the user with a clear description before the context window fills.

---

## Project Overview

**Goal:** Native macOS EPUB reader for a local Calibre-organized AO3 fanfiction library.

**Non-negotiable constraints:**
- User controls all styling. Strip all publisher CSS.
- No Readium. Custom `WKWebView` only.
- No sandboxing. No cloud. No OPDS.
- macOS 14+ (Sonoma). SwiftData + SQLite.swift. AppKit + SwiftUI hybrid.
- MIT license. Distribution via notarized GitHub DMG.

**Reference implementations:**
- [honeycrisp](https://github.com/kyrielie/honeycrisp) — scroll mode, style override, window management
- [epub-reader-light](https://github.com/pichukov/epub-reader-light) — minimal EPUB parsing
- [JustRead design philosophy](https://justread.app/en/blog-post-why-we-built-justread-this-way)

---

## Current Architecture (as of end of Phase 2)

**This section supersedes any conflicting detail in the Phase 0/1/2 descriptions below. The implementation diverged from the original plan in Phase 1 and all subsequent work follows the architecture described here.**

### Core principle: no import pipeline

Calibre's `metadata.db` is queried **directly and read-only** via SQLite.swift. No books, authors, fandoms, or tags are ever copied into SwiftData. The app is a live query layer over the user's existing Calibre database.

### Data layer

**`CalibreLibrary`** (`Database/CalibreLibrary.swift` + `Database/CalibreLibraryPhase2.swift`)
- One instance per open library; replaced wholesale on library switch.
- Opens `metadata.db` with `Connection(path, readonly: true)`.
- **Do NOT call any PRAGMA that writes** (e.g. `journal_mode`, `query_only`) on a readonly connection — SQLite rejects them with "attempt to write a readonly database".
- `books(offset:limit:sort:ascending:search:filter:)` — paginated book fetch, returns `pageSize + 1` rows so the caller can detect a next page without a separate COUNT.
- `books(ids:offset:limit:sort:ascending:search:)` — Phase 2 overload used when a FilterBuilder result is active.
- All bulk metadata (authors, tags, comments) fetched in three JOIN queries per page, not per book.
- Series name is in a separate `series` table joined via `books_series_link`. **There is no `b.series` column on the `books` table.** Always join: `LEFT JOIN books_series_link bsl ON bsl.book = b.id LEFT JOIN series s ON s.id = bsl.series` and select `s.name`.
- `db` and helpers `_authors`, `_tags`, `_comments`, `parseDate` are `internal` (not `private`) so the Phase 2 extension file can access them.
- All `db.prepare(sql, args)` calls use `[Binding?]` (optional elements). `[Binding]` (non-optional) does not match the SQLite.swift overload and causes "closure argument expects 1 argument" compile errors.
- Custom column discovery via `customColumns()` / `customColumnTableName(label:)` in the Phase 2 extension.

**`CalibreBook`** (`Database/Models/CalibreBook.swift`)
- Plain Swift struct, `Identifiable`, `Hashable`. No SwiftData. No faulting.
- Populated per page by `CalibreLibrary`. `authors`, `tags`, `comment` are mutable vars filled by bulk JOINs after the page fetch.
- `epubURL(libraryRoot:)` — scans the book's subfolder for the first `.epub` file.

**`BookState`** (`Database/Models/BookState.swift`)
- The **only** `@Model` in the project. Keyed by `calibreID: Int`.
- Stores: `isLiked`, `isHidden`, reading progress (`totalReadPercent`, `totalReadingTimeSeconds`), reading position (`lastSpineIndex`, `lastCharacterOffset`, `lastScrollOffset`), and annotations (`bookmarksData: Data?`, `highlightsData: Data?`).
- Annotations stored as JSON `Data` — never as `[Bookmark]` or `[Highlight]` directly on the model (bare Swift collections on `@Model` cause a silent CoreData fault).
- `readingModeRaw: String` — enum decoded to `ReadingMode` at access time.
- Character offsets are **UTF-16 code units, text node content only, no HTML tags**. This convention must match `EPUBParser`, `PaginationJS`, and `HighlightBridge` exactly.

**`Collection`** (`Database/Models/Collection.swift`)
- `@Model`. Book membership stored as `calibreIDsRaw: String` (comma-separated integers). Never `[Int]` or `[Book]`.
- Computed `calibreIDs: [Int]` accessor for reading/writing.

**`ReadingGoal`** (`Database/Models/ReadingGoal.swift`)
- `@Model`. `targetBooksCount`, `periodStart`, `periodEnd`.

**SwiftData schema**: `[BookState.self, Collection.self, ReadingGoal.self]`. That's it.

**`LibrarySession`** (`Database/LibrarySession.swift`)
- `@Observable`. Holds the active `CalibreLibrary?` connection.
- `open(url:)` — validates `metadata.db` is readable, creates `CalibreLibrary`, caches `totalCount`.
- `reopenIfNeeded()` — called from `AppDelegate.applicationDidFinishLaunching` to reopen the last library.
- Injected into the SwiftUI environment via `.environment(session)`.

**`LibraryRegistry`** (`Database/LibraryRegistry.swift`)
- Singleton. Persists known library paths and the active path in `UserDefaults`.
- Readable before `ModelContainer` loads — no SwiftData dependency.

### App entry point

**`AmbrosiaApp`** (`App/AmbrosiaApp.swift`)
- SwiftData schema: `[BookState.self, Collection.self, ReadingGoal.self]`.
- `ModelConfiguration("Ambrosia", schema:, isStoredInMemoryOnly: false)` — named store, no `url:` parameter (macOS 14 API does not accept URL; pass a `String` name).
- On schema mismatch (stale store from old `Book`/`Author`/`ReadingState` entities), catches the error, deletes all files matching `"Ambrosia"` in `~/Library/Application Support/Ambrosia/`, and retries. This prevents the CoreData persistent history truncation warnings on every launch.
- `LibrarySession` is created here and passed to `AppDelegate` and the environment.

**`AppDelegate`** (`App/AppDelegate.swift`)
- `chooseLibraryFolder()` — `NSOpenPanel` for directories, validates `metadata.db` is readable before calling `session.open(url:)`.

### Library UI

**`LibraryViewController`** / **`LibraryWindowController`** — AppKit shell hosting SwiftUI via `NSHostingView`.

**`LibraryRootView`** + **`BookListRow`** (`LibraryUI/BookGridItem.swift`)
- AO3-style list. Each row: title · series, authors (tappable → quick author filter), tags (tappable pills → quick tag filter), stat chips (word count, kudos, read %), description (3 lines).
- Paginated at 100 books per page. `loadPage()` calls `library.books(...)` with `limit: pageSize + 1`.
- Two filter modes: **quick filter** (`LibraryFilter.author/tag`) set by tapping a row item; **rule filter** (`FilterResult`) set by the filter drawer.
- `fetchState()` in `BookListRow` avoids `#Predicate` on `Int` comparison — fetches all `BookState` rows and filters in memory with `.first { $0.calibreID == cid }`. This is safe because `BookState` count is bounded by ever-opened books.
- `DebounceTimer(delay: 0.3)` on search input.
- `FlowLayout` — custom SwiftUI `Layout` for wrapping tag pills.

**`FilterDrawerView`** / **`FilterRuleRow`** (`LibraryUI/FilterDrawer/FilterDrawerView.swift`)
- Sheet. AND/OR conjunction picker (shown only when 2+ rules). Dynamic rule rows. Apply / Clear All buttons.

**`FilterRule`** (`LibraryUI/FilterDrawer/FilterRule.swift`)
- `FilterField`: title, authorName, tag, series, wordCountGT/LT, kudosGT/LT, isLiked.
- `FilterOperator`: contains, notContains, equals, startsWith.
- `isComplete` guards against firing half-filled rules.

**`FilterBuilder`** (`LibraryUI/FilterDrawer/FilterBuilder.swift`)
- Translates `[FilterRule]` → SQL WHERE/JOIN fragments → runs against `CalibreLibrary`.
- Two-stage: SQL for all Calibre-owned fields; in-memory post-filter for `isLiked` (which lives in SwiftData `BookState`).
- Returns `FilterResult { calibreIDs: [Int], totalCount: Int }`.
- **Note on `FilterField.series`**: the SQL fragment still references `b.series` — this is a **known bug to fix in Phase 3**. Should be `s.name` with the series JOIN, matching the pattern used in `CalibreLibrary._fetchBooks`.

### Reader (stubs — Phase 3+)

**`ReaderViewController`** (`Reader/ReaderViewController.swift`)
- Opens EPUB via `EPUBLoader.loadFirstSpineHTML(from:)` and loads into a `WKWebView`.
- Stub only — scroll mode not yet wired to `BookState` position saving.

**`EPUBParser.swift`**
- Contains `OPFDescriptionReader` (used during import to read `dc:description`) and `EPUBLoader` (used by `ReaderViewController`).
- `EPUBLoader.loadFirstSpineHTML(from:)` — opens ZIP, parses `container.xml` → OPF → spine, reads first `<itemref>`, strips all publisher CSS, injects baseline readable CSS.
- `SpineParser` XML delegate reads both `<manifest>` items and the first `<spine><itemref>`.

All other Reader files (`PaginationEngine`, `PaginationJS`, `HighlightBridge`, `BookmarkManager`, `ReaderPreferences`, `ReaderWindowController`) are stubs.

### SPM packages

Added via **File → Add Package Dependencies** in Xcode — do NOT hand-author `Package.resolved`. Xcode must generate it.
- `https://github.com/stephencelis/SQLite.swift.git` — product name `SQLite`, from `0.14.1`
- `https://github.com/weichsel/ZIPFoundation.git` — product name `ZIPFoundation`, from `0.9.0`

Both packages must appear in:
1. `XCRemoteSwiftPackageReference` section of `project.pbxproj`
2. `XCSwiftPackageProductDependency` section
3. `packageReferences` on `PBXProject`
4. `packageProductDependencies` on the native target
5. `PBXFrameworksBuildPhase` (as `PBXBuildFile` entries with `productRef`, not `fileRef`)

Missing entry 5 is the most common cause of "missing symbols" linker failures after resolution succeeds.

---

## Debugging Protocol (Read Before Writing Any Code)

These instructions apply to every phase.

### General Swift / Xcode

**When a build fails:**
1. Read the full error including note lines — Xcode often puts the real cause in a secondary note.
2. If the error is in generated SwiftData code (`@Model` macro expansion), right-click → Expand Macro in Xcode.
3. For `#Predicate` macro errors: the macro cannot compare a `@Model` keypath against a property of a plain struct. Assign to a `let` constant first, and if that still fails, replace with `fetch(FetchDescriptor<T>())` + in-memory `.first { $0.field == value }`. Never use `#Predicate` to compare `@Model` properties against `CalibreBook` properties.
4. Report to the user: file, line, full error text, and what you tried.

**Known SwiftData gotchas (verified against this project):**
- `ModelContext` has no `reset()` method.
- `model(for:)` not `existingModel(for:)`.
- `#Predicate` cannot compare `@Model` keypath against non-literal captured values from other types. Use in-memory filter instead.
- No `[String]`, `[Int]`, `[Double]`, or any bare Swift collection as a stored `var` on `@Model`. Use delimited `String` or `Data` (JSON). Violation: silent CoreData fault at runtime.
- `ModelConfiguration` on macOS 14 takes a `String` name as first arg, not a `url:` URL. Correct: `ModelConfiguration("StoreName", schema: schema, isStoredInMemoryOnly: false)`.
- `@Relationship(inverse:)` on both sides causes circular macro resolution. Declare `inverse:` on one side only.

> **Before writing any SwiftData code**, fetch: https://developer.apple.com/documentation/swiftdata

**When SwiftData store has stale entities (CoreData persistent history errors):**
- Catch the `ModelContainer` init error, delete all files matching the store name in `~/Library/Application Support/<AppName>/`, and retry init. See `AmbrosiaApp.swift` for the pattern.

### SQLite.swift

**API rules verified against this project:**
- All `db.prepare(sql, args)` bindings must be `[Binding?]` (optional). Using `[Binding]` (non-optional) resolves to a wrong overload producing "closure argument list expects 1 argument".
- Every explicit cast must be `as Binding?` not `as Binding`.
- Mixed-type array literals (`[name, limit, offset]`) require explicit casts on each element: `[name as Binding?, limit as Binding?, offset as Binding?]`.
- `db.prepare(sql, args).map { $0 }` returns `[[Binding?]]`. Do not use `Array(try db.prepare(sql))` — ambiguous.
- `db.scalar(sql, args)` has overload resolution issues with array args. Prefer `db.prepare(sql, args).map { $0 }.first?.first` pattern.
- **Do NOT call any write PRAGMA** (`journal_mode`, `query_only`) on a `readonly: true` connection. SQLite will fail with "attempt to write a readonly database". A readonly connection already benefits from WAL mode automatically.

### Calibre database schema (verified)

The `books` table in `metadata.db`:
```
id, title, sort, timestamp, pubdate, series_index, author_sort, isbn, lccn, path, flags, uuid, has_cover, last_modified
```

**`books` has NO `series` column.** Series name is in the `series` table, linked via `books_series_link`:
```sql
LEFT JOIN books_series_link bsl ON bsl.book = b.id
LEFT JOIN series s ON s.id = bsl.series
-- then SELECT s.name
```

Other normalised tables follow the same pattern:
- Authors: `books_authors_link` → `authors`
- Tags: `books_tags_link` → `tags`
- Publishers: `books_publishers_link` → `publishers`
- Comments (descriptions): `comments` table with `book`, `text` columns

Custom columns: `custom_columns` table (`id`, `label`, `datatype`). Data in `custom_column_N` tables with `book`, `value` columns.

### WKWebView / JavaScript

**Attach Safari Web Inspector:**
1. In Xcode scheme → Run → Arguments → Environment Variables: `developerExtrasEnabled = YES`
2. Run the app. Safari → Develop menu → your Mac → Ambrosia → WKWebView instance.
3. JS logs appear only in Safari's console, not Xcode output.

**When `getBoundingClientRect()` returns zeros:**
- WKWebView has no frame or is off-screen. Confirm `webView(_:didFinish:)` has fired and `webView.frame.size != .zero`.

**When `WKScriptMessage` is not received:**
- Handler name in `addScriptMessageHandler(_:name:)` must exactly match JS `window.webkit.messageHandlers.<NAME>.postMessage(...)`.
- `WKUserContentController` must be attached to the `WKWebViewConfiguration` at construction time — not added after.

### pbxproj editing

**Never edit `project.pbxproj` with string substitution across multiple operations in a single Python script without verifying brace balance after each change.** Always run a brace-depth check after any pbxproj modification:
```python
depth = 0
for ch in content:
    if ch == '{': depth += 1
    elif ch == '}': depth -= 1
assert depth == 0
```

**Never hand-author `Package.resolved`.** Xcode 16+ uses a format with `originHash` and trait metadata that cannot be reliably reproduced. Delete any hand-written `Package.resolved` and let Xcode generate it via File → Add Package Dependencies.

---

## Phases 0–2: Complete ✓

Phases 0, 1, and 2 are fully implemented and building. The library opens, queries Calibre's `metadata.db` directly, and displays books in a paginated AO3-style list with working filter drawer and sort controls.

See the **Current Architecture** section above for the authoritative description of what was built. The original Phase 0/1/2 plan text below describes the intended design; the architecture section above reflects what was actually implemented and debugged.

### Phase 2 Session Handoff Block (current state)

```
Phases 0–2 complete. App builds and runs on macOS 14+.
Architecture: direct SQLite queries (no import). BookState is the only @Model.

SwiftData schema: [BookState, Collection, ReadingGoal]
Store name: ModelConfiguration("Ambrosia", ...) — String name, no URL parameter.
Stale-store recovery: AmbrosiaApp.swift catches init error, deletes ~/Library/Application Support/Ambrosia/*, retries.

CalibreLibrary:
  - readonly: true connection. No write PRAGMAs ever.
  - Series: LEFT JOIN books_series_link bsl / LEFT JOIN series s, select s.name. NO b.series column.
  - All db.prepare args: [Binding?] — optional. Non-optional [Binding] causes compile errors.
  - db, _authors, _tags, _comments, parseDate are internal (not private) for extension access.
  - CalibreLibraryPhase2.swift: books(ids:...) overload, customColumns(), customColumnTableName(label:).

FilterBuilder: SQL generation from FilterRule array. Two-stage: SQL for Calibre fields, in-memory for isLiked.
FilterResult: { calibreIDs: [Int], totalCount: Int }
KNOWN BUG: FilterField.series SQL fragment still uses b.series — must be changed to s.name with series JOIN.

BookListRow.fetchState(): avoids #Predicate — fetch all BookState + in-memory .first { $0.calibreID == cid }.

SPM: SQLite.swift (product: SQLite) and ZIPFoundation added via Xcode UI.
  Both appear in: XCRemoteSwiftPackageReference, XCSwiftPackageProductDependency,
  packageReferences (PBXProject), packageProductDependencies (target),
  AND PBXFrameworksBuildPhase (as productRef PBXBuildFile entries — required for linking).

EPUBLoader: in EPUBParser.swift. Parses container.xml → OPF → spine → first item → sanitised HTML.
ReaderViewController: stub. Opens first spine item in WKWebView. No position save yet.
All other Reader files are stubs.

Next: Phase 3 — Full EPUBParser (all spine items), ReaderViewController scroll mode with
  BookState position save/restore, ReaderWindowController opened from double-click in library.
  Character offset contract: UTF-16 code units, text nodes only — document at top of EPUBParser.swift.
  Fix FilterField.series SQL fragment in FilterBuilder.swift.
```

---

## Phase 3 — EPUB Parser and Scroll Reader

**Goal:** Full `EPUBParser` replacing the stub `EPUBLoader`, `ReaderViewController` with scroll mode that saves/restores position to `BookState`, and `ReaderWindowController` opened from a double-click in the library list. Fix the `FilterField.series` SQL bug in `FilterBuilder`.

**Token budget:** Large. Split into 3A (EPUBParser), 3B (ReaderViewController + scroll mode), 3C (wire to library).

**Start by fixing the known Phase 2 bug:**

In `FilterBuilder.swift`, `sqlFragment(for:)` case `.series` references `b.series` which does not exist. Replace with:
```swift
case .series:
    // Series name is in the series table — must JOIN books_series_link + series.
    // The calibreIDs(matchingRules:) query already adds series JOIN when needsSeriesJoin is true.
    // Add: let needsSeriesJoin = rules.contains { $0.field == .series }
    // And: needsSeriesJoin ? "LEFT JOIN books_series_link bsl ON bsl.book = b.id LEFT JOIN series s ON s.id = bsl.series" : ""
    switch rule.op {
    case .contains:    return ("s.name LIKE ?", ["%\(v)%"])
    case .notContains: return ("(s.name IS NULL OR s.name NOT LIKE ?)", ["%\(v)%"])
    case .equals:      return ("s.name = ?", [v])
    case .startsWith:  return ("s.name LIKE ?", ["\(v)%"])
    }
```
And add `let needsSeriesJoin = rules.contains { $0.field == .series }` to `calibreIDs(matchingRules:)`, with the corresponding JOIN string added to `joinClause`.

### 3A — EPUBParser

**Critical contract established in this phase — carry forward forever:**
> Character offsets = UTF-16 code unit count, text node content only, HTML tags excluded.
> Document this at the top of `EPUBParser.swift`. Any deviation between Swift-side and JS-side counting causes irreproducible position drift.

Replace `EPUBLoader` and `OPFDescriptionReader` with a unified `EPUBParser` struct:

```swift
/// Character offset convention: UTF-16 code units, text node content only, no HTML tags.
/// EPUBParser, PaginationEngine, PaginationJS, HighlightBridge must all use this convention.
struct EPUBParser {
    let epubURL: URL

    struct SpineItem {
        let index: Int
        let href: String      // Resolved path within ZIP (e.g. "OEBPS/chapter01.xhtml")
        let mediaType: String
    }

    private(set) var spine: [SpineItem] = []
    private(set) var title: String = ""
    private(set) var opfBasePath: String = ""

    mutating func parse() throws { ... }  // container.xml → OPF → spine + title
    func html(for item: SpineItem, userCSS: String) throws -> String  // sanitised HTML
    func mergedHTML(userCSS: String) throws -> String                  // all spine items joined
    func plainText(for item: SpineItem) throws -> String              // for offset arithmetic
}
```

Implement XML parsing with `NSXMLParser` (SAX, minimal memory):
- `ContainerParser`: reads `META-INF/container.xml`, extracts `full-path` attribute of `<rootfile>`.
- `OPFParser`: reads OPF, extracts manifest (`id → href`) and spine (`idref` list) and `dc:title`.
- All parsing uses SAX delegates — do not load the full XML into a DOM.

CSS sanitisation (same as current `EPUBLoader.sanitise` but used for all spine items):
- Remove `<link rel="stylesheet">`, `<style>...</style>`, `style="..."` attributes, `<script>` blocks.
- Inject user CSS before `</head>`.

Image extraction to temp dir — same pattern as current `EPUBLoader` but extract all image types:
```swift
static func extractImages(from epubURL: URL, calibreID: Int?) throws -> URL
```
Clean up in `AppDelegate.applicationWillTerminate` at `FileManager.default.temporaryDirectory.appendingPathComponent("ambrosia")`.

### 3B — ReaderViewController (scroll mode)

```swift
class ReaderViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {
    var book: CalibreBook
    var bookState: BookState       // fetched or created by ReaderWindowController
    var parser: EPUBParser
    var modelContext: ModelContext
    private var imageBaseURL: URL?
    private var saveTimer: Timer?
    private var webView: WKWebView!
}
```

**Setup:**
```swift
override func loadView() {
    let config = WKWebViewConfiguration()
    #if DEBUG
    config.preferences.setValue(true, forKey: "developerExtrasEnabled")
    #endif
    config.userContentController.add(self, name: "positionUpdate")
    webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = self
    view = webView
}
```

**Loading:**
```swift
func loadScrollMode() throws {
    let html = try parser.mergedHTML(userCSS: currentCSS())
    webView.loadHTMLString(html, baseURL: imageBaseURL)
}

func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    let offset = bookState.lastScrollOffset
    if offset > 0 {
        webView.evaluateJavaScript("window.scrollTo(0, \(offset));")
    }
    injectScrollTracker()
}

private func injectScrollTracker() {
    let js = """
    window.addEventListener('scroll', function() {
        window.webkit.messageHandlers.positionUpdate.postMessage(
            JSON.stringify({ scrollY: window.scrollY })
        );
    }, { passive: true });
    """
    webView.evaluateJavaScript(js)
}
```

**Position save (auto-save every 5 seconds + on view disappear):**
```swift
func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == "positionUpdate",
          let body = message.body as? String,
          let json = ... ,
          let y = json["scrollY"] as? Double else { return }
    bookState.lastScrollOffset = y
}

func startAutoSave() {
    saveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
        try? self?.modelContext.save()
    }
}
```

**User CSS** (read from `ReaderPreferences.shared`):
```swift
func currentCSS() -> String {
    let p = ReaderPreferences.shared
    return """
    :root {
        --font-family: \(p.fontFamily);
        --font-size: \(p.fontSize)px;
        --line-height: \(p.lineHeight);
        --max-width: \(p.maxWidth)px;
        --bg-color: \(p.backgroundColor);
        --text-color: \(p.textColor);
    }
    """ + BaseCSS.content
}
```

### 3C — Wire to library

**`ReaderWindowController`:**
```swift
class ReaderWindowController: NSWindowController {
    convenience init(book: CalibreBook, modelContext: ModelContext, libraryRoot: URL) throws {
        // Create window
        // Fetch or create BookState for book.id
        // Parse EPUB
        // Create ReaderViewController with book, bookState, parser, modelContext
        // Set window.contentViewController
        // Update bookState.lastOpenedDate = Date()
    }
}
```

**In `BookListRow.openReader()`** (replace the `print` stub):
```swift
private func openReader() {
    guard let root = URL(string: session.activePath ?? "") else { return }
    guard let wc = try? ReaderWindowController(
        book: book, modelContext: modelContext, libraryRoot: root
    ) else { return }
    wc.showWindow(nil)
}
```
`BookListRow` needs access to `session.activePath` — inject via `let session: LibrarySession` or use `LibraryRegistry.shared.activeURL`.

### Checkpoint — Phase 3 Done When:
- Double-clicking a book opens a reader window.
- EPUB renders with publisher CSS stripped and baseline readable CSS applied.
- Images display correctly.
- Scroll position saves every 5 seconds and restores on reopen.
- `FilterField.series` filter works correctly on a real library.
- Test on AO3 EPUBs with author notes, footnotes, images.

### Phase 3 Session Handoff Block
```
Phase 3 complete.
EPUBParser: parse() → spine; html(for:userCSS:); mergedHTML(userCSS:); plainText(for:).
  Character offset contract: UTF-16 code units, text nodes only — top of EPUBParser.swift.
  Image extraction: temp dir at /tmp/ambrosia/<calibreID>/, baseURL passed to loadHTMLString.
ReaderViewController: WKWebView scroll mode. Auto-save 5s + viewWillDisappear.
  Position: bookState.lastScrollOffset. MessageHandler: positionUpdate.
  developerExtrasEnabled in DEBUG.
ReaderWindowController: opens from BookListRow.openReader(). Creates/fetches BookState.
FilterBuilder.swift: FilterField.series fixed to use s.name with series JOIN.
Next: Phase 4 — Paginated mode, JS pagination engine, resize debounce, temp highlight.
```

---

## Phase 4 — Paginated Mode and JavaScript Pagination Engine

**Goal:** Paginated reading mode using a hidden-but-framed WKWebView for layout measurement, JS TreeWalker pagination, Swift coordination, resize debounce, and temporary highlight after repositioning.

**Do not start Phase 4 until Phase 3 scroll mode is confirmed working on at least 3 different AO3 EPUBs.**

**Token budget:** Very large. Split into 4A (JS engine), 4B (Swift coordinator), 4C (resize + highlight).

### 4A — PaginationJS.swift

Store the entire JS pagination engine as a Swift string constant in `PaginationJS.swift`. Key functions exposed globally on `window`:
- `window.ambrosiaPageinate(pageHeightPx)` — TreeWalker-based pagination → posts `paginationResult` message with `{ boundaries: [{startChar, endChar}] }`
- `window.ambrosiaRenderPage(startChar, endChar)` — scrolls to page start via inserted marker, sets `overflow: hidden`
- `window.ambrosiaHighlight(offset)` — temporary yellow highlight at offset, fades after 2 seconds
- `window.ambrosiaTotalChars()` — returns total UTF-16 char count for validation

Character offset convention: UTF-16 code units, text nodes only. Must match `EPUBParser.plainText(for:).utf16.count` exactly.

**Safety check in `paginate()`:** if `document.body.scrollHeight === 0`, post `{ error: 'layout_not_ready' }` and return.

**Sentence boundary finding:** `findSentenceBoundary(text, localIndex, globalChar)` walks back from the break point to the nearest `.`, `!`, `?`, or `\n`.

### 4B — PaginationEngine (Swift)

```swift
class PaginationEngine: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    struct PageBoundary { let startChar: Int; let endChar: Int }

    // Hidden WKWebView must be in parentView hierarchy with a real non-zero frame.
    // getBoundingClientRect() returns zeros if the WebView is off-screen or frameless.
    func paginate(html: String, pageHeight: CGFloat, baseURL: URL?,
                  completion: @escaping ([PageBoundary]) -> Void)
}
```

The hidden WebView:
- Added as a subview of `parentView` (the reader view)
- `alphaValue = 0` (invisible but has real frame and is in hierarchy)
- Removed from hierarchy after pagination completes
- Apply 2px safety margin: `pageHeight = webView.bounds.height - 2.0`

### 4C — Resize Debounce and Repagination

In `ReaderViewController`:
- `DebounceTimer` (300ms) fires `repaginatePreservingPosition()` from `viewDidLayout()`
- `repaginatePreservingPosition()` saves `currentCharacterOffset`, repaginates, then calls `renderCurrentPage()` + `ambrosiaHighlight(savedOffset)`
- Mode switch: `switchToPaginatedMode()` / `switchToScrollMode()`

**Pagination test harness** — run before shipping Phase 4:
```swift
// sum(endChar - startChar) across all pages must equal parser.plainText(for: item).utf16.count ± 5
```

### Checkpoint — Phase 4 Done When:
- Paginated mode renders correctly at default window size.
- Resize within 300ms triggers repagination with position preservation and 2-second highlight.
- Font size change triggers full HTML reload + repagination with position preservation.
- Pagination harness passes on 5 test books including one 500k+ word book.
- `paginatedTotal` and `expectedTotal` differ by no more than 5 characters.

### Phase 4 Session Handoff Block
```
Phase 4 complete.
PaginationJS: TreeWalker pagination, renderPage(), highlightSentenceAroundOffset(), countAllTextChars().
PaginationEngine: hidden-but-framed WKWebView in parentView. Removes itself after results.
ReaderViewController: switchToPaginatedMode(), paginateCurrentSpine(), renderCurrentPage(),
  repaginatePreservingPosition(). DebounceTimer 300ms.
2px page height safety margin.
Pagination harness: sum(endChar-startChar) within 5 of Swift plainText.utf16.count.
Next: Phase 5 — Annotations (highlights, bookmarks).
```

---

## Phase 5 — Annotations

**Goal:** Text selection → highlight creation via JS bridge. Highlights and bookmarks serialised to `BookState` and restored on spine load.

**Token budget:** Medium.

### 5A — JS Selection Bridge

After page load, inject into the WKWebView:
```javascript
document.addEventListener('mouseup', function() {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || sel.toString().trim().length === 0) return;
    const range = sel.getRangeAt(0);
    const startChar = getCharOffset(range.startContainer, range.startOffset);
    const endChar   = getCharOffset(range.endContainer, range.endOffset);
    window.webkit.messageHandlers.highlightAdded.postMessage(JSON.stringify({
        startChar, endChar,
        selectedText: sel.toString(),
        spineIndex: window.currentSpineIndex || 0
    }));
});

function getCharOffset(node, offset) {
    // UTF-16 count, text nodes only — matches EPUBParser.plainText convention
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let count = 0;
    let current = walker.nextNode();
    while (current) {
        if (current === node) return count + offset;
        count += current.textContent.length;
        current = walker.nextNode();
    }
    return count + offset;
}
```

In Swift receive via `WKScriptMessageHandler`, decode, create `Highlight`, append to `bookState.highlights`, save.

### 5B — Restoring Highlights

After each spine loads, inject existing highlights for that spine index as colored `<span>` elements. Use the same TreeWalker offset traversal in reverse.

### 5C — Bookmarks

`⌘D` saves a `Bookmark` with `spineIndex`, `characterOffset`, 80-char `previewText`. Sidebar panel lists bookmarks; clicking one calls `renderCurrentPage()` to jump to position.

### Checkpoint — Phase 5 Done When:
- Selecting text creates a visible highlight.
- Reopening the book restores highlights in correct positions.
- `⌘D` saves a bookmark; sidebar panel lists bookmarks and jumps on click.

---

## Phase 6 — Secondary Features

**Goal:** Collections, reading goals, CSV export. Implement one at a time.

**Token budget:** Small per feature.

**Collections:** SwiftUI sheet for create/rename. `Collection.calibreIDsRaw` (comma-delimited) stores membership — never `[Int]` directly on `@Model`.

**Reading Goals:** On reader window close, diff `Date()` against session start time and add to `BookState.totalReadingTimeSeconds`. Compare against `ReadingGoal.targetBooksCount`.

**CSV Export:**
```swift
struct ExportManager {
    static func exportToCSV(books: [CalibreBook]) -> String { ... }
}
```
Handle quote escaping by doubling internal quotes.

---

## Phase 7 — Polish, Performance, and Release

**Goal:** Preferences window, multi-window support, performance profiling, notarization.

**Preferences window:** `NSWindowController` hosting SwiftUI `Form`. Expose font family, size, line height, max width, background/text colour. Apply changes by reloading the active reader view. Kudos/word-count custom column label picker (populated from `CalibreLibrary.customColumns()`).

**Multi-window:** Array of `ReaderWindowController` in `AppDelegate`. On double-click, check if book already open by `calibreID` before creating new window.

**Performance profiling:**
- Instruments → Time Profiler on a 500k-word book.
- `mergedHTML()` merge pass will be the bottleneck for large books.
- For books >200k words, consider lazy spine loading: load only first 3 spine items initially.
- `CalibreLibrary` queries are synchronous and fast (<1ms on local SSD). No async needed here.

**Notarization:**
```bash
xcrun notarytool submit Ambrosia.dmg \
  --apple-id <email> --team-id <team> --password <app-specific-password> --wait
xcrun stapler staple Ambrosia.dmg
```

---

## Invariants (Never Violate)

These rules apply across every phase and every session. Review before writing any code.

1. **Do not use Readium.** The entire reader engine is `WKWebView` + custom JS.

2. **Character offset convention:** UTF-16 code units, text nodes only, no HTML tags. `EPUBParser`, `PaginationJS`, `HighlightBridge`, `BookmarkManager` must all use this convention. Any mismatch causes irreproducible position drift.

3. **No `[String]`, `[Int]`, `[Double]`, or any bare Swift collection as a stored `var` on `@Model`.** Use delimited `String` or `Data` (JSON) with a computed property accessor. Violation causes a silent CoreData fault: `CoreData: fault: Could not materialize Objective-C class named "Array"`.

4. **All SwiftData reads/writes on `mainContext` must be `@MainActor`.** Background work uses `@ModelActor`. Never pass `modelContext` across actor boundaries — use persistent identifiers and re-fetch.

5. **Never copy EPUBs or Calibre metadata.** Store absolute paths as `String`. Calibre's library is the single source of truth. Query `metadata.db` read-only.

6. **Pagination WKWebView must be in the view hierarchy with a real frame.** Off-screen or frameless WebViews return zero-height rects from `getBoundingClientRect()`.

7. **Re-generate full HTML on any style change.** Do not patch the live DOM for font or colour changes — layout inconsistencies corrupt pagination state.

8. **Image temp directory lifetime is the app session.** Create at first book open; clean up in `applicationWillTerminate`.

9. **Calibre's `metadata.db` is opened read-only.** Do NOT call any write PRAGMA on the connection. Do NOT attempt to write to the Calibre database in any way.

10. **`books` table has no `series` column.** Always join `books_series_link` + `series` and select `s.name`. This applies to every SQL query that fetches or filters on series.

11. **All `db.prepare(sql, args)` calls use `[Binding?]`.** Non-optional `[Binding]` resolves to a wrong SQLite.swift overload. Every explicit cast in a binding array must be `as Binding?`.

12. **SPM packages must be added via Xcode UI.** Never hand-author `Package.resolved`. Both packages must appear in `PBXFrameworksBuildPhase` as `productRef` build file entries, or linking will fail even when resolution succeeds.

13. **`ModelConfiguration` takes a `String` name, not a URL.** `ModelConfiguration("StoreName", schema:, isStoredInMemoryOnly:)`. No `url:` parameter on macOS 14.

14. **Test pagination on books >500k words before shipping.** Only this load case consistently reveals performance and correctness bugs.

15. **Never use `#Predicate` to compare a `@Model` keypath against a property of a plain struct (`CalibreBook`).** Use in-memory filter: `fetch(FetchDescriptor<BookState>()).first { $0.calibreID == targetID }`.

---

## Reference Index

### Swift / AppKit / SwiftUI
- [NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview)
- [NSApplicationDelegateAdaptor](https://developer.apple.com/documentation/swiftui/nsapplicationdelegateadaptor)
- [MainActor](https://developer.apple.com/documentation/swift/mainactor)
- [AppKit documentation](https://developer.apple.com/documentation/appkit)

### SwiftData
- **[SwiftData overview](https://developer.apple.com/documentation/swiftdata)** ← fetch before writing any @Model code
- **[SwiftData revision history](https://developer.apple.com/documentation/updates/swiftdata)** ← check for API changes between OS versions
- [ModelActor](https://developer.apple.com/documentation/swiftdata/modelactor)
- [FetchDescriptor and SortDescriptor](https://developer.apple.com/documentation/swiftdata/fetchdescriptor)

### WKWebView
- [evaluateJavaScript](https://developer.apple.com/documentation/webkit/wkwebview/1415017-evaluatejavascript)
- [WKScriptMessageHandler](https://developer.apple.com/documentation/webkit/wkscriptmessagehandler)
- [WKUserContentController](https://developer.apple.com/documentation/webkit/wkusercontentcontroller)

### SQLite.swift
- [Full documentation](https://github.com/stephencelis/SQLite.swift/blob/master/Documentation/Index.md)

### EPUB / JavaScript
- [EPUB 3 specification](https://www.w3.org/publishing/epub3/epub-spec.html)
- [MDN: TreeWalker](https://developer.mozilla.org/en-US/docs/Web/API/TreeWalker)
- [MDN: Range](https://developer.mozilla.org/en-US/docs/Web/API/Range)
- [MDN: getBoundingClientRect](https://developer.mozilla.org/en-US/docs/Web/API/Element/getBoundingClientRect)

### ZIPFoundation
- [ZIPFoundation README](https://github.com/weichsel/ZIPFoundation)

### Calibre
- [Calibre DB schema](https://github.com/kovidgoyal/calibre/blob/master/src/calibre/db/schema_upgrades.py)
