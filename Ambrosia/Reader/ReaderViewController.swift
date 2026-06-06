import AppKit
import WebKit
import SwiftData
import SwiftUI

// MARK: - ReaderViewController
//
// Hosts the main visible WKWebView for reading.
// Supports two modes, switchable at runtime:
//
//   .scroll     — full merged HTML, position tracked by window.scrollY
//   .paginated  — same merged HTML, paginated by PaginationEngine,
//                 one page visible at a time, position tracked by page index
//
// Phase 5 additions:
//   - HighlightBridge: selection listener injected after every didFinish;
//     "highlightAdded" messages decoded and persisted to BookState.
//   - BookmarkManager: ⌘D saves a bookmark; sidebar panel lists/jumps/deletes.
//   - Message handlers registered at WKWebViewConfiguration init time (required):
//       positionUpdate, pageAction, highlightAdded
//
// Invariant: every style or font change calls reloadHTML(), which rebuilds
// the full HTML string from EPUBParser and reloads the WebView.
// Never patch the live DOM for style changes — see project invariant #7.
//
// Character offset convention: UTF-16 code units, text nodes only.
// See EPUBParser.swift for the full contract.

class ReaderViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {

    // MARK: - Dependencies

    let book: CalibreBook
    let modelContainer: ModelContainer

    // MARK: - Private: reader state

    private var webView: WKWebView!
    private var parser: EPUBParser?
    private var imageBaseURL: URL?

    private var currentMode: ReadingMode = .scroll
    private var currentHTML: String = ""

    // Paginated mode
    private var pages: [PaginationEngine.PageBoundary] = []
    private var currentPageIndex: Int = 0
    private var paginationEngine: PaginationEngine?

    // Resize debounce
    private let resizeDebounce = DebounceTimer(delay: 0.3)

    // Bookmark sidebar
    private var sidebarPanel: NSPanel?
    private var sidebarHostingView: NSHostingView<BookmarkSidebarView>?

    // MARK: - Private: persistence

    private var saveTimer: Timer?
    private var _saveContext: ModelContext?
    private var saveContext: ModelContext {
        if let c = _saveContext { return c }
        let c = ModelContext(modelContainer)
        _saveContext = c
        return c
    }
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
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        // All message handlers must be registered at construction time.
        config.userContentController.add(self, name: "positionUpdate")   // scroll mode position
        config.userContentController.add(self, name: "pageAction")       // paginated prev/next
        config.userContentController.add(self, name: "highlightAdded")   // text selection → highlight

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        ensureBookState()
        currentMode = bookState?.readingMode ?? .scroll

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.loadEPUB()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard currentMode == .paginated, !pages.isEmpty else { return }
        resizeDebounce.schedule { [weak self] in
            self?.repaginatePreservingPosition()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        saveTimer?.invalidate()
        saveTimer = nil
        sidebarPanel?.close()
        flushPosition()
    }

    // MARK: - EPUB loading

    private func loadEPUB() async {
        guard let pathStr = LibraryRegistry.shared.activePath else {
            await showError("No library open."); return
        }
        let libraryRoot = URL(fileURLWithPath: pathStr)
        guard let epubURL = book.epubURL(libraryRoot: libraryRoot),
              FileManager.default.fileExists(atPath: epubURL.path) else {
            await showError("EPUB file not found: \(book.displayTitle)"); return
        }

        do {
            var p = EPUBParser(epubURL: epubURL)
            try p.parse()
            let imgBase = try EPUBParser.extractImages(from: epubURL, calibreID: book.id)
            let html    = try p.mergedHTML(userCSS: ReaderPreferences.shared.css)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.parser       = p
                self.imageBaseURL = imgBase
                self.currentHTML  = html
                self.webView.loadHTMLString(html, baseURL: imgBase)
            }
        } catch {
            await showError(error.localizedDescription)
        }
    }

    // MARK: - HTML reload (on style/font change)

    func reloadHTML() {
        guard let p = parser else { return }
        do {
            let html = try p.mergedHTML(userCSS: ReaderPreferences.shared.css)
            currentHTML = html
            webView.loadHTMLString(html, baseURL: imageBaseURL)
        } catch {
            print("[ReaderVC] reloadHTML error: \(error)")
        }
    }

    // MARK: - Mode switching

    func switchToScrollMode() {
        currentMode = .scroll
        bookState?.readingMode = .scroll
        saveCurrentCharOffset { [weak self] _ in
            self?.reloadHTML()
        }
    }

    func switchToPaginatedMode() {
        currentMode = .paginated
        bookState?.readingMode = .paginated
        paginateCurrentContent()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Inject PaginationJS first (needed in both modes: paginated uses it
        // for rendering, scroll mode uses ambrosiaHighlight for bookmark jumps).
        webView.evaluateJavaScript(PaginationJS.script, completionHandler: nil)

        // Inject highlight selection listener (Phase 5)
        HighlightBridge.injectSelectionListener(into: webView)

        // Restore persisted highlights for the current document
        let highlights = bookState?.highlights ?? []
        HighlightBridge.restoreHighlights(highlights, into: webView)

        switch currentMode {
        case .scroll:
            restoreScrollPosition()
            injectScrollTracker()
            startAutoSave()

        case .paginated:
            paginateCurrentContent()
        }
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!, withError error: Error) {
        print("[ReaderVC] Navigation failed: \(error.localizedDescription)")
    }

    // MARK: - Scroll mode: position save/restore

    private func restoreScrollPosition() {
        let offset = bookState?.lastScrollOffset ?? 0
        if offset > 0 {
            webView.evaluateJavaScript("window.scrollTo(0, \(offset));", completionHandler: nil)
        }
    }

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
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Paginated mode: pagination

    private func paginateCurrentContent() {
        guard !currentHTML.isEmpty else { return }
        let pageHeight = max(1, webView.bounds.height - 2.0)
        let engine = PaginationEngine(parentView: view)
        paginationEngine = engine
        engine.paginate(html: currentHTML, pageHeight: pageHeight, baseURL: imageBaseURL) { [weak self] boundaries in
            guard let self else { return }
            self.paginationEngine = nil

            if boundaries.isEmpty {
                print("[ReaderVC] Pagination returned 0 pages — falling back to scroll mode")
                self.switchToScrollMode()
                return
            }

            self.pages = boundaries
            let savedOffset = self.bookState?.lastCharacterOffset ?? 0
            self.currentPageIndex = self.pageIndex(forCharOffset: savedOffset)
            self.renderCurrentPage()
            self.startAutoSave()
        }
    }

    private func repaginatePreservingPosition() {
        guard currentMode == .paginated, !currentHTML.isEmpty else { return }
        saveCurrentCharOffset { [weak self] savedOffset in
            guard let self else { return }
            let pageHeight = max(1, self.webView.bounds.height - 2.0)
            let engine = PaginationEngine(parentView: self.view)
            self.paginationEngine = engine
            engine.paginate(
                html: self.currentHTML,
                pageHeight: pageHeight,
                baseURL: self.imageBaseURL
            ) { [weak self] boundaries in
                guard let self else { return }
                self.paginationEngine = nil
                guard !boundaries.isEmpty else { return }
                self.pages = boundaries
                self.currentPageIndex = self.pageIndex(forCharOffset: savedOffset)
                self.renderCurrentPage()
                self.webView.evaluateJavaScript(
                    "window.ambrosiaHighlight(\(savedOffset));",
                    completionHandler: nil
                )
            }
        }
    }

    func renderCurrentPage() {
        guard !pages.isEmpty else { return }
        let idx  = max(0, min(currentPageIndex, pages.count - 1))
        let page = pages[idx]
        webView.evaluateJavaScript(
            "window.ambrosiaRenderPage(\(page.startChar), \(page.endChar));",
            completionHandler: nil
        )
        let progress = Double(idx + 1) / Double(pages.count)
        bookState?.totalReadPercent = progress
    }

    // MARK: - Page navigation (paginated mode)

    func goToNextPage() {
        guard currentMode == .paginated, currentPageIndex < pages.count - 1 else { return }
        currentPageIndex += 1
        renderCurrentPage()
        saveCurrentPage()
    }

    func goToPreviousPage() {
        guard currentMode == .paginated, currentPageIndex > 0 else { return }
        currentPageIndex -= 1
        renderCurrentPage()
        saveCurrentPage()
    }

    // MARK: - Char offset helpers

    private func pageIndex(forCharOffset offset: Int) -> Int {
        guard !pages.isEmpty else { return 0 }
        for (i, page) in pages.enumerated() {
            if offset < page.endChar { return i }
        }
        return pages.count - 1
    }

    private func saveCurrentCharOffset(completion: @escaping (Int) -> Void) {
        if currentMode == .paginated {
            let offset = pages.isEmpty ? 0 : pages[max(0, currentPageIndex)].startChar
            bookState?.lastCharacterOffset = offset
            completion(offset)
        } else {
            webView.evaluateJavaScript("[window.scrollY, document.body.scrollHeight]") { [weak self] result, _ in
                guard let arr = result as? [Double], arr.count == 2, arr[1] > 0 else {
                    completion(0); return
                }
                self?.bookState?.lastScrollOffset = arr[0]
                completion(0)
            }
        }
    }

    private func saveCurrentPage() {
        guard currentMode == .paginated, !pages.isEmpty else { return }
        let page = pages[max(0, min(currentPageIndex, pages.count - 1))]
        bookState?.lastCharacterOffset = page.startChar
        bookState?.lastSpineIndex      = 0
        flushPosition()
    }

    // MARK: - BookState management

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

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        switch message.name {

        case "positionUpdate":
            guard let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let y    = json["scrollY"] as? Double
            else { return }
            bookState?.lastScrollOffset = y

        case "pageAction":
            guard let body = message.body as? String else { return }
            if body == "next" { goToNextPage() }
            else if body == "prev" { goToPreviousPage() }

        case "highlightAdded":
            guard let highlight = HighlightBridge.decodeHighlight(from: message),
                  var state = bookState else { return }
            var existing = state.highlights
            existing.append(highlight)
            state.highlights = existing
            flushPosition()

        default:
            break
        }
    }

    // MARK: - Keyboard events

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "d":
                saveBookmarkAtCurrentPosition()
                return
            case "b":
                toggleBookmarkSidebar()
                return
            default:
                break
            }
        }

        guard currentMode == .paginated else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123, 126: goToPreviousPage()
        case 124, 125: goToNextPage()
        case 49:       goToNextPage()   // space
        default:       super.keyDown(with: event)
        }
    }

    // MARK: - Responder-chain actions (called by menu items via NSApp.sendAction)

    @objc func addBookmark(_ sender: Any?) {
        saveBookmarkAtCurrentPosition()
    }

    @objc func showBookmarkSidebar(_ sender: Any?) {
        toggleBookmarkSidebar()
    }

    // MARK: - Bookmarks

    private func saveBookmarkAtCurrentPosition() {
        guard let state = bookState else { return }

        // Determine the current character offset
        let offset: Int
        if currentMode == .paginated, !pages.isEmpty {
            offset = pages[max(0, currentPageIndex)].startChar
        } else {
            // Scroll mode: use 0 as a safe fallback; a full async version
            // would evaluateJavaScript to get scrollY first, but for a simple
            // bookmark the top-of-visible-area approximation is fine.
            offset = Int(state.lastScrollOffset)
        }

        let spineIndex = state.lastSpineIndex

        BookmarkManager.saveBookmark(
            at:         offset,
            spineIndex: spineIndex,
            in:         webView,
            bookState:  state
        )

        // Brief visual confirmation
        webView.evaluateJavaScript(
            "window.ambrosiaHighlight(\(offset));",
            completionHandler: nil
        )

        // Flush immediately so the bookmark persists even if the app is force-quit
        flushPosition()

        // Refresh sidebar if open
        refreshSidebarIfVisible()
    }

    // MARK: - Bookmark sidebar

    func toggleBookmarkSidebar() {
        if let panel = sidebarPanel, panel.isVisible {
            panel.close()
            return
        }
        openBookmarkSidebar()
    }

    private func openBookmarkSidebar() {
        guard let windowFrame = view.window?.frame else { return }

        let sidebar = makeSidebarView()
        let hosting = NSHostingView(rootView: sidebar)
        hosting.frame = CGRect(x: 0, y: 0, width: 260, height: windowFrame.height)
        sidebarHostingView = hosting

        let panel = NSPanel(
            contentRect: CGRect(
                x: windowFrame.maxX,
                y: windowFrame.minY,
                width: 260,
                height: windowFrame.height
            ),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title       = "Bookmarks"
        panel.isFloatingPanel = true
        panel.contentView = hosting
        panel.becomesKeyOnlyIfNeeded = true
        panel.orderFront(nil)
        sidebarPanel = panel
    }

    private func makeSidebarView() -> BookmarkSidebarView {
        BookmarkSidebarView(
            bookmarks: bookState?.bookmarks ?? [],
            onJump: { [weak self] bookmark in
                guard let self else { return }
                if self.currentMode == .paginated {
                    BookmarkManager.jumpToBookmark(bookmark, in: self.webView) { offset in
                        self.currentPageIndex = self.pageIndex(forCharOffset: offset)
                        self.renderCurrentPage()
                    }
                } else {
                    BookmarkManager.jumpToBookmark(bookmark, in: self.webView, renderPage: nil)
                }
            },
            onDelete: { [weak self] id in
                guard let self, let state = self.bookState else { return }
                BookmarkManager.deleteBookmark(id: id, from: state)
                self.flushPosition()
                self.refreshSidebarIfVisible()
            }
        )
    }

    private func refreshSidebarIfVisible() {
        guard let panel = sidebarPanel, panel.isVisible,
              let hosting = sidebarHostingView else { return }
        hosting.rootView = makeSidebarView()
    }

    // MARK: - Error display

    @MainActor
    private func showError(_ message: String) {
        let html = """
        <html><body style="font-family:system-ui;color:#999;padding:40px;text-align:center">
        <p style="font-size:48px">📖</p><p>\(message)</p>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - Pagination harness (DEBUG)

    #if DEBUG
    func runPaginationHarness() {
        guard let p = parser else { print("[Harness] No parser"); return }
        let paginatedTotal = pages.reduce(0) { $0 + $1.charCount }
        var expectedTotal = 0
        for item in p.spine {
            if let text = try? p.plainText(for: item) {
                expectedTotal += text.utf16.count
            }
        }
        let diff = abs(paginatedTotal - expectedTotal)
        if diff <= 5 {
            print("[Harness] ✅ PASS — paginated=\(paginatedTotal) expected=\(expectedTotal) diff=\(diff)")
        } else {
            print("[Harness] ❌ FAIL — paginated=\(paginatedTotal) expected=\(expectedTotal) diff=\(diff)")
        }
    }
    #endif
}
