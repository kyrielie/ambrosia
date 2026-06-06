import Foundation
import WebKit

// MARK: - HighlightBridge
//
// Owns all JS ↔ Swift communication for text highlights.
//
// RESPONSIBILITIES:
//   - Inject the mouseup selection listener into the reader WKWebView (5A)
//   - Restore existing highlights for the current document as <span> elements (5B)
//
// CHARACTER OFFSET INVARIANT (matches EPUBParser.plainText and PaginationJS):
//   UTF-16 code units, text nodes only, HTML tags excluded.
//   The JS getCharOffset() function here uses the same TreeWalker/node.length
//   approach as PaginationJS.ambrosiaCharOffset(). Never use innerHTML.length.
//
// USAGE (from ReaderViewController, after webView didFinish):
//   HighlightBridge.injectSelectionListener(into: webView)
//   HighlightBridge.restoreHighlights(highlights, into: webView)
//
// Incoming message name: "highlightAdded"
// Payload: JSON { startChar, endChar, selectedText, spineIndex }
// Register handler in WKWebViewConfiguration before WebView init.

enum HighlightBridge {

    // MARK: - 5A: Selection listener JS

    /// JS injected after every page load.
    /// Posts "highlightAdded" when the user releases the mouse over a non-empty selection.
    static let selectionListenerJS: String = """
    (function() {
        // Guard: only install once
        if (window.__ambrosiaHighlightListenerInstalled) return;
        window.__ambrosiaHighlightListenerInstalled = true;

        function getCharOffset(node, localOffset) {
            // UTF-16 code units, text nodes only — matches EPUBParser.plainText convention.
            // node.length is the UTF-16 length in JS (same as Swift's utf16.count).
            var walker = document.createTreeWalker(
                document.body, NodeFilter.SHOW_TEXT, null
            );
            var count = 0;
            var current;
            while ((current = walker.nextNode()) !== null) {
                if (current === node) return count + localOffset;
                count += current.length;
            }
            return count + localOffset;
        }

        document.addEventListener('mouseup', function() {
            var sel = window.getSelection();
            if (!sel || sel.isCollapsed || sel.toString().trim().length === 0) return;

            var range = sel.getRangeAt(0);
            var startChar = getCharOffset(range.startContainer, range.startOffset);
            var endChar   = getCharOffset(range.endContainer,   range.endOffset);

            // spineIndex is set by EPUBParser.sanitise() via a <script> tag in each
            // individual spine item, or is 0 for merged-HTML scroll mode.
            var spineIndex = window.currentSpineIndex || 0;

            window.webkit.messageHandlers.highlightAdded.postMessage(JSON.stringify({
                startChar:    startChar,
                endChar:      endChar,
                selectedText: sel.toString(),
                spineIndex:   spineIndex
            }));
        });
    })();
    """

    /// Injects the selection listener into a WKWebView.
    /// Safe to call multiple times — the JS guards against double installation.
    static func injectSelectionListener(into webView: WKWebView) {
        webView.evaluateJavaScript(selectionListenerJS, completionHandler: nil)
    }

    // MARK: - 5B: Restore highlights

    /// JS template: wraps the character range [startChar, endChar) in a highlight <span>.
    /// Uses the same TreeWalker pattern as getCharOffset but in reverse (seek-and-wrap).
    private static func restoreHighlightJS(startChar: Int, endChar: Int,
                                            colorHex: String, highlightID: String) -> String {
        // language=JavaScript
        return """
        (function() {
            var startChar = \(startChar);
            var endChar   = \(endChar);
            var color     = '\(colorHex)';
            var hid       = '\(highlightID)';

            // Already restored?
            if (document.getElementById('hl-' + hid)) return;

            function nodeAtChar(target) {
                var walker = document.createTreeWalker(
                    document.body, NodeFilter.SHOW_TEXT, null
                );
                var remaining = target;
                var node;
                while ((node = walker.nextNode()) !== null) {
                    if (remaining <= node.length) {
                        return { node: node, offset: remaining };
                    }
                    remaining -= node.length;
                }
                return node ? { node: node, offset: node.length } : null;
            }

            var startPos = nodeAtChar(startChar);
            var endPos   = nodeAtChar(endChar);
            if (!startPos || !endPos) return;

            try {
                var range = document.createRange();
                range.setStart(startPos.node, startPos.offset);
                range.setEnd(endPos.node,   endPos.offset);

                var span = document.createElement('span');
                span.id = 'hl-' + hid;
                span.setAttribute('data-ambrosia-highlight', '1');
                span.style.cssText = [
                    'background-color: ' + color + '80',  // 50% opacity via hex alpha
                    'border-radius: 2px',
                    'cursor: text'
                ].join(';');

                range.surroundContents(span);
            } catch(e) {
                // surroundContents throws if range crosses element boundaries.
                // In that case, fall back to marking start node only.
                try {
                    var fallbackRange = document.createRange();
                    fallbackRange.setStart(startPos.node, startPos.offset);
                    fallbackRange.setEndAfter(startPos.node);
                    var span2 = document.createElement('span');
                    span2.id = 'hl-' + hid + '-fb';
                    span2.setAttribute('data-ambrosia-highlight', '1');
                    span2.style.cssText = 'background-color: ' + color + '80; border-radius: 2px;';
                    fallbackRange.surroundContents(span2);
                } catch(e2) { /* give up silently */ }
            }
        })();
        """
    }

    /// Injects highlight spans for all highlights that belong to the current document.
    /// In scroll mode (merged HTML, spineIndex == 0 for all), pass all highlights.
    /// In paginated mode per-spine, filter by spineIndex before calling.
    static func restoreHighlights(_ highlights: [Highlight], into webView: WKWebView) {
        guard !highlights.isEmpty else { return }
        for h in highlights {
            let js = restoreHighlightJS(
                startChar:   h.startChar,
                endChar:     h.endChar,
                colorHex:    h.colorHex,
                highlightID: h.id.uuidString.replacingOccurrences(of: "-", with: "")
            )
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - Incoming message decoding

    /// Decodes a "highlightAdded" WKScriptMessage body into a Highlight struct.
    /// Returns nil if the payload is malformed or the selection is degenerate.
    static func decodeHighlight(from message: WKScriptMessage) -> Highlight? {
        guard message.name == "highlightAdded",
              let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let startChar    = json["startChar"]    as? Int,
              let endChar      = json["endChar"]      as? Int,
              let selectedText = json["selectedText"] as? String,
              endChar > startChar,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let spineIndex = json["spineIndex"] as? Int ?? 0

        return Highlight(
            spineIndex:   spineIndex,
            startChar:    startChar,
            endChar:      endChar,
            selectedText: selectedText
        )
    }
}
