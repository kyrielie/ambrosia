import Foundation
import WebKit

// MARK: - HighlightBridge

enum HighlightBridge {

    // MARK: - Selection listener JS

    static let selectionListenerJS: String = """
    (function() {
        if (window.__ambrosiaHighlightListenerInstalled) return;
        window.__ambrosiaHighlightListenerInstalled = true;

        function getCharOffset(node, localOffset) {
            var pageStart = window._ambrosiaPageStart || 0;
            var walker = document.createTreeWalker(
                document.body, NodeFilter.SHOW_TEXT, null
            );
            var count = 0, current;
            while ((current = walker.nextNode()) !== null) {
                if (current === node) return pageStart + count + localOffset;
                count += current.length;
            }
            return pageStart + count + localOffset;
        }

        document.addEventListener('mouseup', function(e) {
            var sel = window.getSelection();
            if (!sel || sel.isCollapsed || sel.toString().trim().length === 0) return;

            var range = sel.getRangeAt(0);
            var startChar  = getCharOffset(range.startContainer, range.startOffset);
            var endChar    = getCharOffset(range.endContainer,   range.endOffset);
            var spineIndex = window.currentSpineIndex || 0;

            // Cursor position at mouseup: clientX/Y is viewport-relative.
            // Pass pageY (= clientY + scrollY) so Swift can convert correctly
            // regardless of scroll position at the time the menu item fires.
            var cursorX = e.clientX;
            var cursorPageY = e.clientY + window.scrollY;

            window.__ambrosiaPendingAnnotation = {
                startChar: startChar, endChar: endChar,
                selectedText: sel.toString(), spineIndex: spineIndex
            };

            window.webkit.messageHandlers.highlightAdded.postMessage(JSON.stringify({
                startChar: startChar, endChar: endChar,
                selectedText: sel.toString(), spineIndex: spineIndex,
                cursorX: cursorX, cursorPageY: cursorPageY
            }));
        });
    })();
    """

    static func injectSelectionListener(into webView: WKWebView) {
        webView.evaluateJavaScript(selectionListenerJS, completionHandler: nil)
    }

    // MARK: - Restore highlights (sorted longest-first, overlap detection)

    static func restoreHighlights(_ annotations: [Annotation], into webView: WKWebView) {
        guard !annotations.isEmpty else { return }
        let sorted = annotations.sorted { ($0.endChar - $0.startChar) > ($1.endChar - $1.startChar) }
        var renderedRanges: [(start: Int, end: Int)] = []
        var overlapping: Set<UUID> = []
        for annotation in sorted {
            let s = annotation.startChar, e = annotation.endChar
            if renderedRanges.contains(where: { r in s < r.end && e > r.start }) {
                overlapping.insert(annotation.id)
            }
            renderedRanges.append((s, e))
        }
        for annotation in sorted {
            let js = restoreHighlightJS(annotation: annotation,
                                        useUnderline: overlapping.contains(annotation.id))
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // FIX 2: Multi-node wrap replaces surroundContents.
    // Collects all text nodes in [startChar, endChar), splits the boundary nodes,
    // and wraps each segment in its own span with the same id-prefix + "-N" suffix.
    // This works correctly across <em>, <strong>, <p>, <br> and any other element boundary.
    private static func restoreHighlightJS(annotation: Annotation, useUnderline: Bool) -> String {
        let startChar   = annotation.startChar
        let endChar     = annotation.endChar
        let colorHex    = annotation.colorHex
        let highlightID = annotation.id.uuidString.replacingOccurrences(of: "-", with: "")
        let hasNote     = (annotation.note ?? "").isEmpty == false
        let hasNoteJS   = hasNote ? "true" : "false"
        let useUnderJS  = useUnderline ? "true" : "false"

        return """
        (function() {
            var startChar    = \(startChar);
            var endChar      = \(endChar);
            var color        = '\(colorHex)';
            var hid          = '\(highlightID)';
            var hasNote      = \(hasNoteJS);
            var useUnderline = \(useUnderJS);
            var pageStart    = window._ambrosiaPageStart || 0;
            var pageEnd      = window._ambrosiaPageEnd || Number.MAX_SAFE_INTEGER;

            if (endChar <= pageStart || startChar >= pageEnd) return;
            startChar = Math.max(startChar, pageStart) - pageStart;
            endChar = Math.min(endChar, pageEnd) - pageStart;
            if (endChar <= startChar) return;

            if (document.getElementById('hl-' + hid + '-0')) return;
            if (document.getElementById('hl-' + hid)) return;

            // ── Collect all text nodes with their cumulative char offsets ──────
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
            var nodes = [], offsets = [], cum = 0, node;
            while ((node = walker.nextNode()) !== null) {
                nodes.push(node);
                offsets.push(cum);
                cum += node.length;
            }

            // ── Find which text nodes fall inside [startChar, endChar) ─────────
            var segments = []; // {node, from, to} in node-local offsets
            for (var i = 0; i < nodes.length; i++) {
                var nStart = offsets[i];
                var nEnd   = offsets[i] + nodes[i].length;
                if (nEnd <= startChar) continue;
                if (nStart >= endChar)  break;
                segments.push({
                    node: nodes[i],
                    from: Math.max(0,          startChar - nStart),
                    to:   Math.min(nodes[i].length, endChar   - nStart)
                });
            }
            if (segments.length === 0) return;

            // ── CSS for highlight spans ───────────────────────────────────────
            function spanCSS() {
                if (useUnderline) {
                    return [
                        'text-decoration: underline',
                        'text-decoration-color: ' + color,
                        'text-decoration-thickness: 2px',
                        'text-underline-offset: 2px',
                        'cursor: ' + (hasNote ? 'pointer' : 'text')
                    ].join(';');
                }
                return [
                    'background-color: ' + color + '80',
                    'border-radius: 2px',
                    'cursor: ' + (hasNote ? 'pointer' : 'text')
                ].join(';');
            }

            // ── Wrap each segment in its own span ─────────────────────────────
            for (var si = 0; si < segments.length; si++) {
                var seg    = segments[si];
                var txtNode = seg.node;
                var parent  = txtNode.parentNode;
                if (!parent) continue;

                // Split text node at boundaries
                var before = seg.from > 0          ? txtNode.splitText(seg.from) : txtNode;
                // 'before' is now the target slice starting at seg.from
                var after  = (seg.to - seg.from) < before.length
                             ? before.splitText(seg.to - seg.from)
                             : null;
                // 'before' is exactly the text we want to wrap

                var span = document.createElement('span');
                // Primary span gets base id; segments get -0, -1 … suffix
                span.id = 'hl-' + hid + (segments.length === 1 ? '' : '-' + si);
                span.setAttribute('data-ambrosia-highlight', '1');
                span.setAttribute('data-hl-base', hid);
                span.style.cssText = spanCSS();

                if (hasNote) {
                    span.addEventListener('click', function(baseHid) {
                        return function(e) {
                            e.stopPropagation();
                            window.webkit.messageHandlers.highlightTapped.postMessage(JSON.stringify({
                                id: baseHid,
                                x: e.clientX,
                                // pageY is document-relative; Swift subtracts scrollY to get clientY
                                pageY: e.pageY
                            }));
                        };
                    }(hid));
                }

                parent.insertBefore(span, before);
                span.appendChild(before);
                // 'after' stays in place after the span automatically
            }
        })();
        """
    }

    // MARK: - Remove highlight (delete annotation)
    // Finds all spans with data-hl-base matching the id (handles multi-segment highlights),
    // unwraps each one preserving child nodes.

    static func removeHighlight(id: UUID, from webView: WKWebView) {
        let hexID = id.uuidString.replacingOccurrences(of: "-", with: "")
        let js = """
        (function() {
            var baseID = '\(hexID)';
            // Collect all spans for this annotation (single span or multi-segment)
            var spans = Array.from(document.querySelectorAll('[data-hl-base="' + baseID + '"]'));
            // Also catch the legacy single-span id format
            var single = document.getElementById('hl-' + baseID);
            if (single && !spans.includes(single)) spans.push(single);

            spans.forEach(function(span) {
                var parent = span.parentNode;
                if (!parent) return;
                while (span.firstChild) parent.insertBefore(span.firstChild, span);
                parent.removeChild(span);
            });
            document.body.normalize();
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    static func clearHighlights(from webView: WKWebView, completion: (() -> Void)? = nil) {
        let js = """
        (function() {
            var spans = Array.from(document.querySelectorAll('[data-ambrosia-highlight="1"]'));
            spans.forEach(function(span) {
                var parent = span.parentNode;
                if (!parent) return;
                while (span.firstChild) parent.insertBefore(span.firstChild, span);
                parent.removeChild(span);
            });
            document.body.normalize();
        })();
        """
        webView.evaluateJavaScript(js) { _, _ in completion?() }
    }

    // MARK: - Decode messages

    static func decodeAnnotation(from message: WKScriptMessage) -> Annotation? {
        guard message.name == "highlightAdded",
              let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let startChar    = json["startChar"]    as? Int,
              let endChar      = json["endChar"]      as? Int,
              let selectedText = json["selectedText"] as? String,
              endChar > startChar,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        return Annotation(
            spineIndex:   json["spineIndex"] as? Int ?? 0,
            startChar:    startChar,
            endChar:      endChar,
            selectedText: selectedText,
            colorHex:     "#FFD60A"
        )
    }

    static func decodeTap(from message: WKScriptMessage) -> (id: String, x: CGFloat, pageY: CGFloat)? {
        guard message.name == "highlightTapped",
              let body  = message.body as? String,
              let data  = body.data(using: .utf8),
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id    = json["id"]    as? String,
              let x     = json["x"]    as? CGFloat,
              let pageY = json["pageY"] as? CGFloat
        else { return nil }
        return (id, x, pageY)
    }
}
