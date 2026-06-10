import Foundation

// MARK: - PaginationJS
//
// JS pagination engine for horizontal CSS multi-column paged mode.
//
// ARCHITECTURE — per-spine loading:
//   Each spine item is loaded as a separate HTML document into the WKWebView.
//   The body is given CSS multi-column layout so the browser handles all text
//   reflow. Ambrosia scrolls horizontally between columns. One "page turn"
//   advances by exactly cols_per_screen columns.
//
//   When the user reaches the last column of a spine, the next keypress signals
//   Swift (via pageAction: nextSpineItem). Swift loads the next spine item and
//   restores scroll to column 0. Navigating backward past column 0 signals
//   pageAction: prevSpineItem; Swift loads the previous spine and restores to
//   its last column.
//
//   Blank columns: if the final screen of a spine has fewer than cols_per_screen
//   columns of content, the remaining space is empty (background color). This is
//   natural — CSS columns don't fill beyond their content, and overflow is hidden.
//
// COLUMN MATH:
//   colSize  = (viewportWidth + gap) / colsPerScreen − gap
//   col n starts at pixel: n * (colSize + gap)
//   Current col number:    floor(scrollX / colAndGap)
//   Total cols in spine:   floor((scrollWidth + gap) / colAndGap)
//
// CHARACTER OFFSET INVARIANT (unchanged from original):
//   UTF-16 code units, text nodes only, HTML tags excluded.
//   TreeWalker(NodeFilter.SHOW_TEXT), node.length = UTF-16 code unit count.
//
// EXPOSED GLOBALS (called from Swift via evaluateJavaScript):
//
//   window.ambrosiaSetup(colSize, gap, colsPerScreen)
//     Apply CSS multi-column layout to document.body and store column metrics.
//     Call once after loadHTMLString completes (didFinish navigation).
//
//   window.ambrosiaColumnCount()
//     → Int: total number of columns in this spine item.
//
//   window.ambrosiaCurrentColumn()
//     → Int: zero-based index of the leftmost visible column.
//
//   window.ambrosiaScrollToColumn(n)
//     Snap-scroll to column n. Clamps to valid range.
//
//   window.ambrosiaScrollToFraction(frac)
//     Restore a saved 0–1 progress fraction. Snaps to nearest column boundary.
//
//   window.ambrosiaProgressFraction()
//     → Double 0–1: current reading progress within this spine item.
//
//   window.ambrosiaNavigateToOffset(charOffset)
//     Scroll to the column containing the given UTF-16 char offset.
//     Used by TOC, annotations, and bookmarks (Phase 12, 15).
//
//   window.ambrosiaHighlight(offset)
//     2-second yellow flash at char offset (search / find result).
//
//   window.ambrosiaTotalChars()
//     → Int: total UTF-16 char count (for validation / progress math).
//
//   window.ambrosiaCharOffset(node, localOffset)
//     → Int: global UTF-16 offset for a DOM node + local offset.
//     Called by HighlightBridge from JS selection events.
//
// MESSAGES POSTED TO SWIFT (via window.webkit.messageHandlers.*):
//
//   pageAction  { action: 'nextSpineItem' | 'prevSpineItem' }
//     Fired when the user attempts to navigate past the last / before the
//     first column of this spine. Swift loads the adjacent spine.
//
//   positionUpdate  { fraction: Double, column: Int, totalColumns: Int }
//     Fired after every column navigation so Swift can update BookState
//     progress and the toolbar position indicator.
//
// KEYSTROKES: handled entirely in Swift (ReaderViewController).
//   JS does not install any keydown listeners.

enum PaginationJS {

    static let script: String = #"""
    (function () {
    'use strict';

    // ─── Column layout state ─────────────────────────────────────────────────

    var _colSize       = 0;
    var _gap           = 0;
    var _colAndGap     = 0;
    var _colsPerScreen = 1;
    var _ready         = false;

    // ─── Setup: apply CSS multi-column and store metrics ────────────────────
    //
    // Called by Swift once after didFinish navigation, before any scroll calls.
    // colSize and gap are computed in Swift from the view's actual bounds.

    window.ambrosiaSetup = function (colSize, gap, colsPerScreen) {
        _colSize       = colSize;
        _gap           = gap;
        _colAndGap     = colSize + gap;
        _colsPerScreen = colsPerScreen;
        _ready         = true;

        // Apply multi-column layout to body.
        // column-fill: auto  → columns fill top-to-bottom before starting a new one.
        // body height:100vh  → forces the browser to break into columns rather than
        //                      extending the body vertically.
        //
        // SCROLL MODEL — must match Calibre paged_mode.pyj:
        //   html  → overflow-x: scroll (the scroll container; window.scrollTo works here)
        //            overflow-y: hidden (no vertical scroll)
        //            scrollbar hidden via ::-webkit-scrollbar
        //   body  → overflow-x: visible (columns extend past body boundary into html)
        //            overflow-y: hidden
        //
        // If html is overflow:hidden it becomes a clipping box, not a scroll container.
        // window.scrollTo() silently no-ops against a clipping box — this is why
        // pages appeared not to turn despite ambrosiaNextPage being called correctly.
        var de = document.documentElement;
        de.style.setProperty('overflow-x',         'scroll',  'important');
        de.style.setProperty('overflow-y',          'hidden',  'important');
        de.style.setProperty('scrollbar-width',     'none',    'important');
        de.style.setProperty('width',  window.innerWidth  + 'px', 'important');
        de.style.setProperty('height', window.innerHeight + 'px', 'important');

        var b = document.body;
        b.style.setProperty('column-width',  colSize + 'px',  'important');
        b.style.setProperty('column-gap',    gap    + 'px',   'important');
        b.style.setProperty('column-fill',   'auto',          'important');
        b.style.setProperty('height',        '100vh',         'important');
        b.style.setProperty('overflow-x',    'visible',       'important');
        b.style.setProperty('overflow-y',    'hidden',        'important');
        b.style.setProperty('margin',        '0',             'important');
        b.style.setProperty('padding',       '0',             'important');
        b.style.setProperty('box-sizing',    'content-box',   'important');
        b.style.setProperty('width',         window.innerWidth + 'px', 'important');
        b.style.setProperty('max-width',     'none',          'important');

        // Hide WebKit scrollbar — requires a stylesheet rule, not inline style.
        var styleId = '__ambrosia_col_style__';
        var existing = document.getElementById(styleId);
        if (existing) existing.parentNode.removeChild(existing);
        var st = document.createElement('style');
        st.id = styleId;
        st.textContent = 'html::-webkit-scrollbar { display: none !important; }';
        document.head.appendChild(st);

        // Prevent webkit margin-collapse bleeding above first column.
        b.style.setProperty('-webkit-margin-collapse', 'separate', 'important');

        // Remove break-before on the first element to avoid a blank leading column.
        var first = _firstElementChild(document.body);
        if (first) {
            first.style.setProperty('break-before', 'avoid', 'important');
            // Also handle the common AO3/EPUB pattern of a single wrapper div.
            if (first.tagName && first.tagName.toLowerCase() === 'div') {
                var inner = _firstElementChild(first);
                if (inner) inner.style.setProperty('break-before', 'avoid', 'important');
            }
        }
    };

    function _firstElementChild(parent) {
        var c = parent.firstChild;
        var limit = 20;
        while (c && limit-- > 0) {
            if (c.nodeType === Node.ELEMENT_NODE) return c;
            c = c.nextSibling;
        }
        return null;
    }

    // ─── Column arithmetic ───────────────────────────────────────────────────

    // Total number of columns the browser laid out for this spine item.
    window.ambrosiaColumnCount = function () {
        if (!_ready || _colAndGap === 0) return 1;
        // scrollWidth is the total inline size of the columnar content.
        // (scrollWidth + gap) / colAndGap gives an exact integer when layout
        // is working correctly. We floor to be safe.
        return Math.max(1, Math.floor(
            (document.documentElement.scrollWidth + _gap) / _colAndGap
        ));
    };

    // Zero-based index of the leftmost currently visible column.
    window.ambrosiaCurrentColumn = function () {
        if (!_ready || _colAndGap === 0) return 0;
        // Add a small bias (+2px) so a position at the exact left edge of
        // column N isn't rounded down to column N-1 by floating-point error.
        return Math.max(0, Math.floor((window.scrollX + 2) / _colAndGap));
    };

    // Snap-scroll to column n (zero-based). Clamps to [0, columnCount-1].
    window.ambrosiaScrollToColumn = function (n) {
        if (!_ready) return;
        var maxCol = window.ambrosiaColumnCount() - 1;
        var col    = Math.max(0, Math.min(n, maxCol));
        window.scrollTo({ left: col * _colAndGap, top: 0, behavior: 'instant' });
    };

    // ─── Progress fraction ───────────────────────────────────────────────────

    // Returns 0.0–1.0 representing how far through this spine item the reader is.
    // 1.0 means the last column is fully visible.
    window.ambrosiaProgressFraction = function () {
        var total = window.ambrosiaColumnCount();
        if (total <= 1) return 1.0;
        // Current column / (total - colsPerScreen) gives 1.0 when the last
        // screen-worth of columns is visible.
        var denom = total - _colsPerScreen;
        if (denom <= 0) return 1.0;
        return Math.min(1.0, window.ambrosiaCurrentColumn() / denom);
    };

    // Restore a saved fraction. Snaps to the nearest column boundary.
    window.ambrosiaScrollToFraction = function (frac) {
        if (!_ready) return;
        var total  = window.ambrosiaColumnCount();
        var denom  = total - _colsPerScreen;
        var col    = (denom > 0) ? Math.round(frac * denom) : 0;
        window.ambrosiaScrollToColumn(col);
    };

    // ─── Navigation (called from Swift key handler) ──────────────────────────
    //
    // Swift calls these directly via evaluateJavaScript after a keypress.
    // No debounce or repeat-suppression needed here — Swift guarantees
    // these are called at most once per physical keypress (see ReaderViewController).

    window.ambrosiaNextPage = function () {
        if (!_ready) return;
        var cur   = window.ambrosiaCurrentColumn();
        var total = window.ambrosiaColumnCount();
        var next  = cur + _colsPerScreen;

        if (next >= total) {
            // Past the last column — ask Swift to load the next spine item.
            _postPageAction('nextSpineItem');
            return;
        }

        window.ambrosiaScrollToColumn(next);
        _postPositionUpdate();
    };

    window.ambrosiaPrevPage = function () {
        if (!_ready) return;
        var cur = window.ambrosiaCurrentColumn();

        if (cur === 0) {
            // Already at column 0 — ask Swift to load the previous spine item.
            _postPageAction('prevSpineItem');
            return;
        }

        var prev = Math.max(0, cur - _colsPerScreen);
        window.ambrosiaScrollToColumn(prev);
        _postPositionUpdate();
    };

    function _postPageAction(action) {
        window.webkit.messageHandlers.pageAction.postMessage(
            JSON.stringify({ action: action })
        );
    }

    function _postPositionUpdate() {
        window.webkit.messageHandlers.positionUpdate.postMessage(
            JSON.stringify({
                fraction:     window.ambrosiaProgressFraction(),
                column:       window.ambrosiaCurrentColumn(),
                totalColumns: window.ambrosiaColumnCount()
            })
        );
    }

    // ─── Navigate to a char offset ───────────────────────────────────────────
    //
    // Used by TOC jumps, annotation restore, and bookmark navigation.
    // Inserts a zero-size marker span at the offset, reads its X position,
    // and snaps to the containing column.

    window.ambrosiaNavigateToOffset = function (charOffset) {
        if (!_ready) return;
        var pos = _nodeAtChar(charOffset);
        if (!pos) return;

        var range = document.createRange();
        range.setStart(pos.node, pos.localOffset);
        range.collapse(true);

        var marker = document.createElement('span');
        marker.style.cssText = 'display:inline;font-size:0;line-height:0;';
        range.insertNode(marker);

        var rect  = marker.getBoundingClientRect();
        var docX  = rect.left + window.scrollX;
        marker.parentNode.removeChild(marker);

        // Column containing this X position.
        var col = (_colAndGap > 0)
            ? Math.max(0, Math.floor((docX + _gap - 1) / _colAndGap))
            : 0;
        window.ambrosiaScrollToColumn(col);
        _postPositionUpdate();
    };

    // No-op in scroll mode — callers must not branch on reader mode (invariant).
    // When Ambrosia adds a scroll mode this would do a smooth scrollIntoView.
    // Defined here so callers always find the function regardless of mode.

    // ─── Highlight (find result / search) ───────────────────────────────────

    window.ambrosiaHighlight = function (offset) {
        var existing = document.getElementById('__ambrosia_highlight__');
        if (existing) existing.parentNode.removeChild(existing);

        var pos = _nodeAtChar(offset);
        if (!pos) return;

        var endOffset = Math.min(offset + 80, _countAllTextChars());
        var endPos    = _nodeAtChar(endOffset);
        if (!endPos) return;

        try {
            var range = document.createRange();
            range.setStart(pos.node, pos.localOffset);
            if (endPos.node === pos.node) {
                range.setEnd(endPos.node, endPos.localOffset);
            } else {
                range.setEndAfter(pos.node);
            }

            var span = document.createElement('span');
            span.id  = '__ambrosia_highlight__';
            span.style.cssText = [
                'background-color:rgba(255,214,10,0.55)',
                'border-radius:2px',
                'transition:opacity 1.5s ease',
                'opacity:1'
            ].join(';');

            range.surroundContents(span);

            // Navigate to the column containing the highlight before fading.
            window.ambrosiaNavigateToOffset(offset);

            setTimeout(function () {
                span.style.opacity = '0';
                setTimeout(function () {
                    if (span.parentNode) span.parentNode.removeChild(span);
                }, 1500);
            }, 500);
        } catch (e) {
            // surroundContents throws if range crosses element boundaries — ignore.
        }
    };

    // ─── Char offset utilities ───────────────────────────────────────────────

    window.ambrosiaTotalChars = _countAllTextChars;

    function _countAllTextChars() {
        var walker = document.createTreeWalker(
            document.body, NodeFilter.SHOW_TEXT, null
        );
        var total = 0, node;
        while ((node = walker.nextNode()) !== null) {
            total += node.length;   // UTF-16 code units per JS spec
        }
        return total;
    }

    // Returns { node, localOffset } or null.
    function _nodeAtChar(globalOffset) {
        var walker = document.createTreeWalker(
            document.body, NodeFilter.SHOW_TEXT, null
        );
        var remaining = globalOffset, node;
        while ((node = walker.nextNode()) !== null) {
            if (remaining <= node.length) {
                return { node: node, localOffset: remaining };
            }
            remaining -= node.length;
        }
        // Clamp to last text node if offset slightly exceeds total.
        return node ? { node: node, localOffset: node.length } : null;
    }

    // Global UTF-16 offset for a DOM node + local offset.
    // Called by HighlightBridge from JS selection events.
    window.ambrosiaCharOffset = function (node, localOffset) {
        var walker = document.createTreeWalker(
            document.body, NodeFilter.SHOW_TEXT, null
        );
        var count = 0, current;
        while ((current = walker.nextNode()) !== null) {
            if (current === node) return count + localOffset;
            count += current.length;
        }
        return count + localOffset;
    };

    })(); // end IIFE
    """#;
}
