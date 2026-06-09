# Ambrosia — Phase 9+ Implementation Guide

**This is the authoritative reference for all remaining work. Phases 1–8 are complete.**
Read this entire document before starting any phase. Read `ambrosia_architecture.md` alongside it.
**Before writing any `@Model` code, always fetch:** https://developer.apple.com/documentation/swiftdata

---

## Current Project State (End of Phase 8)

### What exists and works
- **Data layer:** `CalibreLibrary` (read-only SQLite.swift on Calibre's `metadata.db`), `LibrarySession`, `LibraryRegistry`. Book fetches are paginated (100 + 1 per page). Custom column sort bug is fixed (Section A). Series always joined via `books_series_link + series` — no `b.series` column.
- **SwiftData models:** `BookState` (keyed by `calibreID: Int`), `Collection` (`calibreIDsRaw: String`, comma-delimited), `ReadingGoal`. Schema name: `"Ambrosia"` (string, not URL).
- **Library UI:** List view (`LibraryRootView` + `BookListRow`), Email view (`NSSplitViewController` + `NSTableView` sidebar + SwiftUI detail pane), Grid view (`LazyVGrid` cover cards). Native `NSToolbar` via `LibraryToolbarState` (`@Observable`). Filter drawer with `FilterBuilder` → SQL + in-memory. NOT-chip styling on filter pills. Dock icon reopens library window.
- **Reader:** `ReaderViewController` with `WKWebView`. Scroll mode and paginated mode (`PaginationEngine`). `EPUBParser` (ZIPFoundation + NSXMLParser). Custom context menu (Option A: `WebViewContainer` wrapping `WKWebView`, `rightMouseDown` override). Unified `Annotation` model in `BookState.annotationsData: Data?` (JSON `[Annotation]`). Annotation sidebar and popover.
- **Preferences:** Font picker (curated + `NSFontPanel` system picker). Reload strategy (immediate / onNextOpen / manual). Reader window size (screen-fraction or explicit px). Pagination mode toggle (global, stored in `ReaderPreferences`).
- **Search:** `SearchQueryParser` (`tag:`, `author:`, `title:` prefix syntax, AND stacking). Autocomplete overlay (`SearchSuggestionsView`). `CalibreFTSLibrary` for FTS5 (optional, transparent fallback to LIKE).
- **Other:** Reading goal tracking. Collections with `calibreIDsRaw`. CSV export. Notarization scripts.

### Known `BookState` fields (current)
```swift
calibreID: Int, isLiked: Bool, isHidden: Bool, readingModeRaw: String (legacy/inert),
totalReadPercent: Double, totalReadingTimeSeconds: Int,
lastSpineIndex: Int, lastCharacterOffset: Int, lastScrollOffset: Double,
annotationsData: Data?
```

**Planned additions (require SwiftData migration — see migration section):**
```swift
isRead: Bool = false          // manually set or auto-set at ≥98% progress
eloScore: Double = 1000.0
eloMatchCount: Int = 0
isPinnedToTop: Bool = false
```

### What does NOT yet exist (Phase 9+)
`ambrosia_meta.db`, AO3 metadata extraction, series grouping, tag synonyms, reading stats dashboard, bookmarks/annotations overhaul (Phase 15 improvements), ELO ranking, custom fonts (Phase 17), AO3 login/kudos, collections improvements, annotation export, standalone mode, TOC popup, hidden books, pin-to-top window. These are all defined below.

---

## Session Discipline

**Rule 1 — Diagnose before writing:**
```bash
grep -rn "TODO\|FIXME" /path/to/project/
xcodebuild -scheme Ambrosia -destination 'platform=macOS' build 2>&1 | grep -E "error:|warning:"
```
The build output is truth. Your memory of previous sessions is not.

**Rule 2 — One approach to completion.** If a partial implementation exists, continue it. Do not restart.

**Rule 3 — Never claim clean build without running `xcodebuild`.**

**Rule 4 — Write a handoff block before ending:**
```
## Handoff — Session [ID]
State: [COMPLETE / PARTIAL — what's done, what remains]
Last build output: [last 10 lines of xcodebuild]
Files changed: [list]
Next session starts with: [exact first action]
```

---

## New Persistent Stores (All Phases Share These)

### `ambrosia_meta.db`
**Location:** `~/Library/Application Support/Ambrosia/ambrosia_meta.db`
**One write-enabled connection in the entire app.** Calibre's `metadata.db` is read-only forever.

```swift
actor AmbrosiaMetaDB {
    static let shared = AmbrosiaMetaDB()
    private let db: Connection  // read-write, defaults to read-write
    // All INSERT/UPDATE/DELETE through this actor
}
```

Read-only queries (`TagSynonymResolver`, `StatsView`) may use a separate `Connection(path, readonly: true)` — no actor needed.

All tables use `CREATE TABLE IF NOT EXISTS` — phases run DDL on startup in any order.

### SwiftData Migration — Required Before Adding Any `@Model` Field

Add these five fields to `BookState` in a single `SchemaMigrationPlan` (lightweight migration, all have defaults):
```swift
var isRead: Bool = false          // manually set or auto-set at ≥98% progress
var eloScore: Double = 1000.0
var eloMatchCount: Int = 0
// isHidden: Bool = false  ← already exists as of Phase 8
var isPinnedToTop: Bool = false
```

Reference: https://developer.apple.com/documentation/swiftdata/migratingpersistentdatausingschemaversionsandmigrationpolicies

**The existing app catches `ModelContainer` init errors and deletes all user state. A missing migration destroys data.**

---

## Parallelisation Guide

```
TRACK A — Sequential (run first, others depend on it)
  Phase 9 → Phase 10 → Phase 11

TRACK B — Reader improvements (parallel with each other and Track A)
  Phase 12, Phase 15, Phase 17, Phase 22

TRACK C — Library UX (Phase 13, Phase 16 — parallel with each other)

TRACK D — Stats (Phase 14 — session logging independent; dashboard needs Phase 9)

TRACK E — Collections & Search (Phase 19 — fully independent)

TRACK F — Annotation export (Phase 20 — needs Phase 15 merged first)

TRACK G — AO3 network (Phase 18 — needs Phase 9 merged first)

TRACK H — Standalone mode (Phase 21 — fully independent)

TRACK I — Music (Phase 23 stub + Phase 24 full system — BLOCKED on product owner decisions; see Phase 23/24)
```

Give each parallel AI session: `ambrosia_architecture.md`, this document, and one phase to implement. Each produces a clean feature branch.

---

## Phase 9 — AO3 EPUB Metadata Extraction
**Dependencies:** None. Track A (blocks 10, 11, 14 dashboard, 18).

**Goal:** On library open, silently parse AO3 EPUB header pages and persist rich metadata not in Calibre's DB.

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
<dl class="work meta group">
  <dt class="tags">Fandoms:</dt><dd><ul><li><a>Name</a></li></ul></dd>
  <dt>Language:</dt><dd>English</dd>
  <dt>Published:</dt><dd>2021-03-15</dd>
  <dt>Updated:</dt><dd>2023-11-02</dd>
  <dt>Words:</dt><dd>142,350</dd>   <!-- strip commas before parseInt -->
  <dt>Chapters:</dt><dd>23/30</dd>  <!-- '?' means unknown total -->
  <dt>Series:</dt>
  <dd><ul><li>Part <span>2</span> of <a href="/series/12345">Series Name</a></li></ul></dd>
</dl>
```

Work URL/ID: derivable from `<a>` links to `/works/WORK_ID` on the page.

### `AO3MetadataExtractor`
A Swift `struct`. Takes raw HTML, returns `AO3Metadata?`.
- Detect by presence of `dl class="work meta group"`. Return `nil` if absent.
- **Use `SwiftSoup`** (not `NSXMLParser`) — AO3 HTML contains malformed tags that break SAX.
- Chapters: split on `/`. Second component `"?"` → `chapter_total = nil`. If `chapter_current == chapter_total` (both non-nil) → `is_complete = true`.
- Word count: strip commas before `Int()`.
- Series: each `<li>` → part index from `<span>`, name + AO3 ID from `<a href="/series/ID">`. Build JSON array.
- **Tags:** extract five separate lists — fandoms, relationships, characters, additional tags, and category — each from their respective `<dt class="tags">` label. Store each as a JSON array. Category values are a closed set (`F/F`, `F/M`, `M/M`, `Gen`, `Multi`, `Other`); store any unrecognised value as-is without logging an error.

### Background extraction
```swift
// In LibrarySession, after CalibreLibrary is ready:
Task.detached(priority: .background) {
    let allIDs    = /* SELECT id FROM books */
    let existing  = /* SELECT calibre_id FROM ao3_metadata */
    let missing   = Set(allIDs).subtracting(existing)
    for batch in missing.chunked(into: 50) {
        for id in batch {
            if let epub = /* locateEPUB(calibreID: id) */,
               let html = EPUBParser(epub).html(for: 0, userCSS: ""),
               let meta = AO3MetadataExtractor.extract(from: html) {
                await AmbrosiaMetaDB.shared.insert(meta, calibreID: id)
            }
        }
    }
}
```

`@Observable ExtractionProgress(completed: Int, total: Int)` on `LibrarySession`. Toolbar shows "Enriching library…" while in progress. Library is fully usable during extraction — never block main thread.

Preferences → Data: "Re-extract AO3 metadata" button — deletes all `ao3_metadata` + `series_cache` rows and re-runs.

### Reading progress % display
`BookState.totalReadPercent` already exists. Display in list (chip/bar), email (detail pane header), grid (thin bar at bottom of cover card). Show nothing (not 0%) for never-opened books.

### Open questions (resolve with product owner before implementing)
1. For ongoing works (`chapter_total NULL`): display "23/?" or "23 ch"?
2. Compare `extracted_at` against EPUB filesystem mtime to auto-re-extract on update?

---

## Phase 10 — Series Grouping and Cache
**Dependencies:** Phase 9. Track A.

**Goal:** Collapse multi-work series into single library rows. Cache series data to avoid per-page Calibre JOINs. Anthology detection. Missing-work warnings.

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

Populate from `ao3_metadata.series_json` in the Phase 9 background task. Fall back to Calibre's `books_series_link` JOIN for non-AO3 EPUBs.

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

"Group by series" toggle: `LibraryToolbarState.groupBySeries: Bool`, persisted in `UserDefaults`. All three view modes return `[LibraryItem]`.

### Series row display (list + email views)
Series name (bold), work count ("4 works"), combined word count, date range ("2021–2023"), union of all fandoms/tags, warning badge when `missingIndices` non-empty. Clicking warning badge → sheet to enter placeholder notes → written to `series_placeholders`.

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
<div class="ambrosia-series-break"><h2>Work [N]: [Title]</h2></div>
```
`BookState` key = first work's `calibreID`. Spine indices are flat across all EPUBs.

### Open questions (resolve before implementing)
1. Should missing-index placeholders inject a synthetic HTML page in the reader?
2. `totalReadPercent` for series: combined word count or per-work? (recommend per-work for v1)

---

## Phase 11 — AO3 Tag Synonyms and Tag Classification
**Dependencies:** Phase 9 (for `SwiftSoup` + `ambrosia_meta.db` write path). Track A.

**Goal:** Resolve tag queries to canonical AO3 forms using a pre-built seed database. Wire every tag-bearing surface in the app through `TagSynonymResolver`. Treat AO3's structured tag categories (fandom, character, relationship, category) as first-class distinct fields — never conflate them with freeform additional tags.

---

### Background: what the scraper produced

The Phase 11 seed data comes from `ao3_seed_scraper.py`, which was run against the library's tag URLs offline. It produced `AO3TagSeeds.swift` — drop this into the Xcode project and never edit it by hand. To regenerate the Swift file from an existing `ao3_tag_seeds.db` without re-scraping:

```bash
python3 ao3_seed_scraper.py --swift-only --output-dir ./output
```

`AO3TagSeeds.swift` exposes:
```swift
struct AO3TagSeeds {
    static let synonyms: [(synonym: String, canonical: String, tagType: String)]
    static let parentLinks: [(child: String, parent: String)]
    // Inserts into canonical_tags, tag_synonyms, tag_parent_links in one transaction.
    // INSERT OR IGNORE — safe to call again. Targets raw SQLite pointer for ambrosia_meta.db.
    static func loadIfNeeded(db: OpaquePointer) throws
}
```

**Invariant:** `synonym` is never equal to its canonical's name in the seed data. If a string appears in `canonical_tags.name` it is canonical; if it appears only in `tag_synonyms.synonym` it maps to something else. Never assume a string can be both.

---

### DDL — use these exact table names

**Critical schema note:** The phase guide originally specified `fandom_hierarchy`. The actual seed data uses `tag_parent_links` (same structure, different name) plus `tag_subtag_sections`. Use the names below everywhere — `AO3TagSeeds.loadIfNeeded` targets `tag_parent_links`.

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

-- Directed hierarchy edge: child is a sub-type of parent.
-- e.g. child=MCU, parent=Marvel. Both directions written by scraper.
CREATE TABLE IF NOT EXISTS tag_parent_links (
    child_id  INTEGER NOT NULL REFERENCES canonical_tags(id),
    parent_id INTEGER NOT NULL REFERENCES canonical_tags(id),
    PRIMARY KEY (child_id, parent_id)
);
CREATE INDEX IF NOT EXISTS idx_tag_parent_links_child  ON tag_parent_links(child_id);
CREATE INDEX IF NOT EXISTS idx_tag_parent_links_parent ON tag_parent_links(parent_id);

-- Optional: section labels from AO3's wrangling UI ("Relationships", "Characters", etc.)
-- Mirrors tag_parent_links rows exactly; only adds the section label.
-- Do not use at runtime in Phase 11 — reserved for future fandom-browser UI.
CREATE TABLE IF NOT EXISTS tag_subtag_sections (
    child_id  INTEGER NOT NULL REFERENCES canonical_tags(id),
    parent_id INTEGER NOT NULL REFERENCES canonical_tags(id),
    section   TEXT,  -- "Relationships"|"Characters"|"Additional Tags"|"Fandoms"|""
    PRIMARY KEY (child_id, parent_id)
);
```

Do **not** create `fandom_hierarchy`. It does not exist in the seed data.

---

### AO3 tag category model — four structured types vs. freeform

AO3 uses five distinct tag slots on every work. Ambrosia must treat them separately:

| AO3 field | `tag_type` | Source in EPUB HTML | Calibre column | Notes |
|---|---|---|---|---|
| Fandoms | `'fandom'` | `<dt class="tags">Fandoms:</dt>` | Calibre `tags` table (mixed) | Always wrangled; hierarchy applies |
| Relationships | `'relationship'` | `<dt class="tags">Relationships:</dt>` | Calibre `tags` table (mixed) | Wrangled; `*s*` / `*a*` URL encoding |
| Characters | `'character'` | `<dt class="tags">Characters:</dt>` | Calibre `tags` table (mixed) | Wrangled |
| Additional Tags | `'additional'` | `<dt class="tags">Additional Tags:</dt>` | Calibre `tags` table (mixed) | Freeform; synonym resolution applies but hierarchy does not |
| Category | `'category'` | `<dt class="tags">Category:</dt>` | Not in Calibre schema | AO3-specific; values: F/F, F/M, M/M, Gen, Multi, Other |

**Calibre's `tags` table mixes all five types into a single flat list.** It has no type column. The only way to know whether `"Clarke/Lexa"` is a relationship tag or `"Hurt/Comfort"` is additional is from the EPUB HTML — which is why Phase 9's `ao3_metadata` table stores them in separate JSON columns (`fandoms_json`, `relationships_json`, `characters_json`, `additional_tags_json`). Phase 11 must use those columns, not Calibre's `tags` table, for any type-aware operation.

**Category tags** (`F/F`, `Gen`, `M/M`, etc.) are **not** stored in `canonical_tags`. They are a closed fixed vocabulary. Store them in `ao3_metadata.category_json TEXT` (add this column if not already present). Parse from `<dt class="tags">Category:</dt>` in the EPUB header alongside the other tags.

---

### What goes through `TagSynonymResolver` and what does not

| Surface | Passes through resolver | Notes |
|---|---|---|
| Search bar `tag:` query | Yes | Resolve before building SQL |
| Filter drawer tag rules | Yes | Resolve before `FilterBuilder` |
| Tag pill taps (quick filter) | Yes | Tag came from Calibre; may need resolution |
| Fandom-hierarchy expansion | Yes — only for `'fandom'` and `'character'`/`'relationship'` canonical tags | Never expand additional tags via hierarchy |
| Category filter (`F/F`, `Gen`, etc.) | **No** — query `ao3_metadata.category_json` directly | Fixed vocabulary; no synonyms |
| Tag display in list/email rows | **No** — display Calibre's raw tag strings | Resolution is for search/filter only; never mutate display strings |
| Hidden-tags suppression (Phase 13) | Yes — resolve the stored hidden tag before comparing | Ensures "H/C" hides "Hurt/Comfort" books |

---

### `TagSynonymResolver`

A service with a read-only `Connection`. Never writes. Must not block the main thread.

```swift
final class TagSynonymResolver {
    private let db: Connection  // read-only; separate from AmbrosiaMetaDB write actor

    /// Resolve a single tag to its canonical form.
    /// Returns inputTag unchanged if already canonical or unknown.
    func canonical(for inputTag: String) async -> String {
        // Step 1: is it already canonical?
        // SELECT id FROM canonical_tags WHERE name = ?
        // → found: return inputTag unchanged

        // Step 2: is it a known synonym?
        // SELECT c.name FROM tag_synonyms s
        // JOIN canonical_tags c ON c.id = s.canonical_id
        // WHERE s.synonym = ?
        // → found: return c.name

        // Step 3: unknown → queue background AO3 fetch via AO3RateLimiter
        //         write result to ambrosia_meta.db via AmbrosiaMetaDB.shared
        //         return inputTag unchanged for this query
        return inputTag
    }

    /// Resolve multiple tags in one call. Batches steps 1+2 as IN queries
    /// to avoid N round-trips on the read-only connection.
    func canonicalBatch(for tags: [String]) async -> [String: String]
    // returns dict of inputTag → canonical (input unchanged if already canonical/unknown)
}
```

**Batch resolution** is critical for performance. Filter rules and search queries may reference many tags at once. Do not call `canonical(for:)` in a loop — use `canonicalBatch(for:)` which batches the two lookups as `WHERE name IN (?)` and `WHERE synonym IN (?)` queries.

---

### Fandom hierarchy expansion

When Preferences → Library → "Fandom Hierarchy" is **on**, a search for a parent fandom (e.g. `Marvel`) should also match works whose fandom tags are descendants (e.g. `MCU`, `Avengers (Movies)`). Hierarchy expansion applies **only** to `'fandom'`, `'character'`, and `'relationship'` tag types — never to `'additional'` tags.

```sql
-- All canonical tags that are descendants of a given parent (recursive CTE)
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

Call this only when the fandom-hierarchy toggle is on (`UserDefaults` key `"fandomHierarchyEnabled"`, default `false`). The result set is passed to `FilterBuilder` as an expanded `IN` list against Calibre's `tags` table.

**Performance note:** The recursive CTE on a read-only connection is fast for typical fandom trees (depth ≤ 4, branching factor ≤ 50). Cache the expanded set in memory per session per input tag — do not re-query on every keystroke. Invalidate the cache when the "Clear synonym cache" button is pressed.

---

### EPUB HTML parsing for tag types (extends Phase 9)

Phase 9's `AO3MetadataExtractor` already extracts `fandoms_json`, `relationships_json`, `characters_json`, and `additional_tags_json`. Phase 11 adds:

1. **`category_json TEXT`** column to `ao3_metadata` (add via `ALTER TABLE IF NOT EXISTS` or include in DDL if table not yet created). Parse `<dt class="tags">Category:</dt>` → extract `<li>` text values. Valid values: `F/F`, `F/M`, `M/M`, `Gen`, `Multi`, `Other`. Anything else: log and store as-is.

2. **Tag type back-population:** After extraction, for each tag in each typed JSON array, ensure a row exists in `canonical_tags` with the correct `tag_type`. Use `INSERT OR IGNORE` — do not overwrite `last_fetched` on existing rows.
   ```swift
   // In AmbrosiaMetaDB, called after every ao3_metadata insert:
   func ensureCanonicalTags(fandoms: [String], relationships: [String],
                             characters: [String], additional: [String]) async
   // INSERT OR IGNORE INTO canonical_tags (name, tag_type) VALUES (?, ?)
   // for each tag in each list, with the correct tag_type string
   ```
   This ensures that every tag seen in the library has a `canonical_tags` row even before the scraper or live-fetch runs — which makes step 1 of `TagSynonymResolver` more effective immediately.

---

### Seed loading

On first launch (`UserDefaults` flag `"tagSeedLoaded"`): call `AO3TagSeeds.loadIfNeeded(db:)`, passing the raw SQLite pointer for `ambrosia_meta.db`. This inserts into `canonical_tags`, `tag_synonyms`, and `tag_parent_links` in a single transaction with `INSERT OR IGNORE`. Set `last_fetched = NULL` for all seed entries.

Run inside `Task.detached(priority: .background)` — the seed file may be large. Do not block app startup.

---

### "Clear synonym cache" button

Preferences → Library → "Tag Synonyms" → "Clear synonym cache":

```sql
-- Delete live-fetched rows only (keep seeds; seeds have last_fetched IS NULL)
DELETE FROM tag_synonyms
  WHERE canonical_id IN (
      SELECT id FROM canonical_tags WHERE last_fetched IS NOT NULL
  );
DELETE FROM tag_parent_links
  WHERE child_id  IN (SELECT id FROM canonical_tags WHERE last_fetched IS NOT NULL)
     OR parent_id IN (SELECT id FROM canonical_tags WHERE last_fetched IS NOT NULL);
DELETE FROM canonical_tags WHERE last_fetched IS NOT NULL;

-- Re-seed (INSERT OR IGNORE, so safe)
UserDefaults.standard.removeObject(forKey: "tagSeedLoaded")
-- then call AO3TagSeeds.loadIfNeeded(db:) again
```

Also invalidate the in-memory hierarchy expansion cache.

---

### AO3 URL encoding rules (for live-fetch URLs)
- `/` in relationship tags → `*s*` (e.g. "Clarke/Lexa" → "Clarke*s*Lexa")
- `&` in friendship tags → `*a*`
- Spaces → `%20`
- Other: standard percent-encoding

---

### Preferences UI
Preferences → Library → "Tag Synonyms": resolve toggle (default on), fandom-hierarchy toggle (default off), count label ("X canonical tags, Y synonyms, Z hierarchy edges"), "Clear synonym cache" button. Category filter UI (F/F, Gen, etc.) is a separate filter drawer field — not part of this preference panel.

---

## Phase 12 — Reader: Table of Contents Popup
**Dependencies:** None. Track B.

**Goal:** Floating panel showing OPF/NCX TOC beside the reader.

### TOC parsing — extend `EPUBParser`
Add `toc: [TOCEntry]` property. Do not change existing public interface.

```swift
struct TOCEntry: Identifiable {
    let id: String       // navPoint id or UUID
    let title: String
    let spineIndex: Int
    let depth: Int       // 0 = top level
}
```

- **EPUB 2** (`toc.ncx`): manifest item with `media-type="application/x-dtbncx+xml"`. Parse `<navPoint>` with `NSXMLParser`. `<navLabel><text>` → title; `<content src>` → spineIndex by manifest match; `playOrder`/nesting → depth.
- **EPUB 3** (`nav.xhtml`): manifest item with `properties="nav"`. Parse `<nav epub:type="toc"><ol><li><a href>`.
- **Fallback:** generate from spine filenames.

### Panel UI
Floating `NSPanel`. **Critical:** `styleMask` including `.nonactivatingPanel` must be set **at init time** — setting it after init has no effect.

SwiftUI `List` of `TOCEntry` rows, indented `depth * 16pt`. Single-click navigates:
- Scroll: `evaluateJavaScript("window.scrollTo(0, document.getElementById('spine-\(entry.spineIndex)').offsetTop)", completionHandler: nil)`
- Paginated: `window.ambrosiaNavigateToOffset(charOffset)` (Phase 15 adds this JS function)

Panel frame persisted in `UserDefaults` as `"tocPanelFrame"`. Keyboard shortcut: ⌘T.

---

## Phase 13 — Hidden Books, Authors, Tags, and Collections
**Dependencies:** None (Phase 19 Collections needed for "Hidden" collection UI — stub it). Track C.

**Goal:** Hide books by multiple axes: individual book, all works by an author, all works with a given tag, all works in a given collection (this naturally covers "hide liked" and "hide read-later" in bulk), and all already-read or already-seen works. The hidden state is invisible everywhere in the UI except a dedicated toggle in Preferences → Library → "Show Hidden Content". ⌘Z undoable on all hide operations.

### Storage
- **Hidden books:** `BookState.isHidden = true` (already exists). Post-filter in memory after `FetchDescriptor`. Never add to SQL WHERE — invariant 22.
- **Hidden authors:** `UserDefaults` key `"hiddenAuthors"` — `Data` (JSON `[String]`). A book is hidden if ANY of its authors is in this set.
- **Hidden tags:** `UserDefaults` key `"hiddenTags"` — `Data` (JSON `[String]`). A book is hidden if ANY of its tags is in this set.
- **Hidden collections:** `UserDefaults` key `"hiddenCollectionIDs"` — `Data` (JSON `[String]`, using `Collection.id` UUIDs). A book is hidden if its `calibreID` is in any hidden collection's `calibreIDsData`. This is how the user can suppress all "Liked" books or all "Read Later" books from the main list at once.
- **Hide read works:** `UserDefaults` bool `"hideReadBooks"` (default `false`). When true, suppress all books where `BookState.isRead == true`.
- **Hide seen works:** `UserDefaults` bool `"hideSeenBooks"` (default `false`). A book is "seen" if `totalReadPercent > 0`. When true, suppress books the user has ever opened.

A book is suppressed from library display if ANY condition is true. Evaluate in this order (cheapest first):
1. `BookState.isHidden`
2. `hideReadBooks && BookState.isRead`
3. `hideSeenBooks && BookState.totalReadPercent > 0`
4. Any author in `hiddenAuthors`
5. Any tag in `hiddenTags`
6. `calibreID` in any hidden collection

Suppression is applied **after** the Calibre SQL fetch, in the same in-memory post-filter pass used for `isLiked` and collection membership. Do not encode any suppression logic into SQL — it must remain a pure in-memory step.

### Undo pattern
```swift
func hideBook(_ bookState: BookState, context: ModelContext, undoManager: UndoManager?) {
    bookState.isHidden = true
    try? context.save()
    undoManager?.registerUndo(withTarget: self) { [weak bookState, weak context] _ in
        bookState?.isHidden = false
        try? context?.save()
    }
    undoManager?.setActionName("Hide Book")
}
```
For author/tag/collection: same pattern, mutation target is `UserDefaults`. Capture pre-change array in closure.

Undo stack is per-window and ephemeral — correct macOS behaviour, not a bug.

### Context menu additions
- Book row: "Hide This Book", "Hide All Books by [Author]", "Hide All Books Tagged [Tag]" (one item per tag on the book, shown in a submenu if more than 3 tags)
- Series row: "Hide This Series"
- Collection sidebar row: "Hide Collection from Library" (adds to `hiddenCollectionIDs`)

### Preferences — Library → Hidden Content
A dedicated section (only visible/relevant when Preferences → Library → "Show Hidden Content" is off):
- Toggle: "Show Hidden Content" (master reveal switch — when on, hidden books appear with a grey overlay, not fully unsuppressed)
- Sub-section: "Quick Filters" — two on/off toggles: "Hide already-read books" (`hideReadBooks`), "Hide already-seen books" (`hideSeenBooks`)
- Sub-section: "Hidden Authors" — list with remove (×) button per entry; "Clear All" button
- Sub-section: "Hidden Tags" — same pattern
- Sub-section: "Hidden Collections" — shows collection names, not UUIDs; remove button

### "Hidden" built-in collection
`Collection` with `isSystem = true, systemType = "hidden"`. Contains all `calibreID`s where `BookState.isHidden == true`. Visible only inside Preferences or when the master reveal is on. Right-click → "Unhide" (registered with `NSUndoManager`). Do not show this collection in the normal collections sidebar — it is a Preferences-only UI.

---

## Phase 14 — Reading Stats, Goals Dashboard, and Read Tracking
**Dependencies:** None for session logging. Phase 9 for accurate `words_read`. Track D.

### `reading_history` DDL
```sql
CREATE TABLE IF NOT EXISTS reading_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    calibre_id INTEGER NOT NULL,
    session_start TEXT NOT NULL,   -- ISO-8601
    session_end TEXT NOT NULL,     -- ISO-8601
    words_read INTEGER,            -- NULL until word_count available; backfillable
    percent_start REAL,
    percent_end REAL
);
CREATE INDEX IF NOT EXISTS idx_reading_history_calibre ON reading_history(calibre_id);
CREATE INDEX IF NOT EXISTS idx_reading_history_start ON reading_history(session_start);
```

### `book_opens` DDL
A lightweight log separate from session data. Used for "Recently Opened" lists and open-count statistics without aggregating `reading_history`.

```sql
CREATE TABLE IF NOT EXISTS book_opens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    calibre_id INTEGER NOT NULL,
    opened_at TEXT NOT NULL        -- ISO-8601
);
CREATE INDEX IF NOT EXISTS idx_book_opens_calibre ON book_opens(calibre_id);
CREATE INDEX IF NOT EXISTS idx_book_opens_time ON book_opens(opened_at);
```

Write one row on every reader open (`viewDidAppear`), in the same call that starts the `reading_history` session. **Never delete rows** — this is a permanent append-only log. At 1 row per open, even 10,000 opens is ~400 KB; storage is not a concern.

Queries used by the UI:
```sql
-- Recently opened (up to N distinct books, most recent first)
SELECT DISTINCT calibre_id FROM book_opens ORDER BY opened_at DESC LIMIT 20;

-- Open count for a book
SELECT COUNT(*) FROM book_opens WHERE calibre_id = ?;
```

### `ReadingHistoryLogger` — three write points
1. **Open** (`viewDidAppear`): INSERT into `book_opens`; INSERT into `reading_history` with `session_start = session_end = now`, `percent_start`. Capture inserted row `id`.
2. **Autosave** (existing 5s timer): `UPDATE reading_history SET session_end = now, percent_end = current`. Also check auto-read threshold (see below).
3. **Close** (`viewWillDisappear`): final UPDATE to `reading_history`. Final auto-read check.
4. **Crash recovery** (on next `viewDidAppear`): close zombie rows where `session_end == session_start`.

`words_read = (percent_end - percent_start) * word_count` from `ao3_metadata`. Store `NULL` if unavailable.

### Automatic "Read" marking
In `ReadingHistoryLogger`, after every autosave and on close:
```swift
if !bookState.isRead && (bookState.totalReadPercent >= 0.98) {
    bookState.isRead = true
    try? modelContext.save()
}
```
This is the only place `isRead` is set automatically. The user may also set it manually at any time (see Phase 19 UI). Setting `isRead = true` does NOT reset progress or scroll position.

### `StatsView`
`NSPanel` from Window menu / toolbar. SwiftUI sections:

**Overview:** Total works read (`COUNT(DISTINCT calibre_id) WHERE percent_end >= 0.95`), total words read, current streak (consecutive days with ≥1 session backwards from today), longest streak.

**Calendar heatmap:** 52×7 `LazyVGrid`, one cell per day (past 52 weeks). Cell colour: system accent at opacity 0.1–1.0 mapped to `words_read` percentile; grey for no sessions. **No third-party chart library — `Canvas` or `LazyVGrid` only.** Tooltip via `onHover` + custom overlay.

**In-progress books:**
```sql
SELECT calibre_id, MAX(percent_end), MAX(session_end)
FROM reading_history
WHERE percent_end BETWEEN 0.05 AND 0.95
GROUP BY calibre_id ORDER BY MAX(session_end) DESC
```

**Recently opened:** Query `book_opens` for top 10 distinct `calibre_id` by most recent `opened_at`. Display as a horizontal scroll strip with cover thumbnails.

**Goals:** Read existing `ReadingGoal @Model` in full before implementing. Add progress bars. Do not duplicate fields.

### CSV export
`NSSavePanel`. Default filename: `ambrosia-reading-history-YYYY-MM-DD.csv`. Columns: `title, author, calibre_id, session_start, session_end, words_read, percent_start, percent_end`. Use `String.write(to:atomically:encoding:)` — no library.

---

## Phase 15 — Bookmarks and Annotations Overhaul
**Dependencies:** None. Track B.

**Goal:** Separate bookmarks (invisible position markers) from highlights (visible, with notes). Shared panel. Hide-highlights toggle. In-reader note popover.

**Read existing `HighlightBridge`, `mouseup` JS listener, and annotation restore path in full before touching anything.**

### Bookmarks (`startChar == endChar`)
- ⌘D creates one (keep existing shortcut). **Render nothing visible in WKWebView** — no DOM change.
- Panel shows: chapter/spine name, "Spine N, offset X", creation date.
- Click panel row to navigate:
  - Scroll: `evaluateJavaScript("window.scrollTo(0, \(targetScrollOffset))", completionHandler: nil)`
  - Paginated: `window.ambrosiaNavigateToOffset(\(startChar))`

### Highlights (`startChar != endChar`)
- Render as: `<span class="ambrosia-highlight" data-annotation-id="[id]" style="background-color: [colorHex]40">`
- Clicking a span: JS `click` listener posts `{ "type": "highlightClicked", "annotationId": "[id]" }` to Swift via `WKScriptMessageHandler`. Swift shows `NSPopover` anchored near click point.
- **Always pass `completionHandler: nil` on `evaluateJavaScript` — invariant 14.**

### New JS function: `window.ambrosiaNavigateToOffset(charOffset)`
Add to `PaginationJS.swift`:
```javascript
window.ambrosiaNavigateToOffset = function(charOffset) {
    const page = window._ambrosiaPages.find(p => p.start <= charOffset && charOffset < p.end);
    if (page) window.ambrosiaRenderPage(page.start, page.end);
};
```
Must also exist in scroll mode as a no-op — callers must not branch on mode.

### Shared panel
Single `NSPanel`, `styleMask` includes `.nonactivatingPanel` (set at init — not after). Two-tab `TabView`:
- **Bookmarks:** sorted by `spineIndex` then `startChar`. Row: chapter name, date, "Spine N, offset X".
- **Annotations:** sorted by position. Row: colour chip + 80 chars `selectedText` + date + note. Double-click navigates.

⌘B toggle. Frame persisted in `UserDefaults` as `"annotationPanelFrame"`.

### Hide highlights toggle
When off:
```swift
evaluateJavaScript(
    "document.querySelectorAll('.ambrosia-highlight').forEach(el => el.style.backgroundColor = 'transparent');",
    completionHandler: nil
)
```
When on: `evaluateJavaScript("window.ambrosiaRestoreHighlightColors()", completionHandler: nil)`

Pre-register `ambrosiaRestoreHighlightColors` in injected JS — iterates `.ambrosia-highlight` spans, re-reads `data-annotation-id`, restores colour from a JS-side colour map populated during `HighlightBridge.restoreHighlights`.

**Do NOT regenerate full HTML to toggle visibility — invariant 11.**

---

## Phase 16 — ELO Ranking System
**Dependencies:** None. Track C.

### `BookState` fields
`eloScore: Double = 1000.0` and `eloMatchCount: Int = 0` — add via SwiftData migration.

### ELO algorithm
```swift
func kFactor(for matchCount: Int) -> Double {
    switch matchCount {
    case 0..<10: return 64
    case 10..<30: return 32
    default: return 16
    }
}

// Always one save, both changes — invariant 19
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
- Right-click or right arrow key → right book wins
- Escape → skip, no score change

**Pair selection:** fetch 20 `BookState` objects near median `eloScore`; pick random pair excluding last 20 shown (memory only); every 5th pair fully random.

**Library sort:** Add "ELO Score ↓" to sort `Picker`. Books with `eloMatchCount == 0` sort below ranked books — map to `(eloMatchCount == 0 ? 0 : 1, -eloScore)`.

### Open question (resolve before implementing)
ELO scores: per-fandom or global? Recommend global for v1.

---

## Phase 17 — Custom Fonts in Reader
**Dependencies:** None. Track B.

### Font selection UI (Preferences → Reader)
**Curated list** (`Picker`): grouped Serif / Sans-Serif / Monospace. Guaranteed present on macOS 14+:

| Group | Fonts |
|---|---|
| Serif | New York, Georgia, Times New Roman, Palatino |
| Sans-Serif | SF Pro, Helvetica Neue, Arial, Gill Sans |
| Monospace | SF Mono, Menlo, Courier New |

One-line preview in each font alongside each item.

**System picker button** ("Choose from all fonts…"): `NSFontPanel.shared.makeKeyAndOrderFront(nil)`.

**Critical:** `NSFontPanel` does NOT call a delegate. Selection is delivered via `changeFont(_:)` walked through the responder chain. `PreferencesWindowController` must implement:
```swift
override func changeFont(_ sender: NSFontManager?) {
    guard let manager = sender else { return }
    let font = manager.convert(.systemFont(ofSize: 14))
    let family = font.familyName ?? font.fontName
    ReaderPreferences.shared.fontFamily = "\"\(family)\", serif"
    NSFontPanel.shared.orderOut(nil)
}
```

Font classification via `NSFontManager`:
```swift
let traits = NSFontManager.shared.traits(of: font)
if traits.contains(.monoSpaceTrait)        { /* mono */ }
else if !traits.contains(.sansSerifTrait)  { /* serif */ }
else                                        { /* sans-serif */ }
```

Store as CSS font-stack in `ReaderPreferences.shared.fontFamily`. Always append a generic fallback (`serif`, `sans-serif`, or `monospace`). Font change triggers `reloadStrategy`. In `immediate` mode, full HTML regenerated — invariant 11.

---

## Phase 18 — AO3 Login, Kudos, and Bookmarks
**Dependencies:** Phase 9 (needs `story_url`, `ao3_work_id`, `ao3_author_username`, `kudos_count`). Track G.

### `AO3RateLimiter` — implement this first
```swift
actor AO3RateLimiter {
    static let shared = AO3RateLimiter()
    private var lastRequest: Date = .distantPast

    func throttled<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        let elapsed = Date().timeIntervalSince(lastRequest)
        if elapsed < 2.0 { try await Task.sleep(for: .seconds(2.0 - elapsed)) }
        lastRequest = Date()
        return try await work()
    }
}
```
**Invariant 17:** Every request to `archiveofourown.org` goes through `AO3RateLimiter.shared.throttled`. No exceptions.

### Keychain credential storage (no third-party wrapper)
```swift
// Store
SecItemAdd([
    kSecClass: kSecClassInternetPassword,
    kSecAttrService: "com.ambrosia.ao3",
    kSecAttrAccount: username,
    kSecValueData: passwordData,
    kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
] as CFDictionary, nil)

// Retrieve — gate behind LAContext on macOS 14
let context = LAContext()
try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Access AO3 credentials")
// then SecItemCopyMatching
```

Session cookie (`_otwarchive_session`): store in a **private** `HTTPCookieStorage` instance (not `.shared`). Serialise cookie properties dict to Keychain as `Data`.

### Authentication flow
1. `GET https://archiveofourown.org/users/login` → `SwiftSoup` to extract `<input name="authenticity_token">`.
2. `POST /users/login` with `user[login]=…&user[password]=…&authenticity_token=…`.
3. On success: persist `_otwarchive_session` cookie.
4. On 401 or redirect to `/users/login`: show non-modal notification banner. **Do not** show `NSAlert`.

Reference logic: `wendytg/ao3_api` on GitHub (Python). Translate endpoints and form fields to Swift.

### Kudos
```
GET story_url → extract fresh authenticity_token
POST /works/[ao3_work_id]/kudos
    body: authenticity_token=…
    headers: Cookie: _otwarchive_session=…
```
On success: `UPDATE ao3_metadata SET kudos_count = kudos_count + 1 WHERE calibre_id = …`
Disable button if `ao3_author_username` matches logged-in username (AO3 rejects self-kudos).

### AO3 bookmarks
```
POST /works/[ao3_work_id]/bookmarks
    body: bookmark[bookmarker_notes]=…&bookmark[tag_string]=…&bookmark[private]=0or1
          &authenticity_token=…
```
Small `NSPopover`: notes `NSTextView`, tags `NSTextField`, private checkbox, Submit button.

### Reader toolbar additions
Heart button (kudos, grey→red when given). Bookmark button. Both show tooltip "Log in to AO3 in Preferences" when no session. Login UI in Preferences → AO3 Account tab.

---

## Phase 19 — Collections, Saved Searches, Favourite Authors, and Saved Quotes
**Dependencies:** None. Track E.

**Read existing `Collection @Model` in full before writing any code. A migration is required for new fields.**

### Collections — new `@Model` fields
```swift
var isSystem: Bool = false
var systemType: String? = nil  // "readLater" | "liked" | "hidden"
```
`calibreIDsData: Data` stores JSON-encoded `[Int]` — invariant 1.

On first launch (`UserDefaults` flag `"systemCollectionsCreated"`): insert three system collections. System collections cannot be renamed or deleted.

| `systemType` | Display Name | Purpose |
|---|---|---|
| `"readLater"` | "Read Later" | Mark for later; bookmark icon in rows |
| `"liked"` | "Liked" | Mirrors `BookState.isLiked`; star icon in toolbar |
| `"hidden"` | "Hidden" | All `BookState.isHidden == true` books; Preferences-only |

**Liked collection sync:** `BookState.isLiked` is the source of truth. When `isLiked` changes, also update the Liked system collection's `calibreIDsData` in the same `ModelContext.save()` call. On app launch, do a one-time reconciliation pass to make sure the Liked collection's IDs match all `BookState.isLiked == true` records. The Liked collection exists so users can apply collection-level operations to liked books (e.g. hide liked from library view, or export the list).

### Read Later UX
Bookmark icon in every book row (list view), every cover card (grid view), and in the email view detail pane. Tap toggles `calibreID` in `calibreIDsData`. Register with `NSUndoManager`.

**Email view — "Mark for Later" button:** Add a bookmark toolbar button in the email view's detail pane header (SwiftUI `Button` with `bookmark` SF Symbol). State reflects whether the current selection's `calibreID` is in the Read Later collection. Also add to the `NSTableView` sidebar context menu alongside "Open" and "Like/Unlike".

Collection toolbar when Read Later selected:
- "Open Random" — random `calibreID` from `calibreIDsData`, open in reader
- "Clear" — empty `calibreIDsData` (undo: "Clear Read Later")

### Liked UX
**Toolbar star button:** Add a `⭐` (`star` / `star.fill` SF Symbol) button to the main library `NSToolbar` for the currently selected book. When no book is selected the button is disabled. Toggling updates `BookState.isLiked` and syncs the Liked collection. Register with `NSUndoManager`. Action name: "Like" / "Unlike".

In list view rows and email view sidebar, the existing like/unlike context menu item remains. The toolbar button is the new primary affordance for keyboard-driven users.

### Mark as Read UX
Manual read-marking is available in:
- Book row context menu: "Mark as Read" / "Mark as Unread"
- Email view detail pane: a "✓ Read" badge button in the header
- Reader toolbar: a checkmark button (sets `isRead = true` immediately, same as auto-mark)

All operations register with `NSUndoManager`. Setting `isRead = false` does NOT modify `totalReadPercent`.

### Saved searches DDL (`ambrosia_meta.db`)
```sql
CREATE TABLE IF NOT EXISTS saved_searches (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    query_string TEXT,
    filter_rules_json TEXT,   -- serialised FilterResult rules
    created_at TEXT NOT NULL  -- ISO-8601
);
```

UI: bookmark icon at trailing end of search bar (active when any search/filter applied). Popover: name field + Save button. Dropdown of saved searches below search bar. Selecting one restores `LibraryToolbarState.searchText` and deserialises `filter_rules_json` into `FilterDrawer` rules. Trash button to delete (undo supported).

### Favourite Authors DDL (`ambrosia_meta.db`)
```sql
CREATE TABLE IF NOT EXISTS favourite_authors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    author_name TEXT NOT NULL UNIQUE,     -- matches Calibre `authors.name` exactly
    note TEXT,                            -- optional personal note
    added_at TEXT NOT NULL               -- ISO-8601
);
CREATE INDEX IF NOT EXISTS idx_fav_authors_name ON favourite_authors(author_name);
```

**Why `ambrosia_meta.db` and not `UserDefaults`:** Unlike hidden authors (a small exclusion list), favourite authors may accumulate to hundreds of entries and benefit from indexed lookup. Keeping it in SQLite also makes it exportable alongside other user data.

**UX:**
- Book row context menu: "Favourite Author" / "Unfavourite Author" (one item per author; submenu if multiple authors)
- Author pill tap in list view: popover shows author name + "☆ Favourite" toggle
- Favourited authors shown with a star chip in the author list (Preferences → Library → Favourite Authors) with remove button and optional note field
- Library sort: "Favourite Authors First" option in sort picker — books with any favourited author sort above others, then by existing sort within each group

### Saved Quotes DDL (`ambrosia_meta.db`)
Distinct from annotations. Quotes are passages the user wants to remember outside the reading context — more curated, shareable, and not tied to a specific annotation colour or note workflow.

```sql
CREATE TABLE IF NOT EXISTS saved_quotes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    calibre_id INTEGER NOT NULL,
    spine_index INTEGER NOT NULL,
    start_char INTEGER NOT NULL,
    end_char INTEGER NOT NULL,
    selected_text TEXT NOT NULL,
    attribution TEXT,                -- e.g. "Chapter 3" or custom label
    note TEXT,
    created_at TEXT NOT NULL,        -- ISO-8601
    tags_json TEXT                   -- JSON [String] for user-defined quote tags
);
CREATE INDEX IF NOT EXISTS idx_saved_quotes_calibre ON saved_quotes(calibre_id);
```

**UX:**
- Reader context menu: "Save Quote" (alongside "Add Annotation…"). Opens a small `NSPopover` with the selected text (read-only), an attribution field (pre-filled with spine/chapter name), an optional note field, and optional tag field.
- Quotes panel: `NSPanel` (or a third tab in the annotation panel from Phase 15 — evaluate at implementation time). Sorted by book then position. Each row: book title, attribution, first 120 chars of text, note. Double-click navigates to position in reader.
- Export: "Copy Quote" → clipboard as `"[text]" — [book title], [attribution]`. NSSavePanel CSV export from the quotes panel.
- **Character offset contract:** `start_char` and `end_char` use the same UTF-16 convention as annotations (invariant 5).

---

## Phase 20 — Annotation Export and Sharing
**Dependencies:** Phase 15. Track F.

### `AnnotationExporter`
```swift
struct AnnotationExporter {
    func markdown(for book: CalibreBook, annotations: [Annotation], template: String) -> String
    func copyToClipboard(for book: CalibreBook, annotations: [Annotation], template: String)
    func exportToFile(for book: CalibreBook, annotations: [Annotation], template: String)
    // exportToFile: NSSavePanel, default filename "[Title]-annotations.md"
}
```
Export covers **all annotations for the book** — not just the visible page.

Context menu additions (to `ContextMenuAction` enum): `.copyAnnotations`, `.exportAnnotations`.

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
Per highlight: `> {{text}}\n\n{{note}}\n*Added: {{created_date}}*\n\n---\n`

### Custom template
`ReaderPreferences` gains `annotationExportTemplate: String`. Preferences → Reader: `TextEditor` with "Restore Default" button. Variables: `{{title}}`, `{{author}}`, `{{export_date}}`, `{{highlights}}`, `{{bookmarks}}`; per-item: `{{text}}`, `{{note}}`, `{{chapter}}`, `{{created_date}}`. Implementation: `String.replacingOccurrences` loop. No templating library.

---

## Phase 21 — Standalone Mode (No Calibre Required)
**Dependencies:** None. Track H.

**Goal:** Point Ambrosia at a folder of AO3 EPUBs. Ambrosia generates a Calibre-compatible `metadata.db`.

### Trigger
On "Open Library Folder…", if folder has no `metadata.db` but has `.epub` files: confirmation sheet "No Calibre library found. Set up an Ambrosia library here? A metadata.db file will be created in this folder."

`metadata.db` lives **in the same folder as the EPUBs** (portable). `ambrosia_meta.db` stays in Application Support.

### `CalibreLibraryWriter`
Distinct class with its own write-enabled `Connection`. **Never instantiated while `CalibreLibrary` has `metadata.db` open — invariant 18.**
```swift
let writer = CalibreLibraryWriter(folderURL: chosenFolder)
try writer.createSchema()
try writer.importEPUBs(from: chosenFolder)
writer.close()  // explicit close, guaranteed dealloc before CalibreLibrary opens
let library = CalibreLibrary(root: chosenFolder)
```

### Schema
Source exact DDL from `kovidgoyal/calibre` at `src/calibre/db/schema_upgrades.py`. Required tables: `books`, `authors`, `books_authors_link`, `tags`, `books_tags_link`, `series`, `books_series_link`, `publishers`, `books_publishers_link`, `comments`, `data`, `custom_columns`. Set `PRAGMA user_version` to match Calibre's current value from that file.

Test against Calibre 6.x and 7.x before shipping.

### AO3 detection per EPUB
1. `EPUBParser` → read `dc:publisher` from OPF. If `"Archive of Our Own"` (case-insensitive) → import.
2. Else: check spine item 0 HTML for `dl class="work meta group"`. If found → import.
3. Neither: log skip. After import: "3 files skipped (not recognised as AO3 EPUBs)". Never silently discard.

### Cover generation
Calibre expects `<book_folder>/cover.jpg` and `has_cover = 1`.
1. Check EPUB manifest for cover image. If found, extract as `cover.jpg`.
2. If not: generate with `CGContext`. Background: `abs(title.hashValue) % 6` → one of 6 hardcoded colours. Title text: `NSFont.systemFont(ofSize: 24, weight: .medium)`, centred, white. JPEG quality 0.9.

### Duplicate detection
Two EPUBs with same `ao3_work_id`: keep newer (filesystem mtime). Show warning: "Duplicate: [Title] — kept newer version."

### Ongoing sync
"Scan for New EPUBs" toolbar action: rescan, insert new EPUBs (match by UUID from OPF, fallback to filename). **Do not** auto-delete rows for missing files — show "N books not found on disk" with "Remove missing" button. Never silently delete user data.

---

## Phase 22 — Pin Reader Window to Top
**Dependencies:** None. Track B (tiny — bundle with another B-track phase).

```swift
func togglePinToTop() {
    guard let window = readerWindowController.window else { return }
    let newValue = !bookState.isPinnedToTop
    bookState.isPinnedToTop = newValue
    window.level = newValue ? .floating : .normal
    try? modelContext.save()
}
```

Restore on window open:
```swift
window.level = bookState.isPinnedToTop ? .floating : .normal
```

`isPinnedToTop: Bool = false` is a new `BookState` field — add to the SwiftData migration plan alongside the other new fields.

---

## Phase 23 — macOS Music Player Integration (Stub)
**Dependencies:** Phase 15 merged. **Track I — DO NOT START. Blocked on product owner decisions.**

### What is blocked (confirm with product owner first)
1. Which player: Petrichor (`kushalpandya/Petrichor`) or Apple Music (`MusicKit` / `MPMusicPlayerController`)?
2. Transition type: crossfade, immediate replace, or queue as next? (`MusicKit` WWDC 2024 has `Transition` enum; `MPMusicPlayerController.systemMusicPlayer` has no crossfade; Petrichor is AVFoundation-based and needs custom crossfade code.)
3. IPC mechanism: Petrichor has no AppleScript or URL scheme API (verify current state). Apple Music supports AppleScript.

### What can be pre-built now (do not block on above)
Add `musicTrigger: String?` to `Annotation` struct (stored in `BookState.annotationsData` JSON automatically).

In reader, when position advances past a bookmark's `startChar` and `musicTrigger != nil`:
```swift
NotificationCenter.default.post(name: .ambrosiaMusicCheckpointReached, object: trigger)
```
Leave the notification handler as a stub. **Do not wire up any player until product owner confirms integration target.**

---

## Phase 24 — Music Playlist System
**Dependencies:** Phase 23 product owner decisions resolved. Phase 15 merged (for `Annotation` extension and character offset infrastructure). **Track I — DO NOT START until Phase 23 blockers are resolved.**

**Goal:** Let users associate music with their reading. Three trigger modes per playlist: position-based (a specific character offset triggers a song), chapter-based (one song per spine item), or vibe-based (songs tagged with a vibe are shuffled when a chapter/location matches that vibe). Songs have user-defined tags for vibe matching.

### DDL (`ambrosia_meta.db`)

```sql
-- A playlist belongs to one book (or NULL for a global/default playlist)
CREATE TABLE IF NOT EXISTS music_playlists (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    calibre_id INTEGER,              -- NULL = global playlist; non-NULL = book-specific
    trigger_mode TEXT NOT NULL,      -- 'position' | 'chapter' | 'vibe'
    created_at TEXT NOT NULL,
    UNIQUE(calibre_id, name)
);
CREATE INDEX IF NOT EXISTS idx_music_playlists_calibre ON music_playlists(calibre_id);

-- Individual songs in a playlist
CREATE TABLE IF NOT EXISTS playlist_songs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    playlist_id INTEGER NOT NULL REFERENCES music_playlists(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    artist TEXT,
    player_uri TEXT,                 -- player-specific URI (MusicKit catalogID, file path, etc.)
    sort_order INTEGER NOT NULL DEFAULT 0,
    UNIQUE(playlist_id, sort_order)
);
CREATE INDEX IF NOT EXISTS idx_playlist_songs_playlist ON playlist_songs(playlist_id);

-- User-defined vibe tags on songs (many-to-many)
CREATE TABLE IF NOT EXISTS song_tags (
    song_id INTEGER NOT NULL REFERENCES playlist_songs(id) ON DELETE CASCADE,
    tag TEXT NOT NULL,
    PRIMARY KEY (song_id, tag)
);
CREATE INDEX IF NOT EXISTS idx_song_tags_tag ON song_tags(tag);

-- Position triggers: 'position' mode — a specific char offset → a specific song
CREATE TABLE IF NOT EXISTS music_position_triggers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    playlist_id INTEGER NOT NULL REFERENCES music_playlists(id) ON DELETE CASCADE,
    song_id INTEGER NOT NULL REFERENCES playlist_songs(id) ON DELETE CASCADE,
    spine_index INTEGER NOT NULL,
    char_offset INTEGER NOT NULL,    -- UTF-16, text nodes only — invariant 5
    UNIQUE(playlist_id, spine_index, char_offset)
);

-- Chapter triggers: 'chapter' mode — one song per spine index
CREATE TABLE IF NOT EXISTS music_chapter_triggers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    playlist_id INTEGER NOT NULL REFERENCES music_playlists(id) ON DELETE CASCADE,
    spine_index INTEGER NOT NULL,
    song_id INTEGER,                 -- NULL = randomise from playlist
    UNIQUE(playlist_id, spine_index)
);

-- Vibe triggers: 'vibe' mode — spine index → vibe tag → pick matching song at random
CREATE TABLE IF NOT EXISTS music_vibe_triggers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    playlist_id INTEGER NOT NULL REFERENCES music_playlists(id) ON DELETE CASCADE,
    spine_index INTEGER NOT NULL,
    vibe_tag TEXT NOT NULL,          -- matches song_tags.tag
    UNIQUE(playlist_id, spine_index)
);
```

### Trigger resolution at runtime
When the reader's position changes (scroll or page turn), `MusicTriggerEngine` evaluates:

1. **Position mode:** Query `music_position_triggers` for triggers in the current spine whose `char_offset` has been passed. Fire on first pass only (track fired trigger IDs in memory for the session). Post `ambrosiaMusicCheckpointReached` with the resolved `player_uri`.

2. **Chapter mode:** On every spine change, query `music_chapter_triggers` for the new `spine_index`. If `song_id` is non-NULL, use that song. If `song_id` is NULL, pick a random song from the playlist. Post notification.

3. **Vibe mode:** On every spine change, query `music_vibe_triggers` for the new `spine_index`. Get the `vibe_tag`. Query all `song_tags` rows matching that tag, join to `playlist_songs`. Pick one at random. Post notification.

```swift
actor MusicTriggerEngine {
    private var firedTriggerIDs: Set<Int> = []   // reset on book open
    
    func evaluatePositionChange(
        spineIndex: Int, charOffset: Int, playlistID: Int
    ) async -> String? { /* ... */ }
    
    func evaluateChapterChange(
        spineIndex: Int, playlistID: Int
    ) async -> String? { /* ... */ }
}
```

`MusicTriggerEngine` must not block the main thread. All DB queries are read-only and go through a `Connection(path, readonly: true)` — no actor for reads (see `ambrosia_meta.db` read pattern).

### Playlist editor UI
`NSPanel` or sheet, launched from Reader toolbar (music note SF Symbol: `music.note.list`).

- Playlist picker at top (book-specific vs global)
- Trigger mode segmented control: Position / Chapter / Vibe
- Song list (`NSTableView`): title, artist, vibe tags, drag to reorder
- "Add Song…" button: opens player-specific picker (implementation deferred to player integration)
- Per-song: edit vibe tags (token field), remove button
- Trigger assignment:
  - **Position mode:** "Set Trigger Here" button in reader injects current position into the editor. Triggers appear as rows with spine + offset.
  - **Chapter mode:** table of spine items; each row has a song picker or "Random" toggle.
  - **Vibe mode:** table of spine items; each row has a vibe tag text field.

### Vibe tag design
Vibe tags are arbitrary user strings ("tense", "soft", "epic", "sad", etc.). No canonical list is enforced. Autocomplete from existing `song_tags` entries when typing. The user assigns the same tags to multiple songs and to spine locations — the engine then randomly selects a matching song.

### Open questions (resolve before implementing)
1. Player confirmed by product owner (Phase 23 blocker)?
2. Crossfade duration configurable or fixed?
3. Should position triggers fire only once per session, or re-fire if the user scrolls back?
4. Behaviour when no song matches the vibe tag (fallback to random from playlist, or silence)?

---

## Swift Packages

| Package | URL | Used in | Purpose |
|---|---|---|---|
| `SwiftSoup` | `https://github.com/scinfu/SwiftSoup` | 9, 11, 18 | HTML parsing for AO3 EPUB headers, tag pages, auth form. Add via Xcode SPM UI only. |

No other new packages. `SQLite.swift` and `ZIPFoundation` already cover all other needs. Do not add packages for CSV export, Markdown, ELO arithmetic, font panel, or heatmap chart — all achievable with stdlib / AppKit / SwiftUI.

---

## Invariants (Complete List 1–23)

**Never violate any of these. Check the ones applicable to your phase before writing any code.**

1. Never store `[String]`, `[Int]`, `[Double]`, or any bare Swift collection on `@Model`. Use JSON `Data` or delimited `String`. Violation: silent CoreData fault `"Could not materialize Objective-C class named 'Array'"`.
2. Never use `#Predicate` to compare `@Model` keypaths against plain struct properties. Use `FetchDescriptor` + in-memory `.first { $0.calibreID == id }`.
3. `ModelConfiguration("Ambrosia", schema:, isStoredInMemoryOnly:)` — String name, no `url:` parameter on macOS 14.
4. `ModelContext` has no `reset()`. Do not call it.
5. Character offsets: UTF-16 code units, text nodes only, no HTML tags. `EPUBParser`, `PaginationJS`, `HighlightBridge`, all annotation code must use this — everywhere, no exceptions. Deviation causes irreproducible position drift.
6. `books` table has no `series` column. Always `LEFT JOIN books_series_link bsl ON bsl.book = b.id LEFT JOIN series s ON s.id = bsl.series` and select `s.name`.
7. All `db.prepare(sql, args)` calls use `[Binding?]` (optional elements). Non-optional `[Binding]` causes compile error. Every explicit cast must be `as Binding?`.
8. Never call any write PRAGMA on the Calibre read-only connection.
9. Never hand-author `Package.resolved`. Add SPM packages via Xcode UI only. Verify packages appear as `productRef` build file entries in `PBXFrameworksBuildPhase`.
10. Pagination `WKWebView` must be in the view hierarchy with a real non-zero frame. Off-screen or frameless → zero from `getBoundingClientRect()`.
11. Regenerate full HTML on any style change. Never patch the live DOM — corrupts pagination state.
12. Image temp directory (`/tmp/ambrosia/<calibreID>/`) lifetime is the app session. Clean up in `applicationWillTerminate`.
13. `CalibreFTSLibrary` opened read-only. Always return `nil` on error to allow LIKE fallback.
14. All `evaluateJavaScript` calls must pass `completionHandler: nil` explicitly. Omitting causes silent failure in some build configs.
15. Before writing any `@Model` code, fetch https://developer.apple.com/documentation/swiftdata.
16. Never open `ambrosia_meta.db` with more than one write connection simultaneously.
17. All requests to `archiveofourown.org` must go through `AO3RateLimiter.shared.throttled`. No direct `URLSession` calls to that domain.
18. `CalibreLibraryWriter` must be fully deallocated before `CalibreLibrary` opens the `metadata.db` it created. Never share write and read connections on the same SQLite file.
19. ELO score updates must commit both books' `eloScore` and `eloMatchCount` in a single `ModelContext.save()`. Never update one without the other.
20. `SeriesGroup` is a computed value type. Never persist it in SwiftData, `ambrosia_meta.db`, or any store.
21. Any new `@Model` field requires a `VersionedSchema` + `SchemaMigrationPlan` before the build ships. Existing crash-and-retry recovery deletes all user state.
22. All `BookState` field lookups use in-memory filter after `FetchDescriptor`. Applies to all new fields: `isHidden`, `isRead`, `eloScore`, `eloMatchCount`, `isPinnedToTop`.
23. `SeriesGroup.works` is always ordered by `series_index ASC`. Never sort by `calibreID` or title.
24. `NSPanel.styleMask` including `.nonactivatingPanel` must be set at init time. Setting it post-init has no effect.
25. `NSFontPanel` does not call a delegate. Selection is delivered via `changeFont(_:)` walked up the responder chain.
26. `Task.detached(priority: .background)` for all EPUB extraction and `ambrosia_meta.db` writes. Never block the main thread.
27. `book_opens` is append-only. Never delete rows. Never add a purge/truncate code path.
28. `isRead` is set automatically only in `ReadingHistoryLogger` when `totalReadPercent >= 0.98`. All other automatic setting of `isRead` is forbidden. Manual user overrides via context menu, detail pane, or reader toolbar are the only other valid write sites.
29. The Liked system collection's `calibreIDsData` must be kept in sync with `BookState.isLiked` in the same `ModelContext.save()` call. Never update one without reconciling the other.
30. `saved_quotes` `start_char` and `end_char` use the same UTF-16 text-node convention as annotations (invariant 5). No exceptions.
31. `music_position_triggers` `char_offset` uses the same UTF-16 text-node convention (invariant 5).
32. `MusicTriggerEngine` read queries must use a read-only `Connection` — not the `AmbrosiaMetaDB` write actor. Read-only connections do not need actor isolation.
33. Book suppression (hidden/read/seen/author/tag/collection) is applied exclusively in the in-memory post-filter pass, never in SQL. Calibre SQL must remain unaware of all suppression state.
34. Never use `fandom_hierarchy` as a table name anywhere in the codebase. The correct table is `tag_parent_links`. `AO3TagSeeds.loadIfNeeded` targets `tag_parent_links` — using the wrong name will silently produce empty hierarchy results.
35. Calibre's `tags` table is type-blind — it mixes fandoms, relationships, characters, and additional tags in a single flat list. Never infer tag type from the Calibre `tags` table. Tag type comes from `ao3_metadata`'s separate JSON columns (populated by EPUB extraction) or from `canonical_tags.tag_type`.
36. Category tags (`F/F`, `Gen`, `M/M`, etc.) are a closed vocabulary and are **not** stored in `canonical_tags`. They are stored in `ao3_metadata.category_json` only. Never pass category values through `TagSynonymResolver`.
37. `TagSynonymResolver` must use `canonicalBatch(for:)` for any multi-tag input. Never call `canonical(for:)` in a loop — it creates N separate read-only DB round-trips.
38. Fandom hierarchy expansion (`tag_parent_links` recursive CTE) applies only to `'fandom'`, `'character'`, and `'relationship'` tag types. Never expand `'additional'` tags via the hierarchy.

---

## Reference Links

### SwiftData
- **Overview:** https://developer.apple.com/documentation/swiftdata ← fetch before any `@Model` code
- **Migrations:** https://developer.apple.com/documentation/swiftdata/migratingpersistentdatausingschemaversionsandmigrationpolicies
- **Revision history:** https://developer.apple.com/documentation/updates/swiftdata
- **ModelActor:** https://developer.apple.com/documentation/swiftdata/modelactor
- **FetchDescriptor:** https://developer.apple.com/documentation/swiftdata/fetchdescriptor

### WKWebView
- **evaluateJavaScript:** https://developer.apple.com/documentation/webkit/wkwebview/1415017-evaluatejavascript
- **WKScriptMessageHandler:** https://developer.apple.com/documentation/webkit/wkscriptmessagehandler
- **WKUserContentController:** https://developer.apple.com/documentation/webkit/wkusercontentcontroller

### AppKit / SwiftUI
- **NSHostingView:** https://developer.apple.com/documentation/swiftui/nshostingview
- **MainActor:** https://developer.apple.com/documentation/swift/mainactor
- **AppKit docs:** https://developer.apple.com/documentation/appkit

### SQLite / EPUB / External
- **SQLite.swift docs:** https://github.com/stephencelis/SQLite.swift/blob/master/Documentation/Index.md
- **Calibre DB schema:** https://github.com/kovidgoyal/calibre/blob/master/src/calibre/db/schema_upgrades.py
- **EPUB 3 spec:** https://www.w3.org/publishing/epub3/epub-spec.html
- **TreeWalker (MDN):** https://developer.mozilla.org/en-US/docs/Web/API/TreeWalker
- **ZIPFoundation:** https://github.com/weichsel/ZIPFoundation
- **SwiftSoup:** https://github.com/scinfu/SwiftSoup

---

## Common Bugs Checklist — Check Before Each Phase

**SwiftData**
- [ ] New `@Model` field → `VersionedSchema` + `SchemaMigrationPlan` before running. No exceptions.
- [ ] No bare Swift collections on `@Model`. JSON `Data` or delimited `String` only.
- [ ] `#Predicate` only against `@Model` keypaths — never against plain struct properties.
- [ ] `ModelConfiguration` takes `String` name, not URL, on macOS 14.
- [ ] `isRead` auto-set only in `ReadingHistoryLogger`. No other automatic write sites.
- [ ] Liked collection `calibreIDsData` synced in same `save()` call as `BookState.isLiked` change.

**WKWebView**
- [ ] `WKWebViewConfiguration` fully configured (all handlers added) before `WKWebView` is initialised.
- [ ] All `evaluateJavaScript` calls pass `completionHandler: nil` explicitly.
- [ ] Paginated `WKWebView` in view hierarchy with real non-zero frame.
- [ ] Full HTML regenerated on style changes — never patch live DOM.

**SQLite.swift**
- [ ] All `db.prepare(sql, args)` use `[Binding?]` (optional array).
- [ ] No write PRAGMAs on Calibre read-only connection.
- [ ] `CREATE TABLE IF NOT EXISTS` on all tables.
- [ ] Music trigger `char_offset` and quote `start_char`/`end_char`: UTF-16, text nodes only.
- [ ] `book_opens` is append-only — no DELETE or TRUNCATE ever.

**AppKit**
- [ ] `NSPanel.styleMask` including `.nonactivatingPanel` set **at init time**.
- [ ] `NSFontPanel` selection via `changeFont(_:)` in responder chain — no delegate.
- [ ] `NSUndoManager` per-window and ephemeral — correct macOS behaviour.

**Tag system**
- [ ] Table name is `tag_parent_links`, never `fandom_hierarchy`.
- [ ] Tag type lookup uses `ao3_metadata` JSON columns, never Calibre `tags` table.
- [ ] Category tags (`F/F`, `Gen`, etc.) never passed through `TagSynonymResolver`.
- [ ] Multi-tag resolution uses `canonicalBatch(for:)`, never `canonical(for:)` in a loop.
- [ ] Hierarchy expansion only for `'fandom'`/`'character'`/`'relationship'` — never `'additional'`.
- [ ] All `archiveofourown.org` requests through `AO3RateLimiter.shared.throttled`.
- [ ] `AmbrosiaMetaDB` write access through single `actor`.
- [ ] `MusicTriggerEngine` reads use a separate read-only `Connection`, not the write actor.
