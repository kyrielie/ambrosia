# Project Ambrosia — Final Adjustment Plan (Revised)

All decisions from design review are locked in below.
Always read this document before starting any session.
Always fetch https://developer.apple.com/documentation/swiftdata before writing any @Model code.

---

## How to use this document

Start each session by pasting the section header you are implementing as context.
Stop at ~70% context window, write a handoff block, end the session.
Never implement across more than one major section per session.

---

## Locked-in decisions

| Question | Decision |
|---|---|
| Toolbar style | Native NSToolbar in window chrome (AppKit + NSToolbarDelegate), same items as current SwiftUI toolbar by default. SwiftUI inline toolbar preserved for the "classic" list view. |
| Email view list pane | NSTableView (AppKit) for scroll performance. Title + author only per row, compact ~52 pt height. NSSplitViewController container. |
| Annotation migration | Wipe old bookmarksData / highlightsData. Start fresh with annotationsData. No migration needed. |
| Default toolbar items | Search · Filter · Sort · Divider · Collections · Reading Goal · Export · View Mode — same as current SwiftUI toolbar. |
| Annotation entry | Popover anchored to selected text. Non-blocking. |

---

## Section A — Critical Bug Fix: Custom Column Sort

**Implement this first. It is the only item causing a visible runtime crash.**

### Root cause

`CalibreLibrary.swift` `orderBy(for:ascending:)` returns hardcoded strings like
`"COALESCE(b.custom_column_wordcount, 0) ASC"`. These column names do not exist in
Calibre's schema. Custom column data lives in `custom_column_N` tables discovered at
runtime via the `custom_columns` table.

`CalibreLibraryPhase2.swift` `books(ids:...)` does the dynamic JOIN correctly — but only
for filtered pages. The base `books(offset:limit:...)` method used for normal browsing does
not, so word-count sorting always errors during normal use.

Additionally `CalibreLibraryPhase2.swift` hardcodes label candidates `"words"`,
`"word_count"`, `"wordcount"` instead of reading `CustomColumnConfig.shared.wordCountLabel`.

### Fix — `Database/CalibreLibrary.swift`

1. Add a helper that builds a conditional sort JOIN and ORDER clause:

```swift
/// Returns (joinSQL, orderClause) for a custom column sort, or nil if
/// CustomColumnConfig has no label configured or the label isn't in the DB.
func customColumnSort(configLabel: String?, alias: String, direction: String)
    -> (join: String, order: String)?
{
    guard let label = configLabel,
          let tbl   = customColumnTableName(label: label)
    else { return nil }
    let join  = "LEFT JOIN \(tbl) \(alias) ON \(alias).book = b.id"
    let order = "COALESCE(\(alias).value, 0) \(direction)"
    return (join, order)
}
```

2. In `books(offset:limit:sort:ascending:search:)`, before building the SQL string,
   call `customColumnSort` for `.wordCount` and `.kudos`. If it returns nil, fall back
   to `"b.title \(direction)"`. Inject the JOIN into the FROM clause and use the returned
   ORDER string. Use aliases `wc_base` / `k_base` to avoid conflicts with Phase2 aliases.

3. In `orderBy(for:ascending:)`, remove the hardcoded `b.custom_column_*` strings.
   Return `"wc_base.value"` / `"k_base.value"` when the JOIN is active, `"b.title"`
   otherwise. The caller constructs the SQL so it can conditionally add the JOIN.

   **Simpler alternative** (recommended — less refactor): instead of a separate
   `orderBy()` helper, build the full SQL string inline in `books()` so the JOIN and
   ORDER clause are always constructed together. This avoids the current split where
   `orderBy` returns a clause that assumes a JOIN that may not be present.

### Fix — `Database/CalibreLibraryPhase2.swift`

Replace the hardcoded label candidates in `books(ids:...)`:

```swift
// Before:
let wcTbl = customColumnTableName(label: "words")
         ?? customColumnTableName(label: "word_count")
         ?? customColumnTableName(label: "wordcount")

// After:
let wcTbl = CustomColumnConfig.shared.wordCountLabel
    .flatMap { customColumnTableName(label: $0) }

let kTbl = CustomColumnConfig.shared.kudosLabel
    .flatMap { customColumnTableName(label: $0) }
```

If either returns nil, omit the JOIN and fall back to `"b.title \(direction)"` for that
sort field — same graceful fallback as the base method.

### Test checklist

- [ ] Preferences → set word count column to "words". Sort by Word Count. No SQL error.
- [ ] Preferences → set word count column to "(none)". Sort by Word Count. Falls back to title sort, no crash.
- [ ] Preferences → set wrong label. Falls back, no crash.
- [ ] FilterBuilder word-count rules still work (they use a separate SQL path).

---

## Section B — Context Menu + Unified Annotations

Split into two sub-sessions: B1 (context menu) then B2 (annotations). Do not start B2
until B1 builds cleanly.

### B1 — Context menu

**`Reader/ReaderViewController.swift`**

Add `WKUIDelegate` conformance. In `loadView()`, set `webView.uiDelegate = self`.

Suppress the default WebKit context menu:

```swift
func webView(_ webView: WKWebView,
             contextMenuConfigurationFor element: WKContextMenuElementInfo,
             completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
    completionHandler(nil)
}
```

Provide a custom NSMenu via `NSView.menu`. Override `rightMouseDown` on a thin
`NSView` subclass wrapping the WKWebView (or subclass WKWebView itself):

```swift
override func rightMouseDown(with event: NSEvent) {
    let menu = NSMenu(title: "")
    menu.addItem(NSMenuItem(title: "Search in Browser",
                            action: #selector(searchInBrowser), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Add Annotation…",
                            action: #selector(addAnnotationFromSelection), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Copy",
                            action: #selector(NSText.copy(_:)), keyEquivalent: ""))
    NSMenu.popUpContextMenu(menu, with: event, for: self)
}
```

`searchInBrowser`:

```swift
@objc private func searchInBrowser() {
    webView.evaluateJavaScript("window.getSelection().toString()", completionHandler: nil) { result, _ in
        guard let text = result as? String, !text.isEmpty else { return }
        var comps = URLComponents(string: "https://www.google.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: text)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }
}
```

Note: `NSWorkspace.shared.open(_:)` always uses the system default browser regardless
of which search engine URL is used. The user's browser choice is respected automatically.

### B2 — Unified Annotation type

**`Database/Models/BookState.swift`**

Remove `bookmarksData: Data?`, `highlightsData: Data?`, `struct Bookmark`, `struct Highlight`
and all computed accessors for them.

Add:

```swift
// MARK: - Annotation (unified bookmark + highlight)

var annotationsData: Data?   // JSON-encoded [Annotation]. Never [Annotation] directly.

var annotations: [Annotation] {
    get {
        guard let d = annotationsData else { return [] }
        return (try? JSONDecoder().decode([Annotation].self, from: d)) ?? []
    }
    set {
        annotationsData = try? JSONEncoder().encode(newValue)
    }
}
```

Add top-level (not nested) `struct Annotation: Codable, Identifiable`:

```swift
struct Annotation: Codable, Identifiable {
    var id: UUID          = UUID()
    var spineIndex: Int                 // which spine item
    var startChar: Int                  // UTF-16 code units, text nodes only
    var endChar: Int                    // == startChar for point annotations (old bookmarks)
    var selectedText: String            // "" for point annotations
    var note: String?                   // user-written note, optional
    var colorHex: String                // "#FFD60A" yellow default
    var isPointAnnotation: Bool { startChar == endChar }
    var createdDate: Date               = Date()
}
```

Since `annotationsData` is a new field on `BookState` (which already exists in the
SwiftData store), SwiftData will add the column transparently — no migration needed.
The old `bookmarksData` and `highlightsData` columns are simply orphaned and ignored;
SwiftData does not error on extra columns in the store.

**`Reader/AnnotationSidebarView.swift`** (new file — replaces BookmarkSidebarView.swift)

- 260 pt overlay panel, same position/behaviour as BookmarkSidebarView.
- Lists all `bookState.annotations` sorted by (spineIndex, startChar).
- Each row:
  - SF Symbol: `bookmark.fill` (point) or `highlighter` (ranged).
  - Preview text (first 60 chars of `selectedText`, or spine position for point annotations).
  - Note preview if non-nil.
  - Date (relative, compact).
  - Trash button to delete.
- Tapping a row: call `jumpToAnnotation(_:)` in ReaderViewController.
- Inline note editing: tapping the note area expands a `TextEditor` for that row.

**`Reader/AnnotationPopover.swift`** (new file)

A SwiftUI View for the popover shown when "Add Annotation…" is tapped in the context menu.
The popover is presented via `NSPopover` anchored to the WKWebView at the mouse position.

```
┌──────────────────────────────────────────┐
│ "Selected text preview here…"  (gray,    │
│  2 lines max, read-only)                 │
│                                          │
│ Note (optional)                          │
│ ┌──────────────────────────────────────┐ │
│ │ TextEditor placeholder "Add a note…" │ │
│ └──────────────────────────────────────┘ │
│                                          │
│ Highlight colour:                        │
│  🟡  🔴  🟢  🔵  🟣              │
│                                          │
│            [ Cancel ] [ Save ]           │
└──────────────────────────────────────────┘
```

Width: 320 pt. `NSPopover.behavior = .semitransient`.

**`Reader/ReaderViewController.swift`**

- Remove all `Bookmark` / `Highlight` / `BookmarkManager` / `HighlightBridge` references
  that are now superseded. Keep `HighlightBridge.restoreHighlights` but update its
  signature to accept `[Annotation]`.
- `⌘D` → creates a point annotation at the current scroll/page position (no popover —
  just saves immediately with empty note and default colour). Shows a brief
  `"Annotation saved"` HUD label that fades after 1.5 s.
- `⌘B` → shows/hides the annotation sidebar.
- `addAnnotationFromSelection()` → evaluates JS to get selection range, presents
  `NSPopover` containing `NSHostingView<AnnotationPopover>`.
- `jumpToAnnotation(_ annotation: Annotation)` → scroll to `annotation.startChar` or
  call `renderPage(at: annotation.startChar)` in paginated mode.
- `restoreAnnotations()` → called in `webView(_:didFinish:)`. Calls
  `HighlightBridge.restoreHighlights(bookState.annotations.filter { !$0.isPointAnnotation }, into: webView)`.

**`Reader/HighlightBridge.swift`** — update `restoreHighlights` signature:

```swift
static func restoreHighlights(_ annotations: [Annotation], into webView: WKWebView)
```

**`Reader/BookmarkManager.swift`** — delete this file entirely. All functionality now in
ReaderViewController + AnnotationSidebarView.

---

## Section C — Preferences: Font Picker + Reload Strategy

### C1 — Full system font picker

**`Preferences/PreferencesWindowController.swift`**

Replace the hardcoded `fontFamilies: [String]` array.

Classify fonts by trait using `NSFontManager`:

```swift
private struct FontGroup: Identifiable {
    let id: String
    let title: String
    let families: [String]
}

private var fontGroups: [FontGroup] {
    let all = NSFontManager.shared.availableFontFamilies
    var serif: [String] = [], sansSerif: [String] = [], mono: [String] = [], other: [String] = []

    for family in all.sorted() {
        guard let font = NSFont(name: family, size: 12) else { other.append(family); continue }
        let traits = NSFontManager.shared.traits(of: font)
        if traits.contains(.monoSpaceTrait)        { mono.append(family) }
        else if !traits.contains(.sansSerifTrait)  { serif.append(family) }
        else                                        { sansSerif.append(family) }
    }
    return [
        FontGroup(id: "serif",    title: "Serif",      families: serif),
        FontGroup(id: "sans",     title: "Sans-Serif",  families: sansSerif),
        FontGroup(id: "mono",     title: "Monospace",   families: mono),
        FontGroup(id: "other",    title: "Other",       families: other),
    ].filter { !$0.families.isEmpty }
}
```

Show a grouped List with a search field above it. The selected family name is stored in
`prefs.fontFamily` as a CSS font stack, e.g. `"\"Iowan Old Style\", Georgia, serif"`.

Live preview: a `Text("The quick brown fox")` rendered with `.font(.custom(family, size: prefs.fontSize))` next to the list.

**`Reader/ReaderPreferences.swift`** — change the default:

```swift
@Published var fontFamily: String = UserDefaults.standard.string(forKey: "pref.fontFamily")
    ?? "\"Iowan Old Style\", Georgia, serif"
```

### C2 — Reload strategy

Add to `ReaderPreferences`:

```swift
enum ReloadStrategy: String, CaseIterable, Identifiable {
    case immediate    // reload webview as soon as preference changes (current behaviour)
    case onNextOpen   // store dirty flag; reload on next book open
    case manual       // user presses "Apply to open windows"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .immediate:  return "Immediately"
        case .onNextOpen: return "On next book open"
        case .manual:     return "Manually"
        }
    }
}

@Published var reloadStrategy: ReloadStrategy = .manual   // new default: don't interrupt reading
```

**`Reader/ReaderViewController.swift`**

Currently subscribes unconditionally to `ReaderPreferences.shared.objectWillChange`.
Change to:

```swift
private var prefsCancellable: AnyCancellable?

func subscribeToPreferences() {
    prefsCancellable = ReaderPreferences.shared.objectWillChange.sink { [weak self] _ in
        guard ReaderPreferences.shared.reloadStrategy == .immediate else { return }
        DispatchQueue.main.async { self?.reloadHTML() }
    }
}
```

Add `@objc func applyPreferences()` — called from "Apply to open windows" button via
responder chain:

```swift
@objc func applyPreferences() { reloadHTML() }
```

**`Preferences/PreferencesWindowController.swift`** — add in Reading section:

```
When preferences change:   [ Manually ▾ ]
                            Immediately
                            On next book open
                            Manually
```

When strategy is `.manual`, show an active "Apply to All Open Windows" button that
calls `NSApp.sendAction(#selector(ReaderViewController.applyPreferences), to: nil, from: nil)`.

---

## Section D — Library Views + Native Toolbar

This is the largest section. Split into three sub-sessions: D1 (toolbar), D2 (email view),
D3 (grid view). Confirm D1 builds before starting D2.

### D1 — Native NSToolbar

**Architecture decision:** The SwiftUI inline toolbar in `LibraryRootView` stays in place
and continues to function as the toolbar for the classic List view (and is always the
fallback). The native NSToolbar is added to `LibraryWindowController` and communicates
with `LibraryRootView` state via a shared `LibraryToolbarState` observable object.

**`LibraryUI/LibraryToolbarState.swift`** (new file)

```swift
@Observable
final class LibraryToolbarState {
    var searchText: String = ""
    var showFilterDrawer: Bool = false
    var showCollections: Bool = false
    var showReadingGoal: Bool = false
    var triggerExport: Bool = false
    var viewMode: LibraryViewMode = .list
    var sortField: SortField = .title
    var ascending: Bool = true
}
```

Injected into the environment from `LibraryViewController`. Observed by both
`LibraryWindowController` (to update toolbar item states) and `LibraryRootView`
(to respond to toolbar actions).

**`LibraryUI/LibraryWindowController.swift`** — add NSToolbar:

```swift
private func configureToolbar() {
    let toolbar = NSToolbar(identifier: "LibraryToolbar")
    toolbar.delegate = self
    toolbar.allowsUserCustomization = true
    toolbar.autosavesConfiguration = true
    toolbar.displayMode = .iconOnly
    window?.toolbar = toolbar
}
```

Implement `NSToolbarDelegate`:

```swift
func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.search, .filter, .sort, .flexibleSpace, .collections, .readingGoal, .export, .viewMode]
}

func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.search, .filter, .sort, .collections, .readingGoal, .export, .viewMode,
     .space, .flexibleSpace, .separator]
}

func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
             willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    switch identifier {
    case .search:
        let item = NSSearchToolbarItem(itemIdentifier: identifier)
        item.searchField.bind(.value, to: toolbarState, withKeyPath: "searchText")
        return item
    case .filter:
        return makeButtonItem(.filter, label: "Filter", image: "line.3.horizontal.decrease.circle",
                              action: #selector(toggleFilter))
    case .sort:
        return makeSortMenuItem()
    case .collections:
        return makeButtonItem(.collections, label: "Collections", image: "tray.2",
                              action: #selector(showCollections))
    case .readingGoal:
        return makeButtonItem(.readingGoal, label: "Goal", image: "target",
                              action: #selector(showReadingGoal))
    case .export:
        return makeButtonItem(.export, label: "Export", image: "arrow.up.doc",
                              action: #selector(exportCSV))
    case .viewMode:
        return makeViewModeSegmentedItem()
    default:
        return nil
    }
}
```

Each `@objc` action method sets the appropriate property on `toolbarState`, which
`LibraryRootView` observes and responds to (showing sheets, triggering export, etc.).

The `NSSearchToolbarItem` gives the search field native toolbar behaviour including
proper keyboard focus and animation on macOS 13+.

The Sort toolbar item is an `NSMenuToolbarItem` presenting a menu of `SortField` cases
(same as the current Picker).

The View Mode item is an `NSToolbarItem` wrapping an `NSSegmentedControl` with three
segments: list icon, envelope icon, grid icon.

**`LibraryUI/LibraryRootView.swift`** (modified)

Remove the `private var toolbar: some View` computed property entirely.
Observe `LibraryToolbarState` from the environment instead of local `@State` for
search, filter, sort, collections, readingGoal, export, and viewMode.
Keep the filter chip banner, book list, footer, and all sheet presentations — just driven
by `toolbarState` instead of local state.

The SwiftUI inline toolbar is preserved as a private computed property but only shown
when `viewMode == .list` AND the window does not have a native toolbar attached (i.e.,
during previews or testing). In practice with the native toolbar attached it is hidden.

### D2 — Email view (split pane)

**Architecture:** `NSSplitViewController` containing two child view controllers:
- Left: `EmailSidebarViewController` (NSTableView, AppKit)
- Right: `EmailDetailViewController` (NSHostingView<EmailDetailView>, SwiftUI)

`NSSplitViewController` and `NSSplitView` handle the divider drag natively and save
the split position via `autosaveName`.

**`LibraryUI/Email/EmailSidebarViewController.swift`** (new file)

AppKit `NSViewController` with an `NSScrollView` containing an `NSTableView`.

Cell view (`EmailBookCellView : NSTableCellView`):
- Title: `NSTextField` bold, `.labelColor`, 1 line, truncates tail.
- Author: `NSTextField` secondary colour, 1 line, truncates tail.
- Progress bar: a thin `NSView` (2 pt height, accent colour, width = frame.width × readPercent)
  shown at the bottom of the cell when `readPercent > 0`.
- Row height: 52 pt fixed.

```swift
func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 52 }
```

Data source: an `[CalibreBook]` array set by the parent. On selection change,
calls a delegate/callback closure with the selected `CalibreBook?`.

Selection drives `EmailDetailViewController` — the detail pane updates instantly on
single-click. Double-click opens the reader window.

**`LibraryUI/Email/EmailDetailView.swift`** (new SwiftUI file)

Right pane. Shown when a book is selected; shows placeholder text when none is selected.

Layout (scrollable):
```
Title (title2, bold)
Author · Series #N · Word count · Kudos       (secondary, caption)

[Tag pill] [Tag pill] [Tag pill]              (FlowLayout — reuse existing)

Description (full text, selectable)

                        [ Open Book ▶ ]
```

Receives `CalibreBook?` and `BookState?`. "Open Book" calls `AppDelegate.shared?.openReaderWindow(book:)`.

**`LibraryUI/Email/EmailLibraryViewController.swift`** (new file)

Parent `NSViewController` that:
1. Creates `NSSplitViewController`.
2. Adds `EmailSidebarViewController` as first child (min width 220, max 360, preferred 280).
3. Adds `EmailDetailViewController` as second child (min width 400).
4. Sets `splitView.autosaveName = "AmbrosiaSplitView"`.
5. Wires sidebar selection → detail pane update.
6. Handles pagination: loads books on scroll-to-bottom in the sidebar (same page size and
   CalibreLibrary calls as the list view).
7. Observes `LibraryToolbarState` for search/filter/sort changes and reloads the book list.

**`LibraryUI/LibraryViewController.swift`** (modified)

Add a `viewMode` property driven by `LibraryToolbarState.viewMode`. On change, swap
`contentViewController`:
- `.list` → existing `NSHostingView<LibraryRootView>` (current behaviour)
- `.email` → `EmailLibraryViewController`
- `.grid` → `GridLibraryViewController` (Section D3)

### D3 — Grid view

Simpler than the email view. A SwiftUI `LazyVGrid` of cover art cards.

**`LibraryUI/Grid/GridLibraryView.swift`** (new SwiftUI file)

```
LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200))]) {
    ForEach(books) { book in
        GridBookCard(book: book)
            .onTapGesture(count: 2) { openReader(book) }
    }
}
```

`GridBookCard`: 160×210 pt card.
- Top 130 pt: cover art from `book.coverImageURL` (Calibre stores `cover.jpg` in the
  book's folder alongside the EPUB). If no cover, a generated placeholder using the
  book's initials on an accent-colour background.
- Bottom 80 pt: title (2 lines, bold, small font), author (1 line, secondary).

Cover image loading: use `AsyncImage` with the `file://` URL to the cover. No network
requests. Cache is handled by the OS image pipeline.

**`CalibreBook.swift`** — add:

```swift
var coverURL: URL? {
    guard let root = libraryRoot else { return nil }
    return root.appendingPathComponent(path).appendingPathComponent("cover.jpg")
}
```

`libraryRoot` is not currently stored on `CalibreBook`. Either:
- Pass it at call site: `book.coverURL(libraryRoot: session.libraryRoot)`
- Or add `var libraryRoot: URL?` set when the book is fetched from `CalibreLibrary`.

Recommended: add `mutating func setCoverURL(libraryRoot: URL)` called in `_fetchBooks`
after populating the struct, so the URL is always available on the book.

---

## Section E — Reader Window Size

### E1 — Larger default size

**`Reader/ReaderWindowController.swift`**

Replace the hardcoded `contentRect` with a screen-fraction calculation:

```swift
let screen      = NSScreen.main ?? NSScreen.screens.first!
let visible     = screen.visibleFrame
let width       = (ReaderPreferences.shared.useScreenFraction)
    ? min(visible.width  * 0.75, 1400)
    : ReaderPreferences.shared.defaultWindowWidth
let height      = (ReaderPreferences.shared.useScreenFraction)
    ? min(visible.height * 0.85, 1100)
    : ReaderPreferences.shared.defaultWindowHeight
let contentRect = NSRect(x: 0, y: 0, width: width, height: height)
```

Also increase `minSize` from `(480, 400)` to `(600, 500)`.

### E2 — User-set default size

**`Reader/ReaderPreferences.swift`**

```swift
@Published var useScreenFraction:     Bool    = boolDefault("pref.useScreenFraction", true)
@Published var defaultWindowWidth:    CGFloat = cgfloatDefault("pref.windowWidth",    960)
@Published var defaultWindowHeight:   CGFloat = cgfloatDefault("pref.windowHeight",   1080)
```

Add private helpers `boolDefault` / `cgfloatDefault` that read from UserDefaults and
observe `didSet` to write back.

**`Preferences/PreferencesWindowController.swift`** — add "Reader Window" section:

```
Default size     [✓] Use 75% of screen size
                 Width   [960] px    ← shown only when toggle is off
                 Height  [1080] px
```

---

## Section F — Filter: NOT Prefix on Tag Bubbles

**Single file change: `LibraryUI/BookGridItem.swift`**

In `activeFilterChip`, inside `ForEach(completeRules)`, add NOT badge styling:

```swift
ForEach(completeRules) { rule in
    let negated = rule.op == .notContains || rule.op == .notEquals
    HStack(spacing: 3) {
        if negated {
            Text("NOT")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.red.opacity(0.85))
                .clipShape(Capsule())
        }
        Text(rule.field.label)
            .font(.caption2).foregroundStyle(.secondary)
        if !rule.value.isEmpty {
            Text(rule.value).font(.caption2.bold())
        }
    }
    .padding(.horizontal, 7).padding(.vertical, 3)
    .background(negated ? Color.red.opacity(0.08) : Color.accentColor.opacity(0.12))
    .clipShape(Capsule())
    .overlay(Capsule().stroke(
        negated ? Color.red.opacity(0.3) : Color.accentColor.opacity(0.3),
        lineWidth: 0.5))
}
```

---

## Section G — Dock Icon Reopens Library Window

**Single file change: `App/AppDelegate.swift`**

1. Ensure the library window controller is never released on close.
   In `LibraryWindowController.init`, confirm the window has:
   ```swift
   window.isReleasedWhenClosed = false
   ```

2. Add `applicationShouldHandleReopen`:
   ```swift
   func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
       if !hasVisibleWindows {
           libraryWindowController?.showWindow(nil)
           libraryWindowController?.window?.makeKeyAndOrderFront(nil)
       }
       return true
   }
   ```

   `libraryWindowController` is already a stored property on `AppDelegate`.
   No re-creation needed — just show it again.

---

## Implementation order

| Session | Section | Size |
|---|---|---|
| 8A | A — Custom column bug fix | Small |
| 8B | F — NOT filter chip; G — Dock reopen | Small |
| 8C-1 | B1 — Context menu | Small |
| 8C-2 | B2 — Unified annotation model + sidebar + popover | Large |
| 8D | C — Font picker + reload strategy | Medium |
| 8E-1 | D1 — LibraryToolbarState + NSToolbar in LibraryWindowController | Medium |
| 8E-2 | D2 — Email view (NSSplitViewController + NSTableView sidebar + SwiftUI detail) | Large |
| 8E-3 | D3 — Grid view + cover art loading | Medium |
| 8F | E — Window size preference | Small |

Always start a session by pasting the relevant section above.
Do not start 8C-2 until 8C-1 builds.
Do not start 8E-2 until 8E-1 builds.

---

## Invariants (carry forward — never violate)

1. Never store `[String]`, `[Int]`, `[Double]`, or any bare Swift collection as a
   stored `var` on `@Model`. Use delimited `String` or JSON `Data`.
2. Never use `#Predicate` to compare a `@Model` keypath against a `CalibreBook` property.
   Use in-memory filter: `fetch(FetchDescriptor<BookState>()).first { $0.calibreID == id }`.
3. `ModelConfiguration("Ambrosia", schema:, isStoredInMemoryOnly:)` — String name, no URL.
4. `ModelContext` has no `reset()`. Do not call it.
5. Never call `model(for:)` across different `ModelContext` instances.
6. Character offset contract: UTF-16 code units, text nodes only, no HTML tags.
   `EPUBParser`, `PaginationJS`, `HighlightBridge`, all annotation code must use this.
7. `books` table has no `series` column. Always JOIN `books_series_link + series`.
8. All `db.prepare(sql, args)` calls use `[Binding?]` (optional). Non-optional causes
   "closure argument expects 1 argument" compile error.
9. Never call any write PRAGMA on the readonly Calibre connection.
10. Never hand-author `Package.resolved`.
11. All `evaluateJavaScript` calls must pass `completionHandler: nil` (not bare zero-arg).
12. When adding Swift files: register PBXFileReference + PBXBuildFile + PBXSourcesBuildPhase
    + correct PBXGroup children in `project.pbxproj`. Verify the group's `path =` matches
    the file's actual subdirectory on disk. Always run brace-balance check after edits.
13. Fetch https://developer.apple.com/documentation/swiftdata before writing any @Model code.

---

## Section H — Settings: Pagination Mode Toggle

### What it controls

`ReaderPreferences.shared.defaultReadingMode` is a **global override** — it applies to
every book on every open, ignoring per-book `BookState.readingModeRaw`. This means the
per-book mode stored in `BookState` becomes unused once this preference exists; the reader
always reads from `ReaderPreferences` instead of `BookState`.

### `Reader/ReaderPreferences.swift`

Add a new `ReadingMode` enum (move it here from `BookState.swift` since it's now a
preference, not per-book state):

```swift
enum ReadingMode: String, CaseIterable, Identifiable {
    case scroll    = "scroll"
    case paginated = "paginated"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .scroll:    return "Scroll"
        case .paginated: return "Paginated"
        }
    }
}
```

Add the stored preference:

```swift
@Published var defaultReadingMode: ReadingMode {
    didSet { UserDefaults.standard.set(defaultReadingMode.rawValue,
                                       forKey: Keys.defaultReadingMode) }
}

// In Keys enum:
static let defaultReadingMode = "rp.defaultReadingMode"

// In Defaults enum:
static let defaultReadingMode = ReadingMode.scroll

// In init():
let rawMode = ud.string(forKey: Keys.defaultReadingMode) ?? Defaults.defaultReadingMode.rawValue
defaultReadingMode = ReadingMode(rawValue: rawMode) ?? .scroll

// In resetToDefaults():
defaultReadingMode = Defaults.defaultReadingMode
```

### `Reader/ReaderViewController.swift`

Replace all reads of `bookState?.readingMode` (or `bookState?.readingModeRaw`) with
`ReaderPreferences.shared.defaultReadingMode` when deciding the initial mode at load time.
The per-book `BookState.readingModeRaw` field is no longer read; it can remain in the
model for now (removing it would require a SwiftData migration) but is ignored.

In `loadScrollMode()` / `loadPaginatedMode()` calls, keep the mode-switch buttons in the
reader toolbar functional so the user can still switch mode per-reading-session — but
on the *next* open, `ReaderPreferences.shared.defaultReadingMode` wins again.

Do **not** write back to `BookState.readingModeRaw` any more (that was what kept the
per-book mode). Remove those write-backs.

### `Preferences/PreferencesWindowController.swift`

Add to the Reading section, above "When preferences change":

```
Default reading mode     ( ) Scroll   (•) Paginated
```

Use a `Picker` with `.radioGroupStyle()` or a `Picker` with `.segmented` style:

```swift
Picker("Default reading mode", selection: $prefs.defaultReadingMode) {
    ForEach(ReadingMode.allCases) { mode in
        Text(mode.label).tag(mode)
    }
}
.pickerStyle(.segmented)
```

### `Database/Models/BookState.swift`

Remove the `readingModeRaw` field and the `readingMode` computed accessor. Because
removing a stored property from a SwiftData `@Model` requires a migration schema version
bump, instead mark it `@Transient` or just leave the stored column orphaned in the DB
(SwiftData ignores extra columns). The safest path with no migration risk:

**Keep `readingModeRaw: String` in the model but stop reading or writing it.**
Delete the `readingMode: ReadingMode` computed accessor so no code references it.
The DB column becomes inert. Document this with a comment:
```swift
// Legacy — superseded by ReaderPreferences.shared.defaultReadingMode (global override).
// Not removed to avoid SwiftData migration. Never read or written.
var readingModeRaw: String = "scroll"
```

---

## Section I — Search: Autocomplete, Prefix Syntax, Full-Text Search

Split into three sub-sessions: I1 (query parser + prefix stacking), I2 (autocomplete UI),
I3 (FTS5 integration). Confirm each builds before starting the next.

### I1 — Search Query Parser

The search field currently passes a raw string to `CalibreLibrary.fuzzyTitleCondition(for:)`.
The new parser sits in front of that and intercepts prefix tokens before they reach the
fuzzy search. Non-prefixed tokens still go through `fuzzyTitleCondition`.

**`Database/SearchQueryParser.swift`** (new file)

```swift
/// Parses a free-form search string into structured tokens.
///
/// Supported syntax:
///   tag:action              → books whose tag list contains "action"
///   author:rowling          → books whose author name contains "rowling"
///   title:goblet            → books whose title contains "goblet"
///   tag:action author:jo    → AND logic: both conditions must match
///   goblet fire             → plain fuzzy title/author search (unchanged)
///   tag:action goblet       → tag filter AND plain fuzzy on "goblet"
///
/// Prefix tokens stack additively. They also combine additively with any
/// active FilterDrawer rules (the caller merges them into the same SQL).
struct SearchQuery {
    let tagTerms:     [String]   // one SQL LIKE condition per term
    let authorTerms:  [String]
    let titleTerms:   [String]
    let plainTerms:   [String]   // remainder → fuzzyTitleCondition per term
    var isEmpty: Bool {
        tagTerms.isEmpty && authorTerms.isEmpty && titleTerms.isEmpty && plainTerms.isEmpty
    }
}

struct SearchQueryParser {

    static func parse(_ input: String) -> SearchQuery {
        var tags: [String] = [], authors: [String] = [],
            titles: [String] = [], plain: [String] = []

        // Tokenise on whitespace. Quoted values ("foo bar") treated as one token.
        let tokens = tokenise(input)

        for token in tokens {
            if let value = token.dropPrefix("tag:"),    !value.isEmpty { tags.append(value) }
            else if let value = token.dropPrefix("author:"), !value.isEmpty { authors.append(value) }
            else if let value = token.dropPrefix("title:"),  !value.isEmpty { titles.append(value) }
            else if !token.isEmpty { plain.append(token) }
        }
        return SearchQuery(tagTerms: tags, authorTerms: authors,
                           titleTerms: titles, plainTerms: plain)
    }

    /// Splits on whitespace, honouring double-quoted phrases.
    private static func tokenise(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        for ch in input {
            if ch == "\"" { inQuote.toggle() }
            else if ch == " " && !inQuote {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else { current.append(ch) }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        guard lowercased().hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
```

**`Database/CalibreLibrary.swift`** — update `_fetchBooks` and `bookCount`

Add a new internal method that takes a `SearchQuery` instead of a raw `String`:

```swift
func books(offset: Int, limit: Int, sort: SortField, ascending: Bool,
           query: SearchQuery) -> [CalibreBook]
```

Build the SQL WHERE clause from the query:

```swift
private func whereClause(for query: SearchQuery) -> (String, [Binding?]) {
    var clauses: [String] = []
    var args: [Binding?]  = []

    // tag: terms — each requires a subquery or join
    for term in query.tagTerms {
        clauses.append("""
            EXISTS (
                SELECT 1 FROM books_tags_link btl2
                JOIN tags t2 ON t2.id = btl2.tag
                WHERE btl2.book = b.id AND LOWER(t2.name) LIKE ?
            )
            """)
        args.append("%\(term.lowercased())%" as Binding?)
    }

    // author: terms
    for term in query.authorTerms {
        clauses.append("""
            EXISTS (
                SELECT 1 FROM books_authors_link bal2
                JOIN authors a2 ON a2.id = bal2.author
                WHERE bal2.book = b.id AND LOWER(a2.name) LIKE ?
            )
            """)
        args.append("%\(term.lowercased())%" as Binding?)
    }

    // title: terms
    for term in query.titleTerms {
        clauses.append("LOWER(b.title) LIKE ?")
        args.append("%\(term.lowercased())%" as Binding?)
    }

    // plain terms — existing fuzzy title logic
    if !query.plainTerms.isEmpty {
        let joined = query.plainTerms.joined(separator: " ")
        let (fuzzyClause, fuzzyArgs) = CalibreLibrary.fuzzyTitleCondition(for: joined)
        clauses.append(fuzzyClause)
        args.append(contentsOf: fuzzyArgs)
    }

    if clauses.isEmpty { return ("", []) }
    return (clauses.joined(separator: " AND "), args)
}
```

Update `_fetchBooks` to call `whereClause(for:)` when a `SearchQuery` is present.
Maintain the existing `String?` overload for backwards compatibility — it wraps the
string in `SearchQueryParser.parse()` before delegating to the new path.

**`LibraryUI/BookGridItem.swift`** (and `LibraryToolbarState.swift` once D1 is built)

Parse the search text on every debounce tick before passing to `loadPage`:

```swift
private func loadPage() {
    let query = SearchQueryParser.parse(searchText)
    // Pass query to library.books(offset:limit:sort:ascending:query:)
    ...
}
```

Prefix tokens stack additively with `activeFilterResult`. The `FilterBuilder` produces a
list of calibre IDs; the new search layer then filters those IDs further using the WHERE
clause from `whereClause(for:)`. Concretely, when `activeFilterResult` is non-nil, use
`library.books(ids: result.calibreIDs, ..., query: query)` — add the query WHERE clause
as an additional AND condition inside the existing `ids`-based query.

### I2 — Autocomplete Suggestions

**Rules from design review:**
- Tag suggestions: appear while typing plain text (before any prefix), showing matching
  tags from the library.
- Author suggestions: appear only after the user types `author:` prefix.
- Title suggestions: appear only after the user types `title:` prefix.
- Plain text shows tag suggestions only (not author or title — those are too numerous
  and noisy).

**`Database/CalibreLibrary.swift`** — add three suggestion methods:

```swift
/// Tags whose name contains `prefix`, up to `limit` results.
/// Used for autocomplete. Sorted by frequency (most-used tags first).
func tagSuggestions(prefix: String, limit: Int = 8) -> [String] {
    guard !prefix.isEmpty else { return [] }
    let sql = """
        SELECT t.name, COUNT(btl.book) AS freq
        FROM tags t
        JOIN books_tags_link btl ON btl.tag = t.id
        WHERE LOWER(t.name) LIKE ?
        GROUP BY t.id
        ORDER BY freq DESC
        LIMIT ?
        """
    let rows = (try? db.prepare(sql, ["%\(prefix.lowercased())%" as Binding?,
                                       limit as Binding?]).map { $0 }) ?? []
    return rows.compactMap { $0[0] as? String }
}

/// Author names containing `prefix`, up to `limit` results.
func authorSuggestions(prefix: String, limit: Int = 8) -> [String] {
    guard !prefix.isEmpty else { return [] }
    let sql = """
        SELECT a.name FROM authors a
        WHERE LOWER(a.name) LIKE ?
        ORDER BY a.sort
        LIMIT ?
        """
    let rows = (try? db.prepare(sql, ["%\(prefix.lowercased())%" as Binding?,
                                       limit as Binding?]).map { $0 }) ?? []
    return rows.compactMap { $0[0] as? String }
}

/// Book titles containing `prefix`, up to `limit` results.
func titleSuggestions(prefix: String, limit: Int = 8) -> [String] {
    guard !prefix.isEmpty else { return [] }
    let sql = "SELECT title FROM books WHERE LOWER(title) LIKE ? ORDER BY title LIMIT ?"
    let rows = (try? db.prepare(sql, ["%\(prefix.lowercased())%" as Binding?,
                                       limit as Binding?]).map { $0 }) ?? []
    return rows.compactMap { $0[0] as? String }
}
```

**`LibraryUI/SearchSuggestionsView.swift`** (new SwiftUI file)

A floating overlay List shown below the search field when suggestions are available.
Presented as a `.popover` or absolutely-positioned overlay — do NOT use `NSPopover`
(which requires an anchor view); use a SwiftUI overlay with `ZStack` alignment.

```swift
struct SearchSuggestionsView: View {
    let suggestions: [SearchSuggestion]
    let onSelect: (SearchSuggestion) -> Void

    var body: some View {
        if suggestions.isEmpty { EmptyView() } else {
            VStack(spacing: 0) {
                ForEach(suggestions) { s in
                    Button { onSelect(s) } label: {
                        HStack {
                            Image(systemName: s.kind.icon).foregroundStyle(.secondary)
                            Text(s.displayText)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider()
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 8)
            .frame(maxWidth: 380)
        }
    }
}

struct SearchSuggestion: Identifiable {
    let id = UUID()
    let kind: SuggestionKind
    let value: String      // the tag/author/title name

    var displayText: String { value }

    /// When selected, this text is appended/inserted into the search field.
    /// Tags are inserted as plain text (no prefix); authors/titles get their prefix.
    var insertText: String {
        switch kind {
        case .tag:    return value
        case .author: return "author:\"\(value)\""
        case .title:  return "title:\"\(value)\""
        }
    }
}

enum SuggestionKind {
    case tag, author, title
    var icon: String {
        switch self {
        case .tag:    return "tag"
        case .author: return "person"
        case .title:  return "book"
        }
    }
}
```

**Suggestion logic in `LibraryRootView` (or `LibraryToolbarState`):**

On every `searchText` change (debounced, 150 ms — faster than the page-load debounce):

```swift
private func updateSuggestions() {
    guard let library = session.library else { suggestions = []; return }
    let q = searchText

    // Detect which prefix (if any) the cursor is in
    if let prefix = q.activePrefixValue(for: "author:") {
        suggestions = library.authorSuggestions(prefix: prefix)
            .map { SearchSuggestion(kind: .author, value: $0) }
    } else if let prefix = q.activePrefixValue(for: "title:") {
        suggestions = library.titleSuggestions(prefix: prefix)
            .map { SearchSuggestion(kind: .title, value: $0) }
    } else {
        // Plain text — show tag suggestions for the last word typed
        let lastWord = q.components(separatedBy: .whitespaces).last ?? ""
        if lastWord.count >= 2 {
            suggestions = library.tagSuggestions(prefix: lastWord)
                .map { SearchSuggestion(kind: .tag, value: $0) }
        } else {
            suggestions = []
        }
    }
}
```

`activePrefixValue(for:)` is a `String` extension that returns the typed value after the
last occurrence of the given prefix in the string, or `nil` if that prefix isn't present.

When the user selects a suggestion, `onSelect` inserts `suggestion.insertText` into the
search string appropriately (replacing the triggering fragment), then clears the suggestion list.

### I3 — Full-Text Search (FTS5)

**Architecture:** `CalibreFTSLibrary` is a separate, optional connection to
`full-text-search.db` in the same directory as `metadata.db`. It is opened lazily and
silently dropped if the file doesn't exist or is structurally invalid. The caller (search
path) never knows or cares whether FTS was used.

**`Database/CalibreFTSLibrary.swift`** (new file)

```swift
/// Optional read-only connection to Calibre's full-text-search.db.
/// Returns nil from the initialiser if the file doesn't exist or
/// lacks the expected FTS5 tables — caller falls back to SQL LIKE search.
final class CalibreFTSLibrary {

    private let db: Connection

    init?(libraryURL: URL) {
        let ftsURL = libraryURL.appendingPathComponent("full-text-search.db")
        guard FileManager.default.fileExists(atPath: ftsURL.path),
              let conn = try? Connection(ftsURL.path, readonly: true)
        else { return nil }

        // Validate that the expected tables exist
        let tables = (try? conn.prepare("SELECT name FROM sqlite_master WHERE type='table'")
            .map { $0[0] as? String ?? "" }) ?? []
        guard tables.contains("books_fts") && tables.contains("books_fts_map")
        else { return nil }

        self.db = conn
    }

    /// Returns calibre book IDs whose full text matches the query.
    /// Uses FTS5 MATCH syntax: multi-word queries use implicit AND.
    /// Returns nil on any error — caller falls back to LIKE search.
    func search(query: String, limit: Int = 500) -> [Int]? {
        // Sanitise query for FTS5 MATCH: remove special chars, wrap in quotes
        let sanitised = query
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"" }         // quote each word to prevent FTS5 syntax errors
            .joined(separator: " ")
        guard !sanitised.isEmpty else { return nil }

        let sql = """
            SELECT m.book FROM books_fts_map m
            JOIN books_fts ON books_fts.rowid = m.id
            WHERE books_fts MATCH ?
            LIMIT ?
            """
        return try? db.prepare(sql, [sanitised as Binding?, limit as Binding?])
            .compactMap { row -> Int? in
                guard let v = row[0] else { return nil }
                if let i = v as? Int64 { return Int(i) }
                if let i = v as? Int   { return i }
                return nil
            }
    }
}
```

**`Database/LibrarySession.swift`**

Add an optional `ftsLibrary: CalibreFTSLibrary?` property. Initialise it in `open(url:)`
after the main `CalibreLibrary` connection succeeds:

```swift
ftsLibrary = CalibreFTSLibrary(libraryURL: url)
```

Set to `nil` in the close path.

**Integration into search flow — `LibraryUI/BookGridItem.swift` (or `loadPage`)**

When `plainTerms` is non-empty, attempt FTS before falling back to SQL LIKE:

```swift
private func resolvedQuery(_ query: SearchQuery) -> SearchQuery {
    guard !query.plainTerms.isEmpty,
          let fts = session.ftsLibrary
    else { return query }

    let plainText = query.plainTerms.joined(separator: " ")
    guard let ftsIDs = fts.search(query: plainText), !ftsIDs.isEmpty else {
        return query   // FTS returned nothing or failed — use LIKE fallback
    }

    // Replace plain terms with an explicit ID constraint.
    // Return a modified query with no plain terms (they've been resolved to IDs)
    // and store the FTS IDs for the caller to pass as an id-set filter.
    // Implementation: expose ftsMatchedIDs on the resolved query.
    return SearchQuery(tagTerms: query.tagTerms, authorTerms: query.authorTerms,
                       titleTerms: query.titleTerms, plainTerms: [],
                       ftsMatchedIDs: ftsIDs)
}
```

Add `ftsMatchedIDs: [Int]?` to `SearchQuery`. When non-nil, `loadPage` intersects these
IDs with the active filter result IDs (if any) and passes the intersection to
`library.books(ids:...)`.

**FTS-specific behaviour:**
- FTS is only used for `plainTerms`. Prefix-syntax tokens (`tag:`, `author:`, `title:`)
  always go through SQL.
- If FTS returns >500 results, truncate to 500 and let the SQL WHERE clause refine further.
- If FTS search errors (corrupt DB, schema mismatch), `CalibreFTSLibrary.search` returns
  `nil` and `resolvedQuery` returns the original query unchanged — LIKE fallback fires
  transparently.
- `full-text-search.db` is opened **read-only**. No write PRAGMAs ever.

**Invariant to add** (Section I3 specific):
> `CalibreFTSLibrary` opened `readonly: true`. Never write to it. Never PRAGMA it.
> Search returns nil on any error — caller always has a LIKE fallback.

---

## Updated implementation order

| Session | Section | Size |
|---|---|---|
| 8A | A — Custom column bug fix | Small |
| 8B | F — NOT filter chip; G — Dock reopen | Small |
| 8C-1 | B1 — Context menu | Small |
| 8C-2 | B2 — Unified annotation model + sidebar + popover | Large |
| 8D | C — Font picker + reload strategy | Medium |
| 8E-1 | D1 — LibraryToolbarState + NSToolbar | Medium |
| 8E-2 | D2 — Email view | Large |
| 8E-3 | D3 — Grid view + cover art | Medium |
| 8F | E — Window size preference | Small |
| 8G | H — Pagination mode toggle in Settings | Small |
| 8H-1 | I1 — SearchQueryParser + prefix SQL | Medium |
| 8H-2 | I2 — Autocomplete suggestions UI | Medium |
| 8H-3 | I3 — FTS5 integration | Medium |
