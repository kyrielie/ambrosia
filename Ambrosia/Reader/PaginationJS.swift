import Foundation

// MARK: - PaginationJS
//
// JavaScript injected into the visible WKWebView in paginated mode.
//
// DESIGN (CSS-columns approach):
//   Pagination is handled entirely by the browser's CSS multi-column layout,
//   configured via PaginationEngine.columnCSS(). This file provides only the
//   helper functions that Swift calls via evaluateJavaScript for:
//     - position save/restore (charOffset ↔ pageIndex conversion)
//     - annotation highlight restoration
//     - the transient "jump" highlight flash
//     - text selection offset capture (unchanged from scroll mode)
//
// CHARACTER OFFSET INVARIANT (unchanged from previous architecture):
//   UTF-16 code units, text nodes only, HTML tags excluded.
//   JS node.length is UTF-16 code units — matches Swift String.utf16.count.
//   window._ambrosiaPageStart is always 0 in this architecture (full document
//   is loaded; no per-page HTML fragment). It is kept for HighlightBridge
//   compatibility so that code needs no changes.
//
// EXPOSED GLOBALS:
//   window.ambrosiaTotalChars()
//     → total UTF-16 char count across all text nodes
//   window.ambrosiaHighlight(globalOffset)
//     → 2-second yellow flash at offset; used after page restore
//   window.ambrosiaCharOffset(node, localOffset)
//     → global char offset for a DOM node + local offset (used by HighlightBridge)
//   window.ambrosiaScrollLeft()
//     → current document.documentElement.scrollLeft (page position)
//
// REMOVED globals (no longer needed with CSS columns):
//   window.ambrosiaPaginate()       — columns are native; no JS measurement loop
//   window.ambrosiaBuildPageHTML()  — no per-page HTML fragments
//   window.ambrosiaRenderPage()     — no scroll-and-clip; replaced by scrollLeft

enum PaginationJS {

    static let script: String = """
    (function() {
    'use strict';

    // Set page start/end to sentinel values — in the CSS columns architecture the
    // full document is always loaded, so all global offsets are local offsets.
    // HighlightBridge reads these and offsets by pageStart; keeping them at 0 /
    // MAX_SAFE_INTEGER ensures its math is a no-op and no changes are needed there.
    window._ambrosiaPageStart = 0;
    window._ambrosiaPageEnd   = Number.MAX_SAFE_INTEGER;

    // ─── Total char count ──────────────────────────────────────────────────────

    function countAllTextChars() {
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var total = 0, node;
        while ((node = walker.nextNode()) !== null) {
            total += node.length;
        }
        return total;
    }
    window.ambrosiaTotalChars = countAllTextChars;

    // ─── Node lookup by global offset ─────────────────────────────────────────

    function nodeAtChar(globalOffset) {
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var remaining = globalOffset, node;
        while ((node = walker.nextNode()) !== null) {
            if (remaining <= node.length) return { node: node, localOffset: remaining };
            remaining -= node.length;
        }
        return node ? { node: node, localOffset: node.length } : null;
    }

    // ─── ambrosiaHighlight ─────────────────────────────────────────────────────
    // Inserts a yellow flash span at `offset` for 2 seconds, then fades out.
    // Used after navigating to a page via jumpToAnnotation or repagination restore.

    window.ambrosiaHighlight = function(offset) {
        var existing = document.getElementById('__ambrosia_highlight__');
        if (existing) existing.parentNode.removeChild(existing);

        var pos = nodeAtChar(offset);
        if (!pos) return;

        var endPos = nodeAtChar(Math.min(offset + 80, countAllTextChars()));
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
            span.id = '__ambrosia_highlight__';
            span.style.cssText = [
                'background-color: rgba(255, 214, 10, 0.55)',
                'border-radius: 2px',
                'transition: opacity 1.5s ease',
                'opacity: 1'
            ].join(';');

            range.surroundContents(span);

            setTimeout(function() {
                span.style.opacity = '0';
                setTimeout(function() {
                    if (span.parentNode) span.parentNode.removeChild(span);
                }, 1500);
            }, 500);
        } catch (e) {
            // surroundContents throws across element boundaries — harmless
        }
    };

    // ─── ambrosiaCharOffset ────────────────────────────────────────────────────
    // Used by HighlightBridge's selection listener JS to convert a DOM node +
    // local offset to a global UTF-16 char offset.
    // pageStart is always 0 here but kept for API compatibility.

    window.ambrosiaCharOffset = function(node, localOffset) {
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var count = 0, current;
        while ((current = walker.nextNode()) !== null) {
            if (current === node) return count + localOffset;
            count += current.length;
        }
        return count + localOffset;
    };

    // ─── ambrosiaScrollLeft ────────────────────────────────────────────────────
    // Convenience accessor so Swift can read scrollLeft via evaluateJavaScript
    // without hardcoding a JS snippet in multiple places.

    window.ambrosiaScrollLeft = function() {
        return document.documentElement.scrollLeft;
    };

    // ─── Legacy stubs (kept so any residual call sites don't throw) ───────────
    // These were part of the old TreeWalker-based pagination engine and are no
    // longer called by ReaderViewController. They are retained as no-ops only to
    // prevent ReferenceErrors if any stale evaluateJavaScript call survives a
    // future merge.

    window.ambrosiaPaginate      = function() {};
    window.ambrosiaRenderPage    = function() {};
    window.ambrosiaBuildPageHTML = function() { return null; };

    })(); // end IIFE
    """;
}
