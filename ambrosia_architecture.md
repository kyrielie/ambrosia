# Project Ambrosia - Architecture Overview

Concise current-state reference for AI engineers working in this repo.

## Product Shape

Ambrosia is a native macOS EPUB reader for AO3-heavy Calibre libraries.

- Target: macOS 15+.
- Calibre is the source of truth for book metadata and EPUB files.
- Calibre `metadata.db` is opened read-only and never modified.
- Publisher CSS/scripts are stripped; reader styling is fully app/user controlled.
- Reader is custom `WKWebView` + injected JavaScript. No Readium.
- No sandboxing, cloud sync, or OPDS.

## Stack

- App lifecycle/windowing: SwiftUI `App` + AppKit `NSApplicationDelegate`, `NSWindowController`, `NSViewController`.
- UI: AppKit shell with SwiftUI content hosted via `NSHostingView`/`NSHostingController`.
- Calibre DB: SQLite.swift, read-only.
- App SwiftData store: `BookState`, `ReadingGoal` only.
- Per-library app SQLite DB: `AmbrosiaMetaDB` actor, writable, under `~/Library/Application Support/Ambrosia/libraries/<hash>/ambrosia_meta.db`.
- EPUB parsing: ZIPFoundation + `NSXMLParser`.
- Rendering: `WKWebView`.
- Packages: SQLite.swift, ZIPFoundation.

## Storage Ownership

### Calibre `metadata.db`

`CalibreLibrary` owns a read-only SQLite connection to a selected library root. It is created by `LibrarySession.open(url:)` and replaced wholesale on library switch.

Important schema facts:

- `books` has no `series` column. Series requires `books_series_link -> series`.
- Authors/tags/publishers are normalized via link tables.
- Comments/descriptions live in `comments`.
- Custom columns are discovered from `custom_columns`; runtime labels come from `CustomColumnConfig.shared`.
- Every `db.prepare(sql, args)` call must use `[Binding?]`.

`CalibreLibrary.books(...)` fetches `pageSize + 1` rows for next-page detection, then bulk-loads authors/tags/comments with page-level JOIN queries.

### SwiftData

`AmbrosiaApp` creates a persistent `ModelContainer("Ambrosia")` with:

- `BookState`: keyed by `calibreID`, stores reading progress, reading position, and ELO fields.
- `ReadingGoal`: reading-goal state.

SwiftData no longer stores collections or annotations.

On SwiftData store init failure, the app shows an alert and falls back to in-memory `AmbrosiaRecovery`; it does not delete existing support files.

### Per-Library App DB

`AmbrosiaMetaDB` is an actor-backed writable SQLite DB scoped by hash of the Calibre library path. It stores:

- `collections`, `collection_members`.
- `annotations`.
- `ao3_metadata`, `series_cache`.

`CollectionStore` wraps collection operations. Bootstrapped system collections:

- Read Later
- Liked
- Skipped
- Finished
- In Progress
- Has Annotations

Annotation inserts/deletes maintain `Has Annotations` membership.

### Registry

`LibraryRegistry` stores known library paths and active path in `UserDefaults`; it is available before SwiftData is initialized.

## Session Model

`LibrarySession` is an `@Observable @MainActor` singleton injected into SwiftUI environment.

It owns:

- `library: CalibreLibrary?`
- `ftsLibrary: CalibreFTSLibrary?`
- `metaDB: AmbrosiaMetaDB?`
- `collectionStore: CollectionStore?`
- `extractionProgress`
- active path and total count

On library open it:

1. Opens `metadata.db` read-only.
2. Opens/creates per-library `ambrosia_meta.db`.
3. Opens optional `full-text-search.db`.
4. Registers the library path and index record.
5. Starts background AO3 metadata extraction from EPUB prefaces.

## Application Structure

```text
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

`LibraryToolbarState` is the bridge between native toolbar controls and SwiftUI/AppKit content. It carries search/sort/filter/view state plus trigger booleans for sheets/actions.

## Library UI

Modes:

- List: SwiftUI AO3-style rows with title, series, authors, tags, stats, description, pagination.
- Email: AppKit split view with table sidebar and SwiftUI detail pane.
- Ranking: placeholder text only; `BookState` already has ELO fields.

Search:

- Raw text is parsed by `SearchQueryParser`.
- Prefixes: `tag:`, `author:`, `title:`, `series:`.
- Single committed prefix tokens become `FilterRule`s.
- Plain terms prefer `CalibreFTSLibrary` (`full-text-search.db`, FTS5) when available, otherwise fall back to fuzzy title LIKE.
- Suggestions query Calibre authors/tags/titles/series directly.

Filters:

- `FilterExpression` contains groups of `FilterRule`s.
- SQL-evaluable rules run against Calibre.
- App-owned rules (`isLiked`, `collection`) are applied in memory using `CollectionStore` membership maps.
- AO3 rating/warning/category rules are implemented as tag-based SQL fragments.

## EPUB Parser

`EPUBParser`:

1. Opens the EPUB zip.
2. Reads `META-INF/container.xml`.
3. Parses OPF manifest/spine/title via SAX.
4. Produces stripped, merged HTML with injected user CSS.
5. Provides plain text for offset arithmetic.
6. Extracts images to `/tmp/ambrosia/<calibreID>/`.

Offset contract everywhere: UTF-16 code units, text-node content only, no HTML tags.

## Reader

`ReaderWindowController.open(book:modelContainer:)` de-duplicates one reader window per Calibre book ID. It updates `BookState.lastOpenedDate` on open and accumulates `totalReadingTimeSeconds` on close.

`ReaderViewController`:

- Builds `WKWebViewConfiguration` before `WKWebView` creation.
- Registers message handlers at construction: `positionUpdate`, `pageAction`, `highlightAdded`, `highlightTapped`, `consoleLog`.
- Loads merged EPUB HTML from the active library path.
- Starts in `ReaderPreferences.shared.defaultReadingMode`.
- Reloads full HTML immediately on reader preference changes.
- Auto-saves position periodically and on disappearance.

Scroll mode loads merged HTML normally and restores scroll offset.

Paginated mode uses one visible `WKWebView` with CSS multi-column layout. One column is one page; page turns set horizontal scroll. There is no hidden measurement web view and no DOM slicing. Resize repagination is debounced.

Find uses `WKFindConfiguration`.

## Annotations

Unified `Annotation` represents point annotations and ranged highlights:

- `startChar == endChar`: point annotation.
- `startChar != endChar`: ranged annotation/highlight.

Annotations are persisted in `AmbrosiaMetaDB.annotations`, not SwiftData. JS selection capture computes UTF-16 offsets with a TreeWalker. Highlights are restored through `HighlightBridge`; sidebar UI is SwiftUI in an `NSPanel`.

`BookmarkManager` is a compile-retained legacy stub. Current bookmark behavior is handled by the annotation system.

## Preferences

`ReaderPreferences` is an `ObservableObject` singleton backed by `UserDefaults`/published properties.

It controls:

- Reader typography, spacing, colors, max width.
- Default reading mode.
- Library color/appearance mode.
- Reader default window sizing.
- Context-menu preferences.

Reader windows subscribe via Combine and regenerate/reload full HTML on changes.

Custom Calibre column labels for word count/kudos are configured via Preferences and stored in `CustomColumnConfig.shared`.

## Key Invariants

1. Calibre DB connections are read-only; never write or issue write PRAGMAs.
2. `books.series` does not exist; always join through `books_series_link`.
3. SQLite.swift SQL bindings use `[Binding?]`.
4. SwiftData schema is only `BookState` and `ReadingGoal`.
5. Do not store bare Swift collections on `@Model`; use scalar columns, delimited strings, or JSON data.
6. Character offsets are UTF-16 code units in text nodes only.
7. `WKWebViewConfiguration` handlers must be registered before `WKWebView` init.
8. Full HTML is regenerated on style changes; avoid live DOM patching.
9. All `evaluateJavaScript` fire-and-forget calls pass `completionHandler: nil`.
10. Full-pane `NSHostingView` must use `sizingOptions = []` when Auto Layout controls size.
11. Image temp directory lifetime is the app session; clean up on app termination.
12. Do not hand-edit `Package.resolved`; add packages through Xcode/SPM workflow.
