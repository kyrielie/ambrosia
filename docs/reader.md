# Reader

Scope: `ReaderWindowController`/`ReaderViewController`, the `WKWebView`-based
reading surface, scroll and paginated modes, and the CSS preference
pipeline. For the source HTML this loads, see `epub-parsing.md`. For
highlight/annotation capture inside the webview, see `annotations.md`.

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

**Table of contents panel:** `ReaderViewController.toggleTOCSidebar()` (menu action `showTOCSidebar(_:)`, sent from `AmbrosiaApp.swift`) opens or closes a floating `NSPanel` titled "Contents", 260pt wide and anchored to the left edge of the reader window. The panel hosts `TOCSidebarView` in an `NSHostingView` with `sizingOptions = []` (see `swiftui-appkit-bridging.md`) and follows the reader window on move and resize. It can be open at the same time as the annotation panel on the right. `globalTOC` flattens every work's `EPUBParser.toc` into `TOCPanelEntry` values whose `spineIndex` is already global, resolved through `SeriesSpineMap`. For a series target each entry carries its work's title, and the view groups entries under per-work section headers; for a single book `workTitle` is nil and the list is flat. `jumpToTOCEntry(_:)` navigates using that global index. In email mode, `EmailReaderSidebarView` renders the same `TOCSidebarView` inside the split-view sidebar (`showTOCInEmailSidebar`), fed by `globalTOCEntries`. `RebindableAction.showTOCSidebar` has no default key binding; this is deliberate (see the comment on `ReaderPreferences.keyBindings`). For how the entries are produced, see `epub-parsing.md`.

**CSS pipeline:** `ReaderPreferences.css` is a computed `String` that interpolates Swift values directly into CSS literal property values. There are no CSS custom properties in the current pipeline. Every preference change — including font size, line height, color, and padding adjustments — triggers a full EPUB re-parse and `WKWebView` reload. Migrating style-only preferences to CSS variable injection (`var(--ambrosia-*)` in a `:root` block) would reduce this to a single `evaluateJavaScript` call for those changes; structural changes (reading mode switches, DOM layout changes) would still require a full reload.

---


---

## Key invariants

6. `WKWebViewConfiguration` message handlers must be registered before `WKWebView` is initialized.

7. Full HTML reload (`reloadHTML`) is required for reading mode switches and other DOM structural changes. It is not required for style-only preference changes (colors, typography, spacing); those should eventually use CSS variable injection to avoid re-parsing the EPUB on every tweak. Until that is implemented, the full reload path remains in place.

8. `evaluateJavaScript` calls that do not need a return value should pass `completionHandler: nil` to avoid retain cycles when the `WKWebView` tears down before the callback fires. Calls that capture a return value must use `[weak self]` closures and guard on `self`. The distinction is about memory safety, not style.
