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
- `readingModeRaw: String` — legacy column retained to avoid SwiftData migration; never read or written by current code

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
│           └── NSHostingView<LibraryRootView>       [list view]
│           └── EmailLibraryViewController            [email/split view]
│           └── (scaffold placeholder)               [ranking view — D3 not yet built]
│
└── ReaderWindowController (NSWindowController)
    └── ReaderViewController (NSViewController, WKWebView)
```

The app entry point (`AmbrosiaApp`) creates the SwiftData `ModelContainer`, initializes `LibrarySession`, and passes both to `AppDelegate`. On schema mismatch (stale entities from old model versions), it catches the init error, deletes all files matching `"Ambrosia"` in `~/Library/Application Support/Ambrosia/`, and retries.

---

## Library UI

### Views

The library has three display modes controlled by `LibraryToolbarState.viewMode` (`LibraryViewMode`: `.list`, `.email`, `.ranking`):

**List view** (`LibraryRootView`): AO3-style list. Each row shows title, series, authors (tappable → quick author filter), tag pills in a wrapping flow layout (tappable → quick tag filter), stat chips, and description. Paginated at 25 books per page (configurable in a future settings section) with a 0.3s debounce on search input. Tags use `FlowLayout` and wrap freely across multiple lines — all tags are displayed with no cap.

**Email view** (`EmailLibraryViewController`): An `NSSplitViewController` with an `NSTableView` sidebar (AppKit, 64pt rows, title + author + read-progress bar) and a SwiftUI detail pane. Single-click updates the detail pane; double-click opens the reader. The sidebar context menu mirrors the list-view context menu: Open, Like/Unlike, and an "Add to Collection" submenu populated from the current collection list. There is no filter-pill header in the sidebar; filter state is shown only in the list view.

**Ranking view** (scaffold placeholder): Currently displays a "Ranking view coming in D3" placeholder. The toolbar segment uses the `list.number` SF Symbol. Full implementation is planned for session D3.

### Filtering

There are two filter modes that compose together:

**Quick filter**: set by tapping an author or tag pill in a book row.

**Rule filter** (`FilterResult`): set via the filter drawer (`FilterDrawerView`). Rules have a field (`title`, `authorName`, `tag`, `series`, `wordCountGT/LT`, `kudosGT/LT`, `isLiked`, `collection`), an operator (`contains`, `notContains`, `equals`, `startsWith`), and a value. `FilterBuilder` translates rules into SQL WHERE/JOIN fragments. It uses two stages: SQL for Calibre-owned fields, then in-memory post-filtering for `isLiked` and `collection` (which live in SwiftData). The result is a `FilterResult { calibreIDs: [Int], totalCount: Int }`.

An active filter shows as a chip strip at the top of the list view with Edit and dismiss (×) controls. The chip strip is not shown in email view.

### Search

Search input passes a raw string to `CalibreLibrary`'s fuzzy title/author condition. There is no prefix-syntax parsing, autocomplete, or FTS5 integration yet — those are planned for sessions I1, I2, and I3. The debounce is 0.3s.

### Toolbar

A native `NSToolbar` delegates to `LibraryToolbarState` (`@Observable`). Default items: Search · Filter · Sort · Divider · Collections · Reading Goal · Export · View Mode. The toolbar communicates with `LibraryRootView` entirely through `LibraryToolbarState` properties — no direct references between the AppKit toolbar and SwiftUI views.

`LibraryToolbarState` also carries trigger flags (`showFilterDrawer`, `showCollections`, `showReadingGoal`, `triggerExport`, `toggleEmailSidebar`) that views observe and act on, then reset to `false`. In email mode, the filter sheet is presented via a zero-size `NSHostingView<FilterSheetCarrier>` permanently embedded in the view hierarchy so that `@Environment(\.dismiss)` resolves correctly through SwiftUI's sheet system.

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

`ReaderWindowController` creates or fetches the `BookState` for the opened book, initializes `EPUBParser`, and constructs `ReaderViewController`. The reader window is opened from `BookListRow` on double-click, or from a single-click in email view.

`ReaderViewController` hosts a `WKWebView` configured at construction time with a `WKUserContentController`. `WKWebViewConfiguration` must be set up before `WKWebView` is initialized — handlers cannot be added after construction.

The reader always opens in scroll mode (`currentMode = .scroll`). A per-session mode switch (scroll ↔ paginated) is available via toolbar buttons; the chosen mode is not persisted between opens. A global default reading mode preference is planned for Section H but not yet implemented.

`ReaderViewController` subscribes to `ReaderPreferences.shared.objectWillChange` via Combine. Any preference change triggers an immediate `reloadHTML()` — full HTML is regenerated from the EPUB and the new CSS, and the WKWebView reloads. There is no deferred or manual reload mode.

**Scroll mode**: loads `mergedHTML` into the WKWebView, restores `bookState.lastScrollOffset` on load, and injects a passive scroll event listener that posts `positionUpdate` messages back to Swift. Position is auto-saved every 5 seconds and on `viewWillDisappear`.

**Paginated mode**: uses `PaginationEngine` — a hidden-but-framed `WKWebView` (invisible but in the view hierarchy with a real non-zero frame, required for `getBoundingClientRect()` to return non-zero values). The JavaScript pagination engine (`PaginationJS.swift`) performs TreeWalker-based pagination and exposes `window.ambrosiaPaginate(pageHeightPx)`, `window.ambrosiaRenderPage(startChar, endChar)`, `window.ambrosiaHighlight(offset)`, and `window.ambrosiaTotalChars()`. On window resize, a 300ms debounce timer triggers repagination with position preservation and a 2-second highlight at the restored offset. A 2px safety margin is applied to page height.

HTML is fully regenerated on any style change — the live DOM is never patched, as partial DOM updates corrupt pagination state.

### Annotations

Annotations use a unified model (`struct Annotation: Codable, Identifiable`) stored as JSON in `BookState.annotationsData: Data?`. Both point annotations (bookmarks, `startChar == endChar`) and ranged annotations (highlights, `startChar != endChar`) use this single type. Fields: `id`, `spineIndex`, `startChar`, `endChar`, `selectedText`, `note`, `colorHex`, `createdDate`.

Text selection is captured via a `mouseup` JavaScript listener that uses a `TreeWalker` to compute UTF-16 character offsets and posts a `highlightAdded` message to Swift. Annotations are restored after each spine load by `HighlightBridge.restoreHighlights(_:into:)`, which inserts colored `<span>` elements at the stored offsets.

Keyboard shortcuts: `⌘D` creates a point annotation at the current position; `⌘B` toggles the annotation sidebar.

The reader presents a custom `NSMenu` context menu (suppressing the default WebKit menu). Items are configurable via `ContextMenuPreferences` (a value type on `ReaderPreferences`, not persisted to UserDefaults): "Search in Browser" and "Add Annotation…". "Copy" is always present.

`BookState` retains two orphaned fields (`bookmarksData`, `highlightsData`) from the pre-unified annotation model. They are never read or written; retained only to avoid SwiftData migration.

---

## Preferences

`ReaderPreferences` is an `ObservableObject` singleton (`@Published` properties). It stores:

**Reader appearance**: font family (as a CSS font stack chosen from 10 named presets: Iowan Old Style, New York, Georgia, Palatino, Times New Roman, Charter, System/SF Pro, Avenir Next, Seravek, Courier New), font size, line height, max width, horizontal/vertical padding, background color, text color.

**Library appearance**: colour mode (`LibraryColorMode`: `.systemDefault`, `.accentColor`, `.custom`) and appearance mode (`LibraryAppearanceMode`: `.system`, `.light`, `.dark`). Custom mode stores separate light and dark hex color pairs for background and text.

**Window size**: `useScreenFraction` (bool), `defaultWindowWidth` (CGFloat), `defaultWindowHeight` (CGFloat). When `useScreenFraction` is true the reader window opens at a fraction of the screen; otherwise the stored pixel dimensions are used.

**Not yet implemented**: default reading mode (planned Section H), configurable reload strategy (currently always immediate).

Preference changes always trigger immediate reload of all open reader windows via Combine. The Preferences window has a static informational note stating this behaviour.

Custom column labels for word count and kudos are configured in Preferences and stored in `CustomColumnConfig.shared`.

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
13. All `evaluateJavaScript` calls must pass `completionHandler: nil` explicitly.
14. Fetch https://developer.apple.com/documentation/swiftdata before writing any `@Model` code.
15. `NSHostingView` used as a full-pane content view must set `sizingOptions = []` to prevent the `{inf, 88}` intrinsic-size crash during state-change layout passes.
