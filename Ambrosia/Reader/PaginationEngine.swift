import AppKit
import WebKit

// MARK: - PaginationEngine
//
// CSS-columns-based pagination engine for Ambrosia.
//
// APPROACH (replaces old TreeWalker/scroll-and-clip design):
//   The full merged HTML document is loaded once into the single visible
//   WKWebView. Pagination is achieved entirely by the browser's own CSS
//   multi-column layout engine:
//
//     body {
//       column-width: <viewportWidth>px;   /* one column = one page */
//       column-gap:   0px;
//       column-fill:  auto;
//       height:       <viewportHeight>px;
//       overflow:     hidden;
//     }
//
//   "Turning a page" is a single scrollLeft assignment:
//     document.documentElement.scrollLeft = pageIndex * viewportWidth
//
//   No DOM slicing, no hidden measurement WebView, no Range.cloneContents(),
//   no per-page loadHTMLString, no offset translation layer.
//
// CHARACTER OFFSET INVARIANT:
//   The TreeWalker UTF-16 offset contract is preserved unchanged. Because
//   the DOM is never modified or split, all existing annotation, highlight,
//   and bookmark offset values remain valid with no adjustment.
//
// THREAD SAFETY: All methods must be called on the main thread.

final class PaginationEngine {

    // MARK: - Geometry

    struct Geometry: Equatable {
        let pageWidth:  CGFloat   // one column width = one viewport width
        let pageHeight: CGFloat
        let pageCount:  Int

        var isEmpty: Bool { pageCount == 0 }
    }

    // MARK: - State

    private(set) var geometry: Geometry = Geometry(pageWidth: 0, pageHeight: 0, pageCount: 0)

    // MARK: - CSS injection

    /// Returns CSS that turns the document into a horizontally-paged column layout.
    /// This is injected as part of userCSS in mergedHTML — not via evaluateJavaScript —
    /// so it is present from the first paint and never causes a layout flash.
    static func columnCSS(viewportWidth: CGFloat, viewportHeight: CGFloat) -> String {
        // Use `columns: 1` (column-count, not column-width) so the browser creates
        // exactly one column whose width equals the body width. column-width is a
        // *hint* the browser can exceed; column-count: 1 is exact.
        //
        // html carries the true viewport clip. We set overflow-x: hidden there so
        // the next column's left edge is never visible. overflow-y is also hidden so
        // no vertical scrollbar appears.
        //
        // body width is set to exactly viewportWidth with box-sizing: border-box so
        // padding doesn't cause it to exceed the clip boundary. margin/max-width are
        // both zeroed so the user's prose width preference doesn't narrow the body
        // below viewportWidth and cause the column algorithm to shrink columns.
        //
        // The padding for readable line length is handled by an inner wrapper on the
        // content itself (set via paddingH/paddingV in user CSS applied before this).
        // We preserve that by NOT zeroing padding here — we only zero margin/max-width.
        let vw = Int(viewportWidth)
        let vh = Int(viewportHeight)
        let imgMaxH = max(40, Int(viewportHeight) - 40)
        return """
        /* === Ambrosia paginated column layout === */

        /*
         * SCROLL MODEL:
         * html must be overflow-x: scroll (not hidden) so that it is a proper
         * scroll container. window.scrollTo() only works when the root element
         * is scrollable. overflow: hidden makes it a clipping box — not a
         * scroll container — and window.scrollTo silently no-ops.
         *
         * The scrollbar is hidden via ::-webkit-scrollbar so it's invisible
         * to the user while the element remains programmatically scrollable.
         *
         * body overflow-x must NOT be hidden either, because the CSS column
         * boxes need to extend horizontally past the body's own boundary for
         * the browser to know there's content to scroll to.
         */
        html {
            width: \(vw)px !important;
            height: \(vh)px !important;
            overflow-x: scroll !important;
            overflow-y: hidden !important;
            scrollbar-width: none !important; /* Firefox */
        }
        html::-webkit-scrollbar {
            display: none !important;          /* WebKit/Blink */
        }
        body {
            -webkit-columns: 1 !important;
            columns: 1 !important;
            column-gap: 0px !important;
            column-fill: auto !important;
            width: \(vw)px !important;
            height: \(vh)px !important;
            max-width: none !important;
            margin-left: 0 !important;
            margin-right: 0 !important;
            overflow-x: visible !important;  /* columns extend past body boundary */
            overflow-y: hidden !important;
            box-sizing: border-box !important;
        }
        img {
            max-width: 100% !important;
            max-height: \(imgMaxH)px !important;
            object-fit: contain !important;
        }
        /* Avoid mid-paragraph column breaks where possible */
        p, li, blockquote { break-inside: avoid-column; }
        h1, h2, h3, h4, h5, h6 { break-after: avoid-column; }
        """
    }

    // MARK: - Compute page count from a loaded WKWebView

    /// After the webView has finished loading a document with columnCSS injected,
    /// call this to compute the total page count from scrollWidth.
    /// The completion is called synchronously if the measurement succeeds, or
    /// with a zero-count Geometry on failure.
    func measurePageCount(in webView: WKWebView,
                          viewportWidth: CGFloat,
                          viewportHeight: CGFloat,
                          completion: @escaping (Geometry) -> Void) {
        // scrollWidth is the total horizontal extent of all columns.
        // Dividing by viewportWidth gives the column (page) count.
        // We read both scrollWidth and the actual column width the browser computed
        // to guard against sub-pixel rounding.
        let js = """
        (function() {
            var sw  = document.documentElement.scrollWidth;
            var bsw = document.body.scrollWidth;
            var vw  = \(Int(viewportWidth));
            var htmlOverflow = getComputedStyle(document.documentElement).overflowX;
            var bodyOverflow = getComputedStyle(document.body).overflowX;
            var colCount = getComputedStyle(document.body).columnCount;
            console.log('[Ambrosia][measurePageCount] scrollWidth=' + sw
                + ' bodyScrollWidth=' + bsw
                + ' vw=' + vw
                + ' html.overflowX=' + htmlOverflow
                + ' body.overflowX=' + bodyOverflow
                + ' body.columnCount=' + colCount);
            if (sw <= 0 || vw <= 0) {
                console.log('[Ambrosia][measurePageCount] BAILING: sw=' + sw + ' vw=' + vw);
                return { scrollWidth: 0, pageCount: 0 };
            }
            var pageCount = Math.max(1, Math.round(sw / vw));
            console.log('[Ambrosia][measurePageCount] pageCount=' + pageCount);
            return { scrollWidth: sw, pageCount: pageCount };
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            if let error {
                print("[PaginationEngine] measurePageCount JS error: \(error)")
                completion(Geometry(pageWidth: viewportWidth,
                                    pageHeight: viewportHeight,
                                    pageCount: 0))
                return
            }
            guard let dict = result as? [String: Any],
                  let pageCount = dict["pageCount"] as? Int,
                  pageCount > 0
            else {
                completion(Geometry(pageWidth: viewportWidth,
                                    pageHeight: viewportHeight,
                                    pageCount: 0))
                return
            }
            let geo = Geometry(pageWidth: viewportWidth,
                               pageHeight: viewportHeight,
                               pageCount: pageCount)
            self.geometry = geo
            completion(geo)
        }
    }

    // MARK: - Navigate to a page

    /// Scrolls the document to the given 0-based page index by setting scrollLeft.
    /// This is the entire "page turn" implementation.
    static func scrollTo(pageIndex: Int, in webView: WKWebView, pageWidth: CGFloat, completion: (() -> Void)? = nil) {
        let targetX = Int(CGFloat(pageIndex) * pageWidth)
        // MUST use window.scrollTo — assigning document.documentElement.scrollLeft
        // is silently dropped by WKWebView in standards-mode documents.
        // html must also be overflow-x: scroll (not hidden) for this to take effect.
        let js = """
        (function() {
            var before = document.documentElement.scrollLeft;
            window.scrollTo({ left: \(targetX), top: 0, behavior: 'instant' });
            var after = document.documentElement.scrollLeft;
            console.log('[Ambrosia][scrollTo] page=\(pageIndex) targetX=\(targetX) before=' + before + ' after=' + after + ' moved=' + (after !== before));
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        completion?()
    }

    // MARK: - Page index for a character offset

    /// Returns the 0-based page index that contains the given UTF-16 character offset.
    /// Inserts a zero-size marker span at the offset, reads its getBoundingClientRect().left
    /// (which in a multi-column layout is the column's left edge relative to the viewport),
    /// then derives the page index from scrollLeft + rect.left.
    static func pageIndex(forCharOffset offset: Int,
                          in webView: WKWebView,
                          pageWidth: CGFloat,
                          completion: @escaping (Int) -> Void) {
        guard pageWidth > 0 else { completion(0); return }

        let js = """
        (function() {
            var target = \(offset);
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
                    var x = rect.left + document.documentElement.scrollLeft;
                    marker.parentNode.removeChild(marker);
                    var pageW = \(Int(pageWidth));
                    return pageW > 0 ? Math.floor(x / pageW) : 0;
                }
                remaining -= node.length;
            }
            return 0;
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            let idx = result as? Int ?? 0
            completion(max(0, idx))
        }
    }

    // MARK: - Current page from scrollLeft

    /// Derives the current page index purely from the webView's current scrollLeft.
    /// No JS evaluation needed — cheap to call on every scroll event if desired.
    static func currentPageIndex(scrollLeft: CGFloat, pageWidth: CGFloat) -> Int {
        guard pageWidth > 0 else { return 0 }
        return max(0, Int((scrollLeft / pageWidth).rounded()))
    }
}
