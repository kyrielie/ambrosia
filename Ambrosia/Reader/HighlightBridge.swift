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
            var count = 0, current, fullParts = [];
            while ((current = walker.nextNode()) !== null) {
                fullParts.push(current.nodeValue || '');
            }
            var fullText = fullParts.join('');

            walker = document.createTreeWalker(
                document.body, NodeFilter.SHOW_TEXT, null
            );
            while ((current = walker.nextNode()) !== null) {
                if (current === node) {
                    return { offset: pageStart + count + localOffset, fullText: fullText };
                }
                count += current.length;
            }
            return { offset: pageStart + count + localOffset, fullText: fullText };
        }

        document.addEventListener('mouseup', function(e) {
            var sel = window.getSelection();
            if (!sel || sel.isCollapsed || sel.toString().trim().length === 0) return;

            var range = sel.getRangeAt(0);
            var startRes   = getCharOffset(range.startContainer, range.startOffset);
            var endRes     = getCharOffset(range.endContainer,   range.endOffset);
            var startChar  = startRes.offset;
            var endChar    = endRes.offset;
            var spineIndex = window.currentSpineIndex || 0;
            var fullText   = startRes.fullText || '';
            var pageStart  = window._ambrosiaPageStart || 0;
            var localStart = Math.max(0, startChar - pageStart);
            var localEnd   = Math.max(localStart, endChar - pageStart);
            var quotePrefix = fullText.slice(Math.max(0, localStart - 200), localStart);
            var quoteSuffix = fullText.slice(localEnd, Math.min(fullText.length, localEnd + 200));
            var chapterTitle = window.ambrosiaAnnotationEngine
                ? window.ambrosiaAnnotationEngine.findNearestChapterTitle(range.startContainer)
                : null;

            // Cursor position at mouseup: clientX/Y is viewport-relative.
            var cursorX = e.clientX;
            var cursorY = e.clientY;

            window.__ambrosiaPendingAnnotation = {
                startChar: startChar, endChar: endChar,
                selectedText: sel.toString(), spineIndex: spineIndex,
                quotePrefix: quotePrefix, quoteSuffix: quoteSuffix,
                chapterTitle: chapterTitle
            };

            window.webkit.messageHandlers.highlightAdded.postMessage(JSON.stringify({
                startChar: startChar, endChar: endChar,
                selectedText: sel.toString(), spineIndex: spineIndex,
                quotePrefix: quotePrefix, quoteSuffix: quoteSuffix,
                chapterTitle: chapterTitle,
                cursorX: cursorX, cursorY: cursorY
            }));
        });
    })();
    """

    static func injectSelectionListener(into webView: WKWebView) {
        webView.evaluateJavaScript(AnnotationEngineJS.script, completionHandler: nil)
        webView.evaluateJavaScript(selectionListenerJS, completionHandler: nil)
    }

    // MARK: - Single-pass batched restore + self-healing re-anchor

    struct ReanchoredAnnotation: Decodable {
        let id: UUID
        let startChar: Int
        let endChar: Int
        let quotePrefix: String
        let quoteSuffix: String
    }

    struct BatchRenderReport: Decodable {
        let reanchored: [ReanchoredAnnotation]
        let orphanedIDs: [UUID]
    }

    private struct BatchRenderItem: Encodable {
        let id: String
        let startChar: Int
        let endChar: Int
        let selectedText: String
        let quotePrefix: String
        let quoteSuffix: String
        let colorKey: String
        let hasHighlight: Bool
        let originalText: String?
        let replacementText: String?
        let needsReanchor: Bool
    }

    private struct BatchRenderPayload: Encodable {
        let annotations: [BatchRenderItem]
    }

    static func restoreHighlights(
        _ annotations: [Annotation],
        into webView: WKWebView,
        completion: ((BatchRenderReport?) -> Void)? = nil
    ) {
        guard !annotations.isEmpty else {
            completion?(nil)
            return
        }
        let items = annotations.map { ann in
            BatchRenderItem(
                id: ann.id.uuidString,
                startChar: ann.startChar,
                endChar: ann.endChar,
                selectedText: ann.selectedText,
                quotePrefix: ann.quotePrefix,
                quoteSuffix: ann.quoteSuffix,
                colorKey: ann.colorKey.rawValue,
                hasHighlight: ann.hasHighlight,
                originalText: ann.originalText,
                replacementText: ann.replacementText,
                needsReanchor: ann.needsReanchor
            )
        }
        guard let encoded = try? JSONEncoder().encode(BatchRenderPayload(annotations: items)) else {
            completion?(nil)
            return
        }
        let base64 = encoded.base64EncodedString()
        let callJS = """
        \(AnnotationEngineJS.script)
        window.ambrosiaAnnotationEngine.renderBatchEncoded('\(base64)');
        """
        webView.evaluateJavaScript(callJS) { result, _ in
            guard let jsonStr = result as? String,
                  let data = jsonStr.data(using: .utf8),
                  let report = try? JSONDecoder().decode(BatchRenderReport.self, from: data) else {
                completion?(nil)
                return
            }
            completion?(report)
        }
    }

    /// Captures `quotePrefix` and `quoteSuffix` (200 UTF-16 chars each) at a point offset.
    static func capturePointContext(
        offset: Int,
        in webView: WKWebView,
        completion: @escaping (_ quotePrefix: String, _ quoteSuffix: String, _ chapterTitle: String?) -> Void
    ) {
        let js = """
        \(AnnotationEngineJS.script)
        (function() {
            var idx = window.ambrosiaAnnotationEngine.buildTextIndex(document.body);
            var pageStart = window._ambrosiaPageStart || 0;
            var localOffset = Math.max(0, Math.min(idx.length, \(offset) - pageStart));
            var ctx = window.ambrosiaAnnotationEngine.extractContext(idx.fullText, localOffset, localOffset);
            var targetNode = null;
            for (var i = 0; i < idx.nodes.length; i++) {
                if (idx.offsets[i] + idx.nodes[i].length >= localOffset) {
                    targetNode = idx.nodes[i];
                    break;
                }
            }
            var chapterTitle = window.ambrosiaAnnotationEngine.findNearestChapterTitle(targetNode);
            return JSON.stringify({
                quotePrefix: ctx.quotePrefix,
                quoteSuffix: ctx.quoteSuffix,
                chapterTitle: chapterTitle
            });
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            guard let jsonStr = result as? String,
                  let data = jsonStr.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion("", "", nil)
                return
            }
            completion(
                dict["quotePrefix"] as? String ?? "",
                dict["quoteSuffix"] as? String ?? "",
                dict["chapterTitle"] as? String
            )
        }
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
            quotePrefix: json["quotePrefix"] as? String ?? "",
            quoteSuffix: json["quoteSuffix"] as? String ?? "",
            chapterTitle: json["chapterTitle"] as? String,
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
