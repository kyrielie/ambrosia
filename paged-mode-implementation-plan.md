# Paged Mode Implementation Plan — Ambrosia macOS Reader

## Current State

The codebase already has the structural skeleton in place:

- `PaginationEngine.swift` — Swift-side coordinator: column geometry math, calls into JS, dispatches spine navigation
- `PaginationJS.swift` — JavaScript injected at load time: applies CSS multi-column, handles `ambrosiaNextPage/PrevPage`, posts `positionUpdate` and `pageAction` messages back to Swift
- `ReaderViewController.swift` — routes between `.scroll` and `.paginated` modes, owns `WKWebView`, calls `applyLayout()` in `didFinish`
- `ReaderMenuWebView` (private subclass in ReaderViewController.swift) — intercepts `keyDown` and `scrollWheel` before `WKWebView` consumes them
- `BookState` — stores `lastSpineIndex` + `lastScrollOffset` (fraction 0–1 in paginated, scrollY in scroll mode)

The main engine is already logically complete. What follows is not a rewrite — it is a structured list of the **specific gaps, bugs, and missing wiring** that need to be closed, followed by the features that build on top of a working foundation.

---

## Known Issues to Fix First

These must be resolved before any feature work because they block the core loop.

### 1. CSS conflict: `body { padding }` from `ReaderPreferences.css` vs. `ambrosiaSetup`

**Problem:** `ReaderPreferences.shared.css` injects `padding: \(paddingV)px \(paddingH)px` on `body`. `ambrosiaSetup` then sets `body { margin: 0; padding: 0 }` with `!important`. This fight is fine, but `paddingH` is also used as the column gap in `PaginationEngine.computeColumnGeometry`. If `paddingH` is 0 the gap is clamped to 1, which is correct, but the visual gutter between the two columns on a two-column layout and the left/right page margins come entirely from `paddingH`. The result is **no visible margin on any column edge**.

**Fix:** In paginated mode the horizontal margin should be expressed as body padding *per column*, not as a page-level padding on the whole multi-column container. The correct approach is:
- Keep `gap` as the space *between* columns (controlled by `paddingH`).
- Add a separate `padding-left` / `padding-right` on each column via `column-rule` (cosmetic only, no structural role) or, more reliably, by wrapping the body's direct children in a `<div>` with left/right padding inside `ambrosiaSetup`. The simplest practical fix: set `body { padding-left: \(paddingH)px; padding-right: \(paddingH)px }` *inside* `ambrosiaSetup` after the column layout is applied, and strip it from the injected `ReaderPreferences.css` when in paginated mode.

Concretely: add a `paginated: Bool` parameter to `ReaderPreferences.css`, or compute a `paginatedCSS` variant that omits `padding` from the body rule.

---

### 2. `lastScrollOffset` dual-use ambiguity

**Problem:** `BookState.lastScrollOffset: Double` is used as two incompatible things:
- **Scroll mode:** absolute `window.scrollY` in pixels (can be thousands)
- **Paginated mode:** a 0–1 progress fraction

`savePaginatedProgress()` writes a fraction, but `restoreScrollPosition()` and `saveCurrentPositionSync` (scroll branch) write and read pixel values. If the user switches modes, the wrong interpretation is applied on restore.

**Fix:** Either:
- Add `lastPaginatedFraction: Double` to `BookState` as a dedicated field (cleanest), *or*
- Normalize on write in scroll mode (divide by `document.scrollHeight`) so both modes always store 0–1. Currently the scroll mode JS already computes `percent` but writes `scrollY` to `lastScrollOffset` and `percent` to `totalReadPercent`. Swap the storage: write `percent` to `lastScrollOffset` in scroll mode too, and restore as `window.scrollTo(0, percent * document.scrollHeight)`.

The second approach requires only a one-line JS change and no schema migration. Recommend it.

---

### 3. `WKWebView` bounds race on cold open in paginated mode

**Problem:** `loadSpineItem` guards `vw > 50, vh > 50` and retries after 50ms if not. But `webView.bounds` can remain `.zero` for several frames even after the view is in the hierarchy, if the window hasn't had its first layout pass. The retry loop can silently succeed with wrong bounds (e.g., 800×0 during a resize) or spin for longer than expected on slower machines.

**Fix:** Instead of polling bounds, wait for `viewDidLayout` to fire once before calling `loadSpineItem`. Add an `isLayoutReady: Bool` flag set to `true` in `viewDidLayout` (after `super.viewDidLayout()`). Gate `loadSpineItem` on this flag rather than on raw bound sizes. If `loadSpineItem` is called before `isLayoutReady`, store `(index, restorePage)` as `pendingSpineLoad` and execute it at the end of the first `viewDidLayout`.

---

### 4. `scrollWheel` is fully blocked in paginated mode

`ReaderMenuWebView.scrollWheel` returns immediately in paginated mode, which prevents trackpad scrolling. This is intentional to avoid drifting off column boundaries. However, it also blocks **two-finger swipe** gestures, which users expect to turn pages.

**Fix:** Implement swipe-to-turn-page using `NSEvent.phase`. In `scrollWheel`:

```swift
override func scrollWheel(with event: NSEvent) {
    guard let vc = viewController, vc.currentMode == .paginated else {
        super.scrollWheel(with: event)
        return
    }
    // Treat a completed two-finger swipe as a page turn.
    if event.phase == .ended || event.momentumPhase == .began {
        let dx = event.scrollingDeltaX
        if abs(dx) > 20 {
            dx < 0 ? vc.goToNextPage() : vc.goToPreviousPage()
        }
    }
}
```

This accumulates swipe delta across the gesture and fires once at lift-off, keeping the view snapped to column boundaries.

---

### 5. `colsPerScreen` is not persisted

`PaginationEngine` has `setColsPerScreen(_:)` but `ReaderPreferences` has no `colsPerScreen` property. The value defaults to 1 and is never saved. The `ColsPerScreen` enum is defined but not wired up.

**Fix:** Add to `ReaderPreferences`:

```swift
@Published var colsPerScreen: ColsPerScreen {
    didSet { UserDefaults.standard.set(colsPerScreen.rawValue, forKey: Keys.colsPerScreen) }
}
```

Default value: `.one` (never surprise users with two-column layout on first launch). Read it in `loadSpineItem` before calling `paginationEngine?.loadSpine(...)`:

```swift
paginationEngine?.setColsPerScreen(ReaderPreferences.shared.colsPerScreen)
```

---

### 6. `applyLayout` is called from `webView(_:didFinish:)` regardless of mode

Currently `webView(_:didFinish:)` calls `paginationEngine?.applyLayout()` unconditionally. In scroll mode this injects the entire PaginationJS bundle and calls `ambrosiaSetup` unnecessarily, adding latency and polluting the global scope.

**Fix:** Guard the call:

```swift
func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if currentMode == .paginated {
        paginationEngine?.applyLayout()
    } else {
        restoreScrollPosition()
        injectScrollTracker()
    }
    // ... rest of didFinish
}
```

---

## Phase 1 — Core Loop (Minimal Viable Paged Mode)

After fixing the above issues, validate the end-to-end flow with this checklist:

1. Open a multi-spine EPUB in paginated mode
2. Press → to advance through all columns of spine 0, then confirm `nextSpineItem` fires and spine 1 loads at column 0
3. Press ← at column 0 of spine 1, confirm `prevSpineItem` fires and spine 0 loads at its last column
4. Close and reopen the book — confirm it restores to the correct spine index and column
5. Resize the window — confirm `reapplyLayout` fires once (debounced ~300ms), preserves position
6. Switch from paginated → scroll → paginated — confirm position is preserved across both transitions

---

## Phase 2 — Two-Column Layout

Once the single-column loop is solid, two-column layout is a one-line change in JS (`colsPerScreen = 2`). The geometry math in `PaginationEngine.computeColumnGeometry` already handles it. The remaining work:

### 2a. Toolbar page indicator

Add a `"Page N of M"` or `"N / M"` indicator to the reader toolbar. Source the numbers from the `positionDidChange` callback already wiring `(currentColumn, totalColumns)` back to `ReaderViewController`. For two-column layout, display *screens* not columns: `screen = column / colsPerScreen + 1`, `totalScreens = ceil(totalColumns / colsPerScreen)`.

### 2b. Blank trailing column

When `totalColumns % colsPerScreen != 0`, the last screen is partial (one column of content, one blank). This is visually correct (background color fills the gap). No code change needed — document this as intentional behavior.

### 2c. Two-column preference UI

Add a segmented control to the reader toolbar or preferences pane:

```
[ 1 ] [ 2 ] columns
```

Bound to `ReaderPreferences.shared.colsPerScreen`. On change, call `paginationEngine?.setColsPerScreen(newValue)` then `paginationEngine?.reapplyLayout()` (which preserves fraction automatically).

---

## Phase 3 — TOC Navigation in Paginated Mode

TOC items link to `href#anchor` targets within spine items. Paginated mode needs to:

1. Determine which spine item contains the target anchor
2. Load that spine item if it's not current
3. Scroll to the column containing the anchor element

### 3a. Anchor-to-spine resolution

`EPUBParser` already has the spine item list with `href`. Add a method:

```swift
func spineIndex(for href: String, fragment: String?) -> (spineIndex: Int, fragment: String?)?
```

Strip query parameters and normalize paths. Return the matching `SpineItem.index` and the fragment (e.g., `"chapter2"` from `Text/chapter2.xhtml#section3`).

### 3b. Jump to anchor in JS

`PaginationJS` already implements `ambrosiaNavigateToOffset(charOffset)` which finds a character offset and snaps to its column. The equivalent for a DOM anchor is simpler — just find the element:

Add to `PaginationJS`:

```javascript
window.ambrosiaScrollToAnchor = function (id) {
    if (!_ready) return;
    var el = id ? document.getElementById(id) : null;
    if (!el) { el = id ? document.querySelector('[name="' + id + '"]') : null; }
    if (!el) return;
    var rect = el.getBoundingClientRect();
    var docX = rect.left + window.scrollX;
    var col = (_colAndGap > 0) ? Math.max(0, Math.floor((docX) / _colAndGap)) : 0;
    window.ambrosiaScrollToColumn(col);
    _postPositionUpdate();
};
```

### 3c. ReaderViewController wiring

```swift
func jumpToTOCEntry(spineIndex: Int, fragment: String?) {
    if spineIndex != currentSpineIndex {
        // Load the spine, then jump to fragment once spineDidLoad fires
        pendingFragmentJump = fragment
        loadSpineItem(index: spineIndex, restorePage: 0)
    } else {
        let js = fragment.map { "window.ambrosiaScrollToAnchor('\($0)');" } ?? ""
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}
```

Store `pendingFragmentJump: String?` on `ReaderViewController`. In `spineDidLoad`:

```swift
engine.spineDidLoad = { [weak self] _ in
    self?.performPendingAnnotationJumpIfNeeded()
    self?.performPendingFragmentJumpIfNeeded()
    self?.savePaginatedProgress()
}
```

---

## Phase 4 — Find / Search in Paginated Mode

`WKWebView.find(_:configuration:)` highlights matches in the currently loaded document, but in paginated mode the match might be on a column that isn't currently visible. The find result will be highlighted but off-screen.

### 4a. Scroll to the find result column

After `webView.find(...)` returns `result.matchFound == true`, evaluate JS to find the position of the native WebKit selection and snap to its column:

```javascript
(function() {
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return -1;
    var rect = sel.getRangeAt(0).getBoundingClientRect();
    var docX = rect.left + window.scrollX;
    return (_colAndGap > 0) ? Math.max(0, Math.floor(docX / _colAndGap)) : 0;
})()
```

Then call `paginationEngine?.scrollToColumn(column)`.

### 4b. Cross-spine find

The current find bar only searches the currently loaded spine item. Cross-spine find requires iterating all spine items, which is expensive. Recommended approach: implement single-spine find first (Phase 4a). Add cross-spine as a later enhancement, iterating spines in background and loading each to search.

---

## Phase 5 — Annotations in Paginated Mode

Annotations (`HighlightBridge`) already work in paginated mode for the *current* spine item. The remaining gaps:

### 5a. Restore highlights on spine load

`restoreAnnotations()` filters `ranged` annotations to `$0.spineIndex == currentSpineIndex` when in paginated mode — correct. But it's called only once at initial load. Call it again (or call `HighlightBridge.restoreHighlights(...)` directly) inside `spineDidLoad` so highlights reappear when navigating between spine items.

```swift
engine.spineDidLoad = { [weak self] _ in
    guard let self else { return }
    let ranged = self.annotations.filter {
        !$0.isPointAnnotation && $0.spineIndex == self.currentSpineIndex
    }
    HighlightBridge.restoreHighlights(ranged, into: self.webView)
    self.performPendingAnnotationJumpIfNeeded()
    self.performPendingFragmentJumpIfNeeded()
    self.savePaginatedProgress()
}
```

### 5b. Jump-to-annotation across spine items

Already implemented in `jumpToAnnotation(_:)` — it calls `loadSpineItem(index: annotation.spineIndex)` and stores `pendingAnnotationJump`. Verify it works end-to-end with the highlight restore in 5a.

### 5c. Annotation sidebar spine scoping

The annotation sidebar shows all annotations for the entire book. Add a subtle indicator (spine item label or chapter title) next to annotations that are in other spine items, so users understand why tapping jumps them to a different part of the book.

---

## Phase 6 — Progress Tracking

Progress in paginated mode has two components:
- **Within-spine fraction:** `ambrosiaProgressFraction()` (0–1 for the current spine item)
- **Whole-book fraction:** needs to weight spine items by their relative text length

### 6a. Whole-book progress

Compute a per-spine character count during initial EPUB parsing:

```swift
// EPUBParser
func spineCharCounts() throws -> [Int] {
    return try spine.map { item in
        let text = try plainText(for: item)
        return text.utf16.count
    }
}
```

Cache this in `BookState` or compute once and store in a local property on `ReaderViewController`. Then:

```
wholeBookFraction = (sum of charCounts[0..<currentSpineIndex] + fraction * charCounts[currentSpineIndex]) / totalChars
```

Write this to `BookState.totalReadPercent` instead of the raw spine fraction.

### 6b. Toolbar progress indicator

Display `"Chapter N of M • Page P of Q"` in the reader toolbar, where:
- N/M = `currentSpineIndex + 1` / `parser.spine.count`
- P/Q = current screen / total screens (from `positionDidChange`)

---

## Phase 7 — Scroll Mode Parity (If Needed)

The scroll mode is already functional. Once paginated mode is complete, consider adding these to scroll mode for parity:

- **Reading time estimation:** total chars / average reading speed → minutes remaining. Works in both modes from character count data.
- **Smooth auto-scroll:** a timer that calls `window.scrollBy(0, 1)` at a user-configurable speed. Block in paginated mode with a clear error message.

---

## Data Model Changes Summary

| What | Where | Change |
|------|-------|--------|
| Store scroll progress as 0–1 fraction (not raw scrollY) | `ReaderViewController.saveCurrentPositionSync` scroll branch | Divide scrollY by scrollHeight in JS; restore as `scrollTo(0, frac * scrollHeight)` |
| `colsPerScreen` preference | `ReaderPreferences` | New `@Published var colsPerScreen: ColsPerScreen` |
| `pendingFragmentJump` | `ReaderViewController` | New `private var pendingFragmentJump: String?` |
| Spine char counts for whole-book progress | `ReaderViewController` | New `private var spineCharCounts: [Int]` |

No `BookState` schema migration required if scroll progress is normalized to 0–1 on the write side.

---

## Invariants to Never Break

These constraints are documented in the existing code and must be preserved throughout all work:

1. **Character offset convention:** UTF-16 code units, text nodes only, HTML tags excluded. Every place that reads or writes a character offset — `EPUBParser.plainText`, `PaginationJS._nodeAtChar`, `HighlightBridge`, `BookmarkManager` — must use the same counting method. Never change one without changing all others.

2. **JS injection timing:** `ambrosiaSetup` must be called after `didFinish` navigation, never before. The DOM is not ready until `didFinish` fires.

3. **Column geometry is computed in Swift, not JS:** `colSize` and `gap` are derived from `webView.bounds.width` in Swift and passed to `ambrosiaSetup`. JS trusts these values. If bounds are wrong, everything is wrong — fix the bounds before calling `applyLayout`, not inside JS.

4. **Key repeat suppression:** one physical keypress = one page turn. `event.isARepeat` must be checked in `ReaderMenuWebView.keyDown` before forwarding to `goToNextPage/goToPreviousPage`. Never remove this guard.

5. **WKWebView scrollbar suppression:** both the JS `scrollbar-width: none` / `::-webkit-scrollbar { display: none }` and the native `enclosingScrollView?.hasHorizontalScroller = false` are needed. Removing either can cause scrollbars to flash during layout transitions on macOS.

6. **No DOM mutation during column layout:** avoid inserting or removing elements between `ambrosiaSetup` and the first `ambrosiaColumnCount()` call. The 50ms delay in `applyLayout` exists precisely to let WebKit settle the column layout before reading `scrollWidth`. If you shorten this delay, column counts can be off by one.

7. **Message handlers registered before WKWebView init:** `positionUpdate`, `pageAction`, `highlightAdded`, `highlightTapped` must all be added to `WKWebViewConfiguration.userContentController` before the `WKWebView` is created. Adding them after creation silently fails on some macOS versions.

---

## Implementation Order

```
Fix issues 1–6 (bugs)
    ↓
Phase 1: validate core loop end-to-end
    ↓
Phase 2: two-column layout + toolbar indicator
    ↓
Phase 3: TOC navigation
    ↓
Phase 5a/b: annotation restore on spine load
    ↓
Phase 4a: find result column scroll
    ↓
Phase 6: whole-book progress fraction
    ↓
Phase 5c / Phase 4b / Phase 7: nice-to-haves
```

Phases 3, 5a, and 6a are independent and can be done in any order after Phase 1. Phase 4a depends on Phase 1 only. Phase 4b (cross-spine find) is a significant standalone project and can be deferred indefinitely.
