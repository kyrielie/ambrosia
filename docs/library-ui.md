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
│           └── placeholder                  [ranking mode]
└── ReaderWindowController
    └── ReaderViewController -> WKWebView
```

`LibraryToolbarState` bridges native toolbar controls and SwiftUI/AppKit content. It carries search, sort, filter, view state, and trigger booleans for sheets/actions.

---

## Modes

- List: SwiftUI AO3-style rows with title, series, authors, tags, stats, description, and pagination. `LibraryRootView.swift` holds paging/filtering/series-grouping orchestration; row rendering has been split out into `BookListRow.swift` and `SeriesListRow.swift`; shared layout and series-grouping helpers (`FlowLayout`, `isAnthology`, `missingIndices`, `parseISODate`, `logMissingVisibleWorkMetadata`) live in `FlowLayout.swift`. These helpers and the row-support types (`LibraryStats`, `LibraryStatsRow`, `TagPillDisplay`) are intentionally `internal`, not `private`, because more than one row file depends on them — see Invariant 16.
- Email: AppKit split view with table sidebar and SwiftUI detail pane.
- Ranking: placeholder text only; `BookState` already has ELO fields.

## Collections

- System collections live in `ambrosia_meta.db`.
- `Series or Merged` is system-maintained from `series_cache` and anthology detection.
- Series grouping uses representative grouped rows for collapsed series.

## Export

CSV export of library books through `ExportManager`.

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

