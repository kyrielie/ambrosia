Help me debug pagination mode. Does this make sense?

The Insight from Calibre's Approach
Calibre's paged mode does not do what your plan proposes. It does something radically simpler and more robust:
It loads the full document into a single WebView, then applies CSS multi-column layout to `document.body`:
css

```css
body {
  column-width: <col_size>px;
  column-gap: <gap>px;
  column-fill: auto;
  width: <viewport_width>px;
  height: 100vh;
  overflow: hidden;
  box-sizing: content-box;
}
```

The browser's own layout engine does all the pagination work. Each "page" is a CSS column. To navigate pages, Calibre simply sets `scrollLeft` to `columnIndex * (columnWidth + columnGap)`. That's it. No DOM slicing, no `Range.cloneContents()`, no hidden measurement WebView, no character offset arithmetic for page boundaries.
The browser handles italic spans crossing page breaks correctly because nothing crosses a boundary — the DOM is untouched, and the CSS column algorithm handles block/inline fragmentation natively, including splitting text nodes across columns without anyone having to know about it.

What the Revised Architecture Looks Like
Entering paginated mode:

1. `EPUBParser` generates `mergedHTML` as normal (strips publisher CSS, injects user CSS).
2. User CSS injection additionally sets the column properties on `body`: `column-width`, `column-gap`, `column-fill: auto`, `height: 100vh`, `overflow-x: hidden`, `overflow-y: hidden`.
3. The full HTML loads into the single visible WKWebView — no hidden measurement WebView needed at all.
4. After `didFinish`, call `document.body.scrollWidth` and `document.body.offsetWidth` via `evaluateJavaScript` to compute total number of columns: `pageCount = ceil(scrollWidth / (columnWidth + columnGap))`.
Navigation:
javascript

```javascript
// Go to page N (0-indexed)
document.documentElement.scrollLeft = N * (columnWidth + columnGap);
```

Position save/restore: Save the current `scrollLeft` value (or derive the column index from it). On restore, set `scrollLeft` after load. This replaces the current `lastScrollOffset` for paginated mode with a `lastPageIndex` or just a `lastScrollLeft`.
Resize: On window resize, recompute column count. The column index of the saved position can be approximated by finding which column contains the saved character offset — but even simpler: since you already have `lastCharacterOffset` from scroll mode, use `document.caretRangeFromPoint` or a TreeWalker to find which column that character now lands in after the new layout, then scroll there.
Switching back to scroll mode: Just reload `mergedHTML` without the column CSS. The hidden WKWebView that the original plan required doesn't exist and doesn't need to be destroyed.



Still cannot go to next page using intended controls. %read is also broken by paginated mode.

Claude responded: Let me instrument this properly before guessing.
Let me instrument this properly before guessing.
Ran 4 commands
Ran 4 commands
I can see the key problems now. Let me check the `BookState` model for `totalReadPercent`:
Ran 3 commands
Ran 3 commands
Now I have a complete picture of both bugs. Let me trace each:
Bug 1 — navigation still broken: `goToNextPage()` guards on `currentPageIndex < paginationGeometry.pageCount - 1`. The most likely reason this always returns early is that `paginationGeometry` is still empty (`.pageCount == 0`) when keys fire. That happens because `measurePageCount` fires in `didFinish`, but `didFinish` is called by WebKit on a re-entrant runloop tick — by the time the JS evaluation returns asynchronously, `paginationGeometry` may still be zero if measurement fails silently. But there's a deeper structural issue: `evaluateJavaScript` on `documentElement.scrollWidth` can return `0` right at `didFinish` because WebKit's compositing hasn't committed yet. We need to defer the measurement, and also add `print` diagnostics. Also, looking at `scrollTo` — it sets `document.documentElement.scrollLeft` but WebKit on macOS may require `window.scrollTo` or setting it on `document.body.scrollLeft` instead, depending on the quirks mode of the document. The loaded HTML has `<!DOCTYPE html>` so it's standards mode, where `documentElement.scrollLeft` should work — but `WKWebView`'s internal scroll view could be interfering. The safer approach is to use `window.scrollTo(x, 0)` which always works regardless of standards/quirks mode.
Bug 2 — %read broken: `totalReadPercent` is stored as a fraction (0–1) but `updateProgressForCurrentPage` sets it to `Double(currentPageIndex + 1) / Double(pageCount)` which is correct. However it's only called from `goToNextPage`/`goToPreviousPage` — it's never set on initial load after geometry is measured. After `restorePaginatedPosition` sets `currentPageIndex`, it never calls `updateProgressForCurrentPage()`. Also the scroll mode code sets `totalReadPercent` via the JS scroll position (which never runs in paginated mode), so the value stays at whatever scroll mode left it, or 0.