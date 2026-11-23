# Library UI

Scope: the app's window/view-controller shell and the three library display
modes (list, email, ranking) plus collections. For search-bar parsing and
the filter drawer/popup engines, see `search-and-filter.md`. For the LRU
caches and cross-surface reload coordination, see `caching.md`.

---

## Application Structure

```
AmbrosiaApp
├── AppDelegate
│   └── LibraryWindowController
│       ├── native NSToolbar -> LibraryToolbarState
│       └── LibraryViewController
│           ├── LibraryRootView              [list mode]
│           ├── EmailLibraryViewController   [split email mode]
│           └── ActivityFeedView             [ranking mode]
└── ReaderWindowController
    └── ReaderViewController -> WKWebView
```

`LibraryToolbarState` bridges native toolbar controls and SwiftUI/AppKit content. It carries search, sort, filter, view state, and trigger booleans for sheets/actions.

---

## Modes

- List: SwiftUI AO3-style rows with title, series, authors, tags, stats, description, and pagination. Querying, filtering, sorting, paging, series grouping, and metadata hydration are managed by `LibraryDisplayController.swift`. `LibraryRootView.swift` acts as a declarative presentation shell; row rendering is split out into `BookListRow.swift` and `SeriesListRow.swift`; shared layout and series-grouping helpers (`FlowLayout`, `isAnthology`, `missingIndices`, `parseISODate`, `logMissingVisibleWorkMetadata`) live in `FlowLayout.swift`. These helpers and the row-support types (`LibraryStats`, `LibraryStatsRow`, `TagPillDisplay`) are intentionally `internal`, not `private`, because more than one row file depends on them — see Invariant 16. Action buttons (Liked, Read Later) update optimistically with 24×24 pt hit areas; persistence, version invalidation, and refresh are debounced and batched per collection. Reading progress (% read) is placed compactly inline inside the stats row (`LibraryStatsRow`) to prevent vertical row jitter during loading.
- Email: AppKit split view with table sidebar and SwiftUI detail pane, also powered by `LibraryDisplayController.swift`.
- Ranking: `ActivityFeedView` (reading activity feed), designed with a compact, native AppKit layout with subtle separators and condensed 2/3-line entries wasting no unnecessary white space. `BookState` already has ELO fields for a future ranking surface.

## Row height bounds

List-mode rows are self-sizing, so unbounded content makes row height unpredictable. Book and series rows share `RowDescriptionContent` and `RowDescriptionPreview`:

- Individual previews are capped at 1,500 characters and 10 rendered lines. Series previews use final `SeriesGroup.works` order, label each work, cap each description at 400 characters, and cap the combined preview at 1,500 characters and 10 lines (ellipsis included in each character limit). Empty descriptions are omitted. Full descriptions remain unchanged in `CalibreBook.displayComment`.
- A `More…` button appears when the character cap or rendered-line cap truncates the preview. Line clipping is measured against a hidden unconstrained text copy only for longer previews. The popover shows the full description; series entries retain their work headings and support text selection. The preview stays line-bounded, so long descriptions do not expand the row without limit.
- Tag pills are capped at `TagPillDisplay.maxVisible` (30) per `BookListRow` and `TagPillDisplay.maxVisibleSeries` (30) per `SeriesListRow` (a series row shows the union of its works' tags, so it needs its own knob); the rest collapse into one non-interactive "+N" pill whose help text lists the hidden labels. Pill order from `TagPillDisplay.make` / `makeForSeries` puts rating, fandom, relationship and character first, so those survive. Single-book rows display visual markers for the author's first-listed relationship (`heart.fill` icon) and first-listed character (`person.fill` icon) with semibold typography and full accessibility labels; series rows do not display first-listed markers. Set either cap to `Int.max` to disable. There is no per-row expand state, because a row that grows on click reintroduces height variance.
- Ungrouped page loads assign `items` and `ao3Metadata` (plus `ao3ExtractionDiagnostics`, `singletonSeriesWarnings`, `rebuildDegraded`) together in one `MainActor.run`, via `rebuildItems()`, so rows do not render bare and then grow when metadata arrives. This mirrors the grouped `rebuildTask`. `items` is not cleared beforehand, so the previous page stays visible until the swap. A page turn therefore waits for the metadata query before showing rows.
- `rebuildItems()` owns the page metadata fetch for non-empty pages in both modes; `loadPage` no longer calls `loadAO3MetadataForCurrentPage()` after it (that was a duplicate fetch in grouped mode, confirmed by reading the grouped `rebuildTask`). The loader is still called for empty-result branches, by the extraction-refresh `onChange`, and from `rebuildItems()`'s synchronous fallback (no metaDB or library) when the page is non-empty.
- `rootContent` shows "Loading" whenever `items` is empty and `books` is not, in both modes (previously grouped only).
- The list is no longer a `List`: `itemList` is `ScrollViewReader { ScrollView { VStack { ForEach(items) { row; Divider() } } } }`. All rows of a page (at most 25) are built once and kept, avoiding NSTableView row recycling and re-measurement on scroll-up. Rows carry their own 16/10 point padding (formerly `listRowInsets`), and `BookListRow`/`SeriesListRow` extend their frame to full width so the double-click hit area is unchanged. When the first item id changes and the view identity (library, page, sort, direction, grouping, search text, filter, visibility signature; `scrollResetKey`) differs from the one last scrolled for, the list scrolls to the top. The same identity with new rows, which is what a silent revalidation produces, keeps the scroll position. Side effect: reloading the same page after a local change (for example skipping the first book) no longer scrolls to the top. The scroll view draws `controlBackgroundColor` behind the rows to match the surface `List` used to provide (uncolored tag pills fill with the same color). `LazyVStack` was not used because its row retention was not verified.
- Known residual: `bookStates` is still assigned synchronously before the swap and drives the "% read" chip. If the list surface is torn down while a rebuild is in flight, `items` is not assigned; this was already true for grouped mode and now applies to ungrouped mode too.

## Toolbar Controls

`LibraryWindowController` configures the native `NSToolbar` (`LibraryToolbar6`), which includes:
- Sidebar toggle (`librarySidebarToggle`)
- Library title (`libraryTitle`)
- Search bar item (`librarySearch` - titles, tags, scoped search)
- Full-Text Search button (`libraryFTSSearch` - `doc.text.magnifyingglass` icon, opens `FTSSearchResultsWindowController`)
- Filter drawer toggle (`libraryFilter`)
- Sort menu (`librarySort`)
- Collections sheet toggle (`libraryCollections`)
- Reading goal sheet (`libraryReadingGoal`)
- Export menu (`libraryExport`)
- View mode switcher (`libraryViewMode` - List, Email, Ranking)

### Sort Controls and Direction State
- **Sort Direction & Random Mode**: Sort direction (Ascending / Descending) in the toolbar and filter popup is disabled in `.random` sort mode (randomized order is reshuffled via the Reshuffle affordance instead).
- **Numeric Sort Defaults (D3)**: Entering `.wordCount` or `.kudos` sort defaults direction to descending (`ascending = false`), restoring the previous non-numeric direction upon switching back to title, author, or other non-numeric sorts.
- **Last View Priority**: Persisted `LastViewState` restored on launch overrides defaults and preserves the user's saved sort field and direction.

## Menu Bar Integrations

The macOS menu bar adapts to whether the user is browsing the library or reading:
- **Reader ▸ Get Info… (`⌘I`)**: Opens the modal "Get Info" sheet (`BookInfoViewController`) for the currently active book in the reader window or email view. Automatically disabled when browsing the library in list view where rows are non-selectable.
- **Edit ▸ Find (`⌘F`)**: Dynamically routes to the library search bar (`focusSearchField`) when in the library window, or activates the reader find bar when a reader window is focused.
- **View ▸ Appearance**: Configures library window theme (`Follow System`, `Always Light`, `Always Dark`) via `ReaderPreferences.libraryAppearanceMode` and provides a quick `Toggle Dark/Light Mode` shortcut (`^⌘T`).
- **View ▸ Reload Library (`⌘R`)**: Manually triggers a snapshot refresh of the library list and email views via `AppDelegate.reloadCurrentLibrary()`.
- **View ▸ Clear All Filters**: Quickly resets active facet and text filters when a filter is applied.
- **Reader Menu Gating**: Navigation (`⌘←`/`⌘→`, `⌘[`/`⌘]`), annotations, table of contents, and window sizing actions are dynamically disabled when no reader window or embedded reader is active (`AppDelegate.hasActiveReader`). In-reader formatting and theme settings are grouped under `Reader Text & Themes`.

## Row Context Menus & Row Selection

In List View, rows (`BookListRow`, `SeriesListRow`) are intentionally **non-selectable** to allow frictionless scrolling and single-click interaction with tags, authors, and bookmark/star toggles without row highlight artifacts. Selection is supported only in Email View's sidebar table.

Row titles are link-style buttons (`RowTitleButton`): a single click opens the work or series, with a pointing-hand cursor and hover underline. Double-clicking blank row space also opens it; that gesture is attached to a `Color.clear` layer in `.background` of the row, so buttons, tag/author controls, and popover triggers never see it. Title, tag, and author controls act on the first click of a multi-click only (`RowClickPolicy`, based on `NSApp.currentEvent.clickCount`), because the first click can reload the list and the second would land on a different element. A double-click on a tag or author therefore applies its filter once, and a double-click on the title opens once. Applying an already-active tag or author rule is also a no-op and does not reapply the query. The background-layer hit testing and click-count behavior are Unverified until checked on macOS.

Book and series rows support macOS right-click / secondary-click context menus across all library modes (`BookListRow`, `SeriesListRow`, and `EmailSidebarViewController`):
- **Reveal in Finder**: Resolves the book's EPUB file URL via `CalibreLibrary.epubURL(for:)` and highlights it in macOS Finder (`AppDelegate.revealInFinder`).
- Collection assignments (Read Later, Liked, Skipped, Finished, In Progress, custom collections).
- Open in Reader / Open in External Reader.

Mark Read, Reset Progress and Remove from Collection are implemented once in `CollectionAssignment` (`markRead`, `resetProgress`, `removeFromCollection`) and called by both `LibraryRootView` and `EmailLibraryViewController`; each view only supplies its own refresh callback.

## Modal Sheets Architecture

All modal library dialogs (`CollectionsView`, `ReadingGoalView`, `ErrorLogView`, `RSSPublishWarningView`, `ManageFeedsView`) are managed and presented centrally as AppKit modal sheets on `LibraryWindowController` (`window.beginSheet`), rather than via multiple SwiftUI `.sheet(isPresented:)` modifiers. This guarantees clean, single-animation presentation and deterministic dismissal without bouncing or re-opening.

## Filter Drawer Dismissal

The filter drawer sheet (`FilterDrawerView`) is presented by one zero-size hosting view owned by `LibraryViewController`, shared across list, email, and ranking modes. Inactive mode views stay mounted, so attaching a sheet to each surface would create competing presenters for the shared `showFilterDrawer` state.

The filter drawer supports cancellation and dismissal:
- Close button in header with `.help("Close (Esc)")`; the shared `.preventInitialButtonFocus()` modifier clears the automatic initial button highlight, and Escape is handled by `.onExitCommand` rather than assigning a keyboard shortcut to the X button.
- Dedicated **Cancel** button in the footer alongside Apply and Clear All.
- Close, Cancel, Apply, Clear All, and Escape all dismiss through one owner callback that sets `showFilterDrawer = false`; the sheet does not mix environment dismissal with presentation-state changes.

### Filter Drawer Sizing & Controls
- **Modal Dimensions**: Fixed `width: 720 pt` and `maxHeight: 460 pt`. This expanded width provides ample horizontal space for multi-control rows (position preset picker and variants toggle) alongside the value autocomplete text field without horizontal clipping or squishing.
- **Position Fields Controls**: For `firstRelationship` and `firstCharacter`, rows display a preset picker (First, First 2, First 3, First 5; defaulting to 1 for relationships, 3 for characters) and a "Variants" checkbox toggle (`matchVariants`).
- **Relationship Count Controls**: Displays a numeric text field (`relationshipCount >= 1`) and the "Variants" checkbox toggle.
- **Field Switch Reset**: Changing a row's field to any standard field resets `limit` and `matchVariants` to nil.

### Filter Ribbon Pills & Context Menus
- **Pill Display**: Rendered with `rule.displayLabel` ("First-listed relationship", "Relationship in first N", "Character in first N", "Relationship count", with " (variants)" appended when enabled).
- **Context Menu Conversions**:
  - On `.tag` pills (`is` / `is not`): offers "Match as First-Listed Relationship" or "Match as First-Listed Character" if the tag matches that role in `book_tags`.
  - On position pills: offers "Match Anywhere" (converting back to `.tag` and dropping limit/variants) and an "Include Tag Variants" toggle.
  - On relationship count pills: offers the "Include Tag Variants" toggle.

- System collections live in `ambrosia_meta.db`.
- `Series or Merged` is system-maintained from `series_cache` and anthology detection.
- Series grouping uses representative grouped rows for collapsed series.

## Export

CSV export of library books through `ExportManager`.

`ExportManager.exportScope(for:)` turns the active `FilterResult` into an
`ExportScope`: `.unrestricted` (no result), `.sqlFilter` (SQL-backed), `.ids` (explicit
IDs) or `.empty`. An explicit result with no IDs means zero matches, so
`buildExportRows` returns no rows for `.empty` and the EPUB flow shows "Nothing to
Export" instead of exporting the whole library. Export does not apply
`LibraryVisibilityPolicy`; whether it should is an open product question.

## Error Log

`ErrorLogView` (sheet, presented from the Export menu's "Error Log…" item)
lists `error_log` rows via `AmbrosiaMetaDB.recentErrors` — see
`metadb-and-migrations.md` for the table/actor methods. Kept as its own
sheet rather than folded into `ActivityFeedView` since most entries aren't
book-linked and errors aren't a user-facing "activity" the way
sessions/annotations/collection changes are.

---

## Key invariant

16. `private` on a top-level type or function scopes it to the declaring *file*, not the module. Before marking a shared row-rendering type (e.g. `LibraryStats`, `TagPillDisplay`) or a shared free function (e.g. `isAnthology`, `missingIndices`, `parseISODate`, `logMissingVisibleWorkMetadata`) as `private`, grep the rest of the target for usages. If more than one file needs it, it is `internal` (the default — omit the modifier), not `private`. When splitting a fat view file into per-row files, this check is mandatory, not optional: it is the single most common source of "Cannot find X in scope" after a file split. Do not create a second, duplicate `private` copy of a helper in a new file as a workaround — that produces an "Invalid redeclaration" error the moment the original is later widened to `internal`, and it leaves two copies to keep in sync.

## Incident notes: LibraryUI row split (build-breakage retro)

The split of `LibraryRootView`'s row rendering into `BookListRow.swift`, `SeriesListRow.swift`, and `FlowLayout.swift`, plus the addition of tag-synonym expansion (`tagExpansions`) to the filter pipeline, shipped with ten-plus build errors across five files. None were logic bugs; all were consistency failures between files — a type renamed in one place and not another, a function declaration deleted while its body survived, helpers left `private` after being split out from their original file, an async closure called without `await`, a parameter threaded through eight method signatures instead of stored once. None of these would have survived a single green `xcodebuild build` run before merge. Invariants 16-21 below exist to keep the next multi-file refactor from repeating this; Invariant 21 (a build gate before merge) is the cheapest one and should be treated as non-negotiable. See `concurrency-invariants.md` for Invariants 17-20; Invariant 21 (the build gate) is repo-wide and lives in `concurrency-invariants.md` as well.


## Load serialization

The list surface starts every page load through `scheduleLoadPage()` (see Invariant 25). Book states for the visible page are refreshed at the end of each `loadPage`, so paging keeps read progress. `refreshVisibilitySnapshots(resetPage:)` keeps the current page only when the surface is ungrouped and not in random order, because recorded grouped offsets and random seeds are invalid after a membership change.

## Surface ownership

The list `NSHostingView` stays alive while hidden, so its handlers must not act when it is not the live surface.

- The three export triggers (`triggerExport`, `triggerEPUBExport`, `triggerAnnotationExport`) are ignored by the list while `isListSurfaceTornDown` is true. Email and ranking each own their own copies and clear the flag they handle. `ActivityFeedView` clears all three because it has nothing to export.
- `LibraryViewController` clears `filterCommitHandler` when it hides the list, and the list re-registers it from `.onChange(of: isListSurfaceTornDown)` as well as `.onAppear`, because SwiftUI may not call `.onAppear` when a hidden hosting view is shown again. Whether it does is gate L1 (not yet run).
- `applyViewMode` ignores a repeated mode so a same-value observation callback does not rebuild a surface.

Series Like and Read Later buttons operate on the stable series identity in
grouped List, Email, and series Reader views. Their states distinguish none,
partial, and full membership. A work-level unlike inserts exclusions for each
flagged series that covers the work; it never writes inherited membership as
an explicit work flag. Name-only series cannot be flagged. The series Reader
toolbar and Reader menu expose series actions only for a series reading target,
and its window subtitle follows the active work.

## First-load gating

`LibraryRootView.loadPage` and `EmailLibraryViewController.loadPage` return immediately while `session.snapshotsReady` is false. When the session posts `.librarySnapshotsDidBecomeReady` each surface seeds its local membership sets from `session.cached*` and schedules the real first load. A surface mounted after the session is ready (a mode switch) behaves as before. Do not add a new first-load trigger that bypasses the guard; before the guard existed the first page loaded with empty visibility sets and was rebuilt by a second load when the Series or Merged sync notification arrived.

## Empty and count states

- Before the first load of an open library finishes, the list shows "Loading". After it, an empty unfiltered list shows either "This library has no books" or "All books are hidden by your settings" (with a Preferences button).
- The footer total is `visibleTotalCount` (visibility-aware) in every mode, computed by `CalibreLibrary.visibleBookCount`. `GroupAwareCountCacheKey` includes `shouldGroupSeriesRows` because that count now runs in ungrouped mode too.


### Last view restore

On open, `LibrarySession.loadLastView` reads the stored `LastViewState` (sort, direction, filter; `UserDefaults` key `lastView.<libraryHash>`, so it survives a cache purge) and validates it (`LastViewValidator`: rules naming a missing collection and `fulltext` rules are dropped, incomplete rows are dropped, and a filter with nothing left becomes the default view). It does this after hydrating snapshots and before `snapshotsReady` flips, and hands the result over once through `takeRestoredLastView()`.

`LibraryDisplayController.applyRestoredLastViewIfNeeded` applies it from `.librarySnapshotsDidBecomeReady` (or `.onAppear` when already ready), only while the toolbar state is still the default view. A restored filter with complete rules goes through `applyFilterRules()` directly. `searchText` is not restored and `groupBySeries` keeps its own key. The shared `LibraryToolbarState` records changes (`didSet` on sort, direction, filter), debounced 0.4 s, keyed by the library hash captured when the change was made; the default view is stored as the absence of a value, so clearing the filter also clears persisted state. `LastViewStore.restoreLastView` is the rollback switch.

Known gaps: the history log, the last-view writer and the future snapshot writer do not yet share one settled-load hook; a restored filter appends one search-history entry at launch (deduped against the latest); if the library is switched without `isOpen` toggling, recording is re-pointed on the next `.librarySnapshotsDidBecomeReady`.

### Revalidation after Calibre changes

`.libraryContentsDidChange` (posted by `LibrarySession.checkForLibraryChanges`) makes `LibraryDisplayController` reload the current view in place via `refreshVisibilitySnapshots(resetPage: false)`. Paging is kept for title, word count and kudos sorts and for every ungrouped sort; the grouped SQL-drain sorts and random order reset to page 1, because their recorded offsets or seed no longer match the changed book set. A SQL-backed filter result is replaced by a fresh one so its known total is recounted; a non-SQL filter is re-applied (`applyFilterRules(resetPage:)`) because its explicit id list predates the new books. `EmailLibraryViewController` does not observe this notification yet: its `reset: false` means "load the next page", so a silent reload needs separate work. Email picks up new books on its next load.
