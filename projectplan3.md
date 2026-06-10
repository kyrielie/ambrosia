# Ambrosia — Phase 9+ Implementation Guide

 **This is the detailed implementation guide and historical roadmap. Use the status labels on each phase before starting work.**
 Read this entire document before starting any phase. Read `ambrosia_architecture.md` alongside it.
 **The database migration (phases M1–M5) is complete in the current repo: collections and annotations now live in per-library `ambrosia_meta.db`; SwiftData is limited to `BookState` and `ReadingGoal`.**
 
 ---
 
 ## Current Project State
 
 ### What exists and works
- **Data layer:** `CalibreLibrary` (read-only SQLite.swift on Calibre's `metadata.db`), `LibrarySession`, `LibraryRegistry`, optional `CalibreFTSLibrary`, and per-library `AmbrosiaMetaDB`. Book fetches are paginated (100 + 1 per page). Series always joins through `books_series_link + series`; no `b.series` column.
- **Per-library app DB:** `ambrosia_meta.db` lives under `~/Library/Application Support/Ambrosia/libraries/<hash>/` and stores collections, collection membership, annotations, AO3 metadata, AO3 extraction diagnostics, series cache/placeholders, canonical tags, tag synonyms, parent links, and subtag sections.
- **Collections:** `CollectionStore` backs system collections: Read Later, Liked, Skipped, Finished, In Progress, Has Annotations, and Series or Merged. `Has Annotations` is synced by annotation writes. `Series or Merged` is synced from collapsed series members and anthology-style merged works.
- **AO3 extraction:** `AO3MetadataExtractor` uses SwiftSoup. `LibrarySession` extracts from the first few EPUB spine items in the background, persists rich AO3 metadata, writes extraction diagnostics for skipped/failed books, and supports re-extraction from preferences.
- **Series:** `series_cache` is populated from AO3 metadata and Calibre fallback data. Current UI uses representative grouped/collapsed series rows and `Series or Merged`; the original missing-work placeholder-note sheet is not part of the current UX.
- **Tag seeds:** Configured AO3 seed databases can be imported into canonical/synonym/hierarchy tables. Storage and seed import are present; complete UI wiring for every tag-bearing surface is not finished.
- **Library UI:** List view (`LibraryRootView` + `BookListRow`) and Email view (`NSSplitViewController` + `NSTableView` sidebar + SwiftUI detail pane). Native `NSToolbar` via `LibraryToolbarState` (`@Observable`). Filter drawer with `FilterBuilder`. Ranking mode is still a placeholder.
- **Reader:** `ReaderViewController` with `WKWebView`, scroll mode, paginated mode via CSS multi-column layout, `EPUBParser` (ZIPFoundation + NSXMLParser), custom context menu, annotation sidebar, and annotation popover.
- **Annotations:** Unified `Annotation` records are persisted in `AmbrosiaMetaDB.annotations`, not SwiftData. Both point annotations and ranged highlights use UTF-16 text-node offsets.
- **Preferences:** Reader typography, spacing, colors, default reading mode, library appearance, default reader window sizing, context-menu preferences, custom Calibre column labels, AO3 extraction controls, and tag seed configuration.
- **Search/export:** `SearchQueryParser` supports `tag:`, `author:`, `title:`, `series:` prefix syntax. `CalibreFTSLibrary` provides optional FTS5 search with fallback. CSV export is implemented.
 
 
 ### What does NOT yet exist
Ranking UI, TOC popup, AO3 login/kudos/bookmarks, saved searches, favourite authors, saved quotes, annotation export/sharing, standalone mode without Calibre, and music integration.
 
 ---
 
 ## Session Discipline
 
 **Rule 1 — Diagnose before writing:**
 ```bash
 grep -rn "TODO\|FIXME" /path/to/project/
 xcodebuild -scheme Ambrosia -destination 'platform=macOS' build 2&gt;&amp;1 | grep -E "error:|warning:"
 ```
 The build output is truth. Your memory of previous sessions is not.
 
 **Rule 2 — One approach to completion.** If a partial implementation exists, continue it. Do not restart.
 
 **Rule 3 — Never claim clean build without running `xcodebuild`.**
 
 **Rule 4 — Write a handoff block before ending:**
 ```
 
 ---
 
 ## Persistent Stores
 
 ### `ambrosia_meta.db` — per-library instance
 **Location:** `~/Library/Application Support/Ambrosia/libraries/&lt;hash&gt;/ambrosia_meta.db`
 
 One per library folder. `&lt;hash&gt;` is derived from the library path — see Phase M1.
 One write-enabled connection in the entire app per library. Calibre's `metadata.db` is read-only forever.
 
 ```swift
 actor AmbrosiaMetaDB {
     // NOT a singleton — one instance per open library, owned by LibrarySession
     let libraryHash: String
     private let db: Connection  // read-write
 
     init(libraryURL: URL) throws { ... }
 }
 ```
 
 Read-only queries (`TagSynonymResolver`, `StatsView`, `MusicTriggerEngine`) may use a separate
 `Connection(path, readonly: true)` — no actor needed for reads.
 
 All tables use `CREATE TABLE IF NOT EXISTS` — phases run DDL on startup in any order.
 
 **New invariant:** `AmbrosiaMetaDB` is never a singleton. It is always accessed through
 `LibrarySession`. Any code that holds a direct reference across a library switch holds a closed
 connection to the previous library's database.
 
 ### SwiftData — `BookState` and `ReadingGoal` only
 
 `BookState` holds reading session state only: position, progress, ELO. See final shape above.
 `ReadingGoal` is unchanged. `Collection @Model` is removed in Phase M2.
 
 The crash-and-retry mechanism in `AmbrosiaApp` (catches `ModelContainer` init error, deletes all
 Application Support files, retries) **must be removed before Phase M4 ships.** It would silently
 wipe reading positions and ELO scores on a migration failure. Replace with a user-facing error alert.
 
 ---
 
 ## Phase 9 — AO3 EPUB Metadata Extraction — Status: Mostly complete
 **Dependencies:** M-track complete. Track A (blocks 10, 11, 14 dashboard, 18).
 
 **Goal:** On library open, silently parse AO3 EPUB header pages and persist rich metadata
 not in Calibre's DB.

 **Current repo note:** Implemented with `AO3MetadataExtractor`, `AO3MetadataRecord`, background extraction in `LibrarySession`, `ao3_metadata`, `ao3_extraction_diagnostics`, `ExtractionProgress`, and Preferences re-extraction. Remaining work is polish and any display coverage not yet wired to all planned surfaces.
 
 ### `ao3_metadata` DDL
 ```sql
 CREATE TABLE IF NOT EXISTS ao3_metadata (
     calibre_id INTEGER PRIMARY KEY,
     story_url TEXT,
     ao3_work_id TEXT,
     ao3_author_username TEXT,
     kudos_count INTEGER,
     word_count INTEGER,
     chapter_current INTEGER,
     chapter_total INTEGER,       -- NULL if unknown ('?')
     is_complete INTEGER NOT NULL DEFAULT 0,
     language TEXT,
     published_date TEXT,         -- ISO-8601
     updated_date TEXT,           -- ISO-8601
     fandoms_json TEXT,           -- JSON array of strings
     relationships_json TEXT,
     characters_json TEXT,
     additional_tags_json TEXT,
     category_json TEXT,          -- JSON array: values from {"F/F","F/M","M/M","Gen","Multi","Other"}
     ao3_collections_json TEXT,
     series_json TEXT,            -- JSON [{"name":str,"index":int,"ao3_id":str}]
     extracted_at TEXT NOT NULL   -- ISO-8601
 );
 ```
 
 ### AO3 EPUB header structure
 ```html
 &lt;dl class="work meta group"&gt;
   &lt;dt class="tags"&gt;Fandoms:&lt;/dt&gt;&lt;dd&gt;&lt;ul&gt;&lt;li&gt;&lt;a&gt;Name&lt;/a&gt;&lt;/li&gt;&lt;/ul&gt;&lt;/dd&gt;
   &lt;dt&gt;Language:&lt;/dt&gt;&lt;dd&gt;English&lt;/dd&gt;
   &lt;dt&gt;Published:&lt;/dt&gt;&lt;dd&gt;2021-03-15&lt;/dd&gt;
   &lt;dt&gt;Updated:&lt;/dt&gt;&lt;dd&gt;2023-11-02&lt;/dd&gt;
   &lt;dt&gt;Words:&lt;/dt&gt;&lt;dd&gt;142,350&lt;/dd&gt;   &lt;!-- strip commas before parseInt --&gt;
   &lt;dt&gt;Chapters:&lt;/dt&gt;&lt;dd&gt;23/30&lt;/dd&gt;  &lt;!-- '?' means unknown total --&gt;
   &lt;dt&gt;Series:&lt;/dt&gt;
   &lt;dd&gt;&lt;ul&gt;&lt;li&gt;Part &lt;span&gt;2&lt;/span&gt; of &lt;a href="/series/12345"&gt;Series Name&lt;/a&gt;&lt;/li&gt;&lt;/ul&gt;&lt;/dd&gt;
 &lt;/dl&gt;
 ```
 
 Work URL/ID: derivable from `&lt;a&gt;` links to `/works/WORK_ID` on the page.
 
 ### `AO3MetadataExtractor`
 A Swift `struct`. Takes raw HTML, returns `AO3Metadata?`.
 - Detect by presence of `dl class="work meta group"`. Return `nil` if absent.
 - **Use `SwiftSoup`** (not `NSXMLParser`) — AO3 HTML contains malformed tags that break SAX.
 - Chapters: split on `/`. Second component `"?"` → `chapter_total = nil`. If `chapter_current == chapter_total` (both non-nil) → `is_complete = true`.
 - Word count: strip commas before `Int()`.
 - Series: each `&lt;li&gt;` → part index from `&lt;span&gt;`, name + AO3 ID from `&lt;a href="/series/ID"&gt;`. Build JSON array.
 - **Tags:** extract five separate lists — fandoms, relationships, characters, additional tags, and category — each from their respective `&lt;dt class="tags"&gt;` label. Store each as a JSON array. Category values are a closed set (`F/F`, `F/M`, `M/M`, `Gen`, `Multi`, `Other`); store any unrecognised value as-is without logging an error.
 
 ### Background extraction
 ```swift
 // In LibrarySession, after CalibreLibrary and metaDB are ready:
 Task.detached(priority: .background) {
     let allIDs   = /* SELECT id FROM books */
     let existing = /* SELECT calibre_id FROM ao3_metadata */
     let missing  = Set(allIDs).subtracting(existing)
     for batch in missing.chunked(into: 50) {
         for id in batch {
             if let epub = /* locateEPUB(calibreID: id) */,
                let html = EPUBParser(epub).html(for: 0, userCSS: ""),
                let meta = AO3MetadataExtractor.extract(from: html) {
                 await librarySession.metaDB?.insert(meta, calibreID: id)
             }
         }
     }
 }
 ```
 
 `@Observable ExtractionProgress(completed: Int, total: Int)` on `LibrarySession`. Toolbar
 shows "Enriching library…" while in progress. Library is fully usable during extraction.
 
 Preferences → Data: "Re-extract AO3 metadata" button — deletes all `ao3_metadata` + `series_cache` rows and re-runs.
 
 ### Reading progress % display
 `BookState.totalReadPercent` already exists. Display in list (chip/bar), email (detail pane header), grid (thin bar at bottom of cover card). Show nothing (not 0%) for never-opened books.
 
 ### Open questions (resolve with product owner before implementing)
 1. For ongoing works (`chapter_total NULL`): display "23/?" or "23 ch"?
 2. Compare `extracted_at` against EPUB filesystem mtime to auto-re-extract on update?
 
 ---
 
 ## Phase 10 — Series Grouping and Cache — Status: Partially complete
 **Dependencies:** Phase 9. Track A.
 
 **Goal:** Collapse multi-work series into single library rows. Cache series data to avoid per-page Calibre JOINs. Anthology detection. Missing-work warnings.

 **Current repo note:** `series_cache`, Calibre fallback seeding, collapsed series membership, anthology sync, and representative grouped/collapsed series rows are implemented. The original placeholder-note sheet and full concatenated series reader workflow are not current behavior.
 
 ### DDL
 ```sql
 CREATE TABLE IF NOT EXISTS series_cache (
     calibre_id INTEGER NOT NULL,
     series_name TEXT NOT NULL,
     series_index INTEGER NOT NULL,
     ao3_series_id TEXT,
     is_anthology INTEGER NOT NULL DEFAULT 0,
     PRIMARY KEY (calibre_id, series_name)
 );
 CREATE INDEX IF NOT EXISTS idx_series_cache_name ON series_cache(series_name);
 CREATE INDEX IF NOT EXISTS idx_series_cache_calibre ON series_cache(calibre_id);
 
 CREATE TABLE IF NOT EXISTS series_placeholders (
     series_name TEXT NOT NULL,
     part_index INTEGER NOT NULL,
     note TEXT,
     PRIMARY KEY (series_name, part_index)
 );
 ```
 
 Populate from `ao3_metadata.series_json` in the Phase 9 background task. Fall back to
 Calibre's `books_series_link` JOIN for non-AO3 EPUBs.
 
 ### Anthology detection (excluded from series grouping)
 - Description (Calibre `comments`) starts with "Anthology" (case-insensitive, after stripping whitespace), **or**
 - `series_cache.is_anthology = 1` (user-flagged via context menu).
 
 ### `SeriesGroup` (never persisted — invariant 20)
 ```swift
 struct SeriesGroup: Identifiable {
     let id: String          // series_name — stable identifier
     let seriesName: String
     let works: [CalibreBook]          // ALWAYS ordered by series_index ASC (invariant 23)
     let allFandoms: [String]
     let allTags: [String]
     let allAuthors: [String]
     let allDescriptions: [String]     // one per work, in index order
     let totalWordCount: Int
     let earliestPublished: Date?
     let latestUpdated: Date?
     let missingIndices: [Int]         // gaps, e.g. [3] if indices 1,2,4 exist
     let isComplete: Bool              // true only when every work is is_complete
 }
 ```
 
 ### Library item enum
 ```swift
 enum LibraryItem: Identifiable {
     case book(CalibreBook)
     case series(SeriesGroup)
     var id: String {
         switch self {
         case .book(let b): return String(b.id)
         case .series(let s): return s.id
         }
     }
 }
 ```
 
 "Group by series" toggle: `LibraryToolbarState.groupBySeries: Bool`, persisted in `UserDefaults`.
 All three view modes return `[LibraryItem]`.
 
 ### Series row display (list + email views)
 Series name (bold), work count ("4 works"), combined word count, date range ("2021–2023"),
 union of all fandoms/tags, warning badge when `missingIndices` non-empty. Clicking warning
 badge → sheet to enter placeholder notes → written to `series_placeholders`.

 **Deviation from current implementation:** Missing-series placeholder note UI was removed from the active UX. `Series or Merged` uses representative grouped/collapsed series rows and system collection membership rather than requiring users to maintain placeholder notes.
 
 ### Series context menu
 - "Open Series" — opens concatenated reader session
 - "Show Individual Works" — expands inline to individual book rows
 - "Mark/Unmark as Anthology"
 - "Hide Series" (Phase 13)
 
 ### Concatenated reader session
 ```swift
 enum ReadingTarget {
     case singleBook(CalibreBook)
     case series(SeriesGroup)
 }
 ```
 For `.series`: one `EPUBParser` per work; join `mergedHTML()` results with:
 ```html
 &lt;div class="ambrosia-series-break"&gt;&lt;h2&gt;Work [N]: [Title]&lt;/h2&gt;&lt;/div&gt;
 ```
 `BookState` key = first work's `calibreID`. Spine indices are flat across all EPUBs.
 
 ### Open questions (resolve before implementing)
 1. Should missing-index placeholders inject a synthetic HTML page in the reader?
 2. `totalReadPercent` for series: combined word count or per-work? (recommend per-work for v1)
 
 ---
 
 ## Phase 11 — AO3 Tag Synonyms and Tag Classification — Status: Partially complete
 **Dependencies:** Phase 9. Track A.
 
 **Goal:** Resolve tag queries to canonical AO3 forms using a pre-built seed database. Wire
 every tag-bearing surface through `TagSynonymResolver`. Treat AO3's structured tag categories
 as first-class distinct fields.

 **Current repo note:** The per-library tag tables exist and configured seed database import/cache clearing is implemented through `AmbrosiaMetaDB` and preferences. Complete query/display wiring across every tag-bearing surface remains incomplete.
 
 ### Background: what the scraper produced
 
 The seed data comes from `ao3_seed_scraper.py`, run against the library's tag URLs offline.
 It produced `AO3TagSeeds.swift` — drop into the Xcode project and never edit by hand.
 To regenerate from an existing `ao3_tag_seeds.db` without re-scraping:
 
 ```bash
 python3 ao3_seed_scraper.py --swift-only --output-dir ./output
 ```
 
 `AO3TagSeeds.swift` exposes:
 ```swift
 struct AO3TagSeeds {
     static let synonyms: [(synonym: String, canonical: String, tagType: String)]
     static let parentLinks: [(child: String, parent: String)]
     static func loadIfNeeded(db: OpaquePointer) throws
     // INSERT OR IGNORE — safe to call again. Targets raw SQLite pointer for ambrosia_meta.db.
 }
 ```
 
 **Invariant:** `synonym` is never equal to its canonical's name in the seed data.
 
 ### DDL
 ```sql
 CREATE TABLE IF NOT EXISTS canonical_tags (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     name TEXT NOT NULL UNIQUE,
     tag_type TEXT NOT NULL,  -- 'fandom'|'character'|'relationship'|'additional'|'unknown'
     last_fetched TEXT        -- ISO-8601; NULL for seed entries
 );
 
 CREATE TABLE IF NOT EXISTS tag_synonyms (
     synonym TEXT NOT NULL,
     canonical_id INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
     PRIMARY KEY (synonym)
 );
 CREATE INDEX IF NOT EXISTS idx_tag_synonyms_canonical ON tag_synonyms(canonical_id);
 
 CREATE TABLE IF NOT EXISTS tag_parent_links (
     child_id  INTEGER NOT NULL REFERENCES canonical_tags(id),
     parent_id INTEGER NOT NULL REFERENCES canonical_tags(id),
     PRIMARY KEY (child_id, parent_id)
 );
 CREATE INDEX IF NOT EXISTS idx_tag_parent_links_child  ON tag_parent_links(child_id);
 CREATE INDEX IF NOT EXISTS idx_tag_parent_links_parent ON tag_parent_links(parent_id);
 
 CREATE TABLE IF NOT EXISTS tag_subtag_sections (
     child_id  INTEGER NOT NULL REFERENCES canonical_tags(id),
     parent_id INTEGER NOT NULL REFERENCES canonical_tags(id),
     section   TEXT,
     PRIMARY KEY (child_id, parent_id)
 );
 ```
 
 Do **not** create `fandom_hierarchy` — it does not exist in the seed data (invariant 34).
 
 ### AO3 tag category model
 
 | AO3 field | `tag_type` | Source | Notes |
 |---|---|---|---|
 | Fandoms | `'fandom'` | `&lt;dt class="tags"&gt;Fandoms:&lt;/dt&gt;` | Hierarchy applies |
 | Relationships | `'relationship'` | `&lt;dt class="tags"&gt;Relationships:&lt;/dt&gt;` | Wrangled |
 | Characters | `'character'` | `&lt;dt class="tags"&gt;Characters:&lt;/dt&gt;` | Wrangled |
 | Additional Tags | `'additional'` | `&lt;dt class="tags"&gt;Additional Tags:&lt;/dt&gt;` | Freeform; no hierarchy |
 | Category | `'category'` | `&lt;dt class="tags"&gt;Category:&lt;/dt&gt;` | Closed vocab; NOT in `canonical_tags` |
 
 Calibre's `tags` table mixes all five types into a single flat list with no type column.
 Tag type comes from `ao3_metadata` JSON columns or `canonical_tags.tag_type` — never from
 Calibre's `tags` table (invariant 35).
 
 Category tags are stored in `ao3_metadata.category_json` only — never passed through
 `TagSynonymResolver` (invariant 36).
 
 ### What goes through `TagSynonymResolver`
 
 | Surface | Resolver | Notes |
 |---|---|---|
 | Search bar `tag:` query | Yes | Resolve before building SQL |
 | Filter drawer tag rules | Yes | Resolve before `FilterBuilder` |
 | Tag pill taps | Yes | Tag came from Calibre; may need resolution |
 | Fandom hierarchy expansion | Yes — fandom/character/relationship only | Never additional tags |
 | Category filter | **No** | Query `ao3_metadata.category_json` directly |
 | Tag display in rows | **No** | Display Calibre's raw strings |
 | Hidden-tags suppression | Yes | Resolve stored hidden tag before comparing |
 
 ### `TagSynonymResolver`
 
 ```swift
 final class TagSynonymResolver {
     private let db: Connection  // read-only; separate from AmbrosiaMetaDB write actor
 
     func canonical(for inputTag: String) async -&gt; String
     // Step 1: SELECT id FROM canonical_tags WHERE name = ? → already canonical
     // Step 2: SELECT c.name FROM tag_synonyms s JOIN canonical_tags c ... WHERE s.synonym = ?
     // Step 3: unknown → queue background AO3 fetch; return inputTag unchanged
 
     func canonicalBatch(for tags: [String]) async -&gt; [String: String]
     // Batch steps 1+2 as IN queries. Always use this for multi-tag input (invariant 37).
 }
 ```
 
 ### Fandom hierarchy expansion
 
 ```sql
 WITH RECURSIVE descendants(id) AS (
     SELECT child_id FROM tag_parent_links WHERE parent_id = (
         SELECT id FROM canonical_tags WHERE name = ?
     )
     UNION
     SELECT tpl.child_id FROM tag_parent_links tpl
     JOIN descendants d ON tpl.parent_id = d.id
 )
 SELECT name FROM canonical_tags WHERE id IN (SELECT id FROM descendants);
 ```
 
 Only when `UserDefaults` key `"fandomHierarchyEnabled"` is true (default `false`).
 Apply only to `'fandom'`, `'character'`, `'relationship'` types (invariant 38).
 Cache results per input tag per session. Invalidate on "Clear synonym cache".
 
 ### Seed loading
 
 On first launch per library (`UserDefaults` key `"tagSeedLoaded_&lt;libraryHash&gt;"`):
 call `AO3TagSeeds.loadIfNeeded(db:)` in `Task.detached(priority: .background)`.
 
 ### "Clear synonym cache" button
 
 Preferences → Library → Tag Synonyms → "Clear synonym cache":
 
 ```sql
 DELETE FROM tag_synonyms WHERE canonical_id IN (
     SELECT id FROM canonical_tags WHERE last_fetched IS NOT NULL);
 DELETE FROM tag_parent_links WHERE child_id IN (
     SELECT id FROM canonical_tags WHERE last_fetched IS NOT NULL)
    OR parent_id IN (SELECT id FROM canonical_tags WHERE last_fetched IS NOT NULL);
 DELETE FROM canonical_tags WHERE last_fetched IS NOT NULL;
 ```
 
 Then remove `"tagSeedLoaded_&lt;libraryHash&gt;"` from `UserDefaults` and re-run
 `AO3TagSeeds.loadIfNeeded`. Invalidate in-memory hierarchy cache.
 
 ### AO3 URL encoding rules
 - `/` in relationship tags → `*s*`
 - `&amp;` in friendship tags → `*a*`
 - Spaces → `%20`
 - Other: standard percent-encoding
 
 ### Preferences UI
 Preferences → Library → "Tag Synonyms": resolve toggle (default on), fandom-hierarchy toggle
 (default off), count label ("X canonical tags, Y synonyms, Z hierarchy edges"), "Clear synonym
 cache" button.
 
 ---
 
 ## Phase 12 — Reader: Table of Contents Popup — Status: Not started
 **Dependencies:** None. Track B.
 
 **Goal:** Floating panel showing OPF/NCX TOC beside the reader.
 
 ### TOC parsing — extend `EPUBParser`
 Add `toc: [TOCEntry]` property. Do not change existing public interface.
 
 ```swift
 struct TOCEntry: Identifiable {
     let id: String
     let title: String
     let spineIndex: Int
     let depth: Int       // 0 = top level
 }
 ```
 
 - **EPUB 2** (`toc.ncx`): manifest item with `media-type="application/x-dtbncx+xml"`. Parse `&lt;navPoint&gt;` with `NSXMLParser`.
 - **EPUB 3** (`nav.xhtml`): manifest item with `properties="nav"`. Parse `&lt;nav epub:type="toc"&gt;&lt;ol&gt;&lt;li&gt;&lt;a href&gt;`.
 - **Fallback:** generate from spine filenames.
 
 ### Panel UI
 Floating `NSPanel`. `styleMask` including `.nonactivatingPanel` set **at init time** — not after (invariant 24).
 
 SwiftUI `List` of `TOCEntry` rows, indented `depth * 16pt`. Single-click navigates:
 - Scroll: `evaluateJavaScript("window.scrollTo(0, document.getElementById('spine-\(entry.spineIndex)').offsetTop)", completionHandler: nil)`
 - Paginated: `window.ambrosiaNavigateToOffset(charOffset)` (Phase 15 adds this JS function)
 
 Panel frame persisted in `UserDefaults` as `"tocPanelFrame"`. Keyboard shortcut: ⌘T.
 
 ---
 
 ## Phase 13 — Hidden Books, Authors, Tags, and Collections — Status: Not started
 **Dependencies:** M-track complete. Track C.
 
 **Goal:** Hide books by multiple axes. Hidden state invisible everywhere except
 Preferences → Library → "Show Hidden Content".
 
 ### Storage
 
 - **Hidden books:** membership in any `hidden`-kind collection (queried via SQL subquery — see M2). **Not** `BookState.isHidden` — that field is removed.
 - **Hidden authors:** `UserDefaults` key `"hiddenAuthors"` — `Data` (JSON `[String]`).
 - **Hidden tags:** `UserDefaults` key `"hiddenTags"` — `Data` (JSON `[String]`).
 - **Hidden collections:** `UserDefaults` key `"hiddenCollectionIDs"` — `Data` (JSON `[String]`, collection UUIDs). A book is hidden if its `calibreID` is in any collection whose ID appears here.
 - **Hide read works:** membership in the `finished` automated collection + `UserDefaults` bool `"hideReadBooks"` (default `false`).
 - **Hide seen works:** `UserDefaults` bool `"hideSeenBooks"` (default `false`). "Seen" = `totalReadPercent &gt; 0`.
 
 Suppression evaluation order (cheapest first):
 1. `calibreID` in any `hidden`-kind collection (SQL subquery — already applied in M2)
 2. `hideReadBooks &amp;&amp; calibreID` in `finished` collection
 3. `hideSeenBooks &amp;&amp; BookState.totalReadPercent &gt; 0`
 4. Any author in `hiddenAuthors`
 5. Any tag in `hiddenTags`
 6. `calibreID` in any `hiddenCollectionIDs` collection
 
 Steps 1 and 2 run in SQL. Steps 3–6 run in the in-memory post-filter pass.
 
 ### Skip action
 
 The skip action (context menu: "Skip This Book") adds to the system `skipped` collection
 (which has `kind = 'hidden'`) via `CollectionStore.skipBook`. Undo via `NSUndoManager`.
 
 ### Undo pattern
 ```swift
 func hideBook(calibreID: Int, collectionStore: CollectionStore,
               undoManager: UndoManager?) {
     Task { try await collectionStore.insertMember(
         collectionID: SystemCollectionID.skipped, calibreID: calibreID) }
     undoManager?.registerUndo(withTarget: self) { _ in
         Task { try await collectionStore.removeMember(
             collectionID: SystemCollectionID.skipped, calibreID: calibreID) }
     }
     undoManager?.setActionName("Hide Book")
 }
 ```
 
 For author/tag: same pattern, mutation target is `UserDefaults`.
 
 ### Context menu additions
 - Book row: "Skip This Book", "Hide All Books by [Author]", "Hide All Books Tagged [Tag]"
   (submenu if more than 3 tags)
 - Series row: "Hide This Series"
 - Collection panel row: "Hide Collection from Library" (adds to `hiddenCollectionIDs`)
 
 ### Preferences — Library → Hidden Content
 - Toggle: "Show Hidden Content" (master reveal)
 - "Hide already-read books" toggle (`hideReadBooks`)
 - "Hide already-seen books" toggle (`hideSeenBooks`)
 - "Hidden Authors" list with remove buttons
 - "Hidden Tags" list with remove buttons
 - "Hidden Collections" list (shows names, not UUIDs) with remove buttons
 
 ---
 
 ## Phase 14 — Reading Stats, Goals Dashboard, and Read Tracking — Status: Partially complete
 **Dependencies:** M-track complete. Phase 9 for accurate `words_read`. Track D.
 
 ### `reading_history` DDL
 ```sql
 CREATE TABLE IF NOT EXISTS reading_history (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     calibre_id INTEGER NOT NULL,
     session_start TEXT NOT NULL,
     session_end TEXT NOT NULL,
     words_read INTEGER,
     percent_start REAL,
     percent_end REAL
 );
 CREATE INDEX IF NOT EXISTS idx_reading_history_calibre ON reading_history(calibre_id);
 CREATE INDEX IF NOT EXISTS idx_reading_history_start ON reading_history(session_start);
 ```
 
 ### `book_opens` DDL
 ```sql
 CREATE TABLE IF NOT EXISTS book_opens (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     calibre_id INTEGER NOT NULL,
     opened_at TEXT NOT NULL
 );
 CREATE INDEX IF NOT EXISTS idx_book_opens_calibre ON book_opens(calibre_id);
 CREATE INDEX IF NOT EXISTS idx_book_opens_time ON book_opens(opened_at);
 ```
 
 Append-only. Never delete rows (invariant 27).
 
 ### `ReadingHistoryLogger` — four write points
 1. **Open** (`viewDidAppear`): INSERT into `book_opens`; INSERT into `reading_history` with `session_start = session_end = now`. Capture inserted row `id`.
 2. **Autosave** (existing 5s timer): UPDATE `reading_history SET session_end = now, percent_end = current`. Check automated collection thresholds.
 3. **Close** (`viewWillDisappear`): final UPDATE. Final threshold check.
 4. **Crash recovery** (on next `viewDidAppear`): close zombie rows where `session_end == session_start`.
 
 `words_read = (percent_end - percent_start) * word_count` from `ao3_metadata`. NULL if unavailable.
 
 ### Automated "Finished" marking
 After every autosave and on close, in `ReadingHistoryLogger`:
 
 ```swift
 if bookState.totalReadPercent &gt;= 98 {
     try await librarySession.metaDB?.syncAutomatedCollection(
         collectionID: SystemCollectionID.finished,
         calibreID: bookState.calibreID,
         shouldBeMember: true)
     try await librarySession.metaDB?.syncAutomatedCollection(
         collectionID: SystemCollectionID.inProgress,
         calibreID: bookState.calibreID,
         shouldBeMember: false)
 } else if bookState.totalReadPercent &gt; 0 {
     try await librarySession.metaDB?.syncAutomatedCollection(
         collectionID: SystemCollectionID.inProgress,
         calibreID: bookState.calibreID,
         shouldBeMember: true)
 }
 ```
 
 This is the only place `finished` collection membership is set automatically. Manual
 "Mark as Read" (Phase 19 UX) also calls `syncAutomatedCollection(finished, ...)` directly.
 
 ### `StatsView`
 `NSPanel` from Window menu / toolbar. SwiftUI sections:
 
 **Overview:** Total works read, total words read, current streak (consecutive days with ≥1
 session), longest streak.
 
 **Calendar heatmap:** 52×7 `LazyVGrid`, one cell per day (past 52 weeks). Cell colour: system
 accent at opacity 0.1–1.0 mapped to `words_read` percentile; grey for no sessions.
 **No third-party chart library — `Canvas` or `LazyVGrid` only.** Tooltip via `onHover`.
 
 **In-progress books:**
 ```sql
 SELECT calibre_id, MAX(percent_end), MAX(session_end)
 FROM reading_history
 WHERE percent_end BETWEEN 0.05 AND 0.95
 GROUP BY calibre_id ORDER BY MAX(session_end) DESC
 ```
 
 **Recently opened:** Query `book_opens` for top 10 distinct `calibre_id` by most recent
 `opened_at`. Display as horizontal scroll strip with cover thumbnails.
 
 **Goals:** Read existing `ReadingGoal @Model` in full before implementing. Add progress bars.
 Do not duplicate fields.
 
 ### CSV export
 `NSSavePanel`. Default filename: `ambrosia-reading-history-YYYY-MM-DD.csv`. Columns:
 `title, author, calibre_id, session_start, session_end, words_read, percent_start, percent_end`.
 Use `String.write(to:atomically:encoding:)` — no library.
 
 ---
 
 ## Phase 15 — Bookmarks and Annotations Overhaul — Status: Mostly complete
 **Dependencies:** M-track complete (annotations now in SQLite). Track B.

 **Current repo note:** `Annotation` persistence moved to `AmbrosiaMetaDB.annotations`; reader highlight capture/restore, point annotations, sidebar, popover, and `Has Annotations` membership sync are implemented. Remaining work is export/sharing and any UX refinements called out in later phases.
 
 **Read existing `HighlightBridge`, `mouseup` JS listener, and annotation restore path in full
 before touching anything. Annotations are now read from and written to `AmbrosiaMetaDB` via
 `librarySession.metaDB` — not from `BookState.annotationsData`.**
 
 ### Bookmarks (`startChar == endChar`)
 - ⌘D creates one. **Render nothing visible in WKWebView** — no DOM change.
 - Panel: chapter/spine name, "Spine N, offset X", creation date.
 - Click to navigate: scroll mode `window.scrollTo`; paginated `window.ambrosiaNavigateToOffset`.
 
 ### Highlights (`startChar != endChar`)
 - Render as: `&lt;span class="ambrosia-highlight" data-annotation-id="[id]" style="background-color: [colorHex]40"&gt;`
 - Click: JS `click` listener posts `{"type":"highlightClicked","annotationId":"[id]"}` to Swift.
   Swift shows `NSPopover` anchored near click point.
 - **Always pass `completionHandler: nil` on `evaluateJavaScript` — invariant 14.**
 
 ### New JS function: `window.ambrosiaNavigateToOffset(charOffset)`
 Add to `PaginationJS.swift`:
 ```javascript
 window.ambrosiaNavigateToOffset = function(charOffset) {
     const page = window._ambrosiaPages.find(p =&gt; p.start &lt;= charOffset &amp;&amp; charOffset &lt; p.end);
     if (page) window.ambrosiaRenderPage(page.start, page.end);
 };
 ```
 Must also exist in scroll mode as a no-op — callers must not branch on mode.
 
 ### Shared panel
 Single `NSPanel`, `.nonactivatingPanel` set at init (invariant 24). Two-tab `TabView`:
 - **Bookmarks:** sorted by `spineIndex` then `startChar`.
 - **Annotations:** sorted by position. Row: colour chip + 80 chars + date + note. Double-click navigates.
 
 ⌘B toggle. Frame persisted in `UserDefaults` as `"annotationPanelFrame"`.
 
 ### Hide highlights toggle
 ```swift
 // Off:
 evaluateJavaScript(
     "document.querySelectorAll('.ambrosia-highlight').forEach(el =&gt; el.style.backgroundColor = 'transparent');",
     completionHandler: nil)
 // On:
 evaluateJavaScript("window.ambrosiaRestoreHighlightColors()", completionHandler: nil)
 ```
 
 Pre-register `ambrosiaRestoreHighlightColors` in injected JS.
 **Do NOT regenerate full HTML to toggle visibility — invariant 11.**
 
 ---
 
 ## Phase 16 — ELO Ranking System — Status: Not started
 **Dependencies:** M-track complete (`eloScore` and `eloMatchCount` added in M4). Track C.
 
 ### `BookState` fields
 `eloScore: Double = 1000.0` and `eloMatchCount: Int = 0` — added in M4 SwiftData migration.
 These fields are already present when Phase 16 begins.
 
 ### ELO algorithm
 ```swift
 func kFactor(for matchCount: Int) -&gt; Double {
     switch matchCount {
     case 0..&lt;10: return 64
     case 10..&lt;30: return 32
     default: return 16
     }
 }
 
 func updateELO(winner: BookState, loser: BookState, context: ModelContext) {
     let k = kFactor(for: winner.eloMatchCount)
     let expected = 1.0 / (1.0 + pow(10.0, (loser.eloScore - winner.eloScore) / 400.0))
     winner.eloScore += k * (1.0 - expected)
     loser.eloScore  += k * (0.0 - (1.0 - expected))
     winner.eloMatchCount += 1
     loser.eloMatchCount  += 1
     try? context.save()  // one save — invariant 19
 }
 ```
 
 ### Ranking panel
 `NSPanel` or sheet. Two book covers/titles side by side.
 - Left-click / left arrow key → left book wins
 - Right-click / right arrow key → right book wins
 - Escape → skip, no score change
 
 **Pair selection:** fetch 20 `BookState` objects near median `eloScore`; pick random pair
 excluding last 20 shown; every 5th pair fully random.
 
 **Library sort:** Add "ELO Score ↓" to sort `Picker`. Books with `eloMatchCount == 0` sort
 below ranked books — map to `(eloMatchCount == 0 ? 0 : 1, -eloScore)`.
 
 ### Open question (resolve before implementing)
 ELO scores: per-fandom or global? Recommend global for v1.
 
 ---
 
 ## Phase 17 — Custom Fonts in Reader — Status: Partially complete
 **Dependencies:** None. Track B.
 
 ### Font selection UI (Preferences → Reader)
 **Curated list** (`Picker`): grouped Serif / Sans-Serif / Monospace. Guaranteed present on macOS 14+:
 
 | Group | Fonts |
 |---|---|
 | Serif | New York, Georgia, Times New Roman, Palatino |
 | Sans-Serif | SF Pro, Helvetica Neue, Arial, Gill Sans |
 | Monospace | SF Mono, Menlo, Courier New |
 
 One-line preview in each font alongside each item.
 
 **System picker button:** `NSFontPanel.shared.makeKeyAndOrderFront(nil)`.
 
 **Critical:** `NSFontPanel` does NOT call a delegate. Selection via `changeFont(_:)` in
 responder chain (invariant 25):
 ```swift
 override func changeFont(_ sender: NSFontManager?) {
     guard let manager = sender else { return }
     let font = manager.convert(.systemFont(ofSize: 14))
     let family = font.familyName ?? font.fontName
     ReaderPreferences.shared.fontFamily = "\"\(family)\", serif"
     NSFontPanel.shared.orderOut(nil)
 }
 ```
 
 Store as CSS font-stack. Always append generic fallback. Font change triggers `reloadStrategy`.
 In `immediate` mode, full HTML regenerated — invariant 11.
 
 ---
 
 ## Phase 18 — AO3 Login, Kudos, and Bookmarks — Status: Not started
 **Dependencies:** Phase 9. Track G.
 
 ### `AO3RateLimiter` — implement this first
 ```swift
 actor AO3RateLimiter {
     static let shared = AO3RateLimiter()
     private var lastRequest: Date = .distantPast
 
     func throttled&lt;T: Sendable&gt;(_ work: @Sendable () async throws -&gt; T) async throws -&gt; T {
         let elapsed = Date().timeIntervalSince(lastRequest)
         if elapsed &lt; 2.0 { try await Task.sleep(for: .seconds(2.0 - elapsed)) }
         lastRequest = Date()
         return try await work()
     }
 }
 ```
 **Invariant 17:** Every request to `archiveofourown.org` goes through `AO3RateLimiter.shared.throttled`.
 
 ### Keychain credential storage
 ```swift
 SecItemAdd([
     kSecClass: kSecClassInternetPassword,
     kSecAttrService: "com.ambrosia.ao3",
     kSecAttrAccount: username,
     kSecValueData: passwordData,
     kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
 ] as CFDictionary, nil)
 ```
 Session cookie (`_otwarchive_session`): store in a **private** `HTTPCookieStorage` instance.
 Serialise to Keychain as `Data`. Gate `SecItemCopyMatching` behind `LAContext` on macOS 14.
 
 ### Authentication flow
 1. `GET https://archiveofourown.org/users/login` → `SwiftSoup` extract `authenticity_token`.
 2. `POST /users/login` with credentials + token.
 3. On success: persist cookie.
 4. On failure: non-modal notification banner. **Not** `NSAlert`.
 
 ### Kudos
 ```
 GET story_url → extract fresh authenticity_token
 POST /works/[ao3_work_id]/kudos  body: authenticity_token=…
 ```
 On success: `UPDATE ao3_metadata SET kudos_count = kudos_count + 1 WHERE calibre_id = ?`
 Disable if `ao3_author_username` matches logged-in username.
 
 ### AO3 bookmarks
 ```
 POST /works/[ao3_work_id]/bookmarks  body: notes, tags, private flag, token
 ```
 `NSPopover`: notes `NSTextView`, tags `NSTextField`, private checkbox, Submit.
 
 ### Reader toolbar additions
 Heart button (kudos). Bookmark button. Both show tooltip "Log in to AO3 in Preferences"
 when no session. Login UI in Preferences → AO3 Account.
 
 ---
 
 ## Phase 19 — Collections UX, Saved Searches, Favourite Authors, and Saved Quotes — Status: Partially complete
 **Dependencies:** M-track complete. Track E.
 
 **The `Collection @Model` and all SwiftData collection code is already removed by the M-track.
 Collections now live in `ambrosia_meta.db` via `CollectionStore`. Read the M-track implementation
 before starting this phase.**

 **Current repo note:** Collection storage, system collection bootstrap, membership APIs, annotation membership sync, and `Series or Merged` sync are implemented. Saved searches, favourite authors, saved quotes, and full user-facing collection UX from this phase remain incomplete.
 
 ### Collections UX
 
 System collections (Read Later, Liked, Skipped, Finished, In Progress, Has Annotations) are
 bootstrapped by `AmbrosiaMetaDB`. This phase adds the user-facing UI for all of them.
 
 **Read Later UX:**
 Bookmark icon in every book row (list view), cover card (grid view), and email view detail pane.
 Tap calls `CollectionStore.toggleMember(collectionID: SystemCollectionID.readLater, calibreID:)`.
 Register with `NSUndoManager`. Email view: bookmark button in detail pane header + sidebar
 context menu item.
 
 Collection toolbar when Read Later selected:
 - "Open Random" — random `calibreID` from membership, open in reader
 - "Clear" — remove all members (undo: "Clear Read Later")
 
 **Liked UX:**
 Toolbar star button (`star`/`star.fill` SF Symbol) for currently selected book. Disabled when
 no selection. Calls `CollectionStore.toggleMember(collectionID: SystemCollectionID.liked,
 calibreID:)`. Register with `NSUndoManager`. Action name: "Like"/"Unlike".
 
 **Mark as Read UX:**
 Manually adds to / removes from the `finished` collection:
 - Book row context menu: "Mark as Read" / "Mark as Unread"
 - Email view detail pane: "✓ Read" badge button
 - Reader toolbar: checkmark button
 
 All call `CollectionStore.syncAutomatedCollection(finished, calibreID:, shouldBeMember:)`.
 Register with `NSUndoManager`. Setting to unread does NOT modify `totalReadPercent`.
 
 ### Saved searches DDL
 ```sql
 CREATE TABLE IF NOT EXISTS saved_searches (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     name TEXT NOT NULL UNIQUE,
     query_string TEXT,
     filter_rules_json TEXT,
     created_at TEXT NOT NULL
 );
 ```
 
 UI: bookmark icon at trailing end of search bar. Popover: name field + Save. Dropdown of
 saved searches. Selecting one restores `LibraryToolbarState.searchText` and deserialises
 `filter_rules_json` into `FilterDrawer` rules.
 
 ### Favourite Authors DDL
 ```sql
 CREATE TABLE IF NOT EXISTS favourite_authors (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     author_name TEXT NOT NULL UNIQUE,
     note TEXT,
     added_at TEXT NOT NULL
 );
 CREATE INDEX IF NOT EXISTS idx_fav_authors_name ON favourite_authors(author_name);
 ```
 
 UX: context menu per author, author pill popover toggle, Preferences list, "Favourite Authors
 First" sort option.
 
 ### Saved Quotes DDL
 ```sql
 CREATE TABLE IF NOT EXISTS saved_quotes (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     calibre_id INTEGER NOT NULL,
     spine_index INTEGER NOT NULL,
     start_char INTEGER NOT NULL,   -- UTF-16, text nodes only (invariant 5)
     end_char INTEGER NOT NULL,
     selected_text TEXT NOT NULL,
     attribution TEXT,
     note TEXT,
     created_at TEXT NOT NULL,
     tags_json TEXT
 );
 CREATE INDEX IF NOT EXISTS idx_saved_quotes_calibre ON saved_quotes(calibre_id);
 ```
 
 UX: "Save Quote" in reader context menu. `NSPopover` with read-only text, attribution, note,
 tags. Quotes panel: `NSPanel` (or third tab in annotation panel from Phase 15). CSV export.
 
 Distinct from `annotations`: quotes are curated excerpts, annotations are reading markers.
 Both use invariant 5 offsets. Both live in `ambrosia_meta.db` scoped to their library.
 
 ---
 
 ## Phase 20 — Annotation Export and Sharing — Status: Not started
 **Dependencies:** Phase 15. Track F.
 
 ### `AnnotationExporter`
 ```swift
 struct AnnotationExporter {
     func markdown(for book: CalibreBook, annotations: [Annotation], template: String) -&gt; String
     func copyToClipboard(for book: CalibreBook, annotations: [Annotation], template: String)
     func exportToFile(for book: CalibreBook, annotations: [Annotation], template: String)
     // NSSavePanel, default filename "[Title]-annotations.md"
 }
 ```
 
 Annotations fetched from `AmbrosiaMetaDB.annotations(for:)` — not from `BookState`.
 Export covers all annotations for the book, not just the visible page.
 
 Context menu additions: `.copyAnnotations`, `.exportAnnotations`.
 
 ### Default template
 ```
 # {{title}} — Annotations
 *Exported {{export_date}}*
 
 ---
 
 ## Bookmarks
 {{bookmarks}}
 
 ## Highlights
 {{highlights}}
 ```
 Per bookmark: `- **{{chapter}}** — {{note}}\n`
 Per highlight: `&gt; {{text}}\n\n{{note}}\n*Added: {{created_date}}*\n\n---\n`
 
 ### Custom template
 `ReaderPreferences` gains `annotationExportTemplate: String`. Preferences → Reader:
 `TextEditor` with "Restore Default" button. Variables: `{{title}}`, `{{author}}`,
 `{{export_date}}`, `{{highlights}}`, `{{bookmarks}}`; per-item: `{{text}}`, `{{note}}`,
 `{{chapter}}`, `{{created_date}}`. Implementation: `String.replacingOccurrences` loop.
 No templating library.
 
 ---
 
 ## Phase 21 — Standalone Mode (No Calibre Required) — Status: Not started
 **Dependencies:** M-track complete. Track H.
 
 **Goal:** Point Ambrosia at a folder of AO3 EPUBs. Ambrosia generates a Calibre-compatible
 `metadata.db`. The `ambrosia_meta.db` for the folder is created by the M1 library hash
 mechanism — no special handling needed for standalone mode.
 
 ### Trigger
 On "Open Library Folder…", if folder has no `metadata.db` but has `.epub` files: confirmation
 sheet "No Calibre library found. Set up an Ambrosia library here? A metadata.db file will be
 created in this folder."
 
 `metadata.db` lives **in the same folder as the EPUBs** (portable).
 
 ### `CalibreLibraryWriter`
 ```swift
 let writer = CalibreLibraryWriter(folderURL: chosenFolder)
 try writer.createSchema()
 try writer.importEPUBs(from: chosenFolder)
 writer.close()  // explicit close, guaranteed dealloc before CalibreLibrary opens
 let library = CalibreLibrary(root: chosenFolder)
 ```
 
 **Never instantiated while `CalibreLibrary` has `metadata.db` open — invariant 18.**
 
 ### Schema
 Source exact DDL from `kovidgoyal/calibre` at `src/calibre/db/schema_upgrades.py`. Required
 tables: `books`, `authors`, `books_authors_link`, `tags`, `books_tags_link`, `series`,
 `books_series_link`, `publishers`, `books_publishers_link`, `comments`, `data`,
 `custom_columns`. Set `PRAGMA user_version` to match Calibre's current value from that file.
 Test against Calibre 6.x and 7.x before shipping.
 
 ### AO3 detection per EPUB
 1. `dc:publisher` from OPF == "Archive of Our Own" (case-insensitive) → import.
 2. Else: spine item 0 HTML contains `dl class="work meta group"` → import.
 3. Neither: log skip. Show count after import. Never silently discard.
 
 ### Cover generation
 1. Check EPUB manifest for cover image. If found, extract as `cover.jpg`.
 2. If not: generate with `CGContext`. Background: `abs(title.hashValue) % 6` → 6 hardcoded
    colours. Title text: `NSFont.systemFont(ofSize: 24, weight: .medium)`, centred, white.
    JPEG quality 0.9.
 
 ### Duplicate detection
 Two EPUBs with same `ao3_work_id`: keep newer (filesystem mtime). Show warning.
 
 ### Ongoing sync
 "Scan for New EPUBs" toolbar action. Match by UUID from OPF, fallback to filename. Never
 auto-delete missing rows — show "N books not found on disk" with "Remove missing" button.
 
 ---
 
 ## Phase 23 — macOS Music Player Integration (Stub) — Status: Blocked
 **Dependencies:** Phase 15 merged. **Track I — DO NOT START. Blocked on product owner decisions.**
 
 ### What is blocked
 1. Which player: Petrichor or Apple Music (MusicKit)?
 2. Transition type: crossfade, immediate replace, or queue as next?
 3. IPC mechanism.
 
 ### What can be pre-built now
 Add `musicTrigger: String?` to `Annotation` struct (persists in `annotations` table automatically
 via the `note` field or a new column — evaluate at implementation time).
 
 In reader, when position advances past a bookmark's `startChar` and `musicTrigger != nil`:
 ```swift
 NotificationCenter.default.post(name: .ambrosiaMusicCheckpointReached, object: trigger)
 ```
 Leave the notification handler as a stub.
 
 ---
 
 ## Phase 24 — Music Playlist System — Status: Blocked
 **Dependencies:** Phase 23 product owner decisions resolved. **Track I — DO NOT START.**
 
 ### DDL
 ```sql
 CREATE TABLE IF NOT EXISTS music_playlists (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     name TEXT NOT NULL,
     calibre_id INTEGER,
     trigger_mode TEXT NOT NULL,   -- 'position' | 'chapter' | 'vibe'
     created_at TEXT NOT NULL,
     UNIQUE(calibre_id, name)
 );
 
 CREATE TABLE IF NOT EXISTS playlist_songs (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     playlist_id INTEGER NOT NULL REFERENCES music_playlists(id) ON DELETE CASCADE,
     title TEXT NOT NULL,
     artist TEXT,
     player_uri TEXT,
     sort_order INTEGER NOT NULL DEFAULT 0,
     UNIQUE(playlist_id, sort_order)
 );
 
 CREATE TABLE IF NOT EXISTS song_tags (
     song_id INTEGER NOT NULL REFERENCES playlist_songs(id) ON DELETE CASCADE,
     tag TEXT NOT NULL,
     PRIMARY KEY (song_id, tag)
 );
 
 CREATE TABLE IF NOT EXISTS music_position_triggers (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     playlist_id INTEGER NOT NULL REFERENCES music_playlists(id) ON DELETE CASCADE,
     song_id INTEGER NOT NULL REFERENCES playlist_songs(id) ON DELETE CASCADE,
     spine_index INTEGER NOT NULL,
     char_offset INTEGER NOT NULL,    -- UTF-16, text nodes only — invariant 5
     UNIQUE(playlist_id, spine_index, char_offset)
 );
 
 CREATE TABLE IF NOT EXISTS music_chapter_triggers (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     playlist_id INTEGER NOT NULL REFERENCES music_playlists(id) ON DELETE CASCADE,
     spine_index INTEGER NOT NULL,
     song_id INTEGER,
     UNIQUE(playlist_id, spine_index)
 );
 
 CREATE TABLE IF NOT EXISTS music_vibe_triggers (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     playlist_id INTEGER NOT NULL REFERENCES music_playlists(id) ON DELETE CASCADE,
     spine_index INTEGER NOT NULL,
     vibe_tag TEXT NOT NULL,
     UNIQUE(playlist_id, spine_index)
 );
 ```
 
 ### Trigger resolution
 ```swift
 actor MusicTriggerEngine {
     private var firedTriggerIDs: Set&lt;Int&gt; = []  // reset on book open
     func evaluatePositionChange(spineIndex: Int, charOffset: Int, playlistID: Int) async -&gt; String?
     func evaluateChapterChange(spineIndex: Int, playlistID: Int) async -&gt; String?
 }
 ```
 All reads through a read-only `Connection` — not the write actor (invariant 32).
 
 ### Open questions
 1. Player confirmed by product owner?
 2. Crossfade configurable or fixed?
 3. Position triggers: fire once per session or re-fire on scroll back?
 4. Fallback when no song matches vibe tag?
 
 ---
 
 ## Swift Packages
 
 | Package | URL | Used in | Purpose |
 |---|---|---|---|
 | `SwiftSoup` | `https://github.com/scinfu/SwiftSoup` | 9, 11, 18 | HTML parsing for AO3 EPUB headers, tag pages, auth form. |
 
 No other new packages. Add via Xcode SPM UI only (invariant 9). `SQLite.swift` and
 `ZIPFoundation` already cover all other needs.
 
 ---
 
 ## Invariants (Complete List)
 
 **Never violate any of these. Check applicable ones before writing any code.**
 
 1. Never store `[String]`, `[Int]`, or any bare Swift collection on `@Model`. Use JSON `Data` or delimited `String`.
 2. Never use `#Predicate` to compare `@Model` keypaths against plain struct properties. Use `FetchDescriptor` + in-memory filter.
 3. `ModelConfiguration("Ambrosia", schema:, isStoredInMemoryOnly:)` — String name, no `url:` on macOS 14.
 4. `ModelContext` has no `reset()`. Do not call it.
 5. Character offsets: UTF-16 code units, text nodes only, no HTML tags. Applies everywhere — `EPUBParser`, `PaginationJS`, `HighlightBridge`, `annotations`, `saved_quotes`, `music_position_triggers`. No exceptions.
 6. `books` table has no `series` column. Always `LEFT JOIN books_series_link + series`.
 7. All `db.prepare(sql, args)` calls use `[Binding?]` (optional elements). Non-optional causes compile error.
 8. Never call any write PRAGMA on the Calibre read-only connection.
 9. Never hand-author `Package.resolved`. Add SPM packages via Xcode UI only.
 10. Pagination `WKWebView` must be in the view hierarchy with a real non-zero frame.
 11. Regenerate full HTML on any style change. Never patch the live DOM.
 12. Image temp directory (`/tmp/ambrosia/&lt;calibreID&gt;/`) lifetime is the app session. Clean up in `applicationWillTerminate`.
 13. `CalibreFTSLibrary` opened read-only. Always return `nil` on error to allow LIKE fallback.
 14. All `evaluateJavaScript` calls must pass `completionHandler: nil` explicitly.
 15. Before writing any `@Model` code, fetch https://developer.apple.com/documentation/swiftdata.
 16. Never open `ambrosia_meta.db` with more than one write connection simultaneously per library.
 17. All requests to `archiveofourown.org` must go through `AO3RateLimiter.shared.throttled`.
 18. `CalibreLibraryWriter` must be fully deallocated before `CalibreLibrary` opens the `metadata.db` it created.
 19. ELO score updates must commit both books' `eloScore` and `eloMatchCount` in a single `ModelContext.save()`.
 20. `SeriesGroup` is a computed value type. Never persist it.
 21. Any new `@Model` field requires `VersionedSchema` + `SchemaMigrationPlan` before the build ships.
 22. All `BookState` field lookups use in-memory filter after `FetchDescriptor`.
 23. `SeriesGroup.works` is always ordered by `series_index ASC`.
 24. `NSPanel.styleMask` including `.nonactivatingPanel` must be set at init time. Not after.
 25. `NSFontPanel` does not call a delegate. Selection via `changeFont(_:)` in the responder chain.
 26. `Task.detached(priority: .background)` for all EPUB extraction and `ambrosia_meta.db` writes.
 27. `book_opens` is append-only. Never delete rows.
 28. The `finished` automated collection is updated automatically only in `ReadingHistoryLogger` when `totalReadPercent &gt;= 98`. Manual overrides via UI are the only other valid write sites.
 29. **Removed.** (Was: Liked collection `calibreIDsData` synced with `BookState.isLiked`. Both replaced by collection membership in M-track.)
 30. `saved_quotes` `start_char` and `end_char` use UTF-16 text-node convention (invariant 5).
 31. `music_position_triggers` `char_offset` uses UTF-16 text-node convention (invariant 5).
 32. `MusicTriggerEngine` read queries must use a read-only `Connection` — not the `AmbrosiaMetaDB` write actor.
 33. Book suppression (hidden/read/seen/author/tag/collection) applied in SQL (for collection-based rules) or in the in-memory post-filter pass. Calibre SQL must remain unaware of SwiftData state.
 34. Never use `fandom_hierarchy` as a table name. The correct table is `tag_parent_links`.
 35. Tag type comes from `ao3_metadata` JSON columns or `canonical_tags.tag_type` — never inferred from Calibre's `tags` table.
 36. Category tags (`F/F`, `Gen`, `M/M`, etc.) are not stored in `canonical_tags`. They live in `ao3_metadata.category_json` only. Never pass through `TagSynonymResolver`.
 37. `TagSynonymResolver` multi-tag input uses `canonicalBatch(for:)`. Never call `canonical(for:)` in a loop.
 38. Fandom hierarchy expansion applies only to `'fandom'`, `'character'`, `'relationship'` types. Never to `'additional'`.
 39. `AmbrosiaMetaDB` is never a singleton. Always accessed through `LibrarySession`. A direct reference held across a library switch is a reference to a closed database.
 40. `ambrosia_meta.db` is per-library. Every table in it is scoped to the library that opened it. Cross-library data sharing via this database is a bug.
 41. The crash-and-retry mechanism (delete Application Support on `ModelContainer` init error) is removed in Phase M4 and must never be re-introduced.
 
 ---
 
 ## Reference Links
 
 ### SwiftData
 - **Overview:** https://developer.apple.com/documentation/swiftdata
 - **Migrations:** https://developer.apple.com/documentation/swiftdata/migratingpersistentdatausingschemaversionsandmigrationpolicies
 - **ModelActor:** https://developer.apple.com/documentation/swiftdata/modelactor
 - **FetchDescriptor:** https://developer.apple.com/documentation/swiftdata/fetchdescriptor
 
 ### WKWebView
 - **evaluateJavaScript:** https://developer.apple.com/documentation/webkit/wkwebview/1415017-evaluatejavascript
 - **WKScriptMessageHandler:** https://developer.apple.com/documentation/webkit/wkscriptmessagehandler
 
 ### AppKit / SwiftUI
 - **NSHostingView:** https://developer.apple.com/documentation/swiftui/nshostingview
 - **MainActor:** https://developer.apple.com/documentation/swift/mainactor
 
 ### SQLite / EPUB / External
 - **SQLite.swift:** https://github.com/stephencelis/SQLite.swift/blob/master/Documentation/Index.md
 - **Calibre DB schema:** https://github.com/kovidgoyal/calibre/blob/master/src/calibre/db/schema_upgrades.py
 - **EPUB 3 spec:** https://www.w3.org/publishing/epub3/epub-spec.html
 - **TreeWalker (MDN):** https://developer.mozilla.org/en-US/docs/Web/API/TreeWalker
 - **ZIPFoundation:** https://github.com/weichsel/ZIPFoundation
 - **SwiftSoup:** https://github.com/scinfu/SwiftSoup
 
 ---
 
 ## Common Bugs Checklist — Check Before Each Phase
 
 **SwiftData**
 - [ ] New `@Model` field → `VersionedSchema` + `SchemaMigrationPlan` before running.
 - [ ] No bare Swift collections on `@Model`.
 - [ ] `#Predicate` only against `@Model` keypaths.
 - [ ] `ModelConfiguration` takes String name, not URL.
 - [ ] `finished` collection membership auto-set only in `ReadingHistoryLogger`. No other automatic write sites.
 - [ ] ELO update commits both books in one `save()`.
 
 **WKWebView**
 - [ ] `WKWebViewConfiguration` fully configured before `WKWebView` is initialised.
 - [ ] All `evaluateJavaScript` calls pass `completionHandler: nil`.
 - [ ] Paginated `WKWebView` in view hierarchy with real non-zero frame.
 - [ ] Full HTML regenerated on style changes — never patch live DOM.
 
 **SQLite.swift**
 - [ ] All `db.prepare(sql, args)` use `[Binding?]`.
 - [ ] No write PRAGMAs on Calibre read-only connection.
 - [ ] `CREATE TABLE IF NOT EXISTS` on all tables.
 - [ ] Invariant 5 on all character offset columns.
 - [ ] `book_opens` is append-only.
 - [ ] `AmbrosiaMetaDB` accessed through `LibrarySession`, never as singleton.
 - [ ] Correct library's `metaDB` is open before any read/write.
 
 **AppKit**
 - [ ] `NSPanel.styleMask` with `.nonactivatingPanel` set at init time.
 - [ ] `NSFontPanel` selection via `changeFont(_:)` in responder chain.
 - [ ] `NSUndoManager` per-window and ephemeral — correct behaviour.
 
 **Collections**
 - [ ] All collection reads/writes through `CollectionStore`, not raw SQL.
 - [ ] Automated collections updated only via `syncAutomatedCollection`.
 - [ ] `hidden`-kind filtering applied in SQL, not in-memory.
 - [ ] Skip action removes from Read Later atomically in same transaction.
 
 **Tag system**
 - [ ] Table name is `tag_parent_links`, never `fandom_hierarchy`.
 - [ ] Tag type from `ao3_metadata` JSON columns, never Calibre `tags` table.
 - [ ] Category tags never through `TagSynonymResolver`.
 - [ ] Multi-tag resolution uses `canonicalBatch(for:)`.
 - [ ] Hierarchy expansion only for fandom/character/relationship types.
 - [ ] All `archiveofourown.org` requests through `AO3RateLimiter`.
 - [ ] `MusicTriggerEngine` reads use read-only `Connection`.
