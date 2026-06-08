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

    private var webView: ReaderMenuWebView!
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

        webView = ReaderMenuWebView(frame: .zero, configuration: config)
        webView.viewController = self
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

    // MARK: - Context menu (B1)

    // MARK: - Context menu actions (B1)

    /// Opens the selected text as a Google search in the user's default browser.
    /// Two-argument evaluateJavaScript form — required by Invariant 11.
    @objc func searchInBrowser() {
        webView.evaluateJavaScript("window.getSelection().toString()") { result, _ in
            guard let text = result as? String, !text.isEmpty else { return }
            var comps = URLComponents(string: "https://www.google.com/search")!
            comps.queryItems = [URLQueryItem(name: "q", value: text)]
            if let url = comps.url { NSWorkspace.shared.open(url) }
        }
    }

    /// Copies the selected text to the clipboard as a formatted quote with book metadata.
    ///
    /// Format:
    ///   "Selected passage here."
    ///
    ///   — Book Title, by Author Name
    @objc func shareSelection() {
        webView.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            guard let self, let text = result as? String, !text.isEmpty else { return }
            let formatted = """
                \u{201C}\(text)\u{201D}

                \u{2014} \(self.book.displayTitle), by \(self.book.displayAuthors)
                """
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(formatted, forType: .string)
                self.showHUD("Copied to clipboard")
            }
        }
    }

    /// Debug implementation for B1 — confirms the menu wiring fires and JS evaluation
    /// returns the expected selection text. Full popover UI (colour picker, note field,
    /// save to BookState.annotationsData) is implemented in session 8C-2.
    ///
    /// If this alert never appears when you tap "Add Annotation…", the target/action
    /// wiring in ReaderMenuWebView.willOpenMenu is broken — check that item.target = vc.
    /// If the alert appears but "selectedText" is empty, the JS evaluation failed or
    /// the menu was opened without an active text selection.
    @objc func addAnnotationFromSelection() {
        webView.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            guard let self else { return }
            let selected = (result as? String) ?? ""
            DispatchQueue.main.async {
                let alert = NSAlert()
                if selected.isEmpty {
                    alert.messageText = "No text selected"
                    alert.informativeText = "Select some text in the reader, then right-click → Add Annotation…"
                } else {
                    alert.messageText = "Add Annotation — wiring confirmed ✓"
                    alert.informativeText = "Selected text (\(selected.count) chars):\n\n\"\(selected.prefix(300))\"\n\nFull popover UI with note field and colour picker is implemented in session 8C-2."
                }
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    // MARK: - HUD

    /// Brief non-blocking confirmation label that fades in, lingers, then fades out.
    private func showHUD(_ message: String) {
        let hud = NSTextField(labelWithString: message)
        hud.font              = .systemFont(ofSize: 13, weight: .medium)
        hud.textColor         = .white
        hud.isBezeled         = false
        hud.isEditable        = false
        hud.backgroundColor   = .clear
        hud.sizeToFit()

        // Pad around the text
        var f = hud.frame
        f = f.insetBy(dx: -14, dy: -7)
        f.origin = CGPoint(
            x: (view.bounds.width  - f.width)  / 2,
            y:  view.bounds.height * 0.12
        )
        hud.frame = f

        hud.wantsLayer        = true
        hud.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        hud.layer?.cornerRadius    = 8
        hud.alphaValue             = 0
        view.addSubview(hud)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            hud.animator().alphaValue = 1
        } completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    hud.animator().alphaValue = 0
                } completionHandler: {
                    hud.removeFromSuperview()
                }
            }
        }
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

// MARK: - ReaderMenuWebView

/// WKWebView subclass that intercepts WebKit's context menu via willOpenMenu(_:with:),
/// replacing it entirely with the reader's custom NSMenu (Option B from B1 spec).
///
/// willOpenMenu is a macOS-only WKWebView method — it is NOT the iOS-only
/// WKUIDelegate method and does not require any delegate hookup.
/// WebKit calls it on the WKWebView instance before displaying the menu, passing
/// the menu it intends to show. We clear that menu and replace it with our own items.
private class ReaderMenuWebView: WKWebView {

    weak var viewController: ReaderViewController?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        // Step 1: strip unwanted WebKit default items by title.
        // "Copy Link with Highlight" pollutes the menu; "Share…" is replaced by our
        // own Share item that formats the quote with book metadata.
        let titlesToStrip: Set<String> = [
            "Copy Link with Highlight",
            "Share\u{2026}",   // "Share…" with Unicode ellipsis (U+2026)
            "Share...",        // ASCII fallback
        ]
        for item in menu.items where titlesToStrip.contains(item.title) {
            menu.removeItem(item)
        }

        guard let vc = viewController else {
            super.willOpenMenu(menu, with: event)
            return
        }

        // Step 2: prepend our custom items at the top of the (now-cleaned) menu.
        let prefs = ReaderPreferences.shared.contextMenu
        var idx = 0

        if prefs.showSearchInBrowser {
            let item = NSMenuItem(
                title: "Search in Browser",
                action: #selector(ReaderViewController.searchInBrowser),
                keyEquivalent: ""
            )
            item.target = vc
            menu.insertItem(item, at: idx)
            idx += 1
        }

        if prefs.showAddAnnotation {
            let item = NSMenuItem(
                title: "Add Annotation\u{2026}",
                action: #selector(ReaderViewController.addAnnotationFromSelection),
                keyEquivalent: ""
            )
            item.target = vc
            menu.insertItem(item, at: idx)
            idx += 1
        }

        let shareItem = NSMenuItem(
            title: "Share",
            action: #selector(ReaderViewController.shareSelection),
            keyEquivalent: ""
        )
        shareItem.target = vc
        menu.insertItem(shareItem, at: idx)
        idx += 1

        if idx > 0 {
            menu.insertItem(.separator(), at: idx)
        }

        super.willOpenMenu(menu, with: event)
    }
}
