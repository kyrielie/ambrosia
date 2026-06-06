import AppKit
import WebKit
import SwiftData

/// Scroll-mode EPUB reader.
///
/// Loading sequence:
///   1. viewDidLoad → parse EPUB + extract images on background thread
///   2. Load merged HTML into WKWebView (baseURL = image temp dir)
///   3. webView(_:didFinish:) → restore bookState.lastScrollOffset
///   4. Inject passive scroll tracker JS
///   5. Start 5-second auto-save timer
///
/// Position save: JS positionUpdate message → bookState.lastScrollOffset
/// Auto-save: every 5 s + viewWillDisappear (final flush)
///
/// Character offset invariant: UTF-16 code units, text nodes only.
/// See top of EPUBParser.swift for the full contract.
class ReaderViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {

    // MARK: - Dependencies (set before viewDidLoad)

    let book: CalibreBook
    let modelContainer: ModelContainer

    // MARK: - Private state

    private var webView: WKWebView!
    private var parser: EPUBParser?
    private var imageBaseURL: URL?
    private var saveTimer: Timer?

    /// We hold a short-lived ModelContext for position saves.
    /// Created lazily on first use, always on the main thread.
    private var _saveContext: ModelContext?
    private var saveContext: ModelContext {
        if let ctx = _saveContext { return ctx }
        let ctx = ModelContext(modelContainer)
        _saveContext = ctx
        return ctx
    }

    /// Cached BookState for this book (fetched or created once on first save).
    private var bookState: BookState?

    // MARK: - Init

    init(book: CalibreBook, modelContainer: ModelContainer) {
        self.book           = book
        self.modelContainer = modelContainer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View lifecycle

    override func loadView() {
        let config = WKWebViewConfiguration()

        // Safari Web Inspector support (DEBUG only)
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        // Scroll position messages from JS
        // Handler name must match JS: window.webkit.messageHandlers.positionUpdate.postMessage(...)
        config.userContentController.add(self, name: "positionUpdate")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Ensure BookState exists before parsing starts (so save timer has something to write to)
        ensureBookState()

        // Parse EPUB + extract images on a background thread, then load HTML on main
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.loadEPUB()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        saveTimer?.invalidate()
        saveTimer = nil
        flushPosition()
    }

    // MARK: - EPUB loading

    private func loadEPUB() async {
        guard let pathStr = LibraryRegistry.shared.activePath else {
            await showError("No library open.")
            return
        }
        let libraryRoot = URL(fileURLWithPath: pathStr)
        guard let epubURL = book.epubURL(libraryRoot: libraryRoot),
              FileManager.default.fileExists(atPath: epubURL.path) else {
            await showError("EPUB file not found: \(book.displayTitle)")
            return
        }

        do {
            // Parse spine
            var p = EPUBParser(epubURL: epubURL)
            try p.parse()

            // Extract images to temp dir
            let imgBase = try EPUBParser.extractImages(from: epubURL, calibreID: book.id)

            // Build merged HTML
            let css  = ReaderPreferences.shared.css
            let html = try p.mergedHTML(userCSS: css)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.parser       = p
                self.imageBaseURL = imgBase
                self.webView.loadHTMLString(html, baseURL: imgBase)
            }
        } catch {
            await showError(error.localizedDescription)
        }
    }

    @MainActor
    private func showError(_ message: String) {
        let html = """
        <html><body style="font-family:system-ui;color:#999;padding:40px;text-align:center">
        <p style="font-size:48px">📖</p>
        <p>\(message)</p>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Restore last scroll position
        let offset = bookState?.lastScrollOffset ?? 0
        if offset > 0 {
            webView.evaluateJavaScript("window.scrollTo(0, \(offset));")
        }

        // Inject passive scroll tracker
        injectScrollTracker()

        // Begin auto-save cycle
        startAutoSave()
    }

    // MARK: - Scroll tracking

    private func injectScrollTracker() {
        let js = """
        (function() {
            window.addEventListener('scroll', function() {
                window.webkit.messageHandlers.positionUpdate.postMessage(
                    JSON.stringify({ scrollY: window.scrollY })
                );
            }, { passive: true });
        })();
        """
        webView.evaluateJavaScript(js)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard message.name == "positionUpdate",
              let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let y    = json["scrollY"] as? Double
        else { return }

        bookState?.lastScrollOffset = y
    }

    // MARK: - BookState management

    /// Fetches or creates a BookState for this book.
    /// Must be called on the main thread (saveContext is main-thread-only).
    private func ensureBookState() {
        let cid = book.id
        let all = (try? saveContext.fetch(FetchDescriptor<BookState>())) ?? []
        if let existing = all.first(where: { $0.calibreID == cid }) {
            bookState = existing
        } else {
            let state = BookState(calibreID: cid)
            saveContext.insert(state)
            try? saveContext.save()
            bookState = state
        }
    }

    // MARK: - Auto-save

    private func startAutoSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.flushPosition()
        }
    }

    private func flushPosition() {
        guard bookState != nil else { return }
        try? saveContext.save()
    }
}
