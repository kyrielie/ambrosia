import Foundation
import WebKit

// MARK: - BookmarkManager
//
// Saves and restores Bookmark values in BookState.
// A bookmark is: spineIndex + characterOffset + 80-char previewText.
//
// Character offset invariant: UTF-16 code units, text nodes only.
// Matches EPUBParser.plainText and HighlightBridge conventions.
//
// USAGE:
//   // Save (triggered by ⌘D in ReaderViewController):
//   BookmarkManager.saveBookmark(at: offset, spineIndex: idx,
//                                in: webView, bookState: state, context: ctx)
//
//   // Jump to bookmark (triggered from sidebar):
//   BookmarkManager.jumpToBookmark(bookmark, in: webView, using: renderPage)

enum BookmarkManager {

    // MARK: - Save

    /// Captures the preview text around `characterOffset` from the live WebView,
    /// then creates and saves a Bookmark into BookState.
    ///
    /// The preview text is extracted via JS (80 chars starting at offset) so it
    /// matches exactly what the user sees — no separate Swift plain-text pass needed.
    static func saveBookmark(
        at characterOffset: Int,
        spineIndex: Int,
        in webView: WKWebView,
        bookState: BookState
    ) {
        let js = """
        (function() {
            var target = \(characterOffset);
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
            var remaining = target;
            var node;
            while ((node = walker.nextNode()) !== null) {
                if (remaining <= node.length) {
                    // Collect 80 chars of text from this point forward
                    var text = '';
                    var slice = node.data.slice(remaining);
                    text += slice;
                    var sibling = walker.nextNode();
                    while (sibling && text.length < 80) {
                        text += sibling.data;
                        sibling = walker.nextNode();
                    }
                    return text.slice(0, 80).replace(/\\s+/g, ' ').trim();
                }
                remaining -= node.length;
            }
            return '';
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            let preview = (result as? String) ?? ""
            // BookmarkManager is superseded by ReaderViewController's annotation system (B2).
            // This code path is no longer called; the body is kept stub-only so the file compiles.
            _ = preview
        }
    }

    // MARK: - Jump

    /// Scrolls the reader to a bookmark position.
    /// In scroll mode: scrolls to the approximate Y position.
    /// In paginated mode: calls the renderPage closure with the bookmark's startChar.
    static func jumpToBookmark(
        _ bookmark: Bookmark,
        in webView: WKWebView,
        renderPage: ((Int) -> Void)?
    ) {
        if let renderPage {
            // Paginated mode: ask ReaderViewController to find and render the right page
            renderPage(bookmark.characterOffset)
        } else {
            // Scroll mode: jump via JS marker insertion (same pattern as ambrosiaRenderPage)
            let js = """
            (function() {
                var target = \(bookmark.characterOffset);
                var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
                var remaining = target;
                var node;
                while ((node = walker.nextNode()) !== null) {
                    if (remaining <= node.length) {
                        var range = document.createRange();
                        range.setStart(node, remaining);
                        range.collapse(true);
                        var marker = document.createElement('span');
                        marker.style.cssText = 'display:inline;font-size:0;line-height:0;';
                        range.insertNode(marker);
                        var rect = marker.getBoundingClientRect();
                        var y = rect.top + window.scrollY - 40;
                        marker.parentNode.removeChild(marker);
                        window.scrollTo({ top: Math.max(0, y), behavior: 'smooth' });
                        return;
                    }
                    remaining -= node.length;
                }
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        // Flash highlight at the target position
        webView.evaluateJavaScript(
            "if (window.ambrosiaHighlight) window.ambrosiaHighlight(\(bookmark.characterOffset));",
            completionHandler: nil
        )
    }

    // MARK: - Delete

    static func deleteBookmark(id: UUID, from bookState: BookState) {
        // Superseded by annotation system (B2). No-op stub — kept so file compiles.
        _ = id; _ = bookState
    }
}
