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
//   let session = PaginationEngine(parentView: readerView)
//   session.load(html: html, pageHeight: view.bounds.height - 2, baseURL: imgURL) { pages in
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
    private var pendingPaginationCompletion: (([PageBoundary]) -> Void)?
    private var pendingPageHTMLCompletion: ((String?) -> Void)?
    private var pendingPageHeight: CGFloat = 0
    private var userCSS: String = ""
    private var isActive = false
    private var isLoaded = false

    // MARK: - Init

    init(parentView: NSView) {
        self.parentView = parentView
    }

    // MARK: - Public API

    /// Loads and paginates `html` at `pageHeight` using a hidden WKWebView attached to `parentView`.
    /// Calls `completion` on the main thread with the resulting page boundaries.
    /// Only one pagination can be active at a time; calling again while active is a no-op.
    func load(
        html: String,
        pageHeight: CGFloat,
        userCSS: String,
        baseURL: URL?,
        completion: @escaping ([PageBoundary]) -> Void
    ) {
        guard !isActive else { return }
        guard let parent = parentView else {
            completion([])
            return
        }

        isActive = true
        isLoaded = false
        pendingPaginationCompletion = completion
        pendingPageHeight = pageHeight
        self.userCSS = userCSS

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
        parent.addSubview(hv, positioned: .below, relativeTo: nil)
        webView = hv

        hv.loadHTMLString(html, baseURL: baseURL)
    }

    /// Recomputes page boundaries on the already-loaded hidden document.
    func repaginate(pageHeight: CGFloat, completion: @escaping ([PageBoundary]) -> Void) {
        guard !isActive, isLoaded, let hv = webView else {
            completion([])
            return
        }

        isActive = true
        pendingPaginationCompletion = completion
        pendingPageHeight = pageHeight
        hv.frame = parentView?.bounds ?? hv.frame
        hv.evaluateJavaScript("window.ambrosiaPaginate(\(pageHeight));") { _, error in
            if let error {
                print("[PaginationEngine] JS error: \(error)")
                self.finishPagination(with: [])
            }
        }
    }

    /// Builds a complete HTML document for a single computed page range.
    func pageHTML(startChar: Int, endChar: Int, completion: @escaping (String?) -> Void) {
        guard isLoaded, let hv = webView else {
            completion(nil)
            return
        }
        pendingPageHTMLCompletion = completion
        let escapedCSS = Self.javascriptStringLiteral(userCSS)
        hv.evaluateJavaScript("window.ambrosiaBuildPageHTML(\(startChar), \(endChar), \(escapedCSS));") { [weak self] result, error in
            guard let self else { return }
            let cb = self.pendingPageHTMLCompletion
            self.pendingPageHTMLCompletion = nil
            if let error {
                print("[PaginationEngine] page HTML JS error: \(error)")
                cb?(nil)
            } else {
                cb?(result as? String)
            }
        }
    }

    func invalidate() {
        webView?.removeFromSuperview()
        webView = nil
        pendingPaginationCompletion = nil
        pendingPageHTMLCompletion = nil
        userCSS = ""
        isActive = false
        isLoaded = false
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
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
                self.finishPagination(with: [])
            }
        }
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        print("[PaginationEngine] Navigation failed: \(error)")
        finishPagination(with: [])
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard message.name == "paginationResult",
              let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            finishPagination(with: [])
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
                finishPagination(with: [])
            }
            return
        }

        // Parse boundaries array
        guard let rawBoundaries = json["boundaries"] as? [[String: Any]] else {
            finishPagination(with: [])
            return
        }

        let pages: [PageBoundary] = rawBoundaries.compactMap { dict in
            guard let s = dict["startChar"] as? Int,
                  let e = dict["endChar"]   as? Int
            else { return nil }
            return PageBoundary(startChar: s, endChar: e)
        }

        finishPagination(with: pages)
    }

    // MARK: - Teardown

    private func finishPagination(with pages: [PageBoundary]) {
        isActive = false
        isLoaded = !pages.isEmpty

        let cb = pendingPaginationCompletion
        pendingPaginationCompletion = nil
        cb?(pages)
    }
}
