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
- **AO3 Preface Card**: `#preface` metadata is formatted with a distinct divider and clear typographic hierarchy. The metadata block (`dl.tags`) formats `<dt>` (Rating, Warnings, Fandoms, Relationships, Characters, Tags) with crisp semibold labels and `<dd>` with formatted inline tag runs, preventing layout blowout in multi-column paginated mode.
- **Summaries and Author Notes**: `.summary`, `blockquote`, and `.notes` render with a 3px accent border on the leading edge and a subtle 5% background callout tint, making author notes and chapter summaries instantly recognizable.
- **Calibre Style Overrides**: `body[class]` and `!important` rules override Calibre's hardcoded `.calibre` and `margin: 0 5pt` rules, ensuring user margins and max-widths take precedence.
- **AO3 Endmatter**: `EPUBParser.buildAO3Endmatter` generates "Read on AO3", "Comments on AO3", and series index links at the conclusion of the story.
- **Curated Reading Themes**: Built-in presets inspired by Kudos include Parchment, Sepia (`#FBF0D9`), Paper (`#FFFFFF`), Night (`#1C1C1E`), Dark (`#16161A`), OLED (`#000000`), and Slate.

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

**Table of contents panel:** `ReaderViewController.toggleTOCSidebar()` (menu action `showTOCSidebar(_:)`, sent from `AmbrosiaApp.swift`) opens or closes a floating `NSPanel` titled "Contents", 260pt wide and anchored to the left edge of the reader window. The panel hosts `TOCSidebarView` in an `NSHostingView` with `sizingOptions = []` (see `swiftui-appkit-bridging.md`) and follows the reader window on move and resize. It can be open at the same time as the annotation panel on the right. `globalTOC` flattens every work's `EPUBParser.toc` into `TOCPanelEntry` values whose `spineIndex` is already global, resolved through `SeriesSpineMap`. For a series target each entry carries its work's title, and the view groups entries under per-work section headers; for a single book `workTitle` is nil and the list is flat. `jumpToTOCEntry(_:)` navigates using that global index. In email mode, `EmailReaderSidebarView` renders the same `TOCSidebarView` inside the split-view sidebar (`showTOCInEmailSidebar`), fed by `globalTOCEntries`. `RebindableAction.showTOCSidebar` has no default key binding; this is deliberate (see the comment on `ReaderPreferences.keyBindings`). For how the entries are produced, see `epub-parsing.md`.

**CSS pipeline:** `ReaderPreferences.css` is a computed `String` that interpolates Swift values directly into CSS literal property values. There are no CSS custom properties in the current pipeline. Every preference change — including font size, line height, color, and padding adjustments — triggers a full EPUB re-parse and `WKWebView` reload. Migrating style-only preferences to CSS variable injection (`var(--ambrosia-*)` in a `:root` block) would reduce this to a single `evaluateJavaScript` call for those changes; structural changes (reading mode switches, DOM layout changes) would still require a full reload.

---


---

## Key invariants

6. `WKWebViewConfiguration` message handlers must be registered before `WKWebView` is initialized.

7. Full HTML reload (`reloadHTML`) is required for reading mode switches and other DOM structural changes. It is not required for style-only preference changes (colors, typography, spacing); those should eventually use CSS variable injection to avoid re-parsing the EPUB on every tweak. Until that is implemented, the full reload path remains in place.

8. `evaluateJavaScript` calls that do not need a return value should pass `completionHandler: nil` to avoid retain cycles when the `WKWebView` tears down before the callback fires. Calls that capture a return value must use `[weak self]` closures and guard on `self`. The distinction is about memory safety, not style.
