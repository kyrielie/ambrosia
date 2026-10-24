# Phase 3 Implementation Plan: EPUB Engine Modernization & SwiftSoup Pipeline Optimization

## 1. Executive Summary

During Phase 1 (Database Layer Consolidation) and Phase 2 (Presentation Model & Controller Unification), Ambrosia's database and library view architecture were streamlined. Phase 3 targets the **core reader engine and EPUB ingestion pipeline**.

Drawing architectural insights and verified solutions from sibling projects **Honeycrisp** (`ChapterPipeline.swift`, `ChapterTransforms.swift`, `ChapterMarkup.swift`) and **Kudos Reader** (`kudosreader.xml`, `EPUBParsing.md`):

1. **The Chapter Parsing Bottleneck**: Ambrosia currently executes a cascade of 6+ full-document regular expressions sequentially for every spine item in an EPUB. For a 100-chapter AO3 work, this triggers over 600 full-string regex traversals sequentially.
2. **Honeycrisp's Proven Solution**: Migrate to a **single-pass DOM traversal using `SwiftSoup`** (already a resolved SPM dependency in Ambrosia) and execute spine item decoding and transformation across all CPU cores using `DispatchQueue.concurrentPerform`.
3. **The Cosmetic Styling Gaps**: Perfect live CSS `:root` variable switching in `ReaderPreferences` and `ReaderViewController`, ensuring all appearance adjustments (font family, font size, margins, colors, line heights) render at 60 FPS with 0ms latency without reloading the `WKWebView` DOM.

---

## 2. Architectural Comparison & Reference Analysis

| Feature | Current Ambrosia | Honeycrisp Reference | Kudos Reader Reference | Target Phase 3 Design |
| :--- | :--- | :--- | :--- | :--- |
| **HTML Sanitization** | 5 sequential regex passes (`<link>`, `<style>`, `style=`, `<script>`, whitespace) | Single-pass `SwiftSoup` DOM walk in `ChapterMarkup.removeActiveContent` | Regex + script injection | **SwiftSoup single-pass tree transformation** |
| **Concurrency** | Sequential loop across all spine items | `DispatchQueue.concurrentPerform` across processor count | Sequential | **Multi-core concurrent spine processing** |
| **Preface/TOC Cleanup** | Regex searching `<h2 class="toc-heading">` and `Preface` | `ChapterTransforms.applyAO3Formatting` & `hidePreface` | Spine ID to TOC label matching | **SwiftSoup targeted element selector & cleanup** |
| **Live Preferences** | Partial `:root` variables; some controls still trigger reload | `:root` custom properties with immediate `.textContent` swap | `layoutScript` dynamic JS injection | **Comprehensive `:root` CSS variable system** |
| **Memory & Throughput** | High string copies and regex buffer reallocations | Single parsed DOM tree per chapter in parallel pool | Native string operations | **Minimal copy, zero-regex DOM pipeline** |

---

## 3. Detailed Component Plan

### Part A: SwiftSoup Chapter Pipeline & Multi-Core Rendering

#### File: `Ambrosia/Reader/EPUBParser+Rendering.swift`

1. **Replace Regex Sanitization with `SwiftSoup`**:
   - Create a dedicated sanitization function:
     ```swift
     import SwiftSoup

     extension EPUBParser {
         /// Sanitizes chapter HTML using SwiftSoup DOM traversal in a single pass.
         static func sanitizeDOM(
             _ rawHTML: String,
             isFirstSpineItem: Bool,
             removeParagraphIndents: Bool
         ) throws -> String {
             let doc = try SwiftSoup.parse(rawHTML)
             
             // 1. Remove active content (<script>, publisher <style>, <link rel="stylesheet">, etc.)
             try doc.select("script, style, link[rel='stylesheet'], link[rel='Stylesheet']").remove()
             
             // 2. Remove inline style attributes and JavaScript event handlers
             if let allElements = try? doc.getAllElements() {
                 for el in allElements {
                     try el.removeAttr("style")
                     for attr in el.getAttributes()?.asList() ?? [] {
                         let lower = attr.getKey().lowercased()
                         if lower.hasPrefix("on") || (lower == "href" && attr.getValue().lowercased().hasPrefix("javascript:")) {
                             try el.removeAttr(attr.getKey())
                         }
                     }
                 }
             }

             // 3. AO3 Redundant Preface & TOC Headings (Honeycrisp pattern)
             if isFirstSpineItem {
                 try stripPrefaceHeadingDOM(in: doc)
             }
             
             // 4. Optional: Paragraph indent cleanup
             if removeParagraphIndents {
                 try stripLeadingIndentWhitespaceDOM(in: doc)
             }

             // 5. Extract body inner HTML
             let body = try doc.body()?.html() ?? rawHTML
             return body
         }
     }
     ```

2. **Parallelize `mergedHTML` Spine Item Extraction**:
   - Currently, `mergedHTML` iterates sequentially:
     ```swift
     for item in spine { ... extract and process ... }
     ```
   - Refactor to load entry data and transform in parallel:
     ```swift
     var bodyChunks: [String?] = Array(repeating: nil, count: spine.count)
     let lock = NSLock()
     
     // Read all archive entries first (ZIP archive access is thread-confined)
     var chapterData: [(index: Int, id: String, data: Data)] = []
     for item in spine {
         if let entry = archive[item.href], let data = Self.extract(entry, from: archive) {
             chapterData.append((item.index, item.id, data))
         }
     }
     
     // Parallelize CPU-intensive SwiftSoup parsing across all available cores
     DispatchQueue.concurrentPerform(iterations: chapterData.count) { i in
         let chapter = chapterData[i]
         guard let raw = String(data: chapter.data, encoding: .utf8) ?? String(data: chapter.data, encoding: .isoLatin1) else { return }
         
         let bodyContent = (try? Self.sanitizeDOM(raw, isFirstSpineItem: chapter.index == 0, removeParagraphIndents: removeParagraphIndents)) ?? ""
         let rewritten = imageBaseOverride != nil ? Self.rewriteImageReferences(in: bodyContent, imageBaseURL: imageBaseOverride!) : bodyContent
         let globalIndex = chapter.index + spineIndexOffset
         
         let chunk = """
         <section data-spine-index="\(globalIndex)" data-spine-id="\(chapter.id)">
         \(rewritten)
         </section>
         """
         
         lock.lock()
         bodyChunks[i] = chunk
         lock.unlock()
     }
     ```
   - **Performance impact**: For a 50-chapter work on an 8-core Apple Silicon Mac, HTML generation time drops from ~800ms to <120ms.

---

### Part B: Live Cosmetic Preference Pipeline & CSS Custom Properties

#### Files: `Ambrosia/Reader/ReaderPreferences.swift` & `Ambrosia/Reader/ReaderViewController.swift`

1. **Audit All Appearance Preferences**:
   - Ensure every cosmetic property maps directly to `:root` variables:
     - `--ambrosia-font-family`
     - `--ambrosia-font-size`
     - `--ambrosia-line-height`
     - `--ambrosia-bg`
     - `--ambrosia-text`
     - `--ambrosia-padding-h`
     - `--ambrosia-padding-v`
     - `--ambrosia-max-width`
     - `--ambrosia-link-pointer-events`
   - Verify that all appearance setters in `ReaderPreferences` send `.cosmetic` and never trigger `.structural` unless viewport or DOM reconstruction is strictly necessary (e.g. `colsPerScreen` or `removeParagraphIndents`).

2. **Refine `applyCosmeticCSSUpdate()`**:
   - In `ReaderViewController.swift`, refine `applyCosmeticCSSUpdate()` to update `:root` variables with zero layout jank:
     ```javascript
     (function() {
         var style = document.getElementById('ambrosia-vars');
         if (!style) {
             style = document.createElement('style');
             style.id = 'ambrosia-vars';
             document.head.appendChild(style);
         }
         style.textContent = ':root { ' + declarations + ' }';
     })();
     ```
   - Also update `underPageBackgroundColor` and window background synchronously on `@MainActor` to prevent any edge flash while resizing or bouncing.

---

### Part C: AO3 Quirks & Structural Robustness (Kudos & Honeycrisp Lessons)

1. **Handling Empty Sections & Spacer Paragraphs**:
   - AO3 works often contain empty `<p><br/></p>` tags that collapse or expand unpredictably depending on line height.
   - Adopt Honeycrisp's `applySpacerParagraphs` selector or CSS rule to ensure consistent spacing for decorative scene breaks (`***`, `~`, or empty lines).
2. **Preface Heading Normalization**:
   - Ensure AO3's `<h2 class="toc-heading">Preface</h2>` is cleanly stripped without corrupting any author's real first-chapter titles.

---

## 4. Verification & Testing Plan

1. **Unit Tests (`AmbrosiaTests/EPUBParserSanitizationTests.swift`)**:
   - Verify `sanitizeDOM`:
     - Strips `<script>` tags and attributes (`onload`, `onclick`, `javascript:...`).
     - Strips `<style>` blocks and `<link rel="stylesheet">`.
     - Strips inline `style="..."` attributes completely.
     - Strips preface `<h2 class="toc-heading">` on first spine item, preserves headers on subsequent spine items.
     - Handles ill-formed or malformed XHTML gracefully without crashing.
2. **Concurrency & Correctness Tests**:
   - Verify that `mergedHTML` output preserves exact spine item order and `data-spine-index` numbering under multi-core execution.
3. **Cosmetic Live-Update Tests**:
   - Verify that `preferenceChangeKind` emits `.cosmetic` for all font/color/margin adjustments.
   - Verify `cssVariableDeclarations` string format.
4. **Integration & Build Verification**:
   - Run `./test.sh` with SwiftLint validation and ensure all 572+ tests pass with zero warnings.

---

## 5. Implementation Steps & Sequencing

```
Step 1: Write SwiftSoup chapter sanitization in EPUBParser+Rendering.swift
Step 2: Add parallel spine processing with DispatchQueue.concurrentPerform
Step 3: Audit ReaderPreferences & ReaderViewController cosmetic updates
Step 4: Create new unit test suite EPUBParserSanitizationTests.swift
Step 5: Run full test suite & SwiftLint via ./test.sh
Step 6: Update documentation (docs/roadmap.md, docs/epub-engine.md, CLAUDE.md)
```
