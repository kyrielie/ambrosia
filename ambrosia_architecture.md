# Project Ambrosia — Architecture Overview

## What This Application Is

Ambrosia is a native macOS EPUB reader designed specifically for AO3 fanfiction libraries managed by [Calibre](https://calibre-ebook.com/). It is a read-only query layer over an existing Calibre database — it never imports, copies, or modifies Calibre's data. The app targets macOS 14+ (Sonoma) and is distributed as a notarized DMG.

Key design principles:
- All publisher CSS is stripped; the user controls all styling.
- No Readium. The reader is built on a custom `WKWebView` with injected JavaScript.
- No sandboxing, no cloud sync, no OPDS.
- Calibre's `metadata.db` is the single source of truth, opened read-only via SQLite.

---

## Technology Stack

- **UI**: AppKit + SwiftUI hybrid. Top-level window management is AppKit (`NSWindowController`, `NSViewController`); most views are SwiftUI hosted via `NSHostingView`.
- **Persistence (app state only)**: SwiftData with three models: `BookState`, `Collection`, `ReadingGoal`. The `ModelConfiguration` uses a string name (`"Ambrosia"`), not a URL — this is a macOS 14 API constraint.
- **Calibre data**: SQLite.swift (`readonly: true` connection). No write PRAGMAs ever.
- **EPUB parsing**: ZIPFoundation + `NSXMLParser` (SAX). No third-party EPUB library.
- **Reader rendering**: `WKWebView` with custom JavaScript injected at runtime.
- **SPM packages**: `SQLite.swift` and `ZIPFoundation`, added via Xcode UI (never hand-authored in `Package.resolved`).

---

## Data Layer

### Calibre database (`CalibreLibrary`)

`CalibreLibrary` opens `metadata.db` with a read-only SQLite connection. One instance exists per open library and is replaced wholesale on library switch. It is held by `LibrarySession` (an `@Observable` singleton injected into the SwiftUI environment).

The Calibre `books` table schema is:
```
id, title, sort, timestamp, pubdate, series_index, author_sort, isbn, lccn, path, flags, uuid, has_cover, last_modified
```

There is **no `series` column on `books`**. Series data always requires a JOIN:
```sql
LEFT JOIN books_series_link bsl ON bsl.book = b.id
LEFT JOIN series s ON s.id = bsl.series
```
Authors, tags, and publishers follow the same normalized link-table pattern (`books_authors_link → authors`, etc.). Comments (descriptions) are in a separate `comments` table.

Custom columns are discovered at runtime via the `custom_columns` table, with data stored in `custom_column_N` tables. Word count and kudos are custom columns whose labels are configured by the user in Preferences and stored in `CustomColumnConfig.shared`.

The primary fetch method `books(offset:limit:sort:ascending:search:filter:)` returns `pageSize + 1` rows to allow next-page detection without a separate `COUNT` query. Bulk metadata (authors, tags, comments) is fetched in three JOIN queries per page, not per book.

All `db.prepare(sql, args)` calls use `[Binding?]` (optional array). Non-optional `[Binding]` resolves to the wrong SQLite.swift overload and produces a compile error.

### App state (`BookState`, `Collection`, `ReadingGoal`)

`BookState` is the only `@Model` that stores per-book reading data. It is keyed by `calibreID: Int` and stores:
- Like/hidden flags
- Reading progress (`totalReadPercent`, `totalReadingTimeSeconds`)
- Reading position (`lastSpineIndex`, `lastCharacterOffset`, `lastScrollOffset`)
- Annotations serialized as `annotationsData: Data?` (JSON-encoded `[Annotation]`)

**Critical SwiftData constraint**: bare Swift collections (`[String]`, `[Int]`, etc.) cannot be stored directly on `@Model` — they cause a silent CoreData fault at runtime. All collections are stored as delimited `String` or JSON `Data` with computed property accessors.

`#Predicate` cannot compare a `@Model` keypath against a property of a plain struct. All `BookState` lookups use an in-memory filter: `fetch(FetchDescriptor<BookState>()).first { $0.calibreID == targetID }`.

### `LibraryRegistry`

A singleton that persists known library paths and the active path in `UserDefaults`. It is readable before `ModelContainer` loads, so it has no SwiftData dependency.

---

## Application Structure

```
AmbrosiaApp (SwiftUI App)
├── AppDelegate (NSApplicationDelegate)
│   └── LibraryWindowController (NSWindowController)
│       ├── NSToolbar (native, delegates to LibraryToolbarState)
│       └── LibraryViewController (NSViewController)
│           └── NSHostingView<LibraryRootView>   [list view]
│           └── EmailLibraryViewController       [email/split view]
│           └── GridLibraryViewController        [grid view]
│
└── ReaderWindowController (NSWindowController)
    └── ReaderViewController (NSViewController, WKWebView)
```

The app entry point (`AmbrosiaApp`) creates the SwiftData `ModelContainer`, initializes `LibrarySession`, and passes both to `AppDelegate`. On schema mismatch (stale entities from old model versions), it catches the init error, deletes all files matching `"Ambrosia"` in `~/Library/Application Support/Ambrosia/`, and retries.

---

## Library UI

### Views

The library has three display modes controlled by `LibraryToolbarState.viewMode`:

**List view** (`LibraryRootView`): AO3-style list. Each row shows title, series, authors (tappable → quick author filter), tag pills (tappable → quick tag filter), stat chips, and description. Paginated at 100 books per page with a 0.3s debounce on search input.

**Email view** (`EmailLibraryViewController`): An `NSSplitViewController` with an `NSTableView` sidebar (AppKit, 52pt rows, title + author) and a SwiftUI detail pane. Single-click updates the detail pane; double-click opens the reader.

**Grid view** (`GridLibraryViewController`): A SwiftUI `LazyVGrid` of cover art cards (160×210pt). Cover images are loaded from Calibre's `cover.jpg` files via `file://` URLs using `AsyncImage`.

### Filtering

There are two filter modes that compose together:

**Quick filter** (`LibraryFilter.author` / `.tag`): set by tapping an author or tag in a book row.

**Rule filter** (`FilterResult`): set via the filter drawer (`FilterDrawerView`). Rules have a field (`title`, `authorName`, `tag`, `series`, `wordCountGT/LT`, `kudosGT/LT`, `isLiked`), an operator (`contains`, `notContains`, `equals`, `startsWith`), and a value. `FilterBuilder` translates rules into SQL WHERE/JOIN fragments. It uses two stages: SQL for Calibre-owned fields, then in-memory post-filtering for `isLiked` (which lives in SwiftData). The result is a `FilterResult { calibreIDs: [Int], totalCount: Int }`.

### Search

Search input is parsed by `SearchQueryParser` before reaching the database. Supported syntax:
- `tag:value` — filter by tag
- `author:value` — filter by author name
- `title:value` — filter by title
- plain text — fuzzy title/author search

Multiple tokens stack with AND logic. Prefix tokens combine additively with active `FilterDrawer` rules.

Autocomplete suggestions appear as a floating overlay: tag suggestions for plain text (≥2 characters), author suggestions after `author:`, title suggestions after `title:`. Suggestions are fetched directly from the Calibre database, sorted by frequency for tags.

If `full-text-search.db` exists alongside `metadata.db`, `CalibreFTSLibrary` opens it read-only and uses FTS5 MATCH for plain-text queries (up to 500 results). If the file is absent or errors, the search falls back transparently to SQL LIKE.

### Toolbar

A native `NSToolbar` delegates to `LibraryToolbarState` (`@Observable`). Default items: Search · Filter · Sort · Divider · Collections · Reading Goal · Export · View Mode. The toolbar communicates with `LibraryRootView` entirely through `LibraryToolbarState` properties — no direct references between the AppKit toolbar and SwiftUI views.

---

## EPUB Parser

`EPUBParser` (a Swift struct) handles all EPUB reading:

1. Opens the EPUB zip via ZIPFoundation.
2. Parses `META-INF/container.xml` to find the OPF path.
3. Parses the OPF with `NSXMLParser` (SAX) to extract the manifest, spine, and `dc:title`.
4. Provides `html(for:userCSS:)` for a single spine item and `mergedHTML(userCSS:)` for all spine items concatenated.
5. Provides `plainText(for:)` for character offset arithmetic.
6. Strips all publisher CSS (`<link>`, `<style>`, `style="..."`, `<script>`) and injects user CSS before `</head>`.
7. Extracts images to a temporary directory at `/tmp/ambrosia/<calibreID>/` and provides the base URL to `WKWebView`.

**Character offset contract** (must be consistent across all components): offsets are **UTF-16 code units, text node content only, no HTML tags**. `EPUBParser`, `PaginationJS`, `HighlightBridge`, and all annotation code must use this convention without exception. Any deviation causes irreproducible position drift.

---

## Reader

### Architecture

`ReaderWindowController` creates or fetches the `BookState` for the opened book, initializes `EPUBParser`, and constructs `ReaderViewController`. The reader window is opened from `BookListRow` on double-click.

`ReaderViewController` hosts a `WKWebView` configured at construction time with a `WKUserContentController`. `WKWebViewConfiguration` must be set up before `WKWebView` is initialized — handlers cannot be added after construction.

Two reading modes are available, controlled by `ReaderPreferences.shared.defaultReadingMode` (a global preference, not per-book):

**Scroll mode**: loads `mergedHTML` into the WKWebView, restores `bookState.lastScrollOffset` on load, and injects a passive scroll event listener that posts `positionUpdate` messages back to Swift. Position is auto-saved every 5 seconds and on `viewWillDisappear`.

**Paginated mode**: uses `PaginationEngine` — a hidden-but-framed `WKWebView` (invisible but in the view hierarchy with a real non-zero frame, required for `getBoundingClientRect()` to return non-zero values). The JavaScript pagination engine (`PaginationJS.swift`) performs TreeWalker-based pagination and exposes `window.ambrosiaPaginate(pageHeightPx)`, `window.ambrosiaRenderPage(startChar, endChar)`, `window.ambrosiaHighlight(offset)`, and `window.ambrosiaTotalChars()`. On window resize, a 300ms debounce timer triggers repagination with position preservation and a 2-second highlight at the restored offset. A 2px safety margin is applied to page height.

HTML is fully regenerated on any style change — the live DOM is never patched, as partial DOM updates corrupt pagination state.

### Annotations

Annotations use a unified model (`struct Annotation: Codable, Identifiable`) stored as JSON in `BookState.annotationsData: Data?`. Both point annotations (bookmarks, `startChar == endChar`) and ranged annotations (highlights, `startChar != endChar`) use this single type. Fields: `id`, `spineIndex`, `startChar`, `endChar`, `selectedText`, `note`, `colorHex`, `createdDate`.

Text selection is captured via a `mouseup` JavaScript listener that uses a `TreeWalker` to compute UTF-16 character offsets and posts a `highlightAdded` message to Swift. Annotations are restored after each spine load by `HighlightBridge.restoreHighlights(_:into:)`, which inserts colored `<span>` elements at the stored offsets.

Keyboard shortcuts: `⌘D` creates a point annotation at the current position; `⌘B` toggles the annotation sidebar.

The reader presents a custom `NSMenu` context menu (suppressing the default WebKit menu) with "Search in Browser", "Add Annotation…", and "Copy".

---

## Preferences

`ReaderPreferences` is an `@Published`-based observable singleton. It stores font family (as a CSS font stack, classified by `NSFontManager` traits into Serif/Sans-Serif/Monospace/Other), font size, line height, max width, background/text colors, default reading mode, window size defaults, and the reload strategy.

The reload strategy (`immediate`, `onNextOpen`, `manual`) controls when preference changes trigger a reader reload. In `manual` mode, "Apply to All Open Windows" sends `applyPreferences` up the responder chain to all open `ReaderViewController` instances.

Custom column labels for word count and kudos are configured here and stored in `CustomColumnConfig.shared`.

---

## Key Invariants

These rules apply across all code in the project. Violations cause runtime crashes or data corruption.

1. Never store bare Swift collections (`[String]`, `[Int]`, etc.) on `@Model`. Use delimited `String` or JSON `Data`.
2. Never use `#Predicate` to compare `@Model` keypaths against `CalibreBook` properties. Use in-memory filter with `FetchDescriptor`.
3. `ModelConfiguration` takes a `String` name, not a URL, on macOS 14.
4. `ModelContext` has no `reset()` method.
5. Character offsets are UTF-16 code units, text nodes only, no HTML tags — everywhere.
6. `books` table has no `series` column. Always `LEFT JOIN books_series_link + series`.
7. All `db.prepare(sql, args)` calls use `[Binding?]` (optional). Non-optional causes a compile error.
8. Never call any write PRAGMA on the read-only Calibre connection.
9. Never hand-author `Package.resolved`. Add SPM packages via Xcode UI only.
10. The pagination `WKWebView` must be in the view hierarchy with a real non-zero frame.
11. Regenerate full HTML on any style change — never patch the live DOM.
12. Image temp directory lifetime is the app session. Clean up in `applicationWillTerminate`.
13. `CalibreFTSLibrary` is opened read-only. Always return `nil` on error to allow LIKE fallback.
14. All `evaluateJavaScript` calls must pass `completionHandler: nil` explicitly.
15. Fetch https://developer.apple.com/documentation/swiftdata before writing any `@Model` code.
