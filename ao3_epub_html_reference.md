# AO3 EPUB Header HTML — Parser Reference

**For the engineer implementing `AO3MetadataExtractor` in Phase 9.**

This document describes the exact HTML structure of the first spine item in Calibre-exported AO3 EPUBs. It is based on three real examples and supersedes any assumptions from the original plan. Do not rely on AO3's web interface HTML — the EPUB export format differs.

---

## Top-Level Structure

```html
<body class="calibre">
  <div id="preface" class="calibre1">
    <h2 class="toc-heading" id="calibre_toc_2">Preface</h2>

    <!-- Work URL is here — extract ao3_work_id from this link -->
    <p class="message">
      <b class="calibre2">TITLE</b><br class="calibre1"/>
      Posted originally on the Archive of Our Own at
      <a href="https://archiveofourown.org/works/WORK_ID">…</a>.
    </p>

    <div class="calibre1">
      <dl class="tags">
        <!-- dt/dd pairs for each metadata field -->
        <dt class="calibre3">FIELD NAME:</dt>
        <dd class="calibre4">FIELD VALUE</dd>
        …
        <!-- Stats are in a different dd class -->
        <dt class="calibre3">Stats:</dt>
        <dd class="calibre5">…plain text…</dd>
      </dl>
    </div>
  </div>
</body>
```

---

## Detection

**SwiftSoup selector:** `doc.select("dl.tags").first()`

If this returns `nil`, the spine item is not an AO3 EPUB header — return `nil` immediately without inserting a row.

> **Note:** Do not check for `class="work meta group"` — that is AO3's web interface class, not the Calibre EPUB export class.

---

## Work URL and Work ID

**Source:** `<p class="message">` — the second `<a>` element whose `href` contains `/works/`.

```swift
let link = try doc.select("p.message a[href*=/works/]").first()
let storyURL = try? link?.attr("href")     // "https://archiveofourown.org/works/7531264"
let ao3WorkID = storyURL?.components(separatedBy: "/works/").last  // "7531264"
```

**Observed variations:**
- `http://archiveofourown.org/works/…` (older exports)
- `https://archiveofourown.org/works/…` (newer exports)

Normalise to `https` when storing `story_url`.

---

## Metadata Fields (`<dl class="tags">`)

Fields are `<dt>` / `<dd>` pairs. Iterate child elements of the `<dl>`, tracking the current `<dt>` label, and parse each `<dd>` accordingly.

```swift
var currentField = ""
for element in try dl.children() {
    if element.tagName() == "dt" {
        currentField = (try? element.text()) ?? ""
    } else if element.tagName() == "dd" {
        parseField(currentField, element: element, into: &result)
    }
}
```

### Field name variations

AO3 uses both singular and plural field names. Handle both:

| Singular (some works) | Plural (some works) | Maps to |
|---|---|---|
| `Relationship:` | `Relationships:` | `relationships_json` |
| `Character:` | `Characters:` | `characters_json` |
| `Additional Tag:` | `Additional Tags:` | `additional_tags_json` |
| `Collection:` | `Collections:` | `ao3_collections_json` |
| `Fandom:` | `Fandoms:` | `fandoms_json` |

Match case-insensitively and strip the trailing colon. Example:

```swift
let key = currentField.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
```

### Fields that are always a single `<a>` tag

- `Rating:` → link text, e.g. `"Explicit"`, `"General Audiences"`, `"Teen And Up Audiences"`, `"Mature"`, `"Not Rated"`
- `Archive Warning:` → link text, e.g. `"No Archive Warnings Apply"`
- `Category:` → link text, e.g. `"M/M"`, `"Gen"`, `"F/M"` — **use the link text, not the href** (href encodes `/` as `*s*`)
- `Language:` → **plain text** in the `<dd>`, no `<a>` tag

### Fields that are comma-separated `<a>` tags (one `<dd>`, multiple links)

- `Fandom:` / `Fandoms:`
- `Relationship:` / `Relationships:`
- `Character:` / `Characters:`
- `Additional Tags:`

```swift
// Extract all link texts from a <dd> with multiple <a> elements
let values = try element.select("a").map { try $0.text() }
// → ["Shiro/Lance (Voltron)", "Keith/Lance (Voltron)", "Shiro/Lance/Keith (Voltron)"]
```

Tags are separated by `, ` in the HTML source but you do not need to split text — select all `<a>` children directly.

### `Series:` field

The series `<dd>` contains interleaved plain text nodes and `<a>` elements. There are **no `<li>` or `<span>` tags**. A work can belong to multiple series (comma-separated in the same `<dd>`).

**Pattern:** `"Part N of <a href="/series/ID">Series Name</a>, Part M of <a>…</a>"`

```swift
var pendingIndex: Int? = nil
var series: [(name: String, index: Int, ao3ID: String)] = []

for node in seriesDD.childNodes() {
    if let text = node as? TextNode {
        let s = text.text()
        // Match "Part N of" with optional leading ", "
        if let match = s.firstMatch(of: /(?:,\s*)?[Pp]art\s+(\d+)\s+of/) {
            pendingIndex = Int(match.1)
        }
    } else if let el = node as? Element, el.tagName() == "a" {
        let href = (try? el.attr("href")) ?? ""
        let name = (try? el.text()) ?? ""
        // ao3_series_id is the last path component of the href
        let ao3ID = href.components(separatedBy: "/series/").last ?? ""
        if let idx = pendingIndex {
            series.append((name: name, index: idx, ao3ID: ao3ID))
            pendingIndex = nil
        }
    }
}
```

**Observed examples:**

| Source | Result |
|---|---|
| `Part 7 of <a href="/series/344591">jack/parse tumblr prompts</a>, Part 1 of <a href="/series/523378">rentboy jack and…</a>` | Two series entries |
| `Part 1 of <a href="/series/506620">Sugar Sweet (OT3, ABO)</a>` | One series entry |
| `Part 2 of <a href="/series/249661">The Pine Demon</a>` | One series entry |

Store as `series_json`: JSON array of `{"name": "…", "index": 1, "ao3_id": "344591"}`.

### `Collections:` field

Same structure as tag fields — comma-separated `<a>` elements. **Optional field** — not all works are in collections.

```swift
let collections = try element.select("a").map { try $0.text() }
// → ["Friend Recommendations - Voltron"]
```

Store as `ao3_collections_json`.

### `Stats:` field

**Class is `calibre5`**, not `calibre4`. All stats are **plain text** inside a single `<dd>`. No child elements. Split on whitespace/newlines.

```
Published: 2016-07-19\nWords: 3,261\nChapters: 1/1
Published: 2016-06-22\n  Completed: 2016-07-11\nWords: 21,069\nChapters: 5/5
```

**Fields present:**

| Key | Always present | Format | Notes |
|---|---|---|---|
| `Published:` | Yes | `YYYY-MM-DD` | Store as ISO-8601 string |
| `Completed:` | No | `YYYY-MM-DD` | Only on finished works |
| `Words:` | Yes | `N,NNN` | Strip commas before `Int()` |
| `Chapters:` | Yes | `N/M` or `N/?` | Split on `/`; `?` → `chapter_total = nil` |
| `Updated:` | No | `YYYY-MM-DD` | Present when work has been updated after initial post |
| `Kudos:` | No | `N,NNN` | Strip commas |
| `Bookmarks:` | No | integer | May appear |
| `Comments:` | No | integer | May appear |

```swift
let statsText = (try? statsDD.text()) ?? ""
// Tokenise on whitespace
let tokens = statsText.components(separatedBy: .whitespacesAndNewlines)
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }

// Iterate as key-value pairs: "Published:", "2016-07-19", "Words:", "3,261", …
var i = 0
while i < tokens.count - 1 {
    let key = tokens[i]
    let val = tokens[i + 1]
    switch key {
    case "Published:":   result.publishedDate = val
    case "Completed:":   result.updatedDate = val     // treat Completed as updated_date
    case "Updated:":     result.updatedDate = val
    case "Words:":       result.wordCount = Int(val.replacingOccurrences(of: ",", with: ""))
    case "Chapters:":
        let parts = val.split(separator: "/")
        result.chapterCurrent = parts.first.flatMap { Int($0) }
        result.chapterTotal   = parts.count > 1 && parts[1] != "?" ? Int(parts[1]) : nil
    default: break
    }
    i += 2
}
```

**Completeness rule:**

```swift
// is_complete = true when chapter_current == chapter_total (both non-nil)
// OR when "Completed:" field is present in stats
result.isComplete = (result.chapterCurrent != nil &&
                     result.chapterTotal != nil &&
                     result.chapterCurrent == result.chapterTotal)
                 || result.completedDate != nil
```

---

## Optional vs Required Fields

All metadata fields in the `<dl>` are optional except `Rating:`, `Archive Warning:`, `Language:`, and `Stats:`. Handle any field being absent gracefully — store `NULL` / `nil` and continue. Do not fail extraction if `Series:`, `Collections:`, `Characters:`, or `Relationships:` are missing.

---

## Chapters Display

Resolved: display as `"N/?"` when `chapter_total` is `NULL`. This matches AO3 conventions.

---

## Full Field → Column Mapping

| `<dt>` text (normalised) | `ao3_metadata` column | Type | Source |
|---|---|---|---|
| *(from p.message)* | `story_url`, `ao3_work_id` | TEXT | `<a href>` |
| `rating` | `rating` | TEXT | link text |
| `archive warning` | `archive_warning` | TEXT | link text |
| `category` | `category` | TEXT | link text |
| `fandom` / `fandoms` | `fandoms_json` | JSON `[String]` | all link texts |
| `relationship` / `relationships` | `relationships_json` | JSON `[String]` | all link texts |
| `character` / `characters` | `characters_json` | JSON `[String]` | all link texts |
| `additional tags` | `additional_tags_json` | JSON `[String]` | all link texts |
| `language` | `language` | TEXT | plain text |
| `series` | `series_json` | JSON `[{name,index,ao3_id}]` | mixed nodes |
| `collections` | `ao3_collections_json` | JSON `[String]` | all link texts |
| `stats → Published` | `published_date` | TEXT ISO-8601 | plain text |
| `stats → Completed` or `Updated` | `updated_date` | TEXT ISO-8601 | plain text |
| `stats → Words` | `word_count` | INTEGER | strip commas |
| `stats → Chapters` (first part) | `chapter_current` | INTEGER | split on `/` |
| `stats → Chapters` (second part) | `chapter_total` | INTEGER or NULL | `?` → NULL |
| *(derived)* | `is_complete` | INTEGER 0/1 | see rule above |
| *(not in EPUB header)* | `kudos_count` | INTEGER NULL | Phase 18 only |
| *(not in EPUB header)* | `ao3_author_username` | TEXT NULL | Phase 18 only |

---

## Invariants for This Component

- Never insert a row if `dl.tags` is absent.
- Always use `SwiftSoup` for parsing — `NSXMLParser` cannot handle real-world AO3 HTML entities and optional closing tags.
- Normalise `http://` to `https://` in `story_url` before storing.
- Strip commas from all numeric strings before `Int()` conversion.
- Run in `Task.detached(priority: .background)` — never block the main thread.
- All writes go through the `AmbrosiaMetaDB` actor.
