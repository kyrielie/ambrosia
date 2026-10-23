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

- List: SwiftUI AO3-style rows with title, series, authors, tags, stats, description, and pagination. Querying, filtering, sorting, paging, series grouping, and metadata hydration are managed by `LibraryDisplayController.swift`. `LibraryRootView.swift` acts as a declarative presentation shell; row rendering is split out into `BookListRow.swift` and `SeriesListRow.swift`; shared layout and series-grouping helpers (`FlowLayout`, `isAnthology`, `missingIndices`, `parseISODate`, `logMissingVisibleWorkMetadata`) live in `FlowLayout.swift`. These helpers and the row-support types (`LibraryStats`, `LibraryStatsRow`, `TagPillDisplay`) are intentionally `internal`, not `private`, because more than one row file depends on them — see Invariant 16.
- Email: AppKit split view with table sidebar and SwiftUI detail pane, also powered by `LibraryDisplayController.swift`.
- Ranking: `ActivityFeedView` (reading activity feed). `BookState` already has ELO fields for a future ranking surface.

## Row height bounds

List-mode rows are self-sizing `List` rows, so unbounded content makes row height unpredictable. Book rows bound it as follows:

- `BookListRow.descriptionRow` renders `RowDescriptionLimit.capped(displayComment)` with `.lineLimit(RowDescriptionLimit.lines)`. Limits: 1,500 characters and 10 lines (an AO3 summary is at most 1,250 characters). Truncation happens in the view only; `CalibreBook.displayComment` is unchanged because `isDescriptionAnthology` reads it. Narrow windows or many paragraph breaks can clip at line 10; that is accepted.
- `SeriesListRow` keeps its existing 4 line description limit.
- Tag pills are capped at `TagPillDisplay.maxVisible` (30) per `BookListRow` and `TagPillDisplay.maxVisibleSeries` (30) per `SeriesListRow` (a series row shows the union of its works' tags, so it needs its own knob); the rest collapse into one non-interactive "+N" pill whose help text lists the hidden labels. Pill order from `TagPillDisplay.make` / `makeForSeries` puts rating, fandom, relationship and character first, so those survive. Set either to `Int.max` to disable. There is no per-row expand state, because a row that grows on click reintroduces height variance.
- Ungrouped page loads assign `items` and `ao3Metadata` (plus `ao3ExtractionDiagnostics`, `singletonSeriesWarnings`, `rebuildDegraded`) together in one `MainActor.run`, via `rebuildUngroupedItems`, so rows do not render bare and then grow when metadata arrives. This mirrors the grouped `rebuildTask`. `items` is not cleared beforehand, so the previous page stays visible until the swap. A page turn therefore waits for the metadata query before showing rows.
- `rebuildItems()` owns the page metadata fetch for non-empty pages in both modes; `loadPage` no longer calls `loadAO3MetadataForCurrentPage()` after it (that was a duplicate fetch in grouped mode, confirmed by reading the grouped `rebuildTask`). The loader is still called for empty-result branches, by the extraction-refresh `onChange`, and from `rebuildItems()`'s synchronous fallback (no metaDB or library) when the page is non-empty.
- `rootContent` shows "Loading" whenever `items` is empty and `books` is not, in both modes (previously grouped only).
- The list is no longer a `List`: `itemList` is `ScrollViewReader { ScrollView { VStack { ForEach(items) { row; Divider() } } } }`. All rows of a page (at most 25) are built once and kept, avoiding NSTableView row recycling and re-measurement on scroll-up. Rows carry their own 16/10 point padding (formerly `listRowInsets`), and `BookListRow`/`SeriesListRow` extend their frame to full width so the double-click hit area is unchanged. When the first item id changes and the view identity (library, page, sort, direction, grouping, search text, filter, visibility signature; `scrollResetKey`) differs from the one last scrolled for, the list scrolls to the top. The same identity with new rows, which is what a silent revalidation produces, keeps the scroll position. Side effect: reloading the same page after a local change (for example skipping the first book) no longer scrolls to the top. The scroll view draws `controlBackgroundColor` behind the rows to match the surface `List` used to provide (uncolored tag pills fill with the same color). `LazyVStack` was not used because its row retention was not verified.
- Known residual: `bookStates` is still assigned synchronously before the swap and drives the "% read" chip. If the list surface is torn down while a rebuild is in flight, `items` is not assigned; this was already true for grouped mode and now applies to ungrouped mode too.

## Collections

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

The list surface starts every page load through `scheduleLoadPage()` (see Invariant 25). Book states for the visible page are refreshed at the end of each `loadPage`, so paging keeps read progress. `refreshMembershipSnapshots(reload:)` mirrors session snapshots without forcing a load; `refreshVisibilitySnapshots(resetPage:)` keeps the current page only when the surface is ungrouped and not in random order, because recorded grouped offsets and random seeds are invalid after a membership change.

## Surface ownership

The list `NSHostingView` stays alive while hidden, so its handlers must not act when it is not the live surface.

- The three export triggers (`triggerExport`, `triggerEPUBExport`, `triggerAnnotationExport`) are ignored by the list while `isListSurfaceTornDown` is true. Email and ranking each own their own copies and clear the flag they handle. `ActivityFeedView` clears all three because it has nothing to export.
- `LibraryViewController` clears `filterCommitHandler` when it hides the list, and the list re-registers it from `.onChange(of: isListSurfaceTornDown)` as well as `.onAppear`, because SwiftUI may not call `.onAppear` when a hidden hosting view is shown again. Whether it does is gate L1 (not yet run).
- `applyViewMode` ignores a repeated mode so a same-value observation callback does not rebuild a surface.

## First-load gating

`LibraryRootView.loadPage` and `EmailLibraryViewController.loadPage` return immediately while `session.snapshotsReady` is false. When the session posts `.librarySnapshotsDidBecomeReady` each surface seeds its local membership sets from `session.cached*` and schedules the real first load. A surface mounted after the session is ready (a mode switch) behaves as before. Do not add a new first-load trigger that bypasses the guard; before the guard existed the first page loaded with empty visibility sets and was rebuilt by a second load when the Series or Merged sync notification arrived.

## Empty and count states

- Before the first load of an open library finishes, the list shows "Loading". After it, an empty unfiltered list shows either "This library has no books" or "All books are hidden by your settings" (with a Preferences button).
- The footer total is `visibleTotalCount` (visibility-aware) in every mode, computed by `CalibreLibrary.visibleBookCount`. `GroupAwareCountCacheKey` includes `shouldGroupSeriesRows` because that count now runs in ungrouped mode too.


### Last view restore

On open, `LibrarySession.loadLastView` reads the stored `LastViewState` (sort, direction, filter; `UserDefaults` key `lastView.<libraryHash>`, so it survives a cache purge) and validates it (`LastViewValidator`: rules naming a missing collection and `fulltext` rules are dropped, incomplete rows are dropped, and a filter with nothing left becomes the default view). It does this after hydrating snapshots and before `snapshotsReady` flips, and hands the result over once through `takeRestoredLastView()`.

`LibraryRootView.applyRestoredLastViewIfNeeded` applies it from `.librarySnapshotsDidBecomeReady` (or `.onAppear` when already ready), only while the toolbar state is still the default view. A restored filter with complete rules goes through `applyFilterRules()` directly and `restoredFilterEcho` makes the `filterExpression` onChange skip its duplicate apply. `searchText` is not restored and `groupBySeries` keeps its own key. The shared `LibraryToolbarState` records changes (`didSet` on sort, direction, filter), debounced 0.4 s, keyed by the library hash captured when the change was made; the default view is stored as the absence of a value, so clearing the filter also clears persisted state. `LastViewStore.restoreLastView` is the rollback switch.

Known gaps: the history log, the last-view writer and the future snapshot writer do not yet share one settled-load hook; a restored filter appends one search-history entry at launch (deduped against the latest); if the library is switched without `isOpen` toggling, recording is re-pointed on the next `.librarySnapshotsDidBecomeReady`.

### Revalidation after Calibre changes

`.libraryContentsDidChange` (posted by `LibrarySession.checkForLibraryChanges`) makes `LibraryRootView.revalidateAfterLibraryContentsChange` reload the current view in place. Paging is kept for title, word count and kudos sorts and for every ungrouped sort; the grouped SQL-drain sorts and random order reset to page 1, because their recorded offsets or seed no longer match the changed book set. A SQL-backed filter result is replaced by a fresh one so its known total is recounted; a non-SQL filter is re-applied (`applyFilterRules(resetPage:)`) because its explicit id list predates the new books. `EmailLibraryViewController` does not observe this notification yet: its `reset: false` means "load the next page", so a silent reload needs separate work. Email picks up new books on its next load.
