# Ambrosia — Export, Filter, Sort, and Catalog Plan

Companion to `ambrosia_architecture.md` and `projectplan3.md`. All decisions below are
final — proceed without asking the user to confirm any of them. Where a decision was
made by the user rather than inferred, that is noted inline as "User decision:".

---

## 0. Terminology: two unrelated "finished" concepts

| | What it means | Where it lives | Set by |
|---|---|---|---|
| `SystemCollectionID.finished` | The user has read the book | `collections`/`collection_members` (system collection, id `...004`) | `ReadingHistoryLogger` when `totalReadPercent >= 98`, or manual "Mark as Read" |
| `AO3CompletionStatus.finished/.unfinished` | The fic is complete on AO3 | `ao3_metadata.chapter_current`/`chapter_total`/`completed_date`/`updated_date` | AO3 extraction at import time |

These are unrelated and must stay unrelated. Section 5 renames only
`AO3CompletionStatus` cases, to **Complete / Work in Progress**. The reading-tracker
collection (`SystemCollectionID.finished`, UI label "Finished") keeps its name and ID —
do not touch it.

---

## 1. Fix CSV export pagination (page 1 only)

**Root cause:** `BookGridItem.swift` / `EmailLibraryViewController.swift` hold
`@State private var books: [CalibreBook]` — one page (25 rows) — and pass that array
directly into `ExportManager.presentExportPanel(books:)`. `ExportManager` has no bug;
it only ever receives the current page.

**Fix — fetch the full result set at export time, not the page:**

```swift
// BookGridItem.swift / EmailLibraryViewController.swift
private func exportCurrentView() {
    Task {
        let allBooks = await fetchAllMatchingBooks()   // new helper, defined below
        await MainActor.run {
            ExportManager.presentExportPanel(books: allBooks)
        }
    }
}

/// Re-runs the current query/filter with no page cap. Mirrors loadPage()'s three
/// branches (SQL-pageable, explicit-IDs, unfiltered) but fetches everything.
private func fetchAllMatchingBooks() async -> [CalibreBook] {
    guard let library = session.library else { return [] }
    let query = queryWithCachedFullText(/* current SearchQuery */)

    if let result = toolbarState.activeFilterResult, result.isSQLBacked {
        return library.books(offset: 0, limit: Int.max,
                              sort: toolbarState.sortField, ascending: toolbarState.ascending,
                              query: query, filter: toolbarState.filterExpression)
    } else if let result = toolbarState.activeFilterResult {
        return library.books(ids: visibleIDs(result.calibreIDs), offset: 0, limit: Int.max,
                              sort: toolbarState.sortField, ascending: toolbarState.ascending,
                              query: query)
    } else {
        return library.books(offset: 0, limit: Int.max,
                              sort: toolbarState.sortField, ascending: toolbarState.ascending,
                              query: query)
    }
}
```

Implementation requirements:
- `library.books(...)` already accepts `offset`/`limit`. Do not add a new query
  method — pass `Int.max` as `limit` instead of the page-size constant. SQLite's
  `LIMIT` accepts arbitrarily large values; the `WHERE` clause is unaffected.
- Run the same `visibleBooks`/`visibleIDs` post-filter (skip/series-merge/publisher
  suppression) on this fetch that `loadPage()` already runs. Do not reimplement that
  suppression logic for export — call the existing helpers, or exported rows will
  include books the user has hidden from view.
- Show a progress indicator while this runs. It is a synchronous SQLite call
  dispatched off the main actor; the save panel must wait for it to complete before
  presenting.
- This same `fetchAllMatchingBooks()` helper is reused by §2 (CSV enrichment), §3
  (EPUB folder export), and §6 (in-memory sort by word count / dates / completion).
  Build it once here, reuse everywhere else in this plan.

---

## 2. Enrich the CSV (AO3 metadata, collections, file location)

**Current state:** `ExportManager.exportToCSV` reads 7 columns directly off
`CalibreBook`. `CalibreBook.wordCount` and `.kudos` are always `nil` —
`CalibreLibrary._mapBookRows` never populates them. The real values live in
`ao3_metadata`, fetched via `AmbrosiaMetaDB.ao3Metadata(for:) -> [Int:
AO3MetadataRecord]`.

**Scope for this pass:** word count is wired up per §2a, which also covers the
existing filter and the broken sort — read §2a before implementing the CSV column
below, since the CSV's word-count cell must follow the same custom-column-primary,
`ao3_metadata`-fallback precedence established there, not just read `ao3_metadata`
directly. Kudos stays out of scope: the CSV column keeps reading `book.kudos` (always
blank) and is not touched in this pass.

**User decision — Collections column scope:** include all collections, both system
(Read Later, Liked, Series or Merged, etc.) and user-created. Do not filter to
user-created collections only.

**Implementation — pass enrichment data alongside books, do not add fields to
`CalibreBook`:**

```swift
// ExportManager.swift
struct ExportRow {
    let book: CalibreBook
    let ao3: AO3MetadataRecord?
    let collectionNames: [String]
    let epubAbsolutePath: String?
}

static func exportToCSV(rows: [ExportRow]) -> String {
    let header = [
        "Title", "Authors", "Series", "Tags",
        "Word Count", "Kudos",          // Kudos: book.kudos, always blank — out of scope this pass
        "Published Date", "Updated Date",
        "Status",                       // Complete / Work in Progress / Unknown — §5 naming
        "Fandoms", "Relationships", "Characters", "Additional Tags", "Category",
        "AO3 Collections", "AO3 Series", "Story URL", "AO3 Work ID",
        "Collections",                  // All Ambrosia collections, system + user-created
        "File Location"
    ]
    var csvRows: [[String]] = [header]
    for r in rows {
        csvRows.append([
            r.book.title,
            r.book.authors.joined(separator: "; "),
            r.book.displaySeries ?? "",
            r.book.tags.joined(separator: "; "),
            wordCountForCSV(book: r.book, ao3: r.ao3),   // §2a: custom column primary, ao3_metadata fallback
            r.book.kudos.map(String.init) ?? "",   // unchanged — out of scope
            r.ao3?.publishedDate ?? r.book.publishedDate.map(isoDate) ?? "",
            r.ao3?.updatedDate ?? "",
            completionLabel(r.ao3),                       // §5
            (r.ao3?.fandoms ?? []).joined(separator: "; "),
            (r.ao3?.relationships ?? []).joined(separator: "; "),
            (r.ao3?.characters ?? []).joined(separator: "; "),
            (r.ao3?.additionalTags ?? []).joined(separator: "; "),
            (r.ao3?.categories ?? []).joined(separator: "; "),
            (r.ao3?.ao3Collections ?? []).joined(separator: "; "),
            (r.ao3?.series ?? []).map(\.name).joined(separator: "; "),
            r.ao3?.storyURL ?? "",
            r.ao3?.workID ?? "",
            r.collectionNames.joined(separator: "; "),
            r.epubAbsolutePath ?? ""
        ])
    }
    return csvRows.map(csvRow).joined(separator: "\r\n") + "\r\n"
}
```

**Assembling `[ExportRow]` at the call site** — bulk fetch, do not N+1 query per book
(same pattern `rebuildItems()` already uses for series enrichment):

```swift
let books = await fetchAllMatchingBooks()   // §1
let ids = books.map(\.id)
let ao3Map = (try? await session.metaDB?.ao3Metadata(for: ids)) ?? [:]
let membershipByID = (try? await session.collectionStore?.membershipByCollectionID()) ?? [:]
let allCollections = (try? await session.collectionStore?.collections()) ?? []
let nameByID = Dictionary(uniqueKeysWithValues: allCollections.map { ($0.id, $0.name) })

// Invert membershipByID (collectionID -> Set<calibreID>) into calibreID -> [collectionName].
// Includes every collection returned by collections() — system and user-created alike,
// per the decision above. Do not filter this list.
var collectionsForBook: [Int: [String]] = [:]
for (collectionID, memberIDs) in membershipByID {
    guard let name = nameByID[collectionID] else { continue }
    for id in memberIDs { collectionsForBook[id, default: []].append(name) }
}

let rows = books.map { book in
    ExportManager.ExportRow(
        book: book,
        ao3: ao3Map[book.id],
        collectionNames: (collectionsForBook[book.id] ?? []).sorted(),
        epubAbsolutePath: session.library.flatMap { book.epubURL(libraryRoot: $0.root)?.path }
    )
}
```

This is two or three bulk DB calls total regardless of library size, not one call per
book.

---

## 2a. Word count: two existing systems, one broken, neither sourcing from the other

There are three independent word-count values in this codebase today, and they do
not talk to each other:

1. **A Calibre custom column**, optionally configured by the user. This is what the
   existing filter (`Word count >` / `Word count <` in the filter drawer) reads.
2. **`ao3_metadata.word_count`**, extracted automatically by Ambrosia from the AO3
   EPUB preface for every AO3 book. Used today only for on-screen display.
3. **`CalibreBook.wordCount`**, a field on the row-mapping struct that is never
   populated by any query (`CalibreLibrary._mapBookRows` leaves it `nil`
   unconditionally) -- effectively dead.

**User decision: the Calibre custom column is the primary source; `ao3_metadata` is
the fallback when no custom column is configured.** `ao3_metadata` is more reliable
in practice (automatic, present for every AO3 book, no setup required), but the
custom-column path is the deliberate, user-configurable override and must take
precedence when set.

### The filter: correct design, needs the fallback added

`FilterBuilder.wordCountSQL` already resolves through
`CustomColumnConfig.shared.wordCountLabel` -> `customColumnTableName(label:)` -> a real
Calibre `custom_column_<id>` table -- this matches Calibre's actual schema convention
correctly. There is a working Preferences UI for this
(`DataTab` in `PreferencesWindowController.swift` -- "Word count column" picker,
auto-detected on library open via `CustomColumnConfig.autoDetect(using:)` in
`BookGridItem.swift`).

**Current fallback when no custom column is configured:** the filter falls back to
`"0 = 1"` -- matches nothing, silently. This is safe (no crash, no wrong results) but
means the word-count filter does nothing at all for any library without a configured
custom column, even though `ao3_metadata.word_count` is sitting there populated for
every AO3 book.

**Fix -- fall back to `ao3_metadata` instead of `"0 = 1"`.** This cannot be a single
SQL fragment, because `ao3_metadata` lives in `ambrosia_meta.db`, a separate database
file from the Calibre connection `FilterBuilder` runs against -- the same
cross-database constraint covered in section 6's sort-by-date discussion, and
resolved the same way: do not `ATTACH`, do not introduce a second cross-database SQL
pattern. Resolve the fallback in Swift, in the caller, the same way
`.collection`/`.status`/`.crossover` are already handled:

```swift
// applyFilterRules(), alongside the existing statusMap/crossoverMap fetch.
// Only needed when no custom column is configured -- skip this fetch entirely otherwise.
let wordCountFallbackMap: [Int: Int]? = CustomColumnConfig.shared.wordCountLabel == nil
    ? (try? session.metaDB?.ao3Metadata(for: allCandidateIDs))?.compactMapValues(\.wordCount)
    : nil
```

```swift
// FilterBuilder.swift -- wordCountGT/wordCountLT, returns nil (no SQL fragment) when
// no custom column is configured, signaling the caller to apply the in-memory fallback:
case .wordCountGT:
    guard let n = rule.numericValue else { return nil }
    guard let label = CustomColumnConfig.shared.wordCountLabel,
          let tbl = customColumnTableName(label: label) else {
        return nil   // signal to caller: no SQL fragment -- apply wordCountFallbackMap instead
    }
    return ("b.id IN (SELECT book FROM \(tbl) WHERE value > ?)", [n as Binding?])
```

The caller in `applyFilterRules()` must then treat a `nil` return for a
`.wordCountGT`/`.wordCountLT` rule as "apply `wordCountFallbackMap` in-memory"
instead of silently dropping the rule (today's effective behavior with `"0 = 1"`) --
the same intersect/subtract pattern already used for `crossoverMap` in section 6.

This mirrors the existing `.collection`/`.status`/`.crossover` pattern exactly --
fields backed by `ao3_metadata` are evaluated in-memory against a pre-fetched map, not
as SQL. The only new logic is the **branch**: check
`CustomColumnConfig.shared.wordCountLabel` first; if set, keep the existing SQL path
unchanged; if not, route through the in-memory `ao3_metadata` fallback instead of
matching nothing.

### The sort: actually broken today, independent of the fallback question

`CalibreLibrary.orderByClause` has:
```swift
case .wordCount: return "COALESCE(b.custom_column_wordcount, 0) \(direction)"
```
`b.custom_column_wordcount` is not how Calibre custom columns work -- they are
separate tables (`custom_column_<id>`), never a column literally named
`custom_column_<label>` on `books`. No Calibre library has this column.
`SortField.allCases` is iterated unfiltered in the sort toolbar menu
(`LibraryWindowController.swift`), so "Word Count" is a real, selectable,
currently-broken menu item -- a live bug, not a theoretical one, independent of the
fallback-precedence question.

**Fix -- same primary/fallback precedence as the filter, resolved in-memory (using
section 6's shared `sortByAO3Metadata` helper) rather than via SQL:**

```swift
func sortedByWordCount(books: [CalibreBook], ascending: Bool,
                        ao3Map: [Int: AO3MetadataRecord]) -> [CalibreBook] {
    if let label = CustomColumnConfig.shared.wordCountLabel,
       let tbl = library.customColumnTableName(label: label) {
        // Primary: Calibre custom column. Real column, real table -- fetch via a
        // bulk query against tbl for the candidate ID set, not a per-book query loop.
        let valuesByID = library.bulkCustomColumnInts(table: tbl, ids: books.map(\.id))
        return books.sorted { a, b in
            let x = valuesByID[a.id], y = valuesByID[b.id]
            return compareNilsLast(x, y, ascending: ascending)
        }
    }
    // Fallback: ao3_metadata.word_count, via the shared helper from section 6.
    return sortByAO3Metadata(books: books, ao3Map: ao3Map, ascending: ascending) { $0.wordCount }
}
```

`bulkCustomColumnInts(table:ids:)` is new -- `CalibreLibraryPhase2.customColumnInt`
today queries one book at a time (`WHERE book = ?`); add a bulk variant
(`WHERE book IN (...)`) for this sort path, the same bulk-not-N+1 requirement applied
everywhere else in this plan.

### CSV export

Covered in section 2 — the `Word Count` column calls `wordCountForCSV(book:ao3:)`.
Per the precedence decision, this must match filter/sort precedence rather than only
reading `ao3_metadata`:

```swift
// ExportManager.swift — single helper, called from the section 2 CSV row builder
func wordCountForCSV(book: CalibreBook, ao3: AO3MetadataRecord?) -> String {
    if let label = CustomColumnConfig.shared.wordCountLabel,
       let value = customColumnWordCountMap[book.id] {   // bulk-fetched once per export, not per row
        return String(value)
    }
    return ao3?.wordCount.map(String.init) ?? ""
}
```

`customColumnWordCountMap` is bulk-fetched once for the full export's candidate ID
set (same bulk-fetch requirement as everywhere else in this plan — do not query the
custom column table per row), using the same `bulkCustomColumnInts(table:ids:)` added
for the sort fix above. Falls through to `ao3?.wordCount` when no column is
configured, keeping the CSV consistent with whatever the filter and sort are actually
using.

### Cleanup found along the way: dead `ColumnsTab`

`PreferencesWindowController.swift` defines two separate views with an identical
"Columns" section -- `ColumnsTab` (around line 730) and the Columns section inside
`DataTab` (around line 861). Only `DataTab()` is instantiated in the `TabView`;
`ColumnsTab` is never referenced anywhere and is dead code. Not required for this
fix, but delete `ColumnsTab` while touching this file -- leaving an unused
near-duplicate of the same picker logic next to the live one invites editing the
wrong copy later.

### Not in scope

Kudos stays on `book.kudos` (always blank) in filter, sort, and CSV. Same fix shape if
revisited later -- `CustomColumnConfig.shared.kudosLabel` as primary,
`ao3Metadata(for:).kudosCount` as fallback, identical structure to word count above --
deliberately deferred for now.

---

## 3. Export EPUBs in current view to a single folder

New capability — no existing partial implementation. Lives next to `ExportManager`,
reusing `fetchAllMatchingBooks()` from §1.

**User decision — filename collisions:** auto-rename on collision by appending
`-2`, `-3`, etc. Do not overwrite or skip; do not prompt per-file.

```swift
// ExportManager.swift
@MainActor
static func presentEPUBExportPanel(books: [CalibreBook], libraryRoot: URL,
                                    ao3Map: [Int: AO3MetadataRecord],
                                    filenameIDSource: ExportFilenameIDSource) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose Folder"
    panel.message = "Choose a folder to copy \(books.count) EPUB\(books.count == 1 ? "" : "s") into."

    panel.begin { response in
        guard response == .OK, let destination = panel.url else { return }
        Task.detached(priority: .userInitiated) {
            var copied = 0, skipped: [String] = []
            for book in books {
                guard let source = book.epubURL(libraryRoot: libraryRoot) else {
                    skipped.append(book.displayTitle); continue
                }
                let filename = book.exportFilename(ao3: ao3Map[book.id], idSource: filenameIDSource)
                let dest = uniqueDestination(for: filename, in: destination)   // auto-rename on collision
                do {
                    try FileManager.default.copyItem(at: source, to: dest)
                    copied += 1
                } catch {
                    skipped.append(book.displayTitle)
                }
            }
            await MainActor.run { presentEPUBExportSummary(copied: copied, skipped: skipped) }
        }
    }
}

/// Appends -2, -3, ... to the filename stem until no file exists at the resulting path.
private static func uniqueDestination(for filename: String, in directory: URL) -> URL {
    let ext = (filename as NSString).pathExtension
    let stem = (filename as NSString).deletingPathExtension
    var candidate = directory.appendingPathComponent(filename)
    var n = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = directory.appendingPathComponent("\(stem)-\(n).\(ext)")
        n += 1
    }
    return candidate
}
```

### Filename identifier: AO3 work ID vs. Calibre ID

**User decision — automatic fallback:** use the AO3 work ID when present; fall back
to the Calibre ID when not (non-AO3 imports, or extraction failure). No Preferences
toggle — this is the only behavior, not a configurable option.

- **AO3 work ID** — `AO3MetadataRecord.workID: String?`, already parsed from the
  preface's `Posted originally on the Archive of Our Own at
  https://archiveofourown.org/works/87288496.` line via regex `#"/works/([0-9]+)"#`.
  `nil` only for non-AO3 books or extraction failures.
- **Calibre ID** — `CalibreBook.id: Int`, always present.

```swift
extension CalibreBook {
    func exportFilename(ao3: AO3MetadataRecord?, idSource: ExportFilenameIDSource) -> String {
        let base = Self.sanitizedForFilename(displayTitle)
        let suffix = ao3?.workID ?? String(id)   // AO3 ID if present, else Calibre ID — always this order
        return "\(base)-\(suffix).epub"
    }

    static func sanitizedForFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return raw
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(120)
            .description
    }
}
```

No filename-sanitization helper exists anywhere in the codebase today — this is new,
small, self-contained, and shared by §3a (series folder export).

This needs no new DB schema, no `AmbrosiaMetaDB` changes, no `EPUBParser`
involvement — it is a `FileManager.copyItem` loop over the existing
`epubURL(libraryRoot:)` helper on `CalibreBook`.

---

## 3a. Series export: folder grouping

**User decision — scope:** build folder grouping only in this pass. Do not build the
merge-to-single-EPUB option (Option B in the original investigation) now — it
requires a new EPUB writer (no package found that provides one; see §9), is the
largest, most architecturally distinct piece of this entire plan, and is deferred to
its own future task.

**User decision — missing series entries:** proceed silently with whatever parts are
present. Do not warn or block when a series has gaps (e.g. parts 1, 2, 4 present, 3
missing).

Series membership and ordering already exist — `AmbrosiaMetaDB.seriesEntries(for:)`
returns `SeriesCacheEntry` rows with `seriesIndex` for ordering and `seriesKey`
(`"ao3:<id>"` or `"calibre:<name>"`, already computed) for grouping.

```swift
func exportSeriesGrouped(books: [CalibreBook], destination: URL, libraryRoot: URL,
                          seriesEntries: [Int: SeriesCacheEntry],
                          ao3Map: [Int: AO3MetadataRecord],
                          filenameIDSource: ExportFilenameIDSource) {
    for book in books {
        let targetFolder: URL
        if let entry = seriesEntries[book.id] {
            targetFolder = destination.appendingPathComponent(
                CalibreBook.sanitizedForFilename(entry.seriesName))
        } else {
            targetFolder = destination
        }
        try? FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        guard let source = book.epubURL(libraryRoot: libraryRoot) else { continue }
        let filename = book.exportFilename(ao3: ao3Map[book.id], idSource: filenameIDSource)
        let dest = uniqueDestination(for: filename, in: targetFolder)   // §3's collision rule
        try? FileManager.default.copyItem(at: source, to: dest)
        // No check against SeriesGroup.missingIndices or any other gap detection —
        // proceed with whatever entries are present, per decision above.
    }
}
```

Books not in any series go directly into the chosen root destination, not into a
subfolder. No new dependencies, no EPUB-format work — same `FileManager.copyItem` as
§3, nested one level deeper for series members.

---

## 3b. Tag-filtering on export: keep selected categories, strip freeform

`AO3MetadataRecord` already stores each tag bucket independently: `fandoms`,
`relationships`, `characters`, `additionalTags` (AO3's "freeform" tags — the
author-written, often joke-y tag pile, e.g. `"no beta we die like Jack's sight"`),
`categories`. Rating and warning are not `AO3MetadataRecord` fields — they live as
ordinary Calibre tags, classified via the existing `AO3TagKind.classify` in
`Database/AO3Metadata.swift`, which buckets any of Calibre's `tags` table entries into
`.rating`/`.warning`/`.category`/`.regular`. AO3 EPUB imports carry rating/warning/
category over as regular Calibre tags; `CalibreBook.tags` already has them mixed in
with everything else. No extraction change needed — this is purely a read-time filter
over data that already exists in two places.

```swift
struct TagExportOptions {
    var includeFandom = true
    var includeRelationship = true
    var includeCharacter = true
    var includeCategory = true     // from Calibre tags, via AO3TagKind.classify
    var includeRating = true       // from Calibre tags, via AO3TagKind.classify
    var includeWarning = true      // from Calibre tags, via AO3TagKind.classify
    var includeFreeform = false    // AO3's "Additional Tags" — default off
}

func filteredTagsForExport(book: CalibreBook, ao3: AO3MetadataRecord?,
                            options: TagExportOptions) -> [String] {
    var result: [String] = []
    if options.includeFandom, let ao3 { result += ao3.fandoms }
    if options.includeRelationship, let ao3 { result += ao3.relationships }
    if options.includeCharacter, let ao3 { result += ao3.characters }
    if options.includeFreeform, let ao3 { result += ao3.additionalTags }
    let buckets = AO3TagBuckets.from(tags: book.tags)   // existing classifier — reuse, do not reimplement
    if options.includeCategory { result += buckets.categories }
    if options.includeRating   { result += buckets.ratings }
    if options.includeWarning  { result += buckets.warnings }
    return result
}
```

**Where this plugs in:**
- **CSV export (§2):** replace `book.tags.joined(separator: "; ")` in the `Tags`
  column with `filteredTagsForExport(...).joined(separator: "; ")`. Since fandoms/
  relationships/characters already have dedicated columns in §2, the `Tags` column
  becomes the home for whatever else is selected (category/rating/warning, plus
  freeform if toggled on).
- **EPUB folder/series export (§3/§3a):** no effect — those are file copies, not
  metadata operations. Not in scope for a sidecar metadata file unless separately
  requested.
- **UI:** a "Tags to include" disclosure with the seven checkboxes above in the same
  export panel used for CSV and EPUB-folder export, defaulting to freeform off,
  everything else on.

No DB schema change — entirely a read-time filter over `ao3_metadata`'s tag-bucket
columns plus Calibre's `tags` table via the existing `AO3TagKind`/`AO3TagBuckets`
machinery.

---

## 4. Catalog: local RSS feed (collections + current search)

OPDS was evaluated and rejected. Calibre's own OPDS server reads directly off
`metadata.db` with no synonym/hierarchy layer — the synonym-expansion engine this
library's tag filtering depends on (`AO3TagSearchResolver.expandedTerms(for:)` in
`CalibreLibrarySearch.swift`, backed by `canonical_tags`/`tag_synonyms`/
`tag_parent_links` in `ambrosia_meta.db`) is entirely Ambrosia-side; Calibre's OPDS
server cannot honor synonym-aware tag search or fandom-hierarchy expansion regardless
of feed format. (Separately, `TagSynonymStore.swift` — a UserDefaults-backed synonym
store — has zero call sites anywhere in the app. Dead code, not part of this work.
The live system is `AO3TagSearchResolver` plus the SQLite tables.) The catalog must be
generated by Ambrosia, routed through `FilterBuilder`/`CollectionStore`, regardless of
feed format.

RSS was chosen over OPDS for two reasons specific to this app: (1) RSS's
`content:encoded` field carries the actual formatted book text inline —
`EPUBParser.mergedHTML(userCSS:)` already produces exactly this, the same code path
the in-app reader uses, so "send formatted text" is a one-field difference, not a new
rendering pipeline; OPDS's native payload is metadata-plus-binary-link, not inline
content. (2) The target client is NetNewsWire, a normal RSS reader — OPDS would
require an OPDS-capable client instead, which is not the target.

**User decision — build scope:** build the collections feed and the current-search
feed together, in one pass. Do not stage current-search as a separate later task.

### Design

1. **HTTP server.** FlyingFox (see §9 for package selection). Bind to loopback/LAN
   only, fixed or user-configured port, started/stopped from a Preferences toggle,
   off by default. This is a new always-on network listener — a deliberate change
   from the current no-network posture — so it must be opt-in, never auto-started.
2. **Feed index page** (plain HTML, not a feed, served at `/`): lists available
   feeds — one link per collection, plus a "Current Search" link.
3. **Per-collection feed** (`/feed/collection/<id>.xml`): RSS 2.0 +
   `content:encoded` namespace. One `<item>` per book in
   `CollectionStore.members(of: id)`:
   - `<title>` — `book.displayTitle`
   - `<description>` — `HTMLStripper.strip(book.comment)` (existing, reused from
     `displayComment`) plus an AO3 stats line (word count, fandoms, status) pulled
     from `ao3_metadata` via `AmbrosiaMetaDB.ao3Metadata(for:)`, same call as §2's CSV
     enrichment.
   - `<content:encoded>` — `EPUBParser(epubURL:).mergedHTML(userCSS: "")`,
     CDATA-wrapped.
   - `<pubDate>` — AO3 `published_date` if present, else Calibre's `pubdate`.
   - `<guid isPermaLink="false">` — stable per-book ID
     (`ambrosia-book-<calibreID>`), so republishing a collection does not surface
     already-seen books as new items.
4. **Current-search feed** (`/feed/search.xml`): same item shape, but the source ID
   set comes from a publish snapshot, not a live per-request query. On "Publish
   current view," capture `toolbarState.activeFilterResult?.calibreIDs` (already the
   full synonym-expanded, `FilterBuilder`-evaluated result) into a small persisted
   snapshot the server reads from. Do not re-run the filter pipeline on every
   NetNewsWire poll (typically every 10–60 minutes) — that recomputation cost is
   unnecessary for something that only changes when the user explicitly republishes.
5. **Item generation reuses existing code — list what is new vs. reused explicitly:**
   - Reused: `CollectionStore.members(of:)`, `toolbarState.activeFilterResult.calibreIDs`,
     `AmbrosiaMetaDB.ao3Metadata(for:)`, `EPUBParser.mergedHTML(userCSS:)`,
     `HTMLStripper.strip(_:)`.
   - New: RSS XML serialization, HTTP routing, the server lifecycle owner (point 7
     below), the current-search snapshot persistence.
6. **Per-item HTML cache.** `mergedHTML` re-parses the entire EPUB per call. Cache
   generated item HTML keyed by `(calibreID, epub file mtime)`; invalidate only when
   the underlying EPUB file's mtime changes, not on every poll. In-memory dictionary
   is sufficient at typical library sizes — no new SQLite table.
7. **Server lifecycle.** New `LocalFeedServer` actor/class, started from the
   Preferences toggle, torn down and restarted on library switch — the same
   ownership pattern `AmbrosiaMetaDB`/`CollectionStore` already follow through
   `LibrarySession`. Do not let it hold a reference across a library switch.
8. **Current-search snapshot persistence.** A single `UserDefaults` key holding the
   last-published ID list and timestamp. This is explicitly a snapshot, not queryable
   data — no new SQLite table.

No `AmbrosiaMetaDB` schema changes needed for the collections feed (reads existing
tables).

---

## 5. Rename AO3 "Finished/Unfinished" → "Complete/Work in Progress"

Pure rename. Extraction logic needs no change — verified against six real preface
samples covering every chapter/date shape (oneshot; same-day-complete multichapter;
multichapter completed on a later day; in-progress with known end; in-progress with
unknown end), and `AO3MetadataExtractor.parseStats` already produces the correct
`isComplete` value for all six. Isolated to `AO3CompletionStatus` — does not touch
`SystemCollectionID.finished`.

### Preface shapes, confirmed against real samples

| Shape | `Stats:` block contents | Example |
|---|---|---|
| Oneshot | `Published` only | "Am I even human?" (1/1) |
| Multichapter, all parts posted same day | `Published` only, no `Updated`/`Completed` | 恩恩乖乖 (5/5, all same date) |
| Multichapter, finished on a later day than started | `Published` and `Completed` | "The Third Option" (37/37, 2018→2020) |
| Multichapter, in progress, known end | `Published` and `Updated` | "When the Show's Over" (10/13) |
| Multichapter, in progress, unknown end | `Published` only, `Chapters: N/?` | "chasing the unknown" (1/?) |

AO3 only stamps a second date when publish and finish dates differ; same-day
completions collapse to a single `Published:` line.

### Extraction logic (verified correct, no change needed)

```swift
private static func parseStats(_ text: String, into record: inout AO3MetadataRecord,
                                completedDate: inout String?) {
    let tokens = text.components(separatedBy: .whitespacesAndNewlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    var index = 0
    while index < tokens.count - 1 {
        let key = tokens[index].trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let value = tokens[index + 1]
        switch key.lowercased() {
        case "published": record.publishedDate = value
        case "completed": completedDate = value; record.updatedDate = value
        case "updated":   record.updatedDate = value
        case "words":     record.wordCount = parseInt(value)
        case "chapters":  let c = parseChapters(value); record.chapterCurrent = c.current; record.chapterTotal = c.total
        case "kudos":     record.kudosCount = parseInt(value)
        default: break
        }
        index += 2
    }
}

record.isComplete = (
    record.chapterCurrent != nil &&
    record.chapterTotal != nil &&
    record.chapterCurrent == record.chapterTotal
) || completedDate != nil
```

Verified token-by-token against all six samples:

| Sample | Tokenized result | `isComplete` |
|---|---|---|
| Am I even human? (1/1) | chapters 1/1 | `true` (chapter match) |
| chasing the unknown (1/?) | chapters 1/? | `false` (no match, `?` total) |
| Con Crush Crunch (1/1) | chapters 1/1 | `true` (chapter match) |
| 恩恩乖乖 (5/5) | chapters 5/5 | `true` (chapter match) |
| The Third Option (37/37) | chapters 37/37, completed=2020-01-27 | `true` (both signals agree) |
| When the Show's Over (10/13) | chapters 10/13, updated=2026-06-24 | `false` (neither fires) |

The single-chapter coercion (`chapterCurrent`/`chapterTotal` defaulting to `1`/`1`
when both are `nil`, a few lines above the `isComplete` calculation) already covers
the oneshot case. No change to this precedence logic — leave as-is.

### Files touching `AO3CompletionStatus` (the rename)

- `FilterRule.swift` — enum definition (`.finished`/`.unfinished`, raw values
  `"Finished"`/`"Unfinished"`, `init?(userValue:)`)
- `AmbrosiaMetaDB.swift` — `ao3CompletionStatusIDs(_:)` switches on the same cases
- `BookGridItem.swift`, `EmailLibraryViewController.swift` — build `statusMap` keyed
  by the enum
- `SearchQueryParser.swift` — `status:` prefix parsing via
  `AO3CompletionStatus(userValue:)`
- `SearchSuggestionsView.swift` — suggestion list from `AO3CompletionStatus.allCases`
- `FilterDrawerView.swift` — picker `ForEach(AO3CompletionStatus.allCases)`

### Rename

```swift
enum AO3CompletionStatus: String, CaseIterable, Identifiable {
    case complete        = "Complete"
    case workInProgress  = "Work in Progress"

    var id: String { rawValue }

    init?(userValue: String) {
        switch userValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "complete", "finished":
            self = .complete
        case "work in progress", "wip", "incomplete", "unfinished":
            self = .workInProgress
        default:
            return nil
        }
    }
}
```

`"wip"` is accepted as input shorthand (not a raw value or picker label) since AO3
users type it routinely — `status:wip` in the search bar must resolve correctly.
`"finished"`/`"unfinished"` are accepted as legacy synonyms so saved/typed search text
and any `FilterRule.value` written before the rename continue to resolve via
`AO3CompletionStatus(userValue: rule.value)` in `FilterBuilder.swift`.

### No re-extraction needed

`is_complete` was already computed correctly at extraction time. The rename changes
only Swift-facing enum cases, raw values, and UI labels. Existing `ao3_metadata` rows
do not need to be regenerated.

### Out of scope, do not change

- `SystemCollectionID.finished` (UUID constant, "Finished" collection name) —
  unchanged.
- `EmailSidebarViewController.swift:696` — `current == total ? "Finished" :
  "Unfinished"`. This is a separate, ad-hoc string in the email sidebar's series
  progress label, not `AO3CompletionStatus`. Inspect this call site directly: if it
  reflects chapter current/total (the AO3 sense), rename it to "Complete"/"Work in
  Progress" for consistency; if it reflects the user's reading position, leave it
  unchanged.

### DB migration

None. `ao3_metadata.is_complete`, `published_date`, `updated_date` are already named
correctly and already populated correctly.

---

## 6. New filters and sort fields

### Crossover / non-crossover filter

`AO3MetadataRecord.fandoms: [String]` is already extracted per book. Crossover =
`fandoms.count > 1`. Evaluated in-memory (same as `.status`/`.collection`), since
fandom data lives in `ao3_metadata`, not Calibre.

```swift
// FilterRule.swift
enum FilterField: ... {
    case crossover   // new; label "Crossover"; boolean value type, like .isLiked
}
```

```swift
// FilterBuilder.swift — alongside the existing statusRules handling in matchingIDsForGroup
let crossoverRules = complete.filter { $0.field == .crossover }
if !crossoverRules.isEmpty {
    var idSet = Set(ids)
    for rule in crossoverRules {
        let wantsCrossover = rule.value == "true"
        idSet = wantsCrossover ? idSet.intersection(crossoverMap)
                                : idSet.subtracting(crossoverMap)
    }
    ids = Array(idSet).sorted()
}
```

```swift
// AmbrosiaMetaDB.swift — new method, same shape as the existing statusMap fetch
func crossoverBookIDs() throws -> Set<Int> {
    let rows = try prepare("SELECT calibre_id, fandoms_json FROM ao3_metadata")
    var result = Set<Int>()
    let decoder = JSONDecoder()
    for row in rows {
        guard let id = row.int(at: 0),
              let json = row[safe: 1] as? String,
              let data = json.data(using: .utf8),
              let fandoms = try? decoder.decode([String].self, from: data) else { continue }
        if fandoms.count > 1 { result.insert(id) }
    }
    return result
}
```

Thread `crossoverMap` through `applyFilterRules()` in both `BookGridItem.swift` and
`EmailLibraryViewController.swift`, next to the existing `statusValues`/`statusMap`
block, and add it as a parameter to `FilterBuilder.matchingIDs(...)`.

### Sort: random with a loggable seed

No `SortField.random` case exists. No seed generation or storage exists anywhere in
the app. No persisted search log exists to log a seed to (§7 covers building that).

**a) Seeded deterministic order in SQL.** SQLite has no native seeded `RANDOM()`; use
a deterministic hash of row ID + seed instead:

```swift
enum SortField: ... {
    case random   // new; label "Random"
}
```

```swift
// CalibreLibrary.orderByClause — seed must be threaded in as a parameter
func orderByClause(sort: SortField, direction: String, randomSeed: Int? = nil) -> String {
    switch sort {
    case .random:
        let seed = randomSeed ?? 0
        return "((b.id * 2654435761) + \(seed)) % 2147483647"
    // ...existing cases
    }
}
```

Plumb the seed from the toolbar sort menu down through `books(...)` →
`_fetchBooks`/`_fetchBooksQueryIDs` → `orderByClause`. Generate the seed once, when
the user selects "Random" (store on `LibraryToolbarState`:
`var randomSeed: Int = Int.random(in: 0...Int.max)`), and regenerate only when the
user explicitly re-randomizes — not on every `loadPage()` call, or every page turn
reshuffles the order.

**b) Logging the seed.** Requires §7's persisted search log (`SearchActivityLog` is
in-memory only today, no seed field). Add `randomSeed: Int?` to
`SearchActivityEntry`; pass `toolbarState.randomSeed` into the existing
`SearchActivityLog.shared.append(...)` call in `loadPage()` whenever
`toolbarState.sortField == .random`. To reproduce a past random order, tapping a past
log entry that used random sort must re-apply that stored seed rather than generating
a new one — build this re-apply path as part of this feature, not as a follow-up.

### Sort by publish date, update date, word count, and complete/WIP status

All four read from `ao3_metadata`, which lives in `ambrosia_meta.db` — a separate
database file from Calibre's `metadata.db`. `SortField.published` exists today but
incorrectly maps only to Calibre's `b.pubdate` (when the file was added to Calibre,
not when the fic was posted/updated). No `.updated` case exists. `SortField.wordCount`
queries `b.custom_column_wordcount`, which is not a real Calibre column (§2a).

**Decision: sort in-memory after fetching, not via cross-database SQL.** Investigated
`ATTACH DATABASE` as an alternative (attach `ambrosia_meta.db` into the Calibre
connection, `JOIN` across both in one query) and rejected it for this use case, for
three reasons:

1. **Precedent in this codebase already answers this.** `AO3TagSearchResolver` (in
   `CalibreLibrarySearch.swift`) already needs data from `ambrosia_meta.db` while
   working with Calibre data, and does it by opening a second, separate `Connection`
   to the meta database — never `ATTACH`. Follow this existing pattern rather than
   introducing a second way of doing the same kind of cross-database access.
2. **Read-only enforcement is non-trivial.** The architecture invariant is "Calibre DB
   connections are read-only; never write or issue write PRAGMAs." `ATTACH` itself
   doesn't write, but to have SQLite *enforce* read-only on the attached file (not
   just rely on the app never issuing a write), the attach must use a
   `file:...?mode=ro` URI, which requires the connection to have been opened with
   `SQLITE_OPEN_URI` — a connection-open-time flag that `SQLite.swift`'s
   `Connection(_:readonly:)` initializer does not expose directly. Workable, but it
   is additional plumbing (a raw `sqlite3_open_v2` call or equivalent), not a
   one-line change.
3. **It solves a different performance problem than the one that exists here.**
   `ATTACH` earns its cost when filtering or joining at the SQL level across a large
   dataset — e.g., selecting the top 50 of 50,000 rows by an indexed column, where
   pushing the work into the database engine avoids pulling every row into the
   application first. Sorting by word count/dates here is a **secondary sort on an
   already-filtered result set** — the candidate IDs are already known (typically
   hundreds, not tens of thousands) from the preceding filter/search step. Reordering
   an already-small in-memory array (`O(n log n)` in Swift) is not meaningfully slower
   than a SQL `ORDER BY` over a join for a set this size. The actual performance
   bottleneck in this app — confirmed elsewhere in this plan — is the *filter* step
   (tag NOT-matching, collection membership), not sorting an already-narrowed result.
   `ATTACH` would be worth real investigation only for a future feature that needs to
   *filter* directly on `ao3_metadata` columns across the entire unfiltered library
   (e.g., "show only books over 10,000 words" pushed down as a first-class SQL
   filter) — a different shape of problem than this sort.

**Implementation — one shared helper for all four sort keys:**

```swift
enum SortField: ... {
    case ao3Published   // ao3_metadata.published_date — distinct from existing .published (Calibre pubdate)
    case ao3Updated      // ao3_metadata.updated_date — new
    // .wordCount and .complete reuse this same in-memory path; no new enum cases needed for them
}

/// Shared by §2a (word count), this section (dates, completion), and any future
/// ao3_metadata-backed sort key. Fetches the candidate ID set unsorted, bulk-fetches
/// ao3_metadata once, sorts in Swift. Do not write a separate implementation per key.
func sortByAO3Metadata<T: Comparable>(
    books: [CalibreBook],
    ao3Map: [Int: AO3MetadataRecord],
    ascending: Bool,
    key: (AO3MetadataRecord) -> T?
) -> [CalibreBook] {
    books.sorted { a, b in
        let aVal = ao3Map[a.id].flatMap(key)
        let bVal = ao3Map[b.id].flatMap(key)
        switch (aVal, bVal) {
        case (nil, nil): return a.title < b.title   // stable tiebreaker
        case (nil, _): return false                  // nil always sorts last, both directions
        case (_, nil): return true
        case let (x?, y?): return ascending ? x < y : x > y
        }
    }
}
```

Call this with `key: { $0.wordCount }`, `key: { $0.publishedDate.flatMap(parseISODate) }`,
`key: { $0.updatedDate.flatMap(parseISODate) }`, or
`key: { $0.isComplete ? 1 : 0 }` (cast to a `Comparable` as needed) for the four
respective sort fields. This is the same "fetch IDs → bulk-fetch `ao3_metadata` →
sort in Swift" shape `rebuildItems()` already uses for series grouping — build all
four sort keys in one implementation pass using this shared helper, not as four
separate sort implementations.

`nil` (no AO3 metadata — non-AO3 imports, or extraction pending/failed) sorts last
regardless of direction, per the `switch` above — not "last when ascending, first
when descending," which is what a naive comparator would produce.

---

## 7. Filter-result caching across view switches

**Confirmed gap:** `LibrarySession.resolvedFulltextCache` caches only raw FTS phrase →
`[Int]` lookups (max 12 entries, evicted in dictionary-iteration order — not true
LRU; fix this ordering bug while touching this code). It does **not** cache the
result of `FilterBuilder.matchingIDs(...)` — the expensive part for collection/
status/tag filters. Every `applyFilterRules()` call re-fetches `collectionMap` and
`statusMap` from disk and reruns the full filter evaluation, regardless of whether
the identical expression was just evaluated seconds ago when switching List → Email →
List.

**Fix — cache `FilterResult` keyed by a canonical signature of the filter inputs, on
`LibrarySession`:**

```swift
// LibrarySession.swift
private var filterResultCache: [String: FilterResult] = [:]
private let filterResultCacheLimit = 8
private var filterResultCacheOrder: [String] = []   // true LRU

func cachedFilterResult(for key: String) -> FilterResult? {
    guard let result = filterResultCache[key] else { return nil }
    touchLRU(key)
    return result
}

func rememberFilterResult(_ result: FilterResult, for key: String) {
    filterResultCache[key] = result
    touchLRU(key)
    while filterResultCache.count > filterResultCacheLimit, let oldest = filterResultCacheOrder.first {
        filterResultCache.removeValue(forKey: oldest)
        filterResultCacheOrder.removeFirst()
    }
}

private func touchLRU(_ key: String) {
    filterResultCacheOrder.removeAll { $0 == key }
    filterResultCacheOrder.append(key)
}
```

**Cache key** must include a membership-version counter, not just the filter
expression — collection/status/crossover membership can change between evaluations
(e.g. liking a book, then returning to the same filter immediately):

```swift
let cacheKey = "\(LibraryFilterDebug.summary(expression: expression))|\(LibraryFilterDebug.summary(query: query))|\(session.membershipVersion)"
```

Bump `membershipVersion: Int` on `LibrarySession` on every `CollectionStore` write
(toggle like, skip, add to collection, etc. — all already funneled through
`CollectionStore`/`syncAutomatedCollection`; add one counter increment at each call
site). This invalidates the entire filter cache on any write rather than surgically
invalidating affected entries — acceptable at a cache size of 8 entries.

**Call site change in `applyFilterRules()`** (both `BookGridItem.swift` and
`EmailLibraryViewController.swift`):

```swift
let cacheKey = "\(LibraryFilterDebug.summary(expression: expression))|\(LibraryFilterDebug.summary(query: query))|\(session.membershipVersion)"
if let cached = session.cachedFilterResult(for: cacheKey) {
    toolbarState.activeFilterResult = cached
    currentPage = 0; loadPage()
    return   // skip the Task { } block entirely — no CollectionStore/AmbrosiaMetaDB round-trip
}
// ...existing Task { } pipeline...
// after computing `result`:
session.rememberFilterResult(FilterResult(calibreIDs: visibleFilteredIDs, totalCount: visibleFilteredIDs.count), for: cacheKey)
```

Going List → Email → List with the same filter active becomes a dictionary lookup
instead of a full `CollectionStore` + `AmbrosiaMetaDB` + `FilterBuilder` round trip.
Clear `filterResultCache` in `LibrarySession.close()` and `open(url:)`, alongside the
existing `resolvedFulltextCache.removeAll()` — both are session-scoped.

---

## 8. NOT-on-tag filter performance

**Confirmed root cause** in `FilterBuilder.swift`, `expandedTagFragment`/
`tagMembershipFragment`: `notContains` on `.tag` produces:

```sql
b.id NOT IN (
  SELECT book FROM books_tags_link btl2
  JOIN tags t2 ON t2.id = btl2.tag
  WHERE t2.name LIKE '%value%'   -- leading wildcard: no index use
     OR t2.name LIKE '%synonym1%' OR t2.name LIKE '%synonym2%' ...  -- synonym expansion multiplies this
)
```

Two costs stack: (1) leading-wildcard `LIKE` cannot use any index on `tags.name`,
forcing a full scan of `tags` per rule evaluation; (2) `NOT IN` over a correlated
subquery forces SQLite to materialize the entire "books with a matching tag" set,
then anti-join against all of `books` — there is no index-seek path for a negative
existence query the way there is for a positive one.

**Fix — rewrite as `NOT EXISTS`:**

```swift
private func tagMembershipFragment(matcher: String, args: [Binding?], negated: Bool) -> (String, [Binding?])? {
    guard !matcher.isEmpty else { return nil }
    if negated {
        return (
            "NOT EXISTS (SELECT 1 FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE btl2.book = b.id AND (\(matcher)))",
            args
        )
    }
    return (
        "EXISTS (SELECT 1 FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE btl2.book = b.id AND (\(matcher)))",
        args
    )
}
```

This mirrors the pattern `whereClause(for: query)` already uses for the positive tag
case (search-bar `tag:` terms use `EXISTS`, correlated on `btl2.book = b.id` — see
`CalibreLibrarySearch.swift` lines ~110–128). `FilterBuilder`'s `notContains` path is
the only place still using the slower `NOT IN` shape — align it with the existing
`EXISTS` pattern already used elsewhere in the same file.

**Do not add an index to `metadata.db`.** Calibre's database is read-only by
invariant; adding a covering index would write to the file, which the architecture
explicitly prohibits regardless of whether the write changes any row data. If
index-level speedup is still needed after the `NOT EXISTS` rewrite, it would require
a denormalized mirror table in `ambrosia_meta.db` kept in sync with Calibre's tag
data — a meaningfully larger change (a new sync mechanism) that should only be
pursued if the `NOT EXISTS` rewrite alone is confirmed insufficient.

This rewrite combines with §7's filter-result cache: the rewrite makes the first
evaluation of a NOT-tag filter faster; the cache makes repeated evaluations of the
same filter free.

---

## 9. Package selection

Two new capabilities in this plan need third-party code: the RSS feed's HTTP server
(§4), and EPUB writing (deferred per §3a's decision, but documented here for when
that work starts).

### HTTP server: FlyingFox

**Decision: use FlyingFox.**

- Repository: `https://github.com/swhitty/FlyingFox`
- Package index: `https://swiftpackageindex.com/swhitty/FlyingFox`
- Latest published version at time of writing: **0.26.2** (0.25.0 added Swift 6.2
  support). Requires Swift 5.9+ on Xcode 15+; runs on macOS 10.15+, iOS 13+, tvOS 13+,
  watchOS 8+, and Linux.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMajor(from: "0.26.0"))
]
// Target:
.target(name: "Ambrosia", dependencies: [
    .product(name: "FlyingFox", package: "FlyingFox")
])
```

Reasoning, evaluated against the four alternatives named:

| Package | Verdict | Why |
|---|---|---|
| **FlyingFox** | **Selected** | Zero package dependencies (confirmed via Swift Package Index — "This package has no package dependencies," including transitive and test dependencies). Built on Swift Concurrency (`async`/`await`) directly — no NIO. Runs on macOS 10.15+ — no platform-version floor increase for this app. MIT license. Actively maintained: 1,035 commits, 36 releases over 4 years, 9 open issues with the most recent closed about a month ago, most recent PR merged 9 days ago. Includes a `FileHTTPHandler` with partial-range-request support, directly applicable to streaming EPUB downloads if that's ever added to the feed server. Ships `FlyingFoxMacros` for declarative routing via `@HTTPHandler`/`@HTTPRoute`. |
| Hummingbird | Rejected | Full async web application framework (routing, middleware, TLS/HTTP2 support) — more machinery than a handful of feed routes needs. Requires macOS 14+, a platform floor increase. ~23 transitive dependencies via SwiftNIO (`swift-nio`, `swift-nio-extras`, `swift-service-lifecycle`, `swift-log`, `async-http-client`, `swift-configuration`). |
| async-http-client | Not applicable | This is an outbound HTTP *client* library (for making requests to other servers), not a server. Wrong category for this use case entirely. |
| swifter (httpswift) | Rejected | Unmaintained: last release 5 years ago, default branch last touched 4 years ago, 109 open issues, last PR merged 2 years ago. Pre-`async`/`await` (thread/blocking-IO based); its own documentation describes async I/O as an experimental, never-shipped "2.0" branch. |

Implementation shape, using the macro-based handler FlyingFox provides (avoids
hand-rolling a routing switch statement):

```swift
import FlyingFox
import FlyingFoxMacros

@HTTPHandler
struct AmbrosiaFeedHandler {
    let session: LibrarySession

    @HTTPRoute("GET /")
    func index() -> HTTPResponse { /* feed index page, §4 point 2 */ }

    @HTTPRoute("GET /feed/collection/:id.xml")
    func collectionFeed(_ request: HTTPRequest) async -> HTTPResponse { /* §4 point 3 */ }

    @HTTPRoute("GET /feed/search.xml")
    func searchFeed() async -> HTTPResponse { /* §4 point 4 */ }
}

let server = HTTPServer(port: 8080, handler: AmbrosiaFeedHandler(session: session))
let task = Task { try await server.run() }
// task.cancel() stops the server — this is the lifecycle hook the
// LocalFeedServer owner (§4 point 7) starts/stops from the Preferences toggle.
```

Run the server inside a `Task` owned by the `LocalFeedServer` lifecycle object from
§4 point 7; cancel that task to stop the server, per FlyingFox's documented shutdown
pattern.

### EPUB writing: no package found

**No package among the five investigated provides EPUB-writing capability.**
EPUBKit (`https://github.com/witekbobrowski/EPUBKit`) was checked specifically for
this — its own source file listing (`Model/EPUBCreator.swift`,
`Model/EPUBDocument.swift`, `Parser/EPUBParser.swift`, etc.) confirms it is read-only:
metadata, manifest, spine, and table-of-contents parsing only. `EPUBCreator` is a
*Dublin Core creator-role model* (author/editor/translator), not an EPUB-file writer.
It also pulls in two further dependencies (`Zip`, `AEXML`), adding dependency surface
for a capability it doesn't even provide. None of the other four packages investigated
(Hummingbird, FlyingFox, async-http-client, swifter) are EPUB-related at all.

When the deferred merge-to-single-EPUB work (§3a, Option B) starts, build the EPUB
writer directly on `ZIPFoundation`'s write APIs (`Archive(url:, accessMode: .create)`,
`addEntry`) — already a dependency of this project for reading, confirmed to also
expose write APIs, just not yet called anywhere in this codebase — plus hand-written
OPF/NCX XML via `XMLDocument`/`XMLElement` (Foundation, no package needed). This is
the same XML-writing groundwork needed for §4's RSS feed; if both features are ever
built, share that groundwork rather than writing it twice.

---

## Suggested build order

1. **§5 rename** (Complete/Work in Progress) — extraction needs no change (verified
   against six real samples); this is a Swift-side enum/label rename touching the
   most files but each change is mechanical. Do this first so later sections (CSV's
   Status column, §6's sort-by-completion) are written against final names.
2. **§8 NOT-tag fix** — isolated to two functions in `FilterBuilder.swift`,
   independently testable, no schema changes.
3. **§7 filter-result caching** — builds on §8 (faster underlying queries make the
   cache's benefit additive rather than masking a slow query); touches
   `LibrarySession` plus both `applyFilterRules()` call sites.
4. **§6 crossover filter + all sort additions, together with §2a's filter and sort
   fixes** — these share the same in-memory, pre-fetched-map pattern
   (`crossoverMap`, `wordCountFallbackMap`, `ao3Map`) on the filter side, and the
   same shared `sortByAO3Metadata` helper on the sort side. Build the word count
   filter's custom-column/fallback branch, the word count sort fix, crossover,
   random, and both date sorts in one pass — they are one implementation effort
   split across two files (`FilterBuilder.swift`, `CalibreLibrary.swift`), not
   several unrelated changes.
5. **§1 + §2 + §2a CSV export** — depends on §5 (Status column naming) and on §2a's
   custom-column lookup existing first (the CSV word-count cell calls the same
   precedence logic, not a separate implementation); reuses `fetchAllMatchingBooks()`
   from §1 and the bulk-fetch pattern from §6.
6. **§3 + §3a EPUB folder/series export** — independent of the above; can be built
   in parallel.
7. **§3b tag-filtering on export** — depends on §2's CSV column layout being in
   place; small, additive.
8. **§9 (FlyingFox dependency) then §4 local RSS feed server** — largest, newest,
   most architecturally distinct piece; build last. Add the FlyingFox package
   dependency first, then build collections feed and current-search feed together
   per the build-scope decision in §4.

Series merge-to-single-EPUB (§3a, Option B) is explicitly deferred — not part of this
build order, to be scoped as its own future task per the decision in §3a.
