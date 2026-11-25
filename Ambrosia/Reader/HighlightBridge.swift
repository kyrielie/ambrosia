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
            var cursorX = e.clientX;
            var cursorY = e.clientY;

            window.__ambrosiaPendingAnnotation = {
                startChar: startChar, endChar: endChar,
                selectedText: sel.toString(), spineIndex: spineIndex
            };

            window.webkit.messageHandlers.highlightAdded.postMessage(JSON.stringify({
                startChar: startChar, endChar: endChar,
                selectedText: sel.toString(), spineIndex: spineIndex,
                cursorX: cursorX, cursorY: cursorY
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
            let start = annotation.startChar, end = annotation.endChar
            if renderedRanges.contains(where: { range in start < range.end && end > range.start }) {
                overlapping.insert(annotation.id)
            }
            renderedRanges.append((start, end))
        }
        for annotation in sorted {
            let highlightJS = restoreHighlightJS(annotation: annotation,
                                                 useUnderline: overlapping.contains(annotation.id))
            webView.evaluateJavaScript(highlightJS, completionHandler: nil)
        }
    }

    // FIX 2: Multi-node wrap replaces surroundContents.
    // Collects all text nodes in [startChar, endChar), splits the boundary nodes,
    // and wraps each segment in its own <mark class="ambrosia-highlight"> with the
    // same id-prefix + "-N" suffix. CSS custom properties drive theme-aware colors,
    // translucency, box-decoration-break: clone, and overlap-underline rendering.
    // swiftlint:disable:next function_body_length
    private static func restoreHighlightJS(annotation: Annotation, useUnderline: Bool) -> String {
        let startChar   = annotation.startChar
        let endChar     = annotation.endChar
        let colorKey    = annotation.colorKey.rawValue
        let highlightID = annotation.id.uuidString.replacingOccurrences(of: "-", with: "")
        let useUnderJS  = useUnderline ? "true" : "false"

        return """
        (function() {
            var startChar    = \(startChar);
            var endChar      = \(endChar);
            var colorKey     = '\(colorKey)';
            var hid          = '\(highlightID)';
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

            // ── Wrap each segment in its own <mark> ───────────────────────────
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

                var mark = document.createElement('mark');
                // Primary mark gets base id; segments get -0, -1 … suffix
                mark.id = 'hl-' + hid + (segments.length === 1 ? '' : '-' + si);
                mark.className = 'ambrosia-highlight';
                mark.setAttribute('data-ambrosia-highlight', '1');
                mark.setAttribute('data-hl-base', hid);
                mark.setAttribute('data-annotation-color', colorKey);
                if (useUnderline) {
                    mark.setAttribute('data-overlap', 'underline');
                }

                mark.addEventListener('click', function(baseHid) {
                    return function(e) {
                        e.stopPropagation();
                        window.webkit.messageHandlers.highlightTapped.postMessage(JSON.stringify({
                            id: baseHid,
                            x: e.clientX,
                            y: e.clientY
                        }));
                    };
                }(hid));

                parent.insertBefore(mark, before);
                mark.appendChild(before);
                // 'after' stays in place after the mark automatically
            }
        })();
        """
    }

    // MARK: - Remove highlight (delete annotation)
    // Finds all spans with data-hl-base matching the id (handles multi-segment highlights),
    // unwraps each one preserving child nodes.

    static func removeHighlight(id: UUID, from webView: WKWebView) {
        let hexID = id.uuidString.replacingOccurrences(of: "-", with: "")
        let removeJS = """
        (function() {
            var baseID = '\(hexID)';
            // Collect all spans for this annotation (single span or multi-segment)
            var spans = Array.from(document.querySelectorAll('[data-hl-base="' + baseID + '"]'));
            // Also catch single-segment highlights using the hl-<id> id format (see restoreHighlights)
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
        webView.evaluateJavaScript(removeJS, completionHandler: nil)
    }

    static func clearHighlights(from webView: WKWebView, completion: (() -> Void)? = nil) {
        let clearJS = """
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
        webView.evaluateJavaScript(clearJS) { _, _ in completion?() }
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
            spineIndex: json["spineIndex"] as? Int ?? 0,
            startChar: startChar,
            endChar: endChar,
            selectedText: selectedText,
            colorHex: "#FFD60A"
        )
    }

    struct TapInfo {
        let id: String
        let locationX: CGFloat
        let locationY: CGFloat
    }

    static func decodeTap(from message: WKScriptMessage) -> TapInfo? {
        guard message.name == "highlightTapped",
              let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              let tapX = json["x"] as? CGFloat,
              let tapY = json["y"] as? CGFloat
        else { return nil }
        return TapInfo(id: id, locationX: tapX, locationY: tapY)
    }
}
