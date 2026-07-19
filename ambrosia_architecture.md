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
- Packages: SQLite.swift, ZIPFoundation, SwiftSoup, FlyingFox 0.26.2.

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

**Fixed.** `CalibreLibrary` no longer holds its own `Connection` to `ambrosia_meta.db`. `ao3WordCounts(ids:)`, `ao3Dates(ids:)`, and `crossoverBookIDs()` now read from in-memory caches (`ao3WordCountCache`, `ao3DateCache`, `crossoverIDCache`) populated by `CalibreLibrary.updateAO3MetaCaches(...)`, which `LibrarySession.refreshAO3MetaCaches()` calls after bulk-fetching from `AmbrosiaMetaDB` on open and after each AO3 extraction batch. `AmbrosiaMetaDB` remains the sole connection owner; `CalibreLibrary` only ever sees pushed-in results.

### SwiftData

`AmbrosiaApp` creates a persistent `ModelContainer("Ambrosia")` with exactly two model types:

- `BookState`: keyed by `calibreID`, stores reading progress, reading position (UTF-16 offset), total reading time, and ELO fields.
- `ReadingGoal`: reading-goal state.

SwiftData does not store collections, annotations, or any AO3 metadata. The `Bookmark` and `Highlight` structs in `BookState.swift` are safe to delete; they were never stored as `@Model` properties and no migration depends on them.

On SwiftData store init failure, the app shows an alert and falls back to in-memory recovery. It does not delete existing support files.

### Per-Library `ambrosia_meta.db`

`AmbrosiaMetaDB` is an actor-backed writable SQLite DB scoped by a hash of the Calibre library path. It stores:

- `collections`, `collection_members`.
- `annotations`.
- `ao3_metadata`, `ao3_extraction_diagnostics`.
- `series_cache`, `series_placeholders`.
- `canonical_tags`, `tag_synonyms`, `tag_parent_links`, `tag_subtag_sections`.
- `reading_history`, `book_opens` (write path wired up: `startReadingSession`, `updateReadingSession`, `closeZombieReadingSessions` are called from the reader session lifecycle).

`CollectionStore` wraps collection operations. Bootstrapped system collections:

- Read Later
- Liked
- Skipped
- Finished
- In Progress
- Has Annotations
- Series or Merged

Annotation inserts/deletes maintain `Has Annotations` membership. Series/anthology sync maintains `Series or Merged` membership for collapsed non-leading series members and anthology-style merged works.

**Migration note:** Most migrations in `runMigrations` are still gated with `CREATE TABLE IF NOT EXISTS` and `ALTER TABLE ... ADD COLUMN` wrapped in `try?`, which is fine for additive, idempotent changes. The destructive `series_placeholders` -> `series_placeholders_keyed` migration in `createAO3Metadata` is now gated on `PRAGMA user_version` and wrapped in a transaction, so it runs exactly once and a crash mid-migration can't strand the table. Use this migration as the template for any future destructive schema change; do not revert to `IF NOT EXISTS`-only gating for anything that drops or renames a table.

### Registry and Preferences

`LibraryRegistry` stores known library paths and the active path in `UserDefaults`; it is available before SwiftData is initialized.

`ReaderPreferences` is an `ObservableObject` singleton backed by `UserDefaults`. It controls reader typography, spacing, colors, default reading mode, library appearance, reader window sizing, context-menu preferences, and custom Calibre column labels.

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
4. Registers the library path and index record.
5. Imports configured AO3 tag seeds into `ambrosia_meta.db`.
6. Starts background AO3 metadata extraction from EPUB prefaces.
7. Seeds Calibre series fallback data and syncs `Series or Merged`.

Collection membership sets (`cachedLikedIDs`, `cachedSkippedIDs`, `cachedSeriesOrMergedIDs`, `cachedAO3PublisherIDs`, `cachedReadLaterIDs`) are cleared on open and on close. `close()` now resets all five, including `cachedReadLaterIDs`.

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

## Library UI

Modes:

- List: SwiftUI AO3-style rows with title, series, authors, tags, stats, description, and pagination. `LibraryRootView.swift` holds paging/filtering/series-grouping orchestration; row rendering has been split out into `BookListRow.swift` and `SeriesListRow.swift`; shared layout and series-grouping helpers (`FlowLayout`, `isAnthology`, `missingIndices`, `parseISODate`, `logMissingVisibleWorkMetadata`) live in `FlowLayout.swift`. These helpers and the row-support types (`LibraryStats`, `LibraryStatsRow`, `TagPillDisplay`) are intentionally `internal`, not `private`, because more than one row file depends on them — see Invariant 16.
- Email: AppKit split view with table sidebar and SwiftUI detail pane.
- Ranking: placeholder text only; `BookState` already has ELO fields.

Search:

- Raw text is parsed by `SearchQueryParser`.
- Prefixes: `tag:`, `author:`, `title:`, `series:`, `status:`, `fulltext:`.
- Only one scoped prefix token is recognised per search string — parsing is not compositional (`"tag:x author:y"` becomes a single `tag:` token whose value is the literal string `"x author:y"`, not two rules). `SearchQuery.hasTrailingPrefixWarning` flags this case so the UI can warn the user, but does not change parsing behavior. Compound quick-searches must go through the drawer/popup instead of the search bar. See "Known Limitations" below.
- Single committed prefix tokens become `FilterRule`s via `SearchQuery.asSingleFilterRule(resolvedTagTerm:)`.
- Plain terms prefer `CalibreFTSLibrary` (`full-text-search.db`, FTS5) when available, otherwise fall back to fuzzy title LIKE.
- Suggestions query Calibre authors/tags/titles/series directly.
- `SearchActivityLog` (`@MainActor` singleton) keeps an in-memory ring buffer (200 entries) of committed search/filter operations for the current session, persisted per-library-hash to a JSON file in Application Support on `close()` and reloaded on `open()`. It dedupes only against the single most recent entry (not the whole window), and is not saved on crash/unclean shutdown — only on the `close()` path.

Filters — two front ends, one engine:

- The **drawer** (`FilterDrawer/FilterRule.swift`, `FilterBuilder.swift`, `FilterDrawerView.swift`) is a generic rule builder: `FilterExpression` is a list of `FilterGroup`s (rules ANDed/ORed within a group), groups joined by one top-level conjunction, across sixteen `FilterField` cases.
- The **AO3-style popup** (`FilterPopup/AO3Filter*.swift`) mirrors AO3's own facet browser (fandom/relationship/character/freeform/warning/category, plus rating/crossover/completion) with checkboxes instead of free-form rules. It has no SQL layer of its own: `AO3FilterPopupState.buildExpression()` converts checkbox state into an ordinary `FilterExpression` only on Apply, and `AO3FilterFacetController` builds throwaway `FilterExpression`s (excluding one field at a time, AO3's "ignoring: type" scoping behavior) purely to call the same `FilterBuilder.matchingIDs` the drawer uses. Every SQL/cache characteristic below applies to both menus identically; the popup adds its own facet-count query load on top (see "Facet counts" under Caching, below).
- SQL-evaluable rule fields (title, comment, author, series, tag/rating/warning/category, word count/kudos when a custom column is configured) are compiled by `FilterBuilder.sqlFragment(for:)` into correlated `EXISTS`/`NOT EXISTS` subqueries (aliased `btl2`/`t2`, `bal2`/`a2`, `bsl2`/`s2`) rather than outer joins — see Invariant 24.
- App-owned/in-memory-only fields (`isLiked`, `collection`, `status`, `crossover`, and `wordCount`/`kudos` when no custom column exists) never produce SQL; they are resolved as `Set<Int>` intersections against caller-supplied membership maps (`likedIDs`, `collectionMap`, `statusMap`, `crossoverMap`) inside `matchingIDsForGroup`, applied as a post-filter over whatever the SQL-backed rules in the same group already returned. This composition is correct only because of that specific evaluation order; see Invariant 25 before adding a new in-memory field type.
- Filter results are cached in `filterResultCache`, an 8-entry LRU keyed on a digest of `FilterExpression` (group index + sorted per-group rules) plus `membershipVersion`, a counter bumped after any liked/skipped/status change. Page and count results have their own, larger (48-entry) LRU caches (`pageCache`, `countCache`, `groupAwareCountCache`) on `CalibreLibrary`, keyed similarly plus sort/offset/visibility/random-seed fields — see "Caching", below.
- Tag-value synonym expansion (canonical tag -> synonym set, via `AmbrosiaMetaDB.expandedTermsBatch`) is resolved per filter application by `TagExpansionResolver.filterTagExpansions(for:metaDB:)`, which returns a small dictionary scoped to only the tag values present in the *current* filter expression — not the full synonym table, and not stable across filter changes. `FilterBuilder` stores its own copy as `let tagExpansions`, set once at `init`, since a `FilterBuilder` instance is fresh per call and safe to own state on. `CalibreLibrary` is a long-lived `actor` shared across both surfaces and across overlapping in-flight queries; `sqlFilterClause`, `sqlFragment`, `calibreIDs(matchingRules:)`, `bookCount`, `wordCountSortedPage`, `randomSortedPage`, and `fetchAllMatchingIDs` all live on `CalibreLibrary` (some called only through `FilterBuilder`, some called directly from `LibraryRootView`/`EmailLibraryViewController`), so `tagExpansions`/`filterTagExpansions` is threaded through as an explicit parameter on all six rather than cached as actor state — caching it there would let one surface's synonym lookup silently overwrite another's mid-query. See Invariant 17.
- The visibility rules that were previously scattered as bool + cached-`Set<Int>` pairs (skipped, series-or-merged grouping, AO3-publisher allow-list, anthology deny-list) are consolidated into `LibraryVisibilityPolicy`, a value type built fresh per surface as `currentVisibilityPolicy` and passed into `CalibreLibrary.wordCountSortedPage`/`randomSortedPage` as `visibility:`, replacing the old `excludeIDs:` parameter and the per-branch AO3-only-random patches. See Invariant 22.

### Caching

Three LRU caches (`LRUCache<Key, Value>`, a bounded dictionary + insertion-order eviction list, not thread-safe on its own — safe here because every instance lives on an actor or `@MainActor` type) cover the filter/search pipeline:

| Cache | Owner | Key | Limit | Cleared by |
|---|---|---|---|---|
| `filterResultCache` | `LibrarySession` | `FilterResultCacheKey` (expression digest + `membershipVersion`) | 8 | library open/close; implicitly stale once `membershipVersion` moves on |
| `pageCache` | `CalibreLibrary` | `PageCacheKey` (query+filter+tagExpansion digests, `visibilityVersion`, sort, ascending, `randomSeed`, offset, limit) | 48 | `updateAO3MetaCaches` (after every AO3 extraction batch); implicitly stale once `visibilityVersion`/`randomSeed` move on |
| `countCache` / `groupAwareCountCache` | `CalibreLibrary` | analogous to `PageCacheKey`, minus offset/limit/sort | 48 each | same as `pageCache` |

Notes and known rough edges:

- Cache keys are built from `LibraryFilterDebug.summary(expression:)`/`summary(query:)`, a function whose primary purpose is debug logging, repurposed as the cache-key digest. Any change to that formatting silently changes cache-key identity; treat it as cache-critical, not just cosmetic, when editing.
- `FilterResultCacheKey`'s digest encodes each group by positional index (`g0`, `g1`, ...) without sorting groups themselves, so two expressions with reordered-but-equivalent groups (e.g. under an `OR` top-level conjunction, where order is semantically irrelevant) produce different keys and miss the cache. Harmless (over-invalidation, not incorrectness) but worth knowing if cache-hit-rate work happens here.
- Facet counts in the AO3 popup (`AmbrosiaMetaDB.topFacets(for:scopedTo:limit:)`, one `json_each` aggregation query per of the 6 `AO3FacetField` cases, run concurrently via `withTaskGroup`, plus one rating query) are **not cached** and re-run in full on every checkbox toggle in `refreshFacets()`. Each query binds the entire scoped ID set as `IN (?, ?, ...)` parameters, which can be large for a broad selection. There is no debounce wired into `refreshFacets()` at present, so rapid toggling can dispatch bursts of 7 aggregation queries. `canonicalize(_:)` additionally issues one `SELECT` per distinct facet name to resolve synonyms (an N+1 pattern bounded by the small per-field row limit, not batched the way `TagExpansionResolver`/`expandedTermsBatch` batches the equivalent lookup elsewhere).

### Reload triggers (List vs Email)

Both surfaces reload from two independent places on every `applyFilterRules()` completion: the explicit `scheduleLoadPage`/`loadPage` call each of its three branches (SQL-pageable, LRU-cached, full compute) makes itself, and a separate observer that exists to reload when *something else* — the other surface, a sort/search change, a preference toggle — changes `toolbarState.activeFilterResult` while this surface is the one onscreen. `LibraryRootView` uses SwiftUI's `.onChange(of: toolbarState.activeFilterResult?.reloadToken)`; `EmailLibraryViewController` uses a hand-rolled `withObservationTracking` observer (`scheduleObservation()` / `toolbarStateDidChange()`), since it's an `NSViewController`, not a SwiftUI view.

Every branch of `applyFilterRules()` on both surfaces sets a one-shot `suppressNextReloadToken` flag immediately before its own reload call, and the observer checks and consumes that flag before reloading — otherwise the filter completion double-fires and races through `scheduleLoadPage`'s non-atomic `loadPageTask?.cancel()`-then-reassign, since the explicit call and the observer-triggered call can run from different execution contexts. See Invariant 27.

Collections:

- System collections live in `ambrosia_meta.db`.
- `Series or Merged` is system-maintained from `series_cache` and anthology detection.
- Series grouping uses representative grouped rows for collapsed series.

### Known Limitations (Filter/Search)

- **Two independent SQL-generation paths** exist for the same tag/author/series matching logic: `FilterBuilder.sqlFragment(for:)` (drawer/popup path) and `CalibreLibrarySearch.whereClause(for:)` (search-bar path). A correctness or performance fix to one (e.g. the NOT EXISTS rewrite, Invariant 24) does not automatically apply to the other — confirmed drifted out of sync: `CalibreLibrarySearch._bookCount(query:)` still carries the outer `LEFT JOIN books_authors_link/authors/books_series_link/series` that `FilterBuilder` deliberately removed (see Invariant 24) because its own `EXISTS` subqueries are self-contained and never reference the outer join aliases. This is dead weight causing the same row-fan-out cost the removed join caused elsewhere, just on the plain-search count path.
- `SearchQueryParser` only parses one scoped prefix token per string (see Search, above) — no compound quick-search syntax.
- AO3 popup facet counts (`topFacets`) are uncached and unde-bounced; see Caching, above.
- `crossoverBookIDs()`/`allCrossoverBookIDs()` (a full-table `json_array_length(fandoms_json) > 1` scan over `ao3_metadata`) is recomputed on every `AO3FilterFacetController.make` call (i.e. every popup open) with no cache, even though it only actually changes after an AO3 extraction batch.
- `AO3FilterFacetController.make` builds `statusMap` by looping every `AO3CompletionStatus` case and issuing one query per case whenever *any* status rule is present, rather than a single query covering all needed statuses at once.
- No index is created (or verified) on `books_tags_link`/`books_authors_link`/`books_series_link` by Ambrosia itself — these tables belong to Calibre's own `metadata.db` schema, and Calibre normally indexes them, but nothing here defensively creates a fallback index (`CREATE INDEX IF NOT EXISTS` is idempotent even against a foreign schema) for libraries where that index is missing or was stripped.

---

## AO3 Metadata and Tags

`AO3MetadataExtractor` parses AO3 EPUB preface HTML with SwiftSoup and returns `AO3MetadataRecord`. `LibrarySession` tries spine[0] first (AO3 EPUBs reliably place the preface there), falling back through the next four spine items for non-standard files, stores successful extraction in `ao3_metadata`, and stores skipped/failed attempts in `ao3_extraction_diagnostics`. Extraction runs concurrently via a capped `TaskGroup` (up to 8 books in flight at once), flushing to the DB every 10 books or every 2 seconds, whichever comes first, with `Task.yield()` between flushes so read queries can cut in.

Extracted fields include story URL, work ID, author username, kudos, word count, chapter counts, completion, language, dates, fandoms, relationships, characters, additional tags, categories, AO3 collections, and AO3 series.

Series metadata is cached in `series_cache`; Calibre series data is inserted as fallback.

Configured AO3 tag seed databases can be imported into `canonical_tags`, `tag_synonyms`, `tag_parent_links`, and `tag_subtag_sections`. Synonym expansion is present at the storage layer but UI coverage is incomplete.

**Fixed.** `AO3TagSearchResolver` has been removed. `canonicalTerm(for:)` and `expandedTerms(for:)` are now actor-isolated methods on `AmbrosiaMetaDB` itself, called through `LibrarySession.metaDB` from the search and filter pipeline. No code path opens an independent connection to `ambrosia_meta.db` for tag resolution anymore.

---



`EPUBParser`:

1. Opens the EPUB zip.
2. Reads `META-INF/container.xml`.
3. Parses OPF manifest/spine/title via SAX.
4. Produces stripped, merged HTML with injected user CSS.
5. Provides plain text for offset arithmetic.
6. Extracts images to `/tmp/ambrosia/<calibreID>/`.

Offset contract everywhere: UTF-16 code units, text-node content only, no HTML tags.

---

## Reader

`ReaderWindowController.open(book:modelContainer:)` de-duplicates one reader window per Calibre book ID. It updates `BookState.lastOpenedDate` on open and accumulates `totalReadingTimeSeconds` on close.

`ReaderViewController`:

- Builds `WKWebViewConfiguration` before `WKWebView` creation.
- Registers message handlers at construction: `positionUpdate`, `pageAction`, `highlightAdded`, `highlightTapped`, `consoleLog`.
- Loads merged EPUB HTML from the active library path.
- Starts in `ReaderPreferences.shared.defaultReadingMode`.
- Reloads full HTML on any `ReaderPreferences.objectWillChange` event via a Combine sink.
- Auto-saves position periodically and on disappearance.

Scroll mode loads merged HTML normally and restores scroll offset.

Paginated mode uses one visible `WKWebView` with CSS multi-column layout. One column is one page; page turns set horizontal scroll. Resize repagination is debounced.

Find uses `WKFindConfiguration`.

**CSS pipeline:** `ReaderPreferences.css` is a computed `String` that interpolates Swift values directly into CSS literal property values. There are no CSS custom properties in the current pipeline. Every preference change — including font size, line height, color, and padding adjustments — triggers a full EPUB re-parse and `WKWebView` reload. Migrating style-only preferences to CSS variable injection (`var(--ambrosia-*)` in a `:root` block) would reduce this to a single `evaluateJavaScript` call for those changes; structural changes (reading mode switches, DOM layout changes) would still require a full reload.

---

## Annotations

Unified `Annotation` represents point annotations and ranged highlights:

- `startChar == endChar`: point annotation.
- `startChar != endChar`: ranged annotation/highlight.

Annotations are persisted in `AmbrosiaMetaDB.annotations`, not SwiftData. JS selection capture computes UTF-16 offsets with a TreeWalker. Highlights are restored through `HighlightBridge`; sidebar UI is SwiftUI in an `NSPanel`.

`BookmarkManager` is a dead stub. All current bookmark behavior is handled by the annotation system. `BookmarkSidebarView` is also dead; it has no instantiation site and is superseded by `AnnotationSidebarView`.

---

## Implemented Utilities

- CSV export of library books through `ExportManager`.
- Preferences window (Reader, Library, Window, Data tabs) for reader defaults, library appearance, custom Calibre column labels, AO3 extraction, and tag seed configuration.
- Optional FTS search through Calibre's `full-text-search.db`.
- Local RSS feed server via FlyingFox (`LocalFeedServer`), off by default; when running, always binds `.inet` (all interfaces) so other devices on the local network can connect — there is no loopback-only mode and no authentication. Serves `GET /` (HTML index of available feeds), `GET /feed/collection/<id>.xml` (one item per collection member), `GET /feed/search.xml` (last-published current-search snapshot, persisted as `CurrentSearchSnapshot` in `UserDefaults`), `GET /feed/random-daily.xml` (one seeded-random book per UTC day, opt-in), and `GET /feeds.opml` (OPML 2.0 export of every non-excluded collection feed plus the daily and search feeds). `RSSPublishView` is the SwiftUI publish sheet (searchable collection list, current-search/single-collection target selection, Publish / Copy Feed URL / Export OPML actions) presented as a sheet from `LibraryWindowController`. All routes are GET-only and read-only; there is no write-back path from a feed reader into Ambrosia yet (see Not Yet Built).
- Seeded random sort with Xorshift64 (`SeededRNG`), stable within a session.

---

## Not Yet Built

- Ranking UI and ELO matchup workflow.
- Reader table-of-contents popup.
- AO3 login, kudos, and AO3 bookmark posting.
- Saved searches.
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

5. Character offsets are UTF-16 code units in text nodes only. This contract must be consistent across `EPUBParser`, `PaginationJS`, `HighlightBridge`, and any JS that reads or writes offsets.

6. `WKWebViewConfiguration` message handlers must be registered before `WKWebView` is initialized.

7. Full HTML reload (`reloadHTML`) is required for reading mode switches and other DOM structural changes. It is not required for style-only preference changes (colors, typography, spacing); those should eventually use CSS variable injection to avoid re-parsing the EPUB on every tweak. Until that is implemented, the full reload path remains in place.

8. `evaluateJavaScript` calls that do not need a return value should pass `completionHandler: nil` to avoid retain cycles when the `WKWebView` tears down before the callback fires. Calls that capture a return value must use `[weak self]` closures and guard on `self`. The distinction is about memory safety, not style.

9. Full-pane `NSHostingView` instances whose frame is controlled by an external Auto Layout constraint (full-pane, sidebar fill, split-view pane) must set `sizingOptions = []`. `NSHostingView` instances in intrinsic-size contexts (preferences windows, popups, sheets) must not set it.

10. `AmbrosiaMetaDB` is the sole owner of `ambrosia_meta.db`. All reads and writes go through the actor, accessed via `LibrarySession.metaDB`. `CalibreLibrary` and the former `AO3TagSearchResolver` previously opened independent `Connection` objects to the same file, violating write-lock coordination; both have been fixed (`CalibreLibrary` now reads from caches pushed in via `updateAO3MetaCaches`, and tag resolution moved onto the `AmbrosiaMetaDB` actor). Do not reintroduce a third connection to this file.

11. All destructive schema migrations (DROP, ALTER with data movement) must be wrapped in `db.transaction` and gated on `PRAGMA user_version`, not on table existence. `IF NOT EXISTS` guards cannot prevent a migration from re-running on subsequent launches.

12. Force-unwraps are prohibited in any code path reachable from database read results. Use `guard let` with a logged fallback or propagate the error. The `series.works.first!` in `ReadingTarget.primaryBook` is a known crash site.

13. All diagnostic `print` calls must be wrapped in `#if DEBUG` or removed before shipping. `Thread.callStackSymbols` must never be called outside `#if DEBUG` blocks.

14. Do not hand-edit `Package.resolved`; add packages through the Xcode/SPM workflow.

15. Image temp directory lifetime is the app session; clean up on app termination.

16. `private` on a top-level type or function scopes it to the declaring *file*, not the module. Before marking a shared row-rendering type (e.g. `LibraryStats`, `TagPillDisplay`) or a shared free function (e.g. `isAnthology`, `missingIndices`, `parseISODate`, `logMissingVisibleWorkMetadata`) as `private`, grep the rest of the target for usages. If more than one file needs it, it is `internal` (the default — omit the modifier), not `private`. When splitting a fat view file into per-row files, this check is mandatory, not optional: it is the single most common source of "Cannot find X in scope" after a file split. Do not create a second, duplicate `private` copy of a helper in a new file as a workaround — that produces an "Invalid redeclaration" error the moment the original is later widened to `internal`, and it leaves two copies to keep in sync.

17. Values that configure a multi-call operation (e.g. `FilterBuilder`'s tag-synonym `tagExpansions`) are stored as a property set once at `init`, not threaded as a parameter through every downstream method across multiple files — but only when the type doing the storing is itself fresh per call, like `FilterBuilder`. This does not apply to methods living on `CalibreLibrary`: it is a long-lived `actor` shared across both surfaces and across overlapping in-flight queries, so caching a per-query value (e.g. `tagExpansions`) as actor state would let a stale query silently overwrite a newer one's value before it reads it back — the exact bug class Invariant 23 generalizes. `sqlFilterClause`, `sqlFragment`, `calibreIDs(matchingRules:)`, `bookCount`, `wordCountSortedPage`, `randomSortedPage`, and `fetchAllMatchingIDs` correctly keep `tagExpansions`/`filterTagExpansions` as an explicit parameter for this reason, confirmed by audit (some are called only through `FilterBuilder`, some directly from view code — either way, `CalibreLibrary`'s side of the call needs the value handed to it, not remembered). If a code review adds a default-valued parameter to more than two or three function signatures in the same change on a type that is itself fresh per call, stop and ask whether the value should be captured once as state instead; if the type is a shared actor or singleton, threading the parameter is very likely the correct choice, not a smell.

18. Do not invoke an `async` closure as a bare trailing argument (`someInit(x: { ... await ... }())`). The closure literal becomes implicitly `async` the moment its body contains `await`, and the call site needs `await` too, but nothing forces this to be visually obvious — the `await` keyword is buried inside the closure body, not next to the call. Resolve async values into a `let` on the line(s) before the call and pass the `let`.

19. Combining `async let` with a `Task.detached { ... }.value` initializer, where the detached closure captures a non-`Sendable` reference type (e.g. `CalibreLibrary?`), fails Swift 6 strict-concurrency checking even though the identical `Task.detached(...).value` pattern compiles fine as a plain (non-`async let`) assignment elsewhere in the same function. Prefer the plain sequential `let x = await Task.detached { ... }.value` form when the captured value is a non-Sendable type; do not assume `async let` and plain `await` are interchangeable here.

20. Renaming or removing a type or top-level function (e.g. an earlier `SeriesEntry` becoming `SeriesCacheEntry`) must be done with a project-wide search (Xcode's rename refactor or `grep -rl`), not by editing the declaration site from memory. A stale type name left at a call site does not always fail with a clear "unknown type" error in isolation — it can surface as a cascading "ambiguous expression" error several lines away, at the point where type inference depends on it.

21. Every commit that touches `.swift` files must pass `xcodebuild build` (or `swift build`) before merge. The bugs in invariants 16-20 are all hard compiler errors, not runtime bugs — a build gate catches all of them for free. There is no historical instance of one of these mistakes shipping that would have survived a green build.

22. Library visibility rules (skip/show-skipped, series-or-merged grouping, AO3-publisher-only, anthology-hiding) live in one value type, `LibraryVisibilityPolicy`, built fresh per surface (`currentVisibilityPolicy`) and passed as `visibility:` into `CalibreLibrary.wordCountSortedPage`/`randomSortedPage`. Do not reintroduce a bool + cached-`Set<Int>` pair wired independently through call sites for a new visibility toggle — add a field to `LibraryVisibilityPolicy` instead. The old `LibraryQueryHelpers.visibleIDs`/`.visibleBooks` free functions and the `excludeIDs:` parameter they fed are retired; do not resurrect either.

23. Async work that writes to shared or cached state on behalf of a UI surface must gate *every* one of its writes behind the same staleness check (task-cancellation or a generation/token guard) as its other results — not just the ones that are obviously part of the "final" result. A guard that protects some writes but not others is worse than no guard: code that reads the guarded writes assumes the whole function is safe, so the unguarded write's staleness is invisible on read. (Found in `applyFilterRules()`: `cachedFilterTagExpansions` was written several `await` points before the existing `libraryFilterApplicationToken` guard, so a superseded filter-application task could overwrite a newer task's tag-synonym expansions after the fact, even though the token guard correctly protected `activeFilterResult` and the other post-guard writes. Fixed by moving the write to after the guard, alongside the other post-guard writes, in both `LibraryRootView` and `EmailLibraryViewController`.)

24. Negated many-to-many filter conditions (tag/rating/warning/category/author/series `notEquals`/`notContains`) must be built as a correlated `NOT EXISTS (... WHERE btl2.book = b.id AND ...)` subquery, never as `b.id NOT IN (SELECT book FROM ... WHERE ...)`. The `NOT IN` shape forces SQLite to materialise the entire matching-book set and anti-join it against all of `books`, and a leading-wildcard `LIKE` inside that subquery can't use any index — a full scan of `tags` per evaluation. `NOT EXISTS` correlates on the outer book id, letting SQLite seek the `books_tags_link(book)` index per book instead. Relatedly: never add an outer `LEFT JOIN books_tags_link/tags` (or the authors/series equivalents) "to support" these fields — every one of them is already a self-contained correlated subquery aliased `btl2/t2` (or `bal2/a2`, `bsl2/s2`); an outer join with unused outer aliases only fans every book out to one row per tag before `SELECT DISTINCT` collapses it back down, multiplying the cost of every `NOT EXISTS` re-evaluation for no benefit. `FilterBuilder.swift` had this outer join removed already (see §9 in that file's comments); `CalibreLibrarySearch._bookCount(query:)` still has the equivalent dead join as of this writing — fix it the same way rather than treating the two files' SQL as independent.

25. In-memory-only filter fields (`isLiked`, `collection`, `status`, `crossover`, and `wordCount`/`kudos` without a configured custom column) are applied in `FilterBuilder.matchingIDsForGroup` as a post-filter over the SQL-backed rules' result *within the same group*, not recomputed from the full library. This is correct only because the code always computes SQL-backed-rule matches first (or falls back to `allCalibreIDs()` when a group has no SQL-backed rules) before intersecting/subtracting the in-memory rule's membership set. If you add a new in-memory-only `FilterField`, follow this same order — SQL rules (or the full-library set) first, in-memory rules second, applied per the group's own conjunction — rather than assuming in-memory rules can be evaluated independently and combined afterward; the existing OR-group union logic in particular depends on each in-memory branch reusing the same pre-narrowed `idSet`, not the raw membership map.

26. `LocalFeedServer` always binds `.inet(port:)` in `restartServerTask()` — there is no loopback-only mode or config flag for it. All routes are unauthenticated; the per-library shared-secret token that used to gate them (`FeedServerAuthToken`, `isAuthorized(_:)`) has been removed, so anyone on the local network who knows or guesses a feed URL can read it. Do not reintroduce a `bindLoopbackOnly`-style toggle without also adding real authentication; a network-scope toggle with no auth behind it is security theater, not a control. `localNetworkURLSync`'s LAN URL is always accurate under this invariant since there is only one bind mode.

27. Any UI surface that (a) can itself trigger `toolbarState.activeFilterResult` to change, and (b) also observes that same property to reload when something *else* changes it, must guard against double-triggering its own reload with a one-shot suppression flag (e.g. `suppressNextReloadToken`), set immediately before the surface's own reload call and consumed by the observer before it reloads. `LibraryRootView` has always done this via SwiftUI's `.onChange` plus a `@State` flag (`suppressNextReloadToken`, set in all three branches of `applyFilterRules()`, consumed in `.onChange(of: toolbarState.activeFilterResult?.reloadToken)`). `EmailLibraryViewController`'s hand-rolled `withObservationTracking` observer (`scheduleObservation()`, `toolbarStateDidChange()`) did not have the equivalent guard until fixed: every `applyFilterRules()` completion fired `scheduleLoadPage` twice — once explicitly, once via the observer — and the two calls raced through `scheduleLoadPage`'s `loadPageTask?.cancel()`-then-reassign, since they could originate from different execution contexts (the full-compute branch's `Task` is not `@MainActor`-isolated). Symptom: switching to email view, or applying a filter while already on it, showed stale/unfiltered sidebar results until a second manual reload. Fixed by adding `suppressNextReloadToken` to `EmailLibraryViewController`, mirroring `LibraryRootView`'s placement, and by writing `activeFilterResult` last (after `skippedIDs`/`seriesOrMergedIDs`/`ao3PublisherIDs`/`anthologyIDs`/`duplicateLoserIDs`/`cachedFilterTagExpansions`) in the full-compute branch, per Invariant 23. When adding a new UI surface that reads or writes `activeFilterResult` (or any other property multiple surfaces both mutate and observe), port this suppression pattern from the start — do not assume `withObservationTracking`/`.onChange` on a shared, multiply-written property is safe without it.