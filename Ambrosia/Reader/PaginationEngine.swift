import AppKit
import WebKit

// MARK: - PaginationEngine
//
// Coordinates JS-side pagination with a hidden-but-framed WKWebView.
//
// WHY A HIDDEN WEBVIEW:
//   Pagination requires accurate getBoundingClientRect() values. WebKit only
//   computes these for views that are (a) in the view hierarchy and (b) have
//   a non-zero frame. A truly off-screen or zero-frame view returns zero rects,
//   making binary-search pagination impossible.
//   Solution: add the hidden WebView as a subview of parentView with alphaValue=0,
//   same frame as parentView, then remove it when pagination is done.
//
// USAGE:
//   let engine = PaginationEngine(parentView: readerView)
//   engine.paginate(html: html, pageHeight: view.bounds.height - 2, baseURL: imgURL) { pages in
//       // pages: [PageBoundary]
//   }
//
// THREAD SAFETY: All methods must be called on the main thread.

final class PaginationEngine: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    // MARK: - PageBoundary

    struct PageBoundary: Equatable {
        let startChar: Int
        let endChar: Int

        var charCount: Int { endChar - startChar }
    }

    // MARK: - Private state

    private weak var parentView: NSView?
    private var webView: WKWebView?
    private var pendingCompletion: (([PageBoundary]) -> Void)?
    private var pendingPageHeight: CGFloat = 0
    private var isActive = false

    // MARK: - Init

    init(parentView: NSView) {
        self.parentView = parentView
    }

    // MARK: - Public API

    /// Paginates `html` at `pageHeight` using a hidden WKWebView attached to `parentView`.
    /// Calls `completion` on the main thread with the resulting page boundaries.
    /// Only one pagination can be active at a time; calling again while active is a no-op.
    func paginate(
        html: String,
        pageHeight: CGFloat,
        baseURL: URL?,
        completion: @escaping ([PageBoundary]) -> Void
    ) {
        guard !isActive else { return }
        guard let parent = parentView else {
            completion([])
            return
        }

        isActive = true
        pendingCompletion = completion
        pendingPageHeight = pageHeight

        // Build configuration — must register message handler at construction time
        let config = WKWebViewConfiguration()
        // paginationResult message carries { boundaries: [{startChar, endChar}] } or { error: '...' }
        config.userContentController.add(self, name: "paginationResult")

        // Create the hidden (but real) WebView and immediately start loading.
        // PaginationJS is injected via evaluateJavaScript in didFinish,
        // after the DOM is painted and getBoundingClientRect() returns real values.
        let hv = WKWebView(frame: parent.bounds, configuration: config)
        hv.alphaValue = 0
        hv.navigationDelegate = self
        parent.addSubview(hv)
        webView = hv

        hv.loadHTMLString(html, baseURL: baseURL)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Layout is ready — inject the pagination script and trigger pagination.
        // We inject here (not just via WKUserScript) to guarantee it runs after
        // atDocumentEnd scripts have settled and the DOM is fully painted.
        let js = """
        \(PaginationJS.script)
        window.ambrosiaPaginate(\(pendingPageHeight));
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                print("[PaginationEngine] JS error: \(error)")
                self.finish(with: [])
            }
        }
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        print("[PaginationEngine] Navigation failed: \(error)")
        finish(with: [])
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard message.name == "paginationResult",
              let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            finish(with: [])
            return
        }

        // Handle layout-not-ready error — retry once after a short delay
        if let error = json["error"] as? String {
            if error == "layout_not_ready" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, let hv = self.webView else { return }
                    let retryJS = "window.ambrosiaPaginate(\(self.pendingPageHeight));"
                    hv.evaluateJavaScript(retryJS, completionHandler: nil)
                }
            } else {
                print("[PaginationEngine] JS pagination error: \(error)")
                finish(with: [])
            }
            return
        }

        // Parse boundaries array
        guard let rawBoundaries = json["boundaries"] as? [[String: Any]] else {
            finish(with: [])
            return
        }

        let pages: [PageBoundary] = rawBoundaries.compactMap { dict in
            guard let s = dict["startChar"] as? Int,
                  let e = dict["endChar"]   as? Int
            else { return nil }
            return PageBoundary(startChar: s, endChar: e)
        }

        finish(with: pages)
    }

    // MARK: - Teardown

    private func finish(with pages: [PageBoundary]) {
        // Remove hidden WebView from hierarchy
        webView?.removeFromSuperview()
        webView = nil
        isActive = false

        let cb = pendingCompletion
        pendingCompletion = nil
        cb?(pages)
    }
}
