import Foundation

// MARK: - PaginationJS
//
// Stores the complete JS pagination engine as a Swift string constant.
// Injected into the hidden layout WKWebView by PaginationEngine, and into
// the visible reader WKWebView by ReaderViewController (paginated mode).
//
// CHARACTER OFFSET INVARIANT (matches EPUBParser.plainText convention):
//   UTF-16 code units, text nodes only, HTML tags excluded.
//   This JS engine counts character positions by walking text nodes with
//   TreeWalker(NodeFilter.SHOW_TEXT) and summing node.length.
//   node.length is the UTF-16 code unit count in JavaScript, which matches
//   Swift's String.utf16.count. Never use node.textContent.length on the
//   body directly — that skips the per-node accumulation needed for offsets.
//
// EXPOSED GLOBALS (called from Swift via evaluateJavaScript):
//   window.ambrosiaPaginate(pageHeightPx)
//     → posts paginationResult: { boundaries: [{startChar, endChar}] }
//       or  paginationResult: { error: 'layout_not_ready' }
//   window.ambrosiaBuildPageHTML(startChar, endChar)
//     → returns a complete HTML document containing only that rendered range
//   window.ambrosiaRenderPage(startChar, endChar)
//     → legacy scroll/clipped renderer, kept for compatibility
//   window.ambrosiaHighlight(offset)
//     → 2-second yellow flash at offset position
//   window.ambrosiaTotalChars()
//     → returns total UTF-16 char count (for harness validation)

enum PaginationJS {

    static let script: String = """
    (function() {
    'use strict';

    // ─── Utility: count total UTF-16 chars in all text nodes ───────────────────

    function countAllTextChars() {
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var total = 0;
        var node;
        while ((node = walker.nextNode()) !== null) {
            total += node.length;  // UTF-16 code units per JS spec
        }
        return total;
    }
    window.ambrosiaTotalChars = countAllTextChars;

    // ─── Utility: find text node + local offset for a global char offset ───────

    // Returns { node, localOffset } or null if offset is beyond all text.
    function nodeAtChar(globalOffset) {
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var remaining = globalOffset;
        var node;
        while ((node = walker.nextNode()) !== null) {
            if (remaining <= node.length) {
                return { node: node, localOffset: remaining };
            }
            remaining -= node.length;
        }
        // Clamp to last text node if offset slightly exceeds total
        return node ? { node: node, localOffset: node.length } : null;
    }

    // ─── Utility: find sentence boundary ────────────────────────────────────────

    // Walks back from breakChar to find a sentence-ending punctuation
    // (.  !  ?  or newline), then returns the index after that punctuation.
    // Falls back to breakChar if no boundary is found within lookback chars.
    function findSentenceBoundary(globalOffset) {
        var LOOKBACK = 120;
        var start = Math.max(0, globalOffset - LOOKBACK);

        // Collect a slice of text around the potential break
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var chars = [];
        var cumulative = 0;
        var node;
        while ((node = walker.nextNode()) !== null) {
            var nodeEnd = cumulative + node.length;
            if (nodeEnd > start && cumulative < globalOffset) {
                var sliceStart = Math.max(0, start - cumulative);
                var sliceEnd   = Math.min(node.length, globalOffset - cumulative);
                var text = node.data.slice(sliceStart, sliceEnd);
                // Track absolute char positions
                for (var i = 0; i < text.length; i++) {
                    chars.push({ ch: text[i], abs: cumulative + sliceStart + i });
                }
            }
            cumulative = nodeEnd;
            if (cumulative >= globalOffset) break;
        }

        // Walk backward looking for sentence end
        for (var j = chars.length - 1; j >= 0; j--) {
            var c = chars[j].ch;
            if (c === '.' || c === '!' || c === '?' || c === '\\n') {
                return chars[j].abs + 1;  // position after the punctuation
            }
        }
        return globalOffset;  // no boundary found, use raw break
    }

    // ─── Core: ambrosiaPaginate ─────────────────────────────────────────────────

    window.ambrosiaPaginate = function(pageHeightPx) {
        // Safety: layout must be ready
        if (document.body.scrollHeight === 0) {
            window.webkit.messageHandlers.paginationResult.postMessage(
                JSON.stringify({ error: 'layout_not_ready' })
            );
            return;
        }

        // Temporarily make body full height so we can measure everything
        var origOverflow = document.body.style.overflow;
        var origHeight   = document.documentElement.style.height;
        document.body.style.overflow = 'visible';
        document.documentElement.style.height = 'auto';

        var boundaries = [];
        var totalChars = countAllTextChars();

        if (totalChars === 0) {
            window.webkit.messageHandlers.paginationResult.postMessage(
                JSON.stringify({ boundaries: [{ startChar: 0, endChar: 0 }] })
            );
            return;
        }

        var lineSafety = Math.max(4, Math.ceil(measuredLineHeight() * 0.5));
        var pageH = Math.max(1, pageHeightPx - lineSafety);
        var currentStartChar = 0;
        var safetyLimit = 5000;  // max pages — prevents infinite loop on malformed content
        var iterations = 0;

        while (currentStartChar < totalChars && iterations < safetyLimit) {
            iterations++;

            // Find candidate end char for this page using binary search
            var lo = currentStartChar;
            var hi = totalChars;
            var bestEnd = currentStartChar + 1;

            // Fast path: try a full page worth first
            // Average chars per page estimation: ~2000 chars as starting guess
            var guess = Math.min(totalChars, currentStartChar + 2000);
            var guessBottom = charToLineBottom(guess);

            // Binary search for the last char that fits within pageH
            var startTop = charToPageTop(currentStartChar);
            if (startTop === null) { break; }
            if (guessBottom !== null && guessBottom - startTop <= pageH) {
                lo = guess;
            }

            var bsIter = 0;
            while (lo < hi && bsIter < 30) {
                bsIter++;
                var mid = Math.floor((lo + hi + 1) / 2);
                var midBottom = charToLineBottom(mid);
                if (midBottom === null) { hi = mid - 1; continue; }
                if (midBottom - startTop <= pageH) {
                    lo = mid;
                    bestEnd = mid;
                } else {
                    hi = mid - 1;
                }
            }
            bestEnd = lo;

            // If we made no progress, advance by 1 to avoid infinite loop
            if (bestEnd <= currentStartChar) {
                bestEnd = currentStartChar + 1;
            }

            // Snap to sentence boundary (avoid breaking mid-sentence)
            if (bestEnd < totalChars) {
                bestEnd = findSentenceBoundary(bestEnd);
                // If boundary search went backwards past start, clamp
                if (bestEnd <= currentStartChar) { bestEnd = currentStartChar + 1; }
            }

            boundaries.push({ startChar: currentStartChar, endChar: bestEnd });
            currentStartChar = bestEnd;
        }

        // Ensure last page reaches totalChars exactly
        if (boundaries.length > 0) {
            boundaries[boundaries.length - 1].endChar = totalChars;
        } else {
            boundaries.push({ startChar: 0, endChar: totalChars });
        }

        // Restore body state
        document.body.style.overflow = origOverflow;
        document.documentElement.style.height = origHeight;

        window.webkit.messageHandlers.paginationResult.postMessage(
            JSON.stringify({ boundaries: boundaries })
        );
    };

    // Returns the top-of-viewport Y coordinate for a given char offset,
    // by inserting a zero-size marker span and measuring getBoundingClientRect.
    // Returns null if the position cannot be measured.
    function charToPageTop(charOffset) {
        var pos = nodeAtChar(charOffset);
        if (!pos) return null;

        var range = document.createRange();
        range.setStart(pos.node, pos.localOffset);
        range.collapse(true);

        var marker = document.createElement('span');
        marker.style.cssText = 'display:inline;font-size:0;line-height:0;';
        range.insertNode(marker);

        var rect = marker.getBoundingClientRect();
        var y = rect.top + window.scrollY;
        marker.parentNode.removeChild(marker);
        return y;
    }

    // Returns an estimated rendered line bottom for the text line containing
    // charOffset. Page breaks use this instead of marker top so the viewport
    // cannot clip through the lower half of glyphs on the final visible line.
    function charToLineBottom(charOffset) {
        var pos = nodeAtChar(charOffset);
        if (!pos) return null;

        var range = document.createRange();
        range.setStart(pos.node, pos.localOffset);
        range.collapse(true);

        var marker = document.createElement('span');
        marker.style.cssText = 'display:inline-block;width:0;height:1em;line-height:1;vertical-align:baseline;padding:0;margin:0;border:0;';
        range.insertNode(marker);

        var rect = marker.getBoundingClientRect();
        var y = rect.bottom + window.scrollY;
        marker.parentNode.removeChild(marker);
        return y;
    }

    function measuredLineHeight() {
        var style = window.getComputedStyle(document.body);
        var parsed = parseFloat(style.lineHeight);
        if (!isNaN(parsed) && parsed > 0) return parsed;

        var fontSize = parseFloat(style.fontSize);
        if (!isNaN(fontSize) && fontSize > 0) return fontSize * 1.4;
        return 24;
    }

    // ─── Core: ambrosiaRenderPage ───────────────────────────────────────────────

    window.ambrosiaRenderPage = function(startChar, endChar) {
        // Scroll to the position of startChar
        var pos = nodeAtChar(startChar);
        if (pos) {
            var range = document.createRange();
            range.setStart(pos.node, pos.localOffset);
            range.collapse(true);

            var marker = document.createElement('span');
            marker.id = '__ambrosia_page_marker__';
            marker.style.cssText = 'display:inline;font-size:0;line-height:0;';
            range.insertNode(marker);

            var rect = marker.getBoundingClientRect();
            var targetY = rect.top + window.scrollY;
            marker.parentNode.removeChild(marker);

            window.scrollTo(0, targetY);
        }

        // Hide overflow so only the current page is visible
        document.body.style.overflow = 'hidden';
        document.documentElement.style.overflow = 'hidden';

        // Store current page bounds for highlight restoration
        window._ambrosiaPageStart = startChar;
        window._ambrosiaPageEnd   = endChar;
    };

    // ─── Core: ambrosiaBuildPageHTML ───────────────────────────────────────────

    function escapeScriptString(value) {
        return String(value)
            .replace(/\\/g, '\\\\')
            .replace(/'/g, "\\'")
            .replace(/\\n/g, '\\n')
            .replace(/\\r/g, '\\r')
            .replace(/<\\/script/gi, '<\\\\/script');
    }

    window.ambrosiaBuildPageHTML = function(startChar, endChar, userCSS) {
        var start = Math.max(0, startChar);
        var end = Math.max(start, endChar);
        var total = countAllTextChars();
        start = Math.min(start, total);
        end = Math.min(end, total);

        var startPos = nodeAtChar(start);
        var endPos = nodeAtChar(end);
        if (!startPos || !endPos) return null;

        var range = document.createRange();
        range.setStart(startPos.node, startPos.localOffset);
        range.setEnd(endPos.node, endPos.localOffset);

        var fragment = range.cloneContents();
        var container = document.createElement('main');
        container.setAttribute('id', 'ambrosia-page');
        container.appendChild(fragment);

        var headHTML = document.head ? document.head.innerHTML : '';
        return [
            '<!DOCTYPE html>',
            '<html>',
            '<head>',
            headHTML,
            '<style>',
            userCSS || '',
            '</style>',
            '<script>',
            'window._ambrosiaPageStart = ' + start + ';',
            'window._ambrosiaPageEnd = ' + end + ';',
            'window._ambrosiaPageSource = \\'paginated-fragment\\';',
            '<\\/script>',
            '</head>',
            '<body>',
            container.outerHTML,
            '</body>',
            '</html>'
        ].join('');
    };

    // ─── Core: ambrosiaHighlight ────────────────────────────────────────────────

    window.ambrosiaHighlight = function(offset) {
        // Remove any existing highlight
        var existing = document.getElementById('__ambrosia_highlight__');
        if (existing) existing.parentNode.removeChild(existing);

        var pageStart = window._ambrosiaPageStart || 0;
        var pageEnd = window._ambrosiaPageEnd || Number.MAX_SAFE_INTEGER;
        var localOffset = offset - pageStart;
        if (offset < pageStart || offset > pageEnd) return;

        var pos = nodeAtChar(localOffset);
        if (!pos) return;

        // Find end of the sentence (up to 80 chars) for the highlight span
        var endOffset = Math.min(localOffset + 80, window.ambrosiaTotalChars());
        var endPos = nodeAtChar(endOffset);
        if (!endPos) return;

        try {
            var range = document.createRange();
            range.setStart(pos.node, pos.localOffset);
            // If same node, set end in same node
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

            // Fade out after 0.5s, remove after 2s
            setTimeout(function() {
                span.style.opacity = '0';
                setTimeout(function() {
                    if (span.parentNode) span.parentNode.removeChild(span);
                }, 1500);
            }, 500);
        } catch (e) {
            // surroundContents throws if range crosses element boundaries — ignore
        }
    };

    // ─── Char offset for a DOM node + local offset (used by HighlightBridge) ───

    window.ambrosiaCharOffset = function(node, localOffset) {
        var pageStart = window._ambrosiaPageStart || 0;
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var count = 0;
        var current;
        while ((current = walker.nextNode()) !== null) {
            if (current === node) return pageStart + count + localOffset;
            count += current.length;
        }
        return pageStart + count + localOffset;
    };

    })(); // end IIFE
    """;
}
