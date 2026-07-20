import Foundation

// MARK: - PaginationJS
//
// JS pagination engine for horizontal CSS multi-column paged mode.
//
// ARCHITECTURE — CSS pre-loaded, JS reads geometry back:
//   Column layout CSS (see ReaderPreferences.paginatedColumnCSS) is baked into
//   the HTML string before it is handed to WKWebView.loadHTMLString, so the
//   browser never renders an un-paginated flash. This file does not compute or
//   receive column geometry from Swift; it reads colWidth/colGap back from
//   getComputedStyle(document.documentElement) after the CSS has already been
//   applied and layout has settled. See invariant 4 in the build plan.
//
//   Columns live on :root (`html`), not `body`. `html` is simultaneously the
//   column container and the scroll container, so window.scrollX maps
//   directly to column position.
//
// CHARACTER OFFSET INVARIANT (unchanged):
//   UTF-16 code units, text nodes only, HTML tags excluded.
//   TreeWalker(NodeFilter.SHOW_TEXT), node.length = UTF-16 code unit count.
//
// EXPOSED GLOBALS (called from Swift via evaluateJavaScript):
//
//   window.ambrosiaSetup(colsPerScreen)
//     Read column metrics back from computed style and store them.
//     Call once after loadHTMLString completes (didFinish navigation).
//
//   window.ambrosiaColumnCount()      → Int
//   window.ambrosiaCurrentColumn()    → Int
//   window.ambrosiaScrollToColumn(n)
//   window.ambrosiaScrollToFraction(frac)
//   window.ambrosiaProgressFraction() → Double 0–1
//   window.ambrosiaNavigateToOffset(charOffset)
//   window.ambrosiaScrollToAnchor(id)
//   window.ambrosiaHighlight(offset)
//   window.ambrosiaPaginationMetrics() → JSON string, read once by Swift after setup
//
// MESSAGES POSTED TO SWIFT (via window.webkit.messageHandlers.*):
//
//   pageAction  { action: 'nextSpineItem' | 'prevSpineItem' }
//   positionUpdate  { fraction: Double, column: Int, totalColumns: Int }
//
// KEYSTROKES: handled entirely in Swift (ReaderViewController).
//   JS does not install any keydown listeners.
//
// The script is assembled from several fileprivate chunks below rather than
// one long literal, so PaginationJS's enum body stays under SwiftLint's
// type_body_length limit. The chunks are concatenated in order and form a
// single IIFE; they are not meaningful Swift APIs on their own.

enum PaginationJS {

    static let script: String = _pjsSetupAndColumnCount + _pjsScrollAndPaging
        + _pjsNavigateAndHighlight + _pjsMetricsAndHelpers
}

// MARK: - Setup, column count, current column

private let _pjsSetupAndColumnCount: String = #"""
    (function () {
    'use strict';

    // ─── Layout metrics (read from computed style, not from Swift) ────────────

    var _colAndGap     = 0;
    var _colsPerScreen = 1;
    var _ready         = false;

    // ─── Setup ────────────────────────────────────────────────────────────────
    //
    // Called once after didFinish. colsPerScreen is the only value Swift needs
    // to pass — everything else is read from the already-applied CSS.

    window.ambrosiaSetup = function (colsPerScreen) {
        _colsPerScreen = colsPerScreen || 1;

        // Read the column width and gap from computed style on :root.
        // These are set by the pre-loaded CSS, so they are already correct.
        var cs = window.getComputedStyle(document.documentElement);
        var colWidth = parseFloat(cs.columnWidth) || window.innerWidth;
        var colGap   = parseFloat(cs.columnGap)   || 0;
        _colAndGap   = colWidth + colGap;

        if (_colAndGap <= 0) {
            // Fallback: divide viewport by colsPerScreen
            _colAndGap = window.innerWidth / _colsPerScreen;
        }

        _ready = true;
        window._colAndGap = _colAndGap;

        console.log('[ambrosiaSetup] colWidth=' + colWidth + ' colGap=' + colGap +
            ' colAndGap=' + _colAndGap + ' scrollWidth=' + document.documentElement.scrollWidth +
            ' clientWidth=' + document.documentElement.clientWidth +
            ' paddingLeft=' + cs.paddingLeft + ' paddingRight=' + cs.paddingRight +
            ' innerWidth=' + window.innerWidth +
            ' devicePixelRatio=' + window.devicePixelRatio +
            ' htmlRect=' + JSON.stringify(document.documentElement.getBoundingClientRect()));

        // Prevent margin-collapse from creating a blank leading column.
        var first = _firstElementChild(document.body);
        if (first) {
            first.style.setProperty('break-before', 'avoid', 'important');
            if (first.tagName && first.tagName.toLowerCase() === 'div') {
                var inner = _firstElementChild(first);
                if (inner) inner.style.setProperty('break-before', 'avoid', 'important');
            }
        }
    };

    function _firstElementChild(parent) {
        var c = parent ? parent.firstChild : null, limit = 20;
        while (c && limit-- > 0) {
            if (c.nodeType === 1) return c;
            c = c.nextSibling;
        }
        return null;
    }

    // ─── Column count ──────────────────────────────────────────────────────────
    //
    // scrollWidth on :root is authoritative when columns are on :root, with
    // one caveat introduced when the horizontal reading margin moved onto
    // `html` (see ReaderPreferences.paginatedColumnCSS, "Fix: move the
    // horizontal margin OFF body entirely and onto `html`"): `html` is now
    // BOTH the padding host and the scrolling/column element this function
    // measures. scrollWidth on a scrolling box with overflowing content
    // reliably includes the box's *leading* padding, but WebKit does not
    // count the *trailing* padding once content overflows past it. Before
    // that CSS change, `html` had no padding at all, so raw scrollWidth was
    // exactly `n*colAndGap - gap` and the formula below could use it
    // directly. Now it is `padLeft + (n*colAndGap - gap)` (or possibly
    // `padLeft + padRight + ...` if this WebKit version does count the
    // trailing edge — see the diagnostic log below), which inflates the
    // computed total and can strand the reader on a phantom trailing
    // column that never satisfies `next >= total` in ambrosiaNextPage.
    // Subtract the leading padding back out before dividing.

    window.ambrosiaColumnCount = function () {
        if (!_ready || _colAndGap <= 0) return 1;
        var cs       = window.getComputedStyle(document.documentElement);
        var gap      = parseFloat(cs.columnGap)    || 0;
        var padLeft  = parseFloat(cs.paddingLeft)  || 0;
        var padRight = parseFloat(cs.paddingRight) || 0;
        var swRaw    = document.documentElement.scrollWidth;
        var sw       = swRaw - padLeft;

        var total = Math.max(1, Math.round((sw + gap) / _colAndGap));

        // DIAGNOSTIC: if the leading-padding-only hypothesis above is wrong
        // (e.g. this WebKit version counts trailing padding too, or counts
        // neither), the three candidate totals below will disagree. If
        // next-spine problems persist after this fix, check the console for
        // this line: whichever candidate matches the actually-correct page
        // count (count real pages by eye and compare) tells us which
        // padding-counting model this WebKit build actually uses, and `sw`
        // above should be changed to match (swRaw, swRaw - padLeft, or
        // swRaw - padLeft - padRight).
        var totalNoSub   = Math.max(1, Math.round((swRaw + gap) / _colAndGap));
        var totalSubBoth = Math.max(1, Math.round((swRaw - padLeft - padRight + gap) / _colAndGap));
        if (totalNoSub !== total || total !== totalSubBoth) {
            console.log('[ambrosiaColumnCount] DIAGNOSTIC candidates disagree' +
                ' swRaw=' + swRaw + ' padLeft=' + padLeft + ' padRight=' + padRight +
                ' gap=' + gap + ' colAndGap=' + _colAndGap +
                ' total(noSub)=' + totalNoSub +
                ' total(subLeftOnly, IN USE)=' + total +
                ' total(subBoth)=' + totalSubBoth);
        }

        return total;
    };

    // ─── Current column ───────────────────────────────────────────────────────
    //
    // Uses round(), not floor(), on scrollX / colAndGap. Rationale: html now
    // carries the horizontal reading margin as its own padding (see
    // ReaderPreferences.paginatedColumnCSS) and is also the scrolling
    // element. Because scrollWidth undercounts the trailing padding, the
    // browser's native max-scroll clamp (scrollWidth - clientWidth) can land
    // short of the ideal i*colAndGap grid position for the LAST column by an
    // amount that depends on padding/gap — 24px in one observed trace. A
    // fixed small bias (previously +2px under floor) can't absorb that; it
    // silently floors the clamped position down to the second-to-last
    // column, which makes ambrosiaNextPage's `next >= total` check never
    // trigger and strands the reader (page-turn does nothing, forever).
    // round() tolerates that shortfall (as long as it's under half a pitch)
    // while still resolving exactly at on-grid positions (0, colAndGap,
    // 2*colAndGap, ...), which is the only place this function is ever
    // called with in normal (non-clamped) navigation.

    window.ambrosiaCurrentColumn = function () {
        if (!_ready || _colAndGap <= 0) return 0;
        var floored = Math.floor((window.scrollX + 2) / _colAndGap);
        var rounded = Math.round(window.scrollX / _colAndGap);
        if (floored !== rounded) {
            console.log('[ambrosiaCurrentColumn] DIAGNOSTIC floor/round disagree' +
                ' scrollX=' + window.scrollX + ' colAndGap=' + _colAndGap +
                ' floor(IN USE PREVIOUSLY)=' + floored + ' round(IN USE NOW)=' + rounded +
                ' shortfall_px=' + (window.scrollX - rounded * _colAndGap));
        }
        return Math.max(0, rounded);
    };
    """#

// MARK: - Scroll to column, progress fraction, page navigation

private let _pjsScrollAndPaging: String = #"""

    // ─── Scroll to column n ───────────────────────────────────────────────────

    window.ambrosiaScrollToColumn = function (n) {
        if (!_ready) return;
        var max = window.ambrosiaColumnCount() - 1;
        var col = Math.max(0, Math.min(Math.round(n), max));
        var target = col * _colAndGap;
        window.scrollTo({ left: target, top: 0, behavior: 'instant' });

        // WebKit undercounts html's trailing padding-right in scrollWidth once
        // content overflows (see ambrosiaColumnCount comment above), so the
        // native scroll clamp can land short of `target` — visible only on the
        // terminal column of a spine, where target actually reaches that edge.
        // Measure the real shortfall (don't assume it equals marginH — a
        // partially filled final screen at colsPerScreen > 1 can add more) and
        // compensate visually by shifting the multicol container itself.
        // html is the unfragmented column container (unlike body, which gets
        // fragmented per-column) so this is a pure repaint offset, not a relayout.
        var shortfall = target - window.scrollX;
        document.documentElement.style.transform = shortfall > 0
            ? 'translateX(-' + shortfall + 'px)'
            : '';

        console.log('[ambrosiaScrollToColumn] requested=' + n + ' clamped=' + col +
            ' target=' + target + ' actualScrollX=' + window.scrollX +
            ' delta=' + (window.scrollX - target) + ' shortfall=' + shortfall);
    };

    // ─── Progress fraction (0–1) ──────────────────────────────────────────────

    window.ambrosiaProgressFraction = function () {
        var total = window.ambrosiaColumnCount();
        if (total <= _colsPerScreen) return 1.0;
        var denom = total - _colsPerScreen;
        return Math.min(1.0, window.ambrosiaCurrentColumn() / denom);
    };

    window.ambrosiaScrollToFraction = function (frac) {
        if (!_ready) return;
        var total = window.ambrosiaColumnCount();
        var denom = total - _colsPerScreen;
        var col   = denom > 0 ? Math.round(Math.max(0, Math.min(1, frac)) * denom) : 0;
        window.ambrosiaScrollToColumn(col);
    };

    // ─── Page navigation ──────────────────────────────────────────────────────

    window.ambrosiaNextPage = function () {
        if (!_ready) return;
        var cur   = window.ambrosiaCurrentColumn();
        var total = window.ambrosiaColumnCount();
        var next  = cur + _colsPerScreen;
        console.log('[ambrosiaNextPage] cur=' + cur + ' total=' + total +
            ' next=' + next + ' scrollX=' + window.scrollX);
        if (next >= total) {
            _postPageAction('nextSpineItem');
            return;
        }
        window.ambrosiaScrollToColumn(next);
        _postPositionUpdate();
    };

    window.ambrosiaPrevPage = function () {
        if (!_ready) return;
        var cur = window.ambrosiaCurrentColumn();
        console.log('[ambrosiaPrevPage] cur=' + cur + ' scrollX=' + window.scrollX);
        if (cur === 0) {
            _postPageAction('prevSpineItem');
            return;
        }
        window.ambrosiaScrollToColumn(Math.max(0, cur - _colsPerScreen));
        _postPositionUpdate();
    };
    """#

// MARK: - Navigate to char offset, scroll to anchor, highlight flash

private let _pjsNavigateAndHighlight: String = #"""

    // ─── Navigate to char offset ──────────────────────────────────────────────
    //
    // Inserts a zero-size marker at the UTF-16 char offset, reads its X position,
    // and snaps to the containing column. Consistent with HighlightBridge's
    // offset convention: UTF-16 code units, text nodes only.

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
        var docX = marker.getBoundingClientRect().left + window.scrollX;
        marker.parentNode.removeChild(marker);
        var col = _colAndGap > 0 ? Math.max(0, Math.floor(docX / _colAndGap)) : 0;
        window.ambrosiaScrollToColumn(col);
        _postPositionUpdate();
    };

    window.ambrosiaScrollToAnchor = function (id) {
        if (!_ready) return;
        var el = document.getElementById(id)
              || document.querySelector('[name="' + id + '"]');
        if (!el) return;
        var docX = el.getBoundingClientRect().left + window.scrollX;
        var col = _colAndGap > 0 ? Math.max(0, Math.floor(docX / _colAndGap)) : 0;
        window.ambrosiaScrollToColumn(col);
        _postPositionUpdate();
    };

    // ─── Highlight (find / bookmark flash) ───────────────────────────────────

    window.ambrosiaHighlight = function (offset) {
        var existing = document.getElementById('__ambrosia_highlight__');
        if (existing) existing.parentNode.removeChild(existing);
        var pos = _nodeAtChar(offset);
        if (!pos) return;
        var endPos = _nodeAtChar(Math.min(offset + 80, _countAllChars()));
        if (!endPos) return;
        try {
            var range = document.createRange();
            range.setStart(pos.node, pos.localOffset);
            if (endPos.node === pos.node) range.setEnd(endPos.node, endPos.localOffset);
            else range.setEndAfter(pos.node);
            var span = document.createElement('span');
            span.id = '__ambrosia_highlight__';
            span.style.cssText =
                'background-color:rgba(255,214,10,0.55);border-radius:2px;transition:opacity 1.5s;opacity:1;';
            range.surroundContents(span);
            window.ambrosiaNavigateToOffset(offset);
            setTimeout(function () {
                span.style.opacity = '0';
                setTimeout(function () { if (span.parentNode) span.parentNode.removeChild(span); }, 1500);
            }, 500);
        } catch (e) { /* surroundContents throws across element boundaries — ignore */ }
    };
    """#

// MARK: - Metrics, internal helpers, IIFE close

private let _pjsMetricsAndHelpers: String = #"""

    // ─── Metrics (used by Swift to read column count after load) ─────────────

    window.ambrosiaPaginationMetrics = function () {
        return JSON.stringify({
            colAndGap: _colAndGap,
            colsPerScreen: _colsPerScreen,
            scrollWidth: document.documentElement.scrollWidth,
            innerWidth: window.innerWidth,
            columns: window.ambrosiaColumnCount(),
            ready: _ready
        });
    };

    // ─── Internal helpers ─────────────────────────────────────────────────────

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

    function _countAllChars() {
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var n, total = 0;
        while ((n = walker.nextNode()) !== null) total += n.length;
        return total;
    }

    function _nodeAtChar(globalOffset) {
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var rem = globalOffset, n;
        while ((n = walker.nextNode()) !== null) {
            if (rem <= n.length) return { node: n, localOffset: rem };
            rem -= n.length;
        }
        return n ? { node: n, localOffset: n.length } : null;
    }

    // Global UTF-16 offset for a DOM node + local offset.
    // Called by HighlightBridge from JS selection events.
    window.ambrosiaCharOffset = function (node, localOffset) {
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var count = 0, current;
        while ((current = walker.nextNode()) !== null) {
            if (current === node) return count + localOffset;
            count += current.length;
        }
        return count + localOffset;
    };

    })();
    """#
