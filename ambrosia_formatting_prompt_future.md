# Ambrosia — Formatting & Theming Feature Brief

## Context

Ambrosia is a native macOS EPUB reader (macOS 14.0+) built around AO3-heavy Calibre libraries. Read `CLAUDE.md` and its linked docs (particularly `docs/overview.md`, `docs/reader.md`, and `docs/library-ui.md`) in full before proceeding. This brief adds a formatting and theming layer across three areas: the EPUB reader, the AO3 preface renderer, and the library view. All work must respect the existing key invariants, particularly Invariant 8 in `docs/reader.md` (full HTML regeneration on style changes, no live DOM patching).

---

## 1. Core Principle: Separate Function from Form

The existing `ReaderPreferences` singleton owns functional reading behavior — font size, line height, scroll/paginated mode, margins, color scheme. **Do not move or restructure those properties.** The new work adds a parallel theme layer on top: a `LibraryTheme` enum for the library view and a `FormattingRuleset` struct for the reader. These live in `ReaderPreferences` as new properties but are architecturally independent of the functional settings.

The motivation is that library themes control SwiftUI layout and visual density, where partial overrides cause breakage. Users select a named theme whole; they do not tweak individual tokens within it. Reader formatting rules are more granular and per-book configurable, but they do not touch typography or reading mode.

---

## 2. Library Themes

### 2.1 `LibraryTheme` enum

Define a `LibraryTheme` enum with exactly two cases for now:

```swift
enum LibraryTheme: String, CaseIterable, Codable {
    case `default`
    case ao3
}
```

Store the active selection in `ReaderPreferences` as:

```swift
@Published var libraryTheme: LibraryTheme  // persisted in UserDefaults
```

Do not expose per-token overrides. The theme is a sealed unit; the user picks one.

### 2.2 `LibraryStyleTokens`

Each theme resolves to a `LibraryStyleTokens` value struct:

```swift
struct LibraryStyleTokens {
    // Row layout
    var rowSpacing: CGFloat
    var rowPadding: EdgeInsets
    var showDescription: Bool
    var descriptionLineLimit: Int

    // Metadata density
    var showWordCount: Bool
    var showKudos: Bool
    var showChapterCount: Bool
    var showRating: Bool
    var showCategories: Bool
    var showWarnings: Bool

    // Tag display
    var tagStyle: TagStyle           // .pill | .plain | .ao3Colored
    var maxTagsVisible: Int          // 0 = unlimited
    var showFandomFirst: Bool

    // Visual
    var accentColor: Color
    var rowBackgroundStyle: RowBackgroundStyle  // .none | .subtle | .ao3Card
}

enum TagStyle { case pill, plain, ao3Colored }
enum RowBackgroundStyle { case none, subtle, ao3Card }
```

Provide a static `func tokens(for theme: LibraryTheme) -> LibraryStyleTokens` factory. The `default` case returns tokens that reproduce current library behavior exactly — no visual change on migration. The `ao3` case increases metadata density, enables `ao3Colored` tags with fandom-first ordering, shows word count/kudos/chapter counts, and uses `ao3Card` row backgrounds.

### 2.3 Injection

Inject `LibraryStyleTokens` as a SwiftUI environment value so any view in the library hierarchy can read it without prop-drilling. Define a custom `EnvironmentKey`. Set it once near the root of `LibraryRootView` based on `ReaderPreferences.shared.libraryTheme`. Views observe `ReaderPreferences` and re-render when the theme changes.

Do not pass tokens into `EmailLibraryViewController` or any AppKit view directly — AppKit views read `ReaderPreferences.shared` directly if they need theme information, same as they do today for other preferences.

### 2.4 AO3 theme metadata sources

The `ao3` theme draws from data already present in `AmbrosiaMetaDB.ao3_metadata`. Kudos, word count, chapter counts, completion, rating, categories, warnings, fandoms, relationships, and characters are all available on `AO3MetadataRecord`. For books where AO3 metadata extraction failed or was not attempted, fall back gracefully to Calibre metadata — Calibre tags substitute for AO3 tags, Calibre word count if available, blanks otherwise. Do not block or error if `ao3_metadata` is absent for a row.

---

## 3. AO3 Preface Renderer

### 3.1 Background

When Ambrosia opens an AO3-exported EPUB, `EPUBParser` currently strips all publisher CSS and renders the preface (the first spine item, which contains the work header) as plain prose. The work header has a known, stable schema produced by AO3's EPUB exporter: title, author, fandom(s), rating, warnings, categories, relationships, characters, additional tags, language, series, stats (words, chapters, kudos, hits, dates), summary, and notes.

`AO3MetadataExtractor` already parses this HTML with SwiftSoup and produces `AO3MetadataRecord`. This record is the source of truth for the preface renderer — do not re-parse the raw HTML.

### 3.2 `AO3PrefaceRenderer`

Create a new `AO3PrefaceRenderer` that takes an `AO3MetadataRecord` and returns a complete HTML string ready for injection into the merged EPUB document in place of the raw preface spine item.

```swift
struct AO3PrefaceRenderer {
    func render(_ record: AO3MetadataRecord, preferences: ReaderPreferences) -> String
}
```

The output HTML must:

- Be self-contained (inline CSS only, no external resources).
- Respect `ReaderPreferences` font, line height, and color scheme so it blends with the rest of the reader document — the preface is not a separate WebView.
- Render the standard AO3 work-header field groups in order: title block, metadata table (fandom, rating, warnings, categories, relationships, characters, additional tags, language, series), stats bar (words, chapters, kudos, hits, published, updated/completed), summary, and notes.
- Use semantic grouping (`<dl>` for the metadata table, `<div class="ao3-stats">` for the stats bar) so CSS can target sections predictably.
- Omit fields with no data cleanly — no empty rows or blank labels.
- Scope all CSS classes under an `ao3-preface` root class to avoid bleed into prose chapters.

The CSS embedded in the output should be generated from `ReaderPreferences` values at render time, not hardcoded. Produce it from a private helper:

```swift
private func prefaceCSS(preferences: ReaderPreferences) -> String
```

### 3.3 Integration point

In `EPUBParser`, after the spine is walked and HTML is merged, check whether the first spine item was identified as an AO3 preface (this identification logic already exists via `AO3MetadataExtractor`). If so, and if an `AO3MetadataRecord` is available for this book from `AmbrosiaMetaDB`, replace the raw preface HTML with the output of `AO3PrefaceRenderer.render(_:preferences:)`.

Pass `ReaderPreferences.shared` at call time. Because `ReaderViewController` already triggers full HTML regeneration on preference changes (invariant 8), the preface will re-render correctly on theme or font changes with no additional wiring.

### 3.4 Settings control

Add a toggle to `ReaderPreferences`:

```swift
@Published var useAO3PrefaceRenderer: Bool  // default true, persisted in UserDefaults
```

When false, `EPUBParser` skips the replacement and the raw preface HTML renders as plain stripped prose (current behavior). Expose this toggle in the Preferences window under the new Formatting section described in section 5.

---

## 4. Reader Formatting Rules

This section defines the architecture for inline web-format sections (text message bubbles, Wikipedia extracts, Tumblr posts, Twitter/X posts, Buzzfeed extracts, blog posts, news articles). CSS for each format is not yet finalized and will be provided in a follow-up brief. Build the data model and detection infrastructure now; leave CSS as empty stubs.

### 4.1 `InlineFormat` enum

```swift
enum InlineFormat: String, Codable, CaseIterable {
    case textBubbles
    case wikipedia
    case tumblr
    case twitter
    case buzzfeed
    case blogPost
    case newsArticle
}
```

### 4.2 `BookFormattingRuleset`

Per-book formatting configuration. Stored as JSON in `AmbrosiaMetaDB` in a new `book_formatting_rules` table keyed by `calibre_id`. Do not use `UserDefaults` for per-book data.

```swift
struct BookFormattingRuleset: Codable {
    var calibreID: Int
    var enabledFormats: Set<InlineFormat>     // formats active for this book
    var manualSections: [FormattingSection]   // user-marked ranges
    var exclusions: [FormattingSection]       // ranges explicitly excluded from auto-detection
    var speakerRules: [SpeakerRule]           // for textBubbles: name → display config
}

struct FormattingSection: Codable {
    var format: InlineFormat
    var startChar: Int    // UTF-16 offset, text nodes only — matches annotation contract
    var endChar: Int
}

struct SpeakerRule: Codable {
    var name: String
    var displayName: String?
    var colorHex: String       // generated on first detection, user-editable later
    var side: BubbleSide       // .leading | .trailing
}

enum BubbleSide: String, Codable { case leading, trailing }
```

### 4.3 `InlineFormatDetector`

A stateless struct that takes the plain-text representation of an EPUB section (from `EPUBParser`'s plain-text output, which already respects the UTF-16 offset contract) and returns detected `FormattingSection` candidates with confidence scores.

```swift
struct InlineFormatDetector {
    func detect(in plainText: String, existingRuleset: BookFormattingRuleset?) -> [DetectedSection]
}

struct DetectedSection {
    var section: FormattingSection
    var confidence: Float          // 0.0–1.0
    var signals: [String]          // human-readable list of matched signals, for debug/display
}
```

Detection signals per format — implement as individual private methods, each returning a partial confidence score that sums toward the threshold (0.7 suggested default):

**Text bubbles:** Lines matching `^(.+?):\s` with 3+ consecutive matches; short median line length (<120 chars); repeated speaker names across ≥2 lines; presence of emoji.

**Wikipedia:** Bracketed numeric references `[1]`; presence of `(disambiguation)` or `See also`; infobox-like leading table pattern; section headers in all-caps or title case at short line lengths.

**Tumblr:** Repeating `name:\n` + indented block pattern (reblog chain); trailing `#word` clusters; `Source:` attribution line.

**Twitter/X:** Lines starting with `@handle`; short line count per block (≤280 chars); presence of RT, like/fave count patterns; timestamp patterns (`HH:MM AM/PM · Mon DD, YYYY`).

**Buzzfeed:** Numbered list items as structural headers (`1.`, `2.` at the start of blocks); "You got: X" or "Which X are you?" patterns; list-of-N title patterns.

**Blog post:** Byline + date header block; section headers; blockquote markers; no reblog chain.

**News article:** Dateline pattern (`CITY, Month DD (Reuters/AP) —`); pull-quote markers; "Read more:" separators; wire service attribution.

Detections that overlap should prefer the higher-confidence result. Manual sections in `BookFormattingRuleset.manualSections` always win over auto-detection. Exclusions always suppress detection regardless of confidence.

### 4.4 HTML annotation pass

After detection, `EPUBParser` performs a second pass that wraps detected sections in semantic `<div>` containers with `data-format` and `data-confidence` attributes. This pass runs after the plain-text offset pass so the offset contract is not disturbed. Wrapper elements are added to the HTML layer only, not to the plain-text representation used for annotation offsets.

```html
<div data-format="textBubbles" data-confidence="0.94">
  <span data-speaker="Squid" data-side="trailing">oh my god guys</span>
  <span data-speaker="Mitchy" data-side="leading">yes, it's true</span>
</div>
```

For text bubbles specifically, the annotation pass must also split lines by speaker and emit `data-speaker` and `data-side` attributes using `SpeakerRule` data from `BookFormattingRuleset`.

### 4.5 CSS stubs

Create a `InlineFormatStylesheet` struct with one static method per format, each returning an empty CSS string for now:

```swift
struct InlineFormatStylesheet {
    static func css(for format: InlineFormat, preferences: ReaderPreferences) -> String { "" }
}
```

These will be filled in when CSS files are delivered. The injection point in `EPUBParser` should call all enabled formats' CSS and concatenate it into the user stylesheet block so the plumbing is in place.

### 4.6 `AmbrosiaMetaDB` schema addition

Add the following table to `AmbrosiaMetaDB`. Apply it as a migration guarded by a schema version check — do not drop and recreate existing tables.

```sql
CREATE TABLE IF NOT EXISTS book_formatting_rules (
    calibre_id INTEGER PRIMARY KEY,
    ruleset_json TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
```

Expose read/write through two new methods on `AmbrosiaMetaDB`:

```swift
func formattingRuleset(for calibreID: Int) async -> BookFormattingRuleset?
func saveFormattingRuleset(_ ruleset: BookFormattingRuleset) async throws
```

---

## 5. Settings UI

The existing Preferences window already has tabs/sections for reader defaults, library appearance, custom column labels, AO3 extraction, and tag seeds. Add a new **Formatting** section. Do not restructure existing sections.

### 5.1 Formatting section layout

The Formatting section contains three groups, separated by visual dividers:

**Library theme**
A picker (segmented or dropdown) toggling between `LibraryTheme.default` and `LibraryTheme.ao3`. Below the picker, a static description of what the selected theme changes — one or two sentences, not a feature list. No per-token overrides exposed here.

**Reader — AO3 preface**
A single toggle: "Style AO3 work headers" (maps to `ReaderPreferences.useAO3PrefaceRenderer`). When on, a brief description: "Replaces the plain preface of AO3-exported EPUBs with a structured work header." When off, show a muted note: "Preface renders as plain text."

**Reader — Inline formatting**
A list of `InlineFormat` cases with:
- A toggle per format (enables/disables auto-detection globally, as a default — per-book overrides live in `BookFormattingRuleset`).
- A label showing the format name and a one-line description of what it detects.

Store global per-format auto-detect defaults in `ReaderPreferences`:

```swift
@Published var enabledInlineFormats: Set<InlineFormat>  // persisted as JSON string in UserDefaults
```

Formats in this set are auto-detected unless a book's `BookFormattingRuleset` explicitly disables or excludes them.

The Inline Formatting group should make clear these are defaults: a section header note reading "Applied automatically unless overridden per book."

### 5.2 Per-book formatting access

The settings for a specific book's formatting rules (manual sections, speaker rules, exclusions) are not part of the global Preferences window. They belong in a per-book inspector or context menu flow in the reader — design and placement of that UI is out of scope for this brief. The data model (`BookFormattingRuleset`) and storage (`book_formatting_rules` table) should be complete so that UI can be built on top later.

---

## 6. Invariants and Constraints

These apply in addition to the existing key invariants documented under `docs/` (see `CLAUDE.md`):

- `LibraryTheme` selection is a sealed choice. Do not expose `LibraryStyleTokens` fields as individual user-settable preferences.
- `BookFormattingRuleset` is per-library data and lives in `AmbrosiaMetaDB`, accessed through `LibrarySession`. It is never stored in `UserDefaults` or SwiftData.
- The UTF-16 offset contract must not be broken by any HTML annotation pass. All `data-format` wrapper `<div>`s and `data-speaker` `<span>`s are added to the HTML representation only, after the plain-text pass.
- `AO3PrefaceRenderer` output is inline CSS only. No external stylesheets, no `<link>` tags, no JavaScript.
- `InlineFormatDetector` is stateless and has no side effects. It does not read from or write to any database.
- CSS stubs in `InlineFormatStylesheet` return empty strings. Do not ship placeholder comments or example rules — empty strings keep the injection path correct without visual side effects.
- Do not add new `WKWebView` message handlers for this feature. The existing `positionUpdate`, `pageAction`, `highlightAdded`, `highlightTapped`, and `consoleLog` handlers are sufficient.
- Schema migrations in `AmbrosiaMetaDB` must be additive only. Guard every new `CREATE TABLE` with `IF NOT EXISTS`.
- `AmbrosiaMetaDB` is accessed through `LibrarySession`, never as a singleton (invariant 13).

---

## 7. Files to Create or Modify

**New files:**
- `LibraryTheme.swift` — `LibraryTheme` enum, `LibraryStyleTokens` struct, factory function, `EnvironmentKey`.
- `AO3PrefaceRenderer.swift` — `AO3PrefaceRenderer` struct and CSS helper.
- `InlineFormat.swift` — `InlineFormat` enum, `BookFormattingRuleset`, `FormattingSection`, `SpeakerRule`.
- `InlineFormatDetector.swift` — `InlineFormatDetector`, `DetectedSection`.
- `InlineFormatStylesheet.swift` — `InlineFormatStylesheet` with empty CSS stubs.

**Modified files:**
- `ReaderPreferences.swift` — add `libraryTheme`, `useAO3PrefaceRenderer`, `enabledInlineFormats`.
- `EPUBParser.swift` — integrate `AO3PrefaceRenderer` replacement and `InlineFormatDetector` annotation pass.
- `AmbrosiaMetaDB.swift` — add `book_formatting_rules` table migration and read/write methods.
- `LibraryRootView.swift` — inject `LibraryStyleTokens` environment value from active `LibraryTheme`.
- Preferences window source — add Formatting section.

Do not modify `LibraryRegistry`, `LibrarySession`, `BookState`, or any SwiftData model.
