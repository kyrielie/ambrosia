# Ambrosia Architecture

Current-state technical reference for engineers working in this repo.

---

## Product Shape

Ambrosia is a native macOS EPUB reader for AO3-heavy Calibre libraries.

- Target: macOS 14.0+.
- Calibre is the source of truth for book metadata and EPUB files.
- Calibre `metadata.db` is opened read-only and never modified.
- App-owned state is stored outside the Calibre library.
- Publisher CSS/scripts are stripped; reader styling is app/user controlled.
- Reader is custom `WKWebView` plus injected JavaScript. No Readium.
- No sandboxing, cloud sync, OPDS, or packaged release flow.

---

## Stack

- App lifecycle/windowing: SwiftUI `App` plus AppKit `NSApplicationDelegate`, `NSWindowController`, and `NSViewController`.
- UI: AppKit shell with SwiftUI content hosted through `NSHostingView`/`NSHostingController`.
- Calibre DB: SQLite.swift 0.15.3, read-only.
- App SwiftData store: `BookState` and `ReadingGoal`.
- Per-library app DB: `AmbrosiaMetaDB` actor, writable SQLite (WAL mode), under `~/Library/Application Support/Ambrosia/libraries/<hash>/ambrosia_meta.db`.
- EPUB parsing: ZIPFoundation 0.9.19 and `NSXMLParser`.
- AO3 HTML parsing: SwiftSoup 2.13.5.
- Rendering: `WKWebView`.
- Local server: FlyingFox 0.26.2.
- Packages: SQLite.swift, ZIPFoundation, SwiftSoup, FlyingFox.

---

## Storage Ownership

### Calibre `metadata.db`

`CalibreLibrary` owns a read-only SQLite connection to a selected library root. It is created by `LibrarySession.open(url:)` and replaced wholesale on library switch.

Important schema facts:

- `books` has no `series` column. Series requires `books_series_link -> series`.
- Authors/tags/publishers are normalized through link tables.
- Comments/descriptions live in `comments`.
- Custom columns are discovered from `custom_columns`; runtime labels come from `CustomColumnConfig.shared`.
- Every `db.prepare(sql, args)` call must use `[Binding?]`.

`CalibreLibrary.books(...)` fetches a page of rows, then bulk-loads authors, tags, and comments with page-level JOIN queries. The `comments` join on the main fetch is omitted unless a filter rule references the comment field (performance optimization: comment blobs are large).

`CalibreLibrary` holds no connection of its own to `ambrosia_meta.db`. `ao3WordCounts(ids:)`, `ao3Dates(ids:)`, and `crossoverBookIDs()` read from in-memory caches (`ao3WordCountCache`, `ao3DateCache`, `crossoverIDCache`) populated by `CalibreLibrary.updateAO3MetaCaches(...)`, which `LibrarySession.refreshAO3MetaCaches()` calls after bulk-fetching from `AmbrosiaMetaDB` on open and after each AO3 extraction batch. `AmbrosiaMetaDB` remains the sole connection owner; `CalibreLibrary` only ever sees pushed-in results.

### SwiftData

`AmbrosiaApp` creates a persistent `ModelContainer("Ambrosia")` with exactly two model types:

- `BookState`: keyed by `calibreID`, stores reading progress, reading position (UTF-16 offset), total reading time, and ELO fields (unused by any current UI — see Not Yet Built).
- `ReadingGoal`: reading-goal state (target count, period start/end), edited from `ReadingGoalView`.

SwiftData does not store collections, annotations, or any AO3 metadata. The dead `Bookmark`/`Highlight` structs and `BookmarkManager`/`BookmarkSidebarView` noted in earlier revisions of this doc have been deleted outright; all bookmark-shaped behavior is handled by the annotation system (`AnnotationSidebarView` is the only sidebar of this kind).

On SwiftData store init failure, the app shows an alert and falls back to in-memory recovery. It does not delete existing support files.

### Per-Library `ambrosia_meta.db`

`AmbrosiaMetaDB` is an actor-backed writable SQLite DB scoped by a hash of the Calibre library path. It stores:

- `collections`, `collection_members`.
- `annotations`.
- `ao3_metadata`, `ao3_extraction_diagnostics`.
- `series_cache`, `series_placeholders` (plus the keyed migration table, see below).
- `canonical_tags`, `tag_synonyms`, `tag_parent_links`, `tag_subtag_sections`.
- `reading_history`, `book_opens`. Write path is fully wired: `startReadingSession`, `updateReadingSession`, and `closeZombieReadingSessions` run from the reader session lifecycle, and both tables now also back the Activity tab's Sessions filter (read-only from that side; nothing new is written for display purposes).

`CollectionStore` wraps collection operations. Bootstrapped system collections:

- Read Later
- Liked
- Skipped
- Finished
- In Progress
- Has Annotations
- Series or Merged

User-created collections are also supported (create, rename, delete, add/remove members) through `CollectionsView`, a sheet reachable from the library toolbar and from per-book/per-selection "add to collection" actions. System collections are visually distinguished but live in the same `collections`/`collection_members` tables as user-created ones.

Annotation inserts/deletes maintain `Has Annotations` membership. Series/anthology sync maintains `Series or Merged` membership for collapsed non-leading series members and anthology-style merged works.

**Migration note:** Most migrations in `runMigrations` are still gated with `CREATE TABLE IF NOT EXISTS` and `ALTER TABLE ... ADD COLUMN` wrapped in `try?`, which is fine for additive, idempotent changes. The destructive `series_placeholders` -> `series_placeholders_keyed` migration in `createAO3Metadata` is gated on `PRAGMA user_version` and wrapped in a transaction, so it runs exactly once and a crash mid-migration can't strand the table. Use this migration as the template for any future destructive schema change; do not revert to `IF NOT EXISTS`-only gating for anything that drops or renames a table.

### Registry and Preferences

`LibraryRegistry` stores known library paths and the active path in `UserDefaults`; it is available before SwiftData is initialized.

`LibraryIndexManager` persists a small JSON index of every library Ambrosia has opened (`hash`, `lastKnownPath`, `displayName`, `lastOpened`) to support a "recent libraries" list independent of `LibraryRegistry`'s single active-path bookkeeping.

`ReaderPreferences` is an `ObservableObject` singleton backed by `UserDefaults`. It controls reader typography, spacing, colors, default reading mode, library appearance, reader window sizing, context-menu preferences, custom Calibre column labels, and paginated-mode columns-per-screen.

`AO3TagSeedDatabaseConfig` is an `ObservableObject` singleton that validates an external AO3 tag seed database (checks for required tables, reports `Counts` of canonical tags/synonyms/hierarchy edges/subtag sections, and surfaces a `ValidationStatus` for the Preferences UI) before `LibrarySession` imports it into `ambrosia_meta.db`.

---

## Session Model

`LibrarySession` is an `@Observable @MainActor` singleton injected into the SwiftUI environment.

It owns:

- `library: CalibreLibrary?`
- `ftsLibrary: CalibreFTSLibrary?`
- `metaDB: AmbrosiaMetaDB?`
- `collectionStore: CollectionStore?`
- `extractionProgress`
- active path, total count, collection membership caches, filter result LRU cache, FTS LRU cache

On library open it:

1. Opens `metadata.db` read-only.
2. Opens/creates per-library `ambrosia_meta.db`.
3. Opens optional `full-text-search.db`.
4. Registers the library path in `LibraryRegistry` and `LibraryIndexManager`.
5. Imports configured AO3 tag seeds into `ambrosia_meta.db`.
6. Starts background AO3 metadata extraction from EPUB prefaces.
7. Seeds Calibre series fallback data and syncs `Series or Merged`.

Collection membership sets (`cachedLikedIDs`, `cachedSkippedIDs`, `cachedSeriesOrMergedIDs`, `cachedAO3PublisherIDs`, `cachedReadLaterIDs`) are cleared on open and on close. `close()` resets all five. `SearchActivityLog.clear()` is also called on library switch (see Activity Feed below).

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
│           └── ActivityFeedView             [activity mode]
└── ReaderWindowController
    └── ReaderViewController -> WKWebView
```

`LibraryToolbarState` bridges native toolbar controls and SwiftUI/AppKit content. It carries search, sort, filter, view state, and trigger booleans for sheets/actions.

The third view-mode slot (`viewMode == .ranking` in `LibraryToolbarState`, left over from an earlier placeholder) now hosts `ActivityFeedView` rather than a ranking UI. `ReadingHistoryView`/`ReadingHistoryDisplayRow`/`ReadingHistoryRow`/`HistoryPill` were removed when this happened; the Activity tab is their replacement. No dedicated ranking/ELO-matchup UI exists yet — see Not Yet Built.

---

## Library UI

Modes:

- List: SwiftUI AO3-style rows with title, series, authors, tags, stats, description, and pagination. `LibraryRootView.swift` holds paging/filtering/series-grouping orchestration; row rendering is split out into `BookListRow.swift` and `SeriesListRow.swift`; shared layout and series-grouping helpers (`FlowLayout`, `isAnthology`, `missingIndices`, `parseISODate`, `logMissingVisibleWorkMetadata`) live in `FlowLayout.swift`. These helpers and the row-support types (`LibraryStats`, `LibraryStatsRow`, `TagPillDisplay`) are intentionally `internal`, not `private`, because more than one row file depends on them — see Invariant 16.
- Email: AppKit split view with table sidebar and SwiftUI detail pane.
- Activity: `ActivityFeedView`, a filterable feed (All / Sessions / Annotations / Collections / Searches) over reading sessions (`reading_history`/`book_opens`), annotation events, collection-membership changes (`CollectionActivityEntry`, reconstructed from `collection_members` on each load — never persisted separately), and recent searches (`SearchActivityLog`, an in-memory 200-entry ring buffer scoped to the current session and cleared on library switch; logging searches to `ambrosia_meta.db` was deliberately rejected to avoid schema growth and writes on the search hot path).

`LibraryRootView` and `EmailLibraryViewController` previously carried independent copies of several pagination/visibility helpers. The genuinely identical pieces (e.g. `visibleIDs` skip/series-grouping/AO3-publisher filtering) are now shared through `LibraryQueryHelpers`, which takes each surface's state as parameters rather than owning it. `loadPage(...)` and `applyFilterRules(...)` remain separate per surface on purpose: List paginates via discrete page replacement, Email is infinite-scroll append, and unifying those would mean redesigning one surface's pagination model rather than deduplicating.

Search:

- Raw text is parsed by `SearchQueryParser`.
- Prefixes: `tag:`, `author:`, `title:`, `series:`.
- Single committed prefix tokens become `FilterRule`s.
- Plain terms prefer `CalibreFTSLibrary` (`full-text-search.db`, FTS5) when available, otherwise fall back to fuzzy title LIKE.
- Suggestions query Calibre authors/tags/titles/series directly.
- Committed search/filter operations are appended to `SearchActivityLog` once the result count is known.

Filters:

- `FilterExpression` contains groups of `FilterRule`s.
- SQL-evaluable rules run against Calibre.
- App-owned rules such as collection membership are applied through `CollectionStore` data.
- AO3 rating/warning/category rules are implemented as tag-based or metadata-backed filters.
- Filter results are cached in an LRU cache keyed on `FilterExpression` plus a `membershipVersion` counter. The version is bumped after any liked/skipped/status change.
- Tag-value synonym expansion (canonical tag -> synonym set, via `AmbrosiaMetaDB.expandedTermsBatch`) is resolved through `TagExpansionResolver`, a shared enum used by both `LibraryRootView`'s `FilterBuilder` and `EmailLibraryViewController`, replacing what had been two independent copies of the same two call-site blocks. The result is still computed once per filter application and stored, not threaded as a parameter through `CalibreLibrary`/`FilterBuilder` query methods (`sqlFilterClause`, `sqlFragment`, `calibreIDs(matchingRules:)`, `bookCount`, `wordCountSortedPage`, `randomSortedPage`, `fetchAllMatchingIDs`, etc.) — see Invariant 17.

Collections:

- System collections and user-created collections both live in `ambrosia_meta.db`'s `collections`/`collection_members` tables.
- `CollectionsView` provides create/rename/delete and add/remove-member UI for both kinds (system collections have restricted rename/delete).
- `Series or Merged` is system-maintained from `series_cache` and anthology detection.
- Series grouping uses representative grouped rows for collapsed series.

---

## AO3 Metadata and Tags

`AO3MetadataExtractor` parses AO3 EPUB preface HTML with SwiftSoup and returns `AO3MetadataRecord`. `LibrarySession` checks the first five spine items for AO3 metadata, stores successful extraction in `ao3_metadata`, and stores skipped/failed attempts in `ao3_extraction_diagnostics`. Extraction runs in batches of 50 with `Task.yield()` between batches so read queries can cut in.

Extracted fields include story URL, work ID, author username, kudos, word count, chapter counts, completion, language, dates, fandoms, relationships, characters, additional tags, categories, AO3 collections, and AO3 series.

Series metadata is cached in `series_cache`; Calibre series data is inserted as fallback.

Configured AO3 tag seed databases (validated via `AO3TagSeedDatabaseConfig`) can be imported into `canonical_tags`, `tag_synonyms`, `tag_parent_links`, and `tag_subtag_sections`. Synonym expansion is present at the storage layer and now has UI coverage in both library search surfaces via `TagExpansionResolver`.

`canonicalTerm(for:)` and `expandedTerms(for:)`/`expandedTermsBatch(for:)` are actor-isolated methods on `AmbrosiaMetaDB` itself, called through `LibrarySession.metaDB` from the search and filter pipeline. No code path opens an independent connection to `ambrosia_meta.db` for tag resolution.

---

`EPUBParser`:

1. Opens the EPUB zip.
2. Reads `META-INF/container.xml`.
3. Parses OPF manifest/spine/title via SAX.
4. Produces stripped, merged HTML with injected user CSS.
5. Provides plain text for offset arithmetic.
6. Extracts images to `/tmp/ambrosia/<calibreID>/`.
7. Parses the OPF `<navMap>`/nav document into `EPUBParser.TOCEntry` values (parser-local; see `SeriesSpineMap`/`TOCSidebarView` below for how these become UI-facing entries).

Offset contract everywhere: UTF-16 code units, text-node content only, no HTML tags.

---

## Reader

`ReaderWindowController.open(target:modelContainer:)` de-duplicates one reader window per `ReadingTarget.windowKey`. A `ReadingTarget` is either `.singleBook(CalibreBook)` or `.series(SeriesGroup)`; opening a series target reads the whole series continuously in one window rather than one book at a time. `ReadingTarget.primaryBook` returns the first work for a series target behind a `precondition` guard on `!series.works.isEmpty` (the earlier force-unwrapped `series.works.first!` crash site referenced in older notes has been removed). It updates `BookState.lastOpenedDate` on open and accumulates `totalReadingTimeSeconds` on close.

`ReaderViewController`:

- Builds `WKWebViewConfiguration` before `WKWebView` creation.
- Registers message handlers at construction: `positionUpdate`, `pageAction`, `highlightAdded`, `highlightTapped`, `consoleLog`.
- For a series target, builds one `EPUBParser` per work (in `ReadingTarget` order) and flattens their spines into a single global ordering via `SeriesSpineMap`, so "global index" (position across the whole series) and "local index" (position within one work's own spine) are both addressable. `spineMap` is rebuilt once per `loadEPUB()` call and never mutated afterward.
- `globalTOC` resolves each work's parsed `EPUBParser.TOCEntry` list into `TOCPanelEntry` values with globally-resolved `spineIndex`, shown in `TOCSidebarView` — a `.singleBook` target simply produces entries with a nil `workTitle`, so the section-header grouping in the sidebar degenerates to a flat list.
- Loads merged EPUB HTML from the active library path.
- Starts in `ReaderPreferences.shared.defaultReadingMode`.
- Reloads full HTML on any `ReaderPreferences.objectWillChange` event via a Combine sink.
- Auto-saves position periodically and on disappearance.

Scroll mode loads merged HTML normally and restores scroll offset.

Paginated mode is coordinated by `PaginationEngine`, a dedicated Swift class rather than ad hoc calls scattered through `ReaderViewController`. Column layout CSS (`ReaderPreferences.paginatedColumnCSS`) is baked into the HTML string before `loadHTMLString` is called, so by the time the page finishes loading, column layout has already settled — there is no post-load JS race to wait out. `PaginationEngine`'s job is limited to injecting `PaginationJS`, telling it how many columns fit on screen (`ColsPerScreen`, 1-3, a user preference), restoring the requested position once column count is known, and exposing navigation/query methods. Column geometry itself (width, gap) is read by JS from `getComputedStyle`, never passed in from Swift. Because the column CSS is baked into the HTML, a resize requires a full spine reload with updated viewport geometry (`loadSpineItem(index:restorePosition:.fraction(_:))`), not just re-running JS. Key-repeat suppression is handled by `ReaderViewController` intercepting `keyDown` directly and calling `PaginationEngine.handleKeyDown(_:)`; the `WKWebView` never sees raw keystrokes, so one physical keypress is one page turn. All `PaginationEngine` public methods must be called on the main thread.

Find uses `WKFindConfiguration`.

**CSS pipeline:** `ReaderPreferences.css` is a computed `String` that interpolates Swift values directly into CSS literal property values. There are no CSS custom properties in the current pipeline. Every preference change — including font size, line height, color, and padding adjustments — triggers a full EPUB re-parse and `WKWebView` reload. Migrating style-only preferences to CSS variable injection (`var(--ambrosia-*)` in a `:root` block) would reduce this to a single `evaluateJavaScript` call for those changes; structural changes (reading mode switches, DOM layout changes, and resizes in paginated mode) would still require a full reload.

---

## Annotations

Unified `Annotation` represents point annotations and ranged highlights:

- `startChar == endChar`: point annotation.
- `startChar != endChar`: ranged annotation/highlight.

Annotations are persisted in `AmbrosiaMetaDB.annotations`, not SwiftData. JS selection capture computes UTF-16 offsets with a TreeWalker. Highlights are restored through `HighlightBridge`; sidebar UI is SwiftUI in an `NSPanel`.

There is no separate bookmark system: the earlier `BookmarkManager`/`BookmarkSidebarView`/`Bookmark`/`Highlight`-struct stand-ins have been deleted from the codebase; all of this behavior lives in the annotation system, surfaced through `AnnotationSidebarView`.

---

## Reading Goals

`ReadingGoalView` is a SwiftData-backed sheet for setting and tracking a reading goal (target count over a period, defaulting to the current calendar month). Progress is computed by counting `BookState` records with `lastOpenedDate` inside `[periodStart, periodEnd]` and `totalReadPercent >= 0.98` (treated as "finished"). Session time itself comes from `ReaderWindowController`, which stores a `sessionStartDate` at window load and diffs it on `windowWillClose`.

---

## Implemented Utilities

- CSV export of library books through `ExportManager`.
- Preferences window (Reader, Library, Window, Data tabs) for reader defaults, library appearance, custom Calibre column labels, AO3 extraction, and tag seed configuration (including `AO3TagSeedDatabaseConfig` validation feedback).
- Optional FTS search through Calibre's `full-text-search.db`.
- Local RSS feed server via FlyingFox (`LocalFeedServer`), off by default, loopback-bound by default. Serves `GET /` (HTML index of available feeds), `GET /feed/collection/<id>.xml` (one item per collection member, system or user-created), `GET /feed/search.xml` (last-published current-search snapshot, persisted as `CurrentSearchSnapshot` in `UserDefaults`), `GET /feed/random-daily.xml` (one seeded-random book per UTC day, opt-in), and `GET /feeds.opml` (OPML 2.0 export of every non-excluded collection feed plus the daily and search feeds). `RSSPublishView` is the SwiftUI publish sheet (searchable collection list, current-search/single-collection target selection, Publish / Copy Feed URL / Export OPML actions) presented as a sheet from `LibraryWindowController`. All routes are GET-only and read-only; there is no write-back path from a feed reader into Ambrosia yet (see Not Yet Built).
- Seeded random sort with Xorshift64 (`SeededRNG`), stable within a session.
- Reader table-of-contents popup (`TOCSidebarView`), spanning an entire series when the reading target is a series.
- Continuous series reading in a single reader window (`ReadingTarget.series`, `SeriesSpineMap`).
- User-created, renameable collections (`CollectionsView`), alongside the system collections.
- Activity feed (`ActivityFeedView`) surfacing recent reading sessions, annotations, collection changes, and searches.
- Reading goal tracking (`ReadingGoalView`, `ReadingGoal`).
- Recent-libraries index (`LibraryIndexManager`), independent of the single active-path bookkeeping in `LibraryRegistry`.

---

## Not Yet Built

- Ranking UI and ELO matchup workflow. `BookState` still has ELO fields, but no UI reads or writes them; the view-mode slot once reserved for this now hosts the Activity feed instead.
- AO3 login, kudos, and AO3 bookmark posting.
- Saved searches (as a persisted, re-runnable object — `SearchActivityLog` is a transient recent-activity list, not saved searches).
- Favourite authors.
- Saved quotes.
- Annotation export/sharing.
- Standalone mode without Calibre.
- Music integration.

---

## Incident Notes: LibraryUI Row Split (build-breakage retro)

The split of `LibraryRootView`'s row rendering into `BookListRow.swift`, `SeriesListRow.swift`, and `FlowLayout.swift`, plus the addition of tag-synonym expansion (`tagExpansions`) to the filter pipeline, shipped with ten-plus build errors across five files. None were logic bugs; all were consistency failures between files — a type renamed in one place and not another, a function declaration deleted while its body survived, helpers left `private` after being split out from their original file, an async closure called without `await`, a parameter threaded through eight method signatures instead of stored once. None of these would have survived a single green `xcodebuild build` run before merge. Invariants 16-21 below exist to keep the next multi-file refactor from repeating this; Invariant 21 (a build gate before merge) is the cheapest one and should be treated as non-negotiable.

---

## Key Invariants

1. Calibre DB connections are read-only. Never issue DDL, DML, or file-modifying PRAGMAs (`journal_mode`, `wal_checkpoint`, `user_version`). Session-scoped performance PRAGMAs (`cache_size`, `temp_store`) are safe and permitted.

2. `books.series` does not exist. Always join through `books_series_link -> series`.

3. SQLite.swift SQL bindings always use `[Binding?]`.

4. The SwiftData schema contains only `BookState` and `ReadingGoal`. Do not add `@Model` types without a versioned migration plan. Do not store bare Swift collections on `@Model`; use scalar columns, delimited strings, or JSON data.

5. Character offsets are UTF-16 code units in text nodes only. This contract must be consistent across `EPUBParser`, `PaginationJS`, `HighlightBridge`, and any JS that reads or writes offsets. For series reading targets, this contract is per-work: `SeriesSpineMap`'s global index is a spine-item index, not a character offset, and must not be conflated with the UTF-16 offset contract within a given spine item.

6. `WKWebViewConfiguration` message handlers must be registered before `WKWebView` is initialized.

7. Full HTML reload (`reloadHTML`) is required for reading mode switches, paginated-mode resizes, and other DOM structural changes. It is not required for style-only preference changes (colors, typography, spacing); those should eventually use CSS variable injection to avoid re-parsing the EPUB on every tweak. Until that is implemented, the full reload path remains in place.

8. `evaluateJavaScript` calls that do not need a return value should pass `completionHandler: nil` to avoid retain cycles when the `WKWebView` tears down before the callback fires. Calls that capture a return value must use `[weak self]` closures and guard on `self`. The distinction is about memory safety, not style.

9. Full-pane `NSHostingView` instances whose frame is controlled by an external Auto Layout constraint (full-pane, sidebar fill, split-view pane) must set `sizingOptions = []`. `NSHostingView` instances in intrinsic-size contexts (preferences windows, popups, sheets) must not set it.

10. `AmbrosiaMetaDB` is the sole owner of `ambrosia_meta.db`. All reads and writes go through the actor, accessed via `LibrarySession.metaDB`. Do not reintroduce a second connection to this file (the earlier `CalibreLibrary`-owned and `AO3TagSearchResolver`-owned connections that once violated this have both been removed; `CalibreLibrary` now only reads from caches pushed in via `updateAO3MetaCaches`, and tag resolution lives on the `AmbrosiaMetaDB` actor itself).

11. All destructive schema migrations (DROP, ALTER with data movement) must be wrapped in `db.transaction` and gated on `PRAGMA user_version`, not on table existence. `IF NOT EXISTS` guards cannot prevent a migration from re-running on subsequent launches.

12. Force-unwraps are prohibited in any code path reachable from database read results. Use `guard let` with a logged fallback, or a `precondition` with a clear invariant message when the unwrap is truly guaranteed by construction (e.g. `ReadingTarget.primaryBook` on `.series`, which preconditions on `SeriesGroup.works` being non-empty rather than force-unwrapping `.first!`). Prefer `guard let` over `precondition` wherever the caller could plausibly recover; reserve `precondition` for cases where recovery isn't meaningful and the message should say which upstream invariant would have to be violated for it to fire.

13. All diagnostic `print` calls must be wrapped in `#if DEBUG` or removed before shipping. `Thread.callStackSymbols` must never be called outside `#if DEBUG` blocks.

14. Do not hand-edit `Package.resolved`; add packages through the Xcode/SPM workflow.

15. Image temp directory lifetime is the app session; clean up on app termination.

16. `private` on a top-level type or function scopes it to the declaring *file*, not the module. Before marking a shared row-rendering type (e.g. `LibraryStats`, `TagPillDisplay`) or a shared free function (e.g. `isAnthology`, `missingIndices`, `parseISODate`, `logMissingVisibleWorkMetadata`) as `private`, grep the rest of the target for usages. If more than one file needs it, it is `internal` (the default — omit the modifier), not `private`. When splitting a fat view file into per-row files, this check is mandatory, not optional: it is the single most common source of "Cannot find X in scope" after a file split. Do not create a second, duplicate `private` copy of a helper in a new file as a workaround — that produces an "Invalid redeclaration" error the moment the original is later widened to `internal`, and it leaves two copies to keep in sync.

17. Values that configure a multi-call operation (e.g. `FilterBuilder`'s tag-synonym `tagExpansions`, resolved once through `TagExpansionResolver`) are stored as a property set once at `init`, not threaded as a parameter through every downstream method across multiple files. If a code review adds a default-valued parameter to more than two or three function signatures in the same change, stop and ask whether the value should be captured once as state instead.

18. Do not invoke an `async` closure as a bare trailing argument (`someInit(x: { ... await ... }())`). The closure literal becomes implicitly `async` the moment its body contains `await`, and the call site needs `await` too, but nothing forces this to be visually obvious — the `await` keyword is buried inside the closure body, not next to the call. Resolve async values into a `let` on the line(s) before the call and pass the `let`.

19. Combining `async let` with a `Task.detached { ... }.value` initializer, where the detached closure captures a non-`Sendable` reference type (e.g. `CalibreLibrary?`), fails Swift 6 strict-concurrency checking even though the identical `Task.detached(...).value` pattern compiles fine as a plain (non-`async let`) assignment elsewhere in the same function. Prefer the plain sequential `let x = await Task.detached { ... }.value` form when the captured value is a non-Sendable type; do not assume `async let` and plain `await` are interchangeable here.

20. Renaming or removing a type or top-level function (e.g. an earlier `SeriesEntry` becoming `SeriesCacheEntry`) must be done with a project-wide search (Xcode's rename refactor or `grep -rl`), not by editing the declaration site from memory. A stale type name left at a call site does not always fail with a clear "unknown type" error in isolation — it can surface as a cascading "ambiguous expression" error several lines away, at the point where type inference depends on it.

21. Every commit that touches `.swift` files must pass `xcodebuild build` (or `swift build`) before merge. The bugs in invariants 16-20 are all hard compiler errors, not runtime bugs — a build gate catches all of them for free. There is no historical instance of one of these mistakes shipping that would have survived a green build.

22. `SearchActivityLog` and `CollectionActivityEntry` are intentionally not persisted to `ambrosia_meta.db`. The former is a session-scoped ring buffer (cleared on library switch); the latter is reconstructed from `collection_members` on each Activity-tab load. Do not add a persisted table for either without first establishing that the Activity tab actually needs history beyond the current session/collection state — that was a deliberate scope cut, not an oversight.
