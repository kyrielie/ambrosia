# Local Source Code References & Companion Architectures

Scope: index of local reference codebases located in [`~/Documents/Applications/swiftreference`](~/Documents/Applications/swiftreference) and companion applications in the parent directory (`../nectar`, `../honeycrisp`, `../calibre`).

This document serves as the permanent architectural reference map so that engineers (AI or human) do not reinvent algorithms, data structures, or search engines already solved and battle-tested in adjacent local repositories.

---

## 1. Inventory of Local Reference Repositories

All paths below are local to this machine. Because `swiftreference` is outside the Ambrosia repository root, shell commands inspecting it require `BypassSandbox: true` (or direct absolute file reads).

| Repository / Directory | Path | Primary Architectural Value for Ambrosia |
| :--- | :--- | :--- |
| **`LeafNative`** | [`../swiftreference/swiftepub/LeafNative`](~/Documents/Applications/swiftreference/swiftepub/LeafNative) | **Local semantic/vector search**, Apple `NaturalLanguage` sentence embeddings, `Accelerate` BLAS SIMD matrix scanning, memory-mapped binary vector store (`ResearchVectorStore`). |
| **`Winston`** | [`../swiftreference/swiftepub/Winston`](~/Documents/Applications/swiftreference/swiftepub/Winston) | **SQLite FTS5 full-text search actor**, `bm25()` ranking, `snippet()` extraction, cooperative Swift concurrency cancellation (`sqlite3_progress_handler`), database corruption auto-reset. |
| **`CotEditor`** | [`../swiftreference/CotEditor`](~/Documents/Applications/swiftreference/CotEditor) | **Precision text finding & regular expressions**, `.withTransparentBounds` for zero-allocation regex word boundary matching, textual vs regex mode dispatch, AppKit find panels. |
| **`kudos-ao3-reader`** | [`../swiftreference/kudos-ao3-reader`](~/Documents/Applications/swiftreference/kudos-ao3-reader) | **AO3 metadata search profile synthesis**, summary truncation bounds (600 chars), POSIX diacritic folding, `SavedSearch` SwiftData model. |
| **`readest`** | [`../swiftreference/swiftepub/readest`](~/Documents/Applications/swiftreference/swiftepub/readest) | **Calibre-parity search modes** (`regex` + `nearby-words` within $N$ words), zero-width pattern guards, HTML inline markup snippet context expansion (`#4594`). |
| **`swift-toolkit`** | [`../swiftreference/swiftepub/swift-toolkit`](~/Documents/Applications/swiftreference/swiftepub/swift-toolkit) | **Readium Swift architecture**, `StringSearchAlgorithm` (`caseSensitive`, `diacriticSensitive`, `exact`, `regularExpression`), cursor-based `SearchIterator` pagination. |
| **`Aidoku`** | [`../swiftreference/Aidoku`](~/Documents/Applications/swiftreference/Aidoku) | **Faceted search & filter drawer UI**, tag pill navigation, source migration workflows. |
| **`FlyingFox`** | [`../swiftreference/swiftepub/FlyingFox`](~/Documents/Applications/swiftreference/swiftepub/FlyingFox) | **Lightweight async Swift HTTP server**, reference for OPDS catalog serving and local feed transfer routes. |
| **`Sumra`** | [`../swiftreference/swiftepub/Sumra`](~/Documents/Applications/swiftreference/swiftepub/Sumra) | **MuPDF native search patches**, ligature geometry, reflow search handoff. |
| **`EPUBKit` / `FolioReaderKit`** | [`../swiftreference/swiftepub/`](~/Documents/Applications/swiftreference/swiftepub) | Classical Swift EPUB DOM, OPF packaging, and spine navigation references. |
| **`Octavo`** | [`../swiftreference/swiftepub/Octavo`](~/Documents/Applications/swiftreference/swiftepub/Octavo) | **Native Kindle MTP sync & format writers**, `MTPKit` (`IOUSBHost`), `KindleFormat` (pure-Swift AZW3/KF8 + MOBI writers), `USBWatcher` hotplug stream. |
| **`tomo`** | [`../swiftreference/swiftepub/tomo`](~/Documents/Applications/swiftreference/swiftepub/tomo) | **USB Kindle/Kobo delivery & iCloud safety**, `swift-azw3`, `bookFileSlug` deduplication, `NSFileCoordinator` + `.icloud` eviction detection. |
| **`Varq`** | [`../swiftreference/swiftepub/Varq`](~/Documents/Applications/swiftreference/swiftepub/Varq) | **macOS system integration & local PKM**, Core Spotlight + App Intents (`v1.2`), idempotent Obsidian Vault Export, macOS 26+ isolated `AIAssistantService` (`v1.1`). |
| **`epub-quicklook-extension`** | [`../swiftreference/epub-quicklook-extension`](~/Documents/Applications/swiftreference/epub-quicklook-extension) | **Finder Quick Look EPUB previewer**, `WKWebView`-based `QLPreviewProvider` with dark-mode CSS. |
| **`Tidemark`** | [`../swiftreference/swiftepub/Tidemark`](~/Documents/Applications/swiftreference/swiftepub/Tidemark) | **Safe pure-Swift Markdown parser**, zero-`Unsafe` bounded parsing for PKM/notes previewing. |
| **`bookokrat`** | [`../swiftreference/tuiepub/bookokrat`](~/Documents/Applications/swiftreference/tuiepub/bookokrat) | **Reader navigation ergonomics**, Vim-style jump list (`Ctrl+O`/`Ctrl+I`) across footnotes/TOC links. |
| **`Nectar`** | [`../nectar`](~/Documents/Applications/nectar) | Companion iOS reader: CSS theme engine (`.nnwtheme`), live CSS variable updates, annotations, AO3 HTML extraction, reading progress, SQLite transfer. |
| **`Honeycrisp`** | [`../honeycrisp`](~/Documents/Applications/honeycrisp) | Companion macOS reader: Standalone file reader, named themes popover, cosmetic vs structural reload separation. |

---

## 2. Deep Dive: Search & Indexing Subsystems

### 2.1 Local Semantic Vector Engine (`LeafNative`)
- **Key File**: [`LeafNative/Sources/LeafNative/ResearchIndex.swift`](~/Documents/Applications/swiftreference/swiftepub/LeafNative/Sources/LeafNative/ResearchIndex.swift)
- **Zero-Download On-Device Embeddings**:
  - Uses `NLEmbedding.sentenceEmbedding(for: language)` from Apple's `NaturalLanguage` framework.
  - Generates unit-normalized sentence embeddings on the local CPU/Neural Engine without downloading external weights or bundling 40+ MB files.
- **Hardware BLAS Matrix Multiplication (`cblas_sgemv`)**:
  - Evaluates cosine similarities of all library vectors against the query in parallel:
    ```swift
    cblas_sgemv(
        CblasRowMajor, CblasNoTrans, Int32(vectors.rows), Int32(vectors.dimension),
        1, vectors.values, Int32(vectors.dimension), query, 1, 0, &scores, 1
    )
    ```
    On Apple Silicon, scanning 10,000 384-dimensional vectors takes $< 1\text{ ms}$.
- **Memory-Mapped Storage (`ResearchVectorStore`)**:
  - File structure: `magic` (`0x4C465631` / "LFV1"), `rows` (UInt32), `dimension` (UInt32), followed by raw contiguous `[Float]`.
  - Mapped via `Data(contentsOf: url, options: .mappedIfSafe)` with zero parsing overhead on startup.
- **Hybrid Blending**:
  - Combines normalized BM25 keyword score ($0.55$) with normalized cosine similarity ($0.45$) when similarity exceeds a minimum semantic threshold (`semanticOnlyThreshold = 0.3`).

### 2.2 Production SQLite FTS5 Indexer (`Winston`)
- **Key File**: [`Winston/Winston/Core/Search/FullTextIndex.swift`](~/Documents/Applications/swiftreference/swiftepub/Winston/Winston/Core/Search/FullTextIndex.swift)
- **Cooperative Cancellation**:
  - Uses `sqlite3_progress_handler` checking Swift Concurrency `Task.isCancelled`:
    ```swift
    sqlite3_progress_handler(database, 500, { _ in
        Task<Never, Never>.isCancelled ? 1 : 0
    }, nil)
    ```
    Instantly halts long SQLite FTS queries if the user types a new character or closes the window.
- **Self-Healing Corruption Resilience**:
  - Traps `SQLITE_CORRUPT` and `SQLITE_NOTADB` (`code & 0xFF`), logs the event, automatically resets the local SQLite index, and initiates a clean background re-index.
- **Direct BM25 & Snippet Querying**:
  - Orders by `bm25(sections)` and extracts passage excerpts using native SQLite `snippet(sections, 7, '', '', '…', 40)`.

### 2.3 Precision Finding & Transparent Bounds (`CotEditor`)
- **Key File**: [`CotEditor/Packages/EditorCore/Sources/TextFind/TextFind.swift`](~/Documents/Applications/swiftreference/CotEditor/Packages/EditorCore/Sources/TextFind/TextFind.swift)
- **Search Modes**:
  - Explicit enum: `.textual(options: String.CompareOptions, fullWord: Bool)` vs `.regularExpression(options: NSRegularExpression.Options, unescapesReplacement: Bool)`.
- **Zero-Allocation Word Boundaries (`.withTransparentBounds`)**:
  - When verifying full-word boundaries around a candidate range, CotEditor uses `options: .withTransparentBounds` on `NSRegularExpression`.
  - This allows lookahead (`(?=...)`), lookbehind (`(?<=...)`), and boundary (`\b`) assertions to inspect surrounding text outside the match range without copying or slicing substrings.

### 2.4 AO3 Work Profile Synthesis (`kudos-ao3-reader`)
- **Key File**: [`kudos-ao3-reader/kudos-ao3-reader/Services/WorkSearchIndex.swift`](~/Documents/Applications/swiftreference/kudos-ao3-reader/kudos-ao3-reader/Services/WorkSearchIndex.swift)
- **Summary Truncation Bound (`summaryLimit = 600`)**:
  - Limits summary length to 600 characters: prevents blurb noise, excessive vector memory, and dilution of key thematic signals.
- **Diacritic Folding**:
  - Normalizes text with `options: [.caseInsensitive, .diacriticInsensitive]` and a fixed `Locale(identifier: "en_US_POSIX")` so indexed text matches across differing user device locales.
- **Persistent Saved Searches**:
  - [`SavedSearch.swift`](~/Documents/Applications/swiftreference/kudos-ao3-reader/kudos-ao3-reader/Models/SavedSearch.swift) models saved query facets via `Codable` SwiftData models.

### 2.5 Calibre Parity & Markup Context Handling (`readest`)
- **Key Files**:
  - Memory: [`readest-app/.claude/memory/search-modes-4560-and-spoiler-bound-bug.md`](~/Documents/Applications/swiftreference/swiftepub/readest/apps/readest-app/.claude/memory/search-modes-4560-and-spoiler-bound-bug.md)
  - Memory: [`readest-app/.claude/memory/search-excerpt-context-4594.md`](~/Documents/Applications/swiftreference/swiftepub/readest/apps/readest-app/.claude/memory/search-excerpt-context-4594.md)
  - Unit Tests: [`foliate-search-modes.test.ts`](~/Documents/Applications/swiftreference/swiftepub/readest/apps/readest-app/src/__tests__/foliate-search-modes.test.ts)
- **Calibre Search Modes**:
  - Implements Calibre's `regex` mode and `nearby-words` mode (matching words occurring within $N$ words of each other, order-independent).
  - Explicitly guards against zero-width regex patterns (`x*`, `^`) causing infinite matching loops.
- **HTML Inline Styling Context Bug Fix (#4594)**:
  - When matching terms wrapped in inline formatting (`<i>italic</i>`, `<em>`, `<b>`), isolated text node matching resulted in empty excerpt context.
  - Solution: `collectBefore` and `collectAfter` walk outward across neighboring text nodes up to a bounded `CONTEXT_LENGTH` (~50 normalized chars).

---

## 3. Deep Dive: Reader & Presentation Subsystems

### 3.1 CSS Themes & Live Updates (`Nectar` & `Honeycrisp`)
- **References**:
  - Nectar: [`../nectar/docs/theme-system.md`](~/Documents/Applications/nectar/docs/theme-system.md), [`nnwtheme-format.md`](~/Documents/Applications/nectar/docs/nnwtheme-format.md)
  - Honeycrisp: [`../honeycrisp/ARCHITECTURE.md`](~/Documents/Applications/honeycrisp/ARCHITECTURE.md)
- **Cosmetic vs Structural Reload Boundary**:
  - Style-only changes (font size, line height, background colors, tint) are dispatched directly to the active `WKWebView` via CSS custom properties (`--ambrosia-*`) without re-parsing the EPUB or resetting scroll/pagination position.
  - Structural changes (scroll vs paginated mode, DOM replacements) trigger `reloadHTML`.

### 3.2 EPUB Publication Search Service (`swift-toolkit` / Readium)
- **Key File**: [`swift-toolkit/Sources/Shared/Publication/Services/Search/StringSearchAlgorithm.swift`](~/Documents/Applications/swiftreference/swiftepub/swift-toolkit/Sources/Shared/Publication/Services/Search/StringSearchAlgorithm.swift)
- **Options Model**:
  ```swift
  public struct SearchOptions: Sendable {
      public var caseSensitive: Bool?
      public var diacriticSensitive: Bool?
      public var exact: Bool?
      public var regularExpression: Bool?
  }
  ```
- **Cursor Iterator**:
  - [`SearchIterator`](~/Documents/Applications/swiftreference/swiftepub/swift-toolkit/docs/Guides/Search.md) pages through match locators using an async cursor (`next()`), preventing memory spikes when searching multi-volume omnibus editions.

### 3.3 Ingestion, In-Memory Triage & State Migration (`Honeycrisp`, `swift-toolkit`, `Nectar`)
- **Drag-and-Drop Handling (`Honeycrisp`)**:
  - Reference: [`../honeycrisp/ARCHITECTURE.md`](~/Documents/Applications/honeycrisp/ARCHITECTURE.md)
  - Implements smooth macOS window drop targets via SwiftUI `.onDrop(of: [.fileURL])` with visual drop overlay states, as well as Dock icon drop handling via `NSApplicationDelegate.application(_:openFiles:)`.
- **In-Memory Streaming EPUB Inspection (`swift-toolkit`)**:
  - Key Reference: [`swift-toolkit/Sources/Shared/Format/Format.swift`](~/Documents/Applications/swiftreference/swiftepub/swift-toolkit/Sources/Shared/Format/Format.swift) and container ZIP parsers.
  - Inspects `META-INF/container.xml` and package `.opf` directly from the ZIP byte stream without uncompressing the full archive to temporary disk. Enables instant pre-triage of dozens of dropped EPUBs in $< 100\text{ ms}$.
- **Cross-Edition User State Migration (`Nectar`)**:
  - Reference: [`../nectar/docs/theme-system.md`](~/Documents/Applications/nectar/docs/theme-system.md)
  - Models reading progress migration (scroll offsets, reading percentages, bookmarks, and annotations) when a work updates from chapter $M$ to chapter $N$ or when consolidating duplicate records.

---

## 4. Engineering Invariants & Boundaries

1. **Strictly Safe Calibre Isolation & Zero-Corruption Mutation**:
   - Calibre's `metadata.db` must never be directly modified while Calibre desktop GUI (`net.kovidgoyal.calibre`) is running.
   - For library updates and duplicate removals, Ambrosia strictly prefers delegating to Calibre's official CLI (`/Applications/calibre.app/Contents/MacOS/calibredb`), which uses Calibre's native Python engine, manages internal triggers, and broadcasts live IPC notifications.
   - Direct SQLite mutations are only permitted in standalone mode or as a guarded Tier 3 fallback when Calibre is verified not running.
   - No permanent file deletion (`rm`/`unlink`) is permitted for user books; file operations must use macOS system Trash (`FileManager.default.trashItem`).
   - Any vector index, embedding matrix, or custom search cache derived from `swiftreference` models (like `LeafNative`'s binary vectors or `Winston`'s SQLite indexes) must be stored in `ambrosia_meta.db` or the Application Support folder—never inside the user's Calibre directory.

2. **Zero Cloud & Zero Network Dependency**:
   - Reference architectures using external web APIs (e.g. `PaperSearch` querying OpenAlex/Crossref) are not permitted for core search. Ambrosia search must remain 100% on-device, private, and offline.

3. **Conforming to Concurrency & Swift 6**:
   - Any ported pattern from `swiftreference` must adhere to Swift 6 strict concurrency (`@Observable`, `actor`, `Sendable`, and `MainActor`).

---

## 5. Maintenance Checklist

When referencing or porting code from `swiftreference`:
- [ ] Check if `LeafNative` already has an optimized `Accelerate` / BLAS implementation of the vector math.
- [ ] Check if `Winston` or `readest` already solved the edge case (e.g. SQLite concurrency cancellation, excerpt context across inline HTML tags, zero-width regex loops).
- [ ] Ensure any newly cited local paths use clickable `~/Documents/Applications/swiftreference/...` markdown links.
- [ ] Keep this document updated whenever new reference repositories or architectural patterns are added.
