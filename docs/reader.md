# Reader

Scope: `ReaderWindowController`/`ReaderViewController`, the `WKWebView`-based
reading surface, scroll and paginated modes, and the CSS preference
pipeline. For the source HTML this loads, see `epub-parsing.md`. For
highlight/annotation capture inside the webview, see `annotations.md`.

---

## Reader

### Reader Application Routing
`AppDelegate.openReaderWindow(book:)` and `openReaderWindow(target:)` inspect `ReaderPreferences.shared.preferredReader` (`PreferredReaderOption`):
- `.inbuilt` (default): Uses `ReaderWindowController.open(...)`. Deduplicates one reader window per Calibre book ID, updates `BookState.lastOpenedDate` on open, and tracks `totalReadingTimeSeconds` on close.
- `.systemDefault`: Opens the book's EPUB file via `NSWorkspace.shared.open(epubURL)` with the macOS system default EPUB application (e.g. Apple Books or Honeycrisp).
- `.customApp`: Opens the EPUB file via `NSWorkspace.shared.open([epubURL], withApplicationAt: appURL, ...)` with a custom `.app` chosen by the user in Preferences (falling back to system default if the app was moved or deleted).
Regardless of whether an internal or external reader is used, `AmbrosiaMetaDB.markBookOpened(calibreID:)` is triggered so reading history and last-opened dates remain current.

### Inbuilt AO3 Reader Tailoring
The inbuilt Ambrosia reader is explicitly tailored for AO3 fanfiction EPUBs:
- **AO3 Preface Card (Reversi-styled)**: `#preface` metadata is formatted as a boxed card using simple stylings from Nectar's Reversi theme (`border`, `border-radius: 6px`, subtle shadow, and background tint driven by `--ao3-preface-*` CSS variables). The metadata block (`dl.tags`) formats `<dt>` and `<dd>` with `wide` classes on long tag lists (Fandoms, Relationships, Characters, Additional Tags, Archive Warnings), letting them span full width while short metadata rows (Rating, Category, Language, Stats) flow inline.
- **Replacement AO3 Title Page**: AO3 EPUB exports place a raw Calibre-generated title page on the second spine item (`split_001.xhtml`). Ambrosia detects this spine and replaces it with a cleanly-structured `.ao3-title-page` layout matching Nectar/Reversi typography: centered work title (`.ao3-work-title`), author byline (`.ao3-work-byline`), elegant section divider, and structured Summary and Notes modules with left border callouts.
- **Summaries and Author Notes**: `.summary`, `blockquote`, and `.notes` render with a 3px accent border on the leading edge and a subtle background callout tint matching the active theme, making author notes and chapter summaries instantly recognizable.
- **Calibre Style Overrides**: `body[class]` and `!important` rules override Calibre's hardcoded `.calibre` and `margin: 0 5pt` rules, ensuring user margins and max-widths take precedence.
- **AO3 Endmatter**: `EPUBParser.buildAO3Endmatter` generates "Read on AO3", "Comments on AO3", and series index links at the conclusion of the story.
- **Curated Dual-Mode Themes**: Built-in presets via `ReaderTheme` include Parchment, Sepia, Paper, Slate, and OLED. Each theme defines separate light and dark color sets (`ThemeColorSet`) that dynamically adapt to the macOS appearance or explicit user choice (`AppearanceMode`: `.system`, `.light`, `.dark`).
- **Typography, Justify & Indent**: Reader preferences support Honeycrisp-style text alignment (`ThemeTextAlignment`: `.book`, `.left`, `.justify`) and configurable first-line paragraph indentation (`paragraphIndent: Double?` in ems), styling paragraphs with clean text-justify and text-indent rules without conflicting with publisher styles.
- **AO3 Work Presentation / Layout Order**: Configurable via `ReaderPreferences.shared.ao3WorkLayoutOrder` (`AO3WorkLayoutOrder`) in Ambrosia Settings -> Reader:
  - `.ao3Web` (Default): Tags block before title (matching AO3 website experience); strips title and "posted originally" link from the top of the tag block, followed by the replacement title page.
  - `.titleFirst`: Renders title and author byline first at the top of the preface card, followed by the tag block, followed by summary and notes.
  - `.ao3EPUB`: Preserves AO3's standard EPUB layout order (title, "posted originally" link, tag block, followed by title page with title, author link, summary, notes).

### Reader Toolbar & Navigation Chrome
`ReaderWindowController` provides a modern unified toolbar (`NSToolbar`):
- **Table of Contents (`.readerTOC`)**: Opens/toggles a separate floating utility window titled "Contents" (`NSPanel`), anchored and synchronized to the left edge of the reader window (mirroring the Annotations panel on the right). Features real-time search filtering, collapsible per-work dropdowns (`DisclosureGroup`) for series/grouped works, current-chapter indicator dot, and immediate single-click chapter navigation.
- **Search in Work (`.readerSearch`)**: Opens `SearchBarViewController`, a floating HUD overlay (12pt corner radius, blurred material background) inspired by Honeycrisp. Provides instant search query execution across all spine items, match counting ("X of Y"), next/previous match cycling (`⌘G` / `⇧⌘G`), and an expandable results drawer showing chapter titles and contextual snippets. In paginated mode, jumps smoothly scroll and column-snap (`snapFoundSelectionToColumn`).
- **Paginated Navigation (`.readerNavigation`)**: Previous page button (`chevron.backward`), dynamic page counter text (`"p. 12 of 84"` or progress percentage), and Next page button (`chevron.forward`). Works in both paginated mode (column turns) and continuous scroll mode (page scrolling).
- **Like Toggle (`.readerLike`)**: Direct Nectar-style quick marking toggle with heart icon (`heart` / `heart.fill` in pink tint) reflecting active work like state.
- **Read Later Toggle (`.readerReadLater`)**: Direct quick marking toggle with bookmark icon (`bookmark` / `bookmark.fill` in orange tint) reflecting Read Later membership.
- **Appearance Popover (`.readerAppearance`)**: `Aa` toolbar item presenting `ReaderAppearancePopoverView` in a native `NSPopover`, featuring Appearance Mode toggle (System, Light, Dark), dual-mode theme swatches, font size steppers with reset, font family selector, text alignment picker (Left, Justify, Default), paragraph indent controls, and column options.
- **Standardized Toolbar Glyph Sizing**: All icons in both the main library window and reader window are standardized to 13pt symbol configurations for a balanced, native macOS appearance.

### Reader content toggles
Preferences -> Reader Content has two toggles that change the built HTML (both structural):
- `removeParagraphIndents` (labelled "Trim leading whitespace used as indents"): strips a leading run of space, tab, NBSP, en space, em space and ideographic space at the start of paragraph-like elements (`EPUBParser.stripLeadingIndentWhitespaceDOM`). ASCII space and tab are already collapsed by HTML at line start, so the non-ASCII characters are what make it visible. Blank elements are skipped. This deletes text, so it shifts character offsets: highlights saved with the toggle in one state can misalign in the other.
- `collapseSpacerParagraphs`: adds the class `ambrosia-spacer` to every `<p>` whose children are only whitespace text (including `&nbsp;`) or `<br>` (`EPUBParser.markSpacerParagraphsDOM`). `ReaderPreferences.css` collapses `p.ambrosia-spacer` to zero height. No text changes, so offsets are identical with the toggle on or off. A childless `<p>` is not tagged. The SwiftSoup-failure fallback path and the feed server (`LocalFeedServer`) do not apply it.

### Menu Bar Integration
The `Reader` menu in `AmbrosiaApp` provides comprehensive keyboard shortcuts:
- **Navigation**: Next Page (`⌘→` / `Space`), Previous Page (`⌘←` / `⇧Space`), Next Chapter (`⌘]`), Previous Chapter (`⌘[`).
- **Appearance**: Increase Font Size (`⌘=`), Decrease Font Size (`⌘-`), Reset Font Size (`⌘0`), Themes submenu, Columns submenu.
- **Work Actions**: Like This Work, Add to Read Later.
- **Find in Work**: Toggle Find Bar (`⌘F`), Find Next (`⌘G`), Find Previous (`⇧⌘G`).

`ReaderViewController`:

- Builds `WKWebViewConfiguration` before `WKWebView` creation.
- Registers message handlers at construction: `positionUpdate`, `pageAction`, `highlightAdded`, `highlightTapped`, `consoleLog`.
- Loads merged EPUB HTML from the active library path.
- Starts in `ReaderPreferences.shared.defaultReadingMode`.
- Reloads full HTML on any `ReaderPreferences.objectWillChange` event via a Combine sink.
- Auto-saves position periodically and on disappearance.

Scroll mode loads merged HTML normally and restores scroll offset.

Paginated mode uses one visible `WKWebView` with CSS multi-column layout. One column is one page; page turns set horizontal scroll. Resize repagination is debounced. WebKit trailing padding shortfall compensation is applied directly to `document.body.style.transform` (cleared prior to offset and anchor navigations) to prevent the last column from offsetting to the right or shifting background canvases.

**Table of contents panel:** `ReaderViewController.toggleTOCSidebar()` (menu action `showTOCSidebar(_:)`, sent from `AmbrosiaApp.swift`) opens or closes a floating `NSPanel` titled "Contents", 260pt wide and anchored to the left edge of the reader window. The panel hosts `TOCSidebarView` in an `NSHostingView` with `sizingOptions = []` (see `swiftui-appkit-bridging.md`) and follows the reader window on move and resize. It can be open at the same time as the annotation panel on the right. `globalTOC` flattens every work's `EPUBParser.toc` into `TOCPanelEntry` values whose `spineIndex` is already global, resolved through `SeriesSpineMap`. For a series target each entry carries its work's title, and the view groups entries under per-work section headers; for a single book `workTitle` is nil and the list is flat. `jumpToTOCEntry(_:)` navigates using that global index. In email mode, `EmailReaderSidebarView` renders the same `TOCSidebarView` inside the split-view sidebar (`showTOCInEmailSidebar`), fed by `globalTOCEntries`. `RebindableAction.showTOCSidebar` defaults to `⌘T` (matching Honeycrisp and standard document TOCs). For how the entries are produced, see `epub-parsing.md`.

**CSS pipeline:** `ReaderPreferences.css(paginated:)` builds the user stylesheet, which `EPUBParser` injects into every document (`mergedHTML` in scroll mode, `sanitise` in paginated mode). Style preferences are CSS custom properties (`--ambrosia-*`) declared in `:root` by `ReaderPreferences.cssVariableDeclarations`. `ReaderPreferences.preferenceChangeKind` classifies each change:

- `.cosmetic` (fonts, colors, spacing, theme, alignment, paragraph indent): `ReaderViewController.applyCosmeticCSSUpdate()` rewrites a `<style id="ambrosia-vars">` element with the current `:root` declarations. No reload.
- `.structural` (reading mode, columns, AO3 layout order, and the content toggles `removeParagraphIndents` and `collapseSpacerParagraphs`, which change the built HTML): debounced `reloadHTML()`.

Two rules are emitted only when the preference is non-default at build time: `p { text-align }` (`textAlignment != .book`) and `p { text-indent }` (`paragraphIndent != nil`). The live path can change the variables they read but cannot create a rule that was never built. `ReaderPreferences.CSSRuleGate` records which of the two rules a document was built with; `ReaderViewController.builtCSSRuleGate` stores it at each build, and the cosmetic sink schedules a reload when the current gate differs. Moving between two non-default values (indent 1.5em to 2em, Left to Justified) stays live.

Known limitation (paginated mode): `paginatedColumnCSS` bakes `paddingH`, `paddingV` and `maxWidth` into literal values, so those three preferences, although classified `.cosmetic`, have no visible effect on an already-loaded paginated document until it reloads. Font size and line height do apply live but nothing re-measures the column count afterwards.

---


---

## Key invariants

6. `WKWebViewConfiguration` message handlers must be registered before `WKWebView` is initialized.

7. Full HTML reload (`reloadHTML`) is required for reading mode switches, DOM structural changes, and any change to `ReaderPreferences.cssRuleGate`. It is not required for other style-only preference changes; those go through `applyCosmeticCSSUpdate()`.

8. `evaluateJavaScript` calls that do not need a return value should pass `completionHandler: nil` to avoid retain cycles when the `WKWebView` tears down before the callback fires. Calls that capture a return value must use `[weak self]` closures and guard on `self`. The distinction is about memory safety, not style.
