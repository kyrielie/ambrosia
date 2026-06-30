import AppKit
import WebKit
import SwiftData
import SwiftUI
import Combine

struct LocalReaderFindState: Equatable {
    var query: String = ""
    var matchCurrent: Int = 0
    var matchTotal: Int = 0
    var isVisible: Bool = false
}

// MARK: - ReaderViewController
//
// Hosts the main visible WKWebView for reading.
// Supports two modes: .scroll and .paginated.
//
// PAGINATION ARCHITECTURE (CSS columns):
//   In paginated mode the full merged HTML document is loaded once into the
//   single visible WKWebView, just like scroll mode. Pagination is provided
//   entirely by the browser's CSS multi-column layout engine:
//
//     body { column-width: <vw>px; column-gap: 0; height: <vh>px; overflow: hidden; }
//
//   One CSS column == one page. "Turning a page" == setting scrollLeft.
//   No hidden measurement WebView. No DOM slicing. No per-page loadHTMLString.
//   No character-offset translation layer.
//
//   The UTF-16 TreeWalker offset contract is fully preserved: the DOM is never
//   modified, so all annotation/highlight offsets remain valid unchanged.
//
// Annotation flow:
//   mouseup → highlightAdded → store pendingAnnotation (NO UI shown)
//   "Add Annotation…" menu item → addAnnotationFromSelection() → present popover
//   ⌘D → savePointAnnotationAtCurrentPosition() → immediate save + sentence preview
//
// Find bar: ⌘F / ⌘G / ⇧⌘G. Uses WKFindConfiguration (macOS 13+).
//
// Message handlers (all registered at construction time):
//   positionUpdate, pageAction, highlightAdded, highlightTapped

class ReaderViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {

    // MARK: - Dependencies

    let target: ReadingTarget
    let book: CalibreBook
    let modelContainer: ModelContainer
    var onReaderContentReady: (() -> Void)?
    private(set) var isReaderContentReady = false

    // MARK: - Private: reader state

    private var webView: ReaderMenuWebView!
    private var parser: EPUBParser?
    private var imageBaseURL: URL?
    /// AO3 metadata for the primary book, fetched asynchronously after the
    /// parser loads. Threaded into mergedHTML for endmatter emission.
    private var ao3Record: AO3MetadataRecord?

    fileprivate var currentMode: ReadingMode = .scroll
    private var currentHTML: String = ""

    private var currentSpineIndex: Int = 0
    private var pendingAnnotationJump: Annotation?
    private var paginationEngine: PaginationEngine?

    /// Set once the view has completed its first AppKit layout pass. Gates
    /// loadSpineItem so paginated geometry is never computed against a
    /// transient .zero/partial bounds (see Known Issue #3).
    private var isLayoutReady = false
    /// A spine load requested before the first layout pass completed.
    /// Replayed once isLayoutReady flips true.
    private var pendingSpineLoad: (index: Int, restorePage: Int?)?

    // Resize debounce
    private let resizeDebounce = DebounceTimer(delay: 0.3)

    /// Local NSEvent monitor that intercepts trackpad/mouse scrollWheel events
    /// before AppKit dispatches them into the WKWebView's own responder chain.
    /// Needed because the NSView-level `scrollWheel(with:)` override on
    /// ReaderMenuWebView never actually runs for trackpad input — WKWebView's
    /// internal scrolling consumes the gesture itself before any subclass
    /// override sees it, which is why `html { overflow-x: scroll }` was still
    /// freely scrollable by hand in paginated mode despite that override.
    private var scrollWheelMonitor: Any?

    // Annotation sidebar
    private var sidebarPanel: NSPanel?
    private var sidebarHostingView: NSHostingView<AnnotationSidebarView>?
    private var sidebarPanelObservers: [NSObjectProtocol] = []

    // Pending annotation captured at mouseup
    private var pendingAnnotation: Annotation?
    private var pendingCursorX: CGFloat = 0
    private var pendingCursorY: CGFloat = 0
    private var pendingMenuAnchorPoint: CGPoint?

    // Active popovers
    private var annotationPopover: NSPopover?
    private var notePopover: NSPopover?

    // Preferences subscription
    private var prefsCancellable: AnyCancellable?

    // Find bar
    private var findBarHostingView: NSHostingView<FindBarView>?
    private var findSearchText: String = ""
    private var findMatchCurrent: Int = 0
    private var findMatchTotal: Int = 0
    private var findCountToken: Int = 0

    // MARK: - Private: persistence

    private var saveTimer: Timer?
    private var readingHistorySessionID: Int64?
    private var _saveContext: ModelContext?
    private var saveContext: ModelContext {
        if let c = _saveContext { return c }
        let c = ModelContext(modelContainer)
        _saveContext = c
        return c
    }
    private var bookState: BookState?
    private var annotations: [Annotation] = []
    var onReadingProgressChanged: (() -> Void)?
    var onAnnotationsChanged: (([Annotation]) -> Void)?
    var onLocalFindStateChanged: ((LocalReaderFindState) -> Void)?
    var onOpenSearchSidebar: (() -> Void)?

    // MARK: - Init

    init(book: CalibreBook, modelContainer: ModelContainer) {
        self.target         = .singleBook(book)
        self.book           = book
        self.modelContainer = modelContainer
        super.init(nibName: nil, bundle: nil)
    }

    init(target: ReadingTarget, modelContainer: ModelContainer) {
        self.target         = target
        self.book           = target.primaryBook
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

        config.userContentController.add(self, name: "positionUpdate")
        config.userContentController.add(self, name: "pageAction")
        config.userContentController.add(self, name: "highlightAdded")
        config.userContentController.add(self, name: "highlightTapped")
        config.userContentController.add(self, name: "consoleLog")   // JS console → Xcode log

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Self.nsColor(hex: ReaderPreferences.shared.readerBackgroundColor)?.cgColor

        webView = ReaderMenuWebView(frame: .zero, configuration: config)
        webView.viewController = self
        webView.navigationDelegate = self
        if let bg = Self.nsColor(hex: ReaderPreferences.shared.readerBackgroundColor) {
            webView.underPageBackgroundColor = bg   // macOS 12+ — fills the scroll area
            webView.setValue(false, forKey: "drawsBackground")  // suppress white default draw
        }
        let engine = PaginationEngine(webView: webView)
        engine.spineNavigationHandler = { [weak self] forward in
            forward ? self?.loadNextSpineItem() : self?.loadPreviousSpineItem()
        }
        engine.positionDidChange = { [weak self] _, _ in
            self?.savePaginatedProgress()
        }
        engine.spineDidLoad = { [weak self] _ in
            self?.performPendingAnnotationJumpIfNeeded()
            self?.savePaginatedProgress()
        }
        paginationEngine = engine
        webView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Disable bounce scroll — in paginated mode horizontal bounce looks wrong.
        // Must run after addSubview: enclosingScrollView is nil until the web
        // view is actually part of a view hierarchy.
        webView.enclosingScrollView?.horizontalScrollElasticity = .none
        webView.enclosingScrollView?.verticalScrollElasticity   = .none

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        ensureBookState()
        currentMode = ReaderPreferences.shared.defaultReadingMode
        subscribeToPreferences()

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.loadEPUB()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startReadingHistoryIfNeeded()
        installScrollWheelMonitor()
        // Without this, AppKit's default first responder (the window itself,
        // or whatever WKWebView's internal scrolling machinery claims) handles
        // arrow keys as raw scroll offsets into the web view's internal
        // NSScrollView, bypassing ReaderMenuWebView.keyDown entirely. That
        // internal scroll is not paging-aware, which is what let horizontal
        // drag/arrow input reveal CSS columns to the right uncontrolled.
        view.window?.makeFirstResponder(webView)
    }

    deinit {
        if let m = scrollWheelMonitor { NSEvent.removeMonitor(m) }
    }

    // Intercepting at the window-event-monitor level — rather than overriding
    // scrollWheel(with:) on the WKWebView subclass — is required because
    // WKWebView's internal scrolling machinery handles trackpad/mouse wheel
    // input itself; a subclass override of scrollWheel(with:) is bypassed
    // entirely for that input path. A local monitor sees the event before
    // AppKit's normal dispatch reaches the view hierarchy at all, so
    // returning nil here reliably prevents the WKWebView from ever scrolling
    // off a column boundary by hand. A completed two-finger swipe is still
    // mapped to a discrete page turn so trackpad users keep that affordance.
    private func installScrollWheelMonitor() {
        guard scrollWheelMonitor == nil else { return }
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.currentMode == .paginated, event.window === self.view.window else {
                return event
            }
            if event.phase == .ended || event.momentumPhase == .began {
                let dx = event.scrollingDeltaX
                if abs(dx) > 20 {
                    dx < 0 ? self.goToNextPage() : self.goToPreviousPage()
                }
            }
            return nil
        }
    }

    private func removeScrollWheelMonitor() {
        if let m = scrollWheelMonitor {
            NSEvent.removeMonitor(m)
            scrollWheelMonitor = nil
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !isLayoutReady {
            isLayoutReady = true
            if let pending = pendingSpineLoad {
                pendingSpineLoad = nil
                loadSpineItem(index: pending.index, restorePage: pending.restorePage)
            }
        }
        repositionFindBar()
        // Sync the annotation panel whenever the reader view's bounds change.
        // Window move/resize notifications cover whole-window geometry changes,
        // but NSSplitView divider drags change the reader pane's screen rect
        // without firing a window resize notification, so we handle them here.
        syncSidebarPanel()
        guard currentMode == .paginated else { return }
        resizeDebounce.schedule { [weak self] in
            self?.paginationEngine?.reapplyLayout()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        removeScrollWheelMonitor()
        saveTimer?.invalidate()
        saveTimer = nil
        removeReaderWindowObservers()
        sidebarPanel?.close()
        annotationPopover?.close()
        notePopover?.close()
        hideFindBar()
        flushPosition(final: true)
    }

    // MARK: - EPUB loading

    private func loadEPUB() async {
        guard let pathStr = LibraryRegistry.shared.activePath else {
            await MainActor.run { self.showError("No library open.") }; return
        }
        let libraryRoot = URL(fileURLWithPath: pathStr)
        do {
            let record = await fetchAO3Record()
            let loaded = try await loadHTML(for: target, libraryRoot: libraryRoot, ao3Record: record)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.ao3Record     = record
                self.parser        = loaded.parser
                self.imageBaseURL  = loaded.imageBaseURL
                self.currentHTML   = loaded.html
                self.loadCurrentHTML()
            }
        } catch {
            await MainActor.run { self.showError(error.localizedDescription) }
        }
    }

    private func fetchAO3Record() async -> AO3MetadataRecord? {
        guard let metaDB = await MainActor.run(body: { AppDelegate.shared?.session.metaDB }) else { return nil }
        let id = book.id
        let map = (try? await metaDB.ao3Metadata(for: [id])) ?? [:]
        return map[id]
    }

    private func loadHTML(for target: ReadingTarget, libraryRoot: URL, ao3Record: AO3MetadataRecord?) async throws -> (parser: EPUBParser?, imageBaseURL: URL?, html: String) {
        switch target {
        case .singleBook(let book):
            guard let epubURL = book.epubURL(libraryRoot: libraryRoot),
                  FileManager.default.fileExists(atPath: epubURL.path) else {
                throw NSError(domain: "Ambrosia.Reader", code: 1, userInfo: [NSLocalizedDescriptionKey: "EPUB file not found: \(book.displayTitle)"])
            }
            var p = EPUBParser(epubURL: epubURL)
            try p.parse()
            let imgBase = try EPUBParser.extractImages(from: epubURL, calibreID: book.id)
            let html = try p.mergedHTML(userCSS: ReaderPreferences.shared.css, ao3Record: ao3Record)
            return (p, imgBase, html)

        case .series(let series):
            // Batch-fetch ao3 records for all works so each gets its own endmatter.
            let allIDs = series.works.map(\.id)
            let metaDB = await MainActor.run { AppDelegate.shared?.session.metaDB }
            let recordMap = (try? await metaDB?.ao3Metadata(for: allIDs)) ?? [:]

            var firstParser: EPUBParser?
            var firstImageBaseURL: URL?
            var parts: [String] = []
            for (offset, work) in series.works.enumerated() {
                guard let epubURL = work.epubURL(libraryRoot: libraryRoot),
                      FileManager.default.fileExists(atPath: epubURL.path) else {
                    throw NSError(domain: "Ambrosia.Reader", code: 2, userInfo: [NSLocalizedDescriptionKey: "EPUB file not found: \(work.displayTitle)"])
                }
                var parser = EPUBParser(epubURL: epubURL)
                try parser.parse()
                let imageBase = try EPUBParser.extractImages(from: epubURL, calibreID: work.id)
                if offset == 0 {
                    firstParser = parser
                    firstImageBaseURL = imageBase
                }
                let displayIndex = series.displayIndex(for: work) ?? offset + 1
                let breakHTML = """
                <div class="ambrosia-series-break"><h2>Work \(displayIndex): \(Self.escapeHTML(work.displayTitle))</h2></div>
                """
                let workHTML = try parser.mergedHTML(userCSS: ReaderPreferences.shared.css, ao3Record: recordMap[work.id])
                parts.append(breakHTML + workHTML)
            }
            return (firstParser, firstImageBaseURL, parts.joined(separator: "\n"))
        }
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - HTML reload

    func reloadHTML() {
        guard let p = parser else { return }
        do {
            let html = try p.mergedHTML(userCSS: ReaderPreferences.shared.css, ao3Record: ao3Record)
            currentHTML = html
            loadCurrentHTML()
        } catch {
            print("[ReaderVC] reloadHTML error: \(error)")
        }
    }

    /// Loads `currentHTML` into the webView, prepending column CSS if in paginated mode.
    private func loadCurrentHTML() {
        isReaderContentReady = false
        if currentMode == .paginated {
            loadPaginatedHTML()
        } else {
            webView.loadHTMLString(currentHTML, baseURL: imageBaseURL)
        }
    }

    // MARK: - Paginated HTML loading

    /// Builds the HTML string for paginated mode by prepending a <style> block
    /// containing the column layout CSS, then loads it. The column CSS is sized
    /// to the current webView bounds. If bounds aren't ready yet, defers briefly.
    private func loadPaginatedHTML() {
        let spineCount = parser?.spine.count ?? 0
        let savedSpine = min(max(0, bookState?.lastSpineIndex ?? currentSpineIndex), max(0, spineCount - 1))
        loadSpineItem(index: savedSpine, restorePage: nil)
    }

    private func loadSpineItem(index: Int, restorePage: Int? = nil) {
        guard let parser, index >= 0, index < parser.spine.count else { return }

        guard isLayoutReady, view.window != nil else {
            pendingSpineLoad = (index, restorePage)
            return
        }

        currentSpineIndex = index
        bookState?.lastSpineIndex = index

        let item = parser.spine[index]
        do {
            let html = try parser.html(for: item, userCSS: ReaderPreferences.shared.css(paginated: true))
            isReaderContentReady = false
            paginationEngine?.setColsPerScreen(ReaderPreferences.shared.colsPerScreen)
            paginationEngine?.loadSpine(html: html, baseURL: imageBaseURL, restoreFraction: restorePage.map(Double.init) ?? bookState?.lastScrollOffset)
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: - Preferences subscription

    private func subscribeToPreferences() {
        prefsCancellable = ReaderPreferences.shared.objectWillChange
            .sink { [weak self] _ in
                if let bg = Self.nsColor(hex: ReaderPreferences.shared.readerBackgroundColor) {
                    self?.webView.underPageBackgroundColor = bg
                    self?.view.layer?.backgroundColor = bg.cgColor
                }
                DispatchQueue.main.asyncAfter(deadline: .now()) {
                    self?.reloadHTML()
                }
            }
    }

    // MARK: - Mode switching

    func switchToScrollMode() {
        saveCurrentPositionSync { [weak self] in
            guard let self else { return }
            self.currentMode = .scroll
            self.currentSpineIndex = 0
            self.pendingAnnotationJump = nil
            self.reloadHTML()
        }
    }

    func switchToPaginatedMode() {
        saveCurrentPositionSync { [weak self] in
            guard let self else { return }
            self.currentMode = .paginated
            let spineCount = self.parser?.spine.count ?? 0
            let savedSpine = min(max(0, self.bookState?.lastSpineIndex ?? self.currentSpineIndex), max(0, spineCount - 1))
            self.loadSpineItem(index: savedSpine, restorePage: nil)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let consoleBridgeJS = """
        (function() {
          if (window.__ambrosiaConsoleBridgeInstalled) return;
          window.__ambrosiaConsoleBridgeInstalled = true;
          const oldLog = console.log;
          console.log = function() {
            try { window.webkit.messageHandlers.consoleLog.postMessage(Array.from(arguments).join(" ")); } catch(e) {}
            oldLog.apply(console, arguments);
          };
        })();
        """
        webView.evaluateJavaScript(consoleBridgeJS, completionHandler: nil)

        if currentMode == .paginated {
            paginationEngine?.applyLayout()
        }

        HighlightBridge.injectSelectionListener(into: webView)
        restoreAnnotations()

        if currentMode == .scroll {
            restoreScrollPosition()
            injectScrollTracker()
        }

        startAutoSave()
        isReaderContentReady = true
        onReaderContentReady?()
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!, withError error: Error) {
        print("[ReaderVC] Navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated else {
            decisionHandler(.allow)
            return
        }

        guard ReaderPreferences.shared.allowReaderLinkClicks,
              let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if url.scheme == "about" || url.scheme == "file" {
            decisionHandler(.allow)
            return
        }

        if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.cancel)
    }

    // MARK: - Scroll mode: position save/restore

    private func restoreScrollPosition() {
        let fraction = bookState?.lastScrollOffset ?? 0
        guard fraction > 0 else { return }
        let clamped = max(0.0, min(1.0, fraction))
        let js = """
        (function() {
            var maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
            window.scrollTo(0, \(clamped) * maxScroll);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func injectScrollTracker() {
        let js = """
        (function() {
            function sendPosition() {
                var doc = document.documentElement;
                var maxScroll = Math.max(1, doc.scrollHeight - window.innerHeight);
                var percent = Math.max(0, Math.min(1, window.scrollY / maxScroll));
                window.webkit.messageHandlers.positionUpdate.postMessage(
                    JSON.stringify({ scrollY: window.scrollY, percent: percent })
                );
            }
            window.addEventListener('scroll', function() {
                sendPosition();
            }, { passive: true });
            sendPosition();
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Paginated mode: position restore

    private func restorePaginatedPosition() {
        let fraction = bookState?.lastScrollOffset ?? 0
        paginationEngine?.scrollToFraction(fraction)
        savePaginatedProgress()
    }

    private func performPendingAnnotationJumpIfNeeded() {
        guard let annotation = pendingAnnotationJump,
              currentMode == .paginated,
              annotation.spineIndex == currentSpineIndex else { return }

        pendingAnnotationJump = nil
        let offset = annotation.startChar
        let js = """
        if (window.ambrosiaNavigateToOffset) { window.ambrosiaNavigateToOffset(\(offset)); }
        if (window.ambrosiaHighlight) { window.ambrosiaHighlight(\(offset)); }
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        savePaginatedProgress()
    }

    private func repaginatePreservingPosition() {
        guard currentMode == .paginated else { return }
        paginationEngine?.queryProgress { [weak self] fraction, _, _ in
            guard let self else { return }
            self.paginationEngine?.applyLayout()
            self.paginationEngine?.scrollToFraction(fraction)
        }
    }

    func goToNextPage() {
        guard currentMode == .paginated else { return }
        paginationEngine?.handleKeyDown(.forward)
    }

    func goToPreviousPage() {
        guard currentMode == .paginated else { return }
        paginationEngine?.handleKeyDown(.backward)
    }

    private func loadNextSpineItem() {
        guard let parser, currentSpineIndex + 1 < parser.spine.count else { return }
        savePaginatedProgress()
        loadSpineItem(index: currentSpineIndex + 1, restorePage: 0)
    }

    private func loadPreviousSpineItem() {
        guard currentSpineIndex > 0 else { return }
        savePaginatedProgress()
        loadSpineItem(index: currentSpineIndex - 1, restorePage: 1)
    }

    private func savePaginatedProgress() {
        guard currentMode == .paginated else { return }
        paginationEngine?.queryProgress { [weak self] fraction, col, total in
            guard let self else { return }
            // total==1 with col==0 means ambrosiaSetup hasn't run yet — don't
            // write 100% progress from a spurious 1.0 fraction.
            guard total > 1 || col > 0 else { return }
            self.bookState?.lastSpineIndex = self.currentSpineIndex
            self.bookState?.lastScrollOffset = fraction
            self.bookState?.totalReadPercent = fraction
            self.onReadingProgressChanged?()
        }
    }

    private func updateProgressForCurrentPage() {
        savePaginatedProgress()
    }
    /// In scroll mode it fires an evaluateJavaScript call.
    private func saveCurrentPositionSync(completion: @escaping () -> Void) {
        if currentMode == .paginated {
            saveCurrentPage()
            completion()
        } else {
            let js = """
            (function() {
                var maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
                var percent = Math.max(0, Math.min(1, window.scrollY / maxScroll));
                var targetY = window.scrollY + 20;
                var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
                var cumulative = 0, node;
                function bottomFor(n, lo) {
                    var r = document.createRange();
                    r.setStart(n, Math.max(0, Math.min(lo, n.length)));
                    r.collapse(true);
                    var m = document.createElement('span');
                    m.style.cssText = 'display:inline-block;width:0;height:1em;line-height:1;vertical-align:baseline;padding:0;margin:0;border:0;';
                    r.insertNode(m);
                    var rect = m.getBoundingClientRect();
                    var b = rect.bottom + window.scrollY;
                    m.parentNode.removeChild(m);
                    return b;
                }
                while ((node = walker.nextNode()) !== null) {
                    if (node.length === 0) continue;
                    var endBottom = bottomFor(node, node.length);
                    if (endBottom >= targetY) {
                        var lo = 0, hi = node.length;
                        while (lo < hi) {
                            var mid = Math.floor((lo + hi) / 2);
                            if (bottomFor(node, mid) < targetY) lo = mid + 1; else hi = mid;
                        }
                        return { percent: percent, charOffset: cumulative + lo };
                    }
                    cumulative += node.length;
                }
                return { percent: percent, charOffset: cumulative };
            })();
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, let dict = result as? [String: Any] else {
                    completion(); return
                }
                let percent = Self.double(from: dict["percent"]) ?? 0
                let charOffset = dict["charOffset"] as? Int ?? 0
                self.bookState?.lastScrollOffset    = min(max(percent, 0), 1)
                self.bookState?.lastCharacterOffset = charOffset
                completion()
            }
        }
    }

    private func saveCurrentPage() {
        savePaginatedProgress()
    }

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

    private func startAutoSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.flushPosition()
        }
    }

    private func flushPosition(final: Bool = false) {
        guard bookState != nil else { return }
        try? saveContext.save()
        updateReadingHistory(final: final)
        onReadingProgressChanged?()
    }

    private func startReadingHistoryIfNeeded() {
        guard readingHistorySessionID == nil else { return }
        let calibreID = book.id
        let percentStart = bookState.map { min(max($0.totalReadPercent, 0), 1) }
        Task {
            do {
                guard let metaDB = await MainActor.run(body: { AppDelegate.shared?.session.metaDB }) else { return }
                try await metaDB.closeZombieReadingSessions(calibreID: calibreID)
                let id = try await metaDB.startReadingSession(calibreID: calibreID, percentStart: percentStart)
                await MainActor.run {
                    self.readingHistorySessionID = id
                }
            } catch {
                print("[ReadingHistory] Start failed: \(error)")
            }
        }
    }

    private func updateReadingHistory(final: Bool = false) {
        guard let sessionID = readingHistorySessionID,
              let state = bookState else { return }
        let calibreID = state.calibreID
        let percent = min(max(state.totalReadPercent, 0), 1)
        Task {
            do {
                let dependencies = await MainActor.run {
                    (
                        metaDB: AppDelegate.shared?.session.metaDB,
                        collectionStore: AppDelegate.shared?.session.collectionStore
                    )
                }
                guard let metaDB = dependencies.metaDB else { return }
                try await metaDB.updateReadingSession(id: sessionID, calibreID: calibreID, percentEnd: percent)
                if percent >= 1.0 {
                    try await dependencies.collectionStore?.syncAutomatedCollection(
                        collectionID: SystemCollectionID.finished,
                        calibreID: calibreID,
                        shouldBeMember: true
                    )
                    try await dependencies.collectionStore?.syncAutomatedCollection(
                        collectionID: SystemCollectionID.inProgress,
                        calibreID: calibreID,
                        shouldBeMember: false
                    )
                } else if percent > 0 {
                    try await dependencies.collectionStore?.syncAutomatedCollection(
                        collectionID: SystemCollectionID.inProgress,
                        calibreID: calibreID,
                        shouldBeMember: true
                    )
                }
                await MainActor.run {
                    AppDelegate.shared?.session.bumpMembershipVersion()  // §7
                }
            } catch {
                print("[ReadingHistory] \(final ? "Final update" : "Update") failed: \(error)")
            }
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        switch message.name {

        case "consoleLog":
            if let body = message.body as? String {
                print("[JS] \(body)")
            }

        case "positionUpdate":
            guard let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            if let fraction = Self.double(from: json["fraction"]) {
                bookState?.lastSpineIndex = currentSpineIndex
                bookState?.lastScrollOffset = min(max(fraction, 0), 1)
                bookState?.totalReadPercent = min(max(fraction, 0), 1)
            } else if let percent = Self.double(from: json["percent"]) {
                bookState?.lastScrollOffset = min(max(percent, 0), 1)
                bookState?.totalReadPercent = min(max(percent, 0), 1)
            }

        case "pageAction":
            guard let body = message.body as? String else { return }
            // JS ambrosiaNextPage/PrevPage posts JSON only when crossing spine boundaries.
            if let data = body.data(using: .utf8),
                    let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let action = dict["action"] as? String {
                switch action {
                case "nextSpineItem": loadNextSpineItem()
                case "prevSpineItem": loadPreviousSpineItem()
                default: break
                }
            }

        case "highlightAdded":
            if let annotation = HighlightBridge.decodeAnnotation(from: message) {
                pendingAnnotation = annotation
                if let body = message.body as? String,
                   let data = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let cursorX    = Self.cgFloat(from: json["cursorX"])
                    let cursorY = Self.cgFloat(from: json["cursorY"])
                    pendingCursorX    = cursorX > 0 ? cursorX : webView.bounds.midX
                    pendingCursorY = cursorY > 0 ? cursorY : webView.bounds.midY
                }
            }

        case "highlightTapped":
            guard let (idStr, clientX, clientY) = HighlightBridge.decodeTap(from: message) else { return }
            let idWithDashes = idStr.inserting(dashes: true)
            guard let uuid = UUID(uuidString: idWithDashes),
                  let annotation = annotations.first(where: { $0.id == uuid }),
                  let note = annotation.note, !note.isEmpty
            else { return }
            DispatchQueue.main.async { [weak self] in
                self?.presentNotePopover(note: note, clientX: clientX, clientY: clientY)
            }

        default:
            break
        }
    }

    // MARK: - Keyboard events

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "d": savePointAnnotationAtCurrentPosition(); return
            case "b": toggleAnnotationSidebar(); return
            case "f": toggleFindBar(); return
            case "g":
                if event.modifierFlags.contains(.shift) { findPrevious() }
                else { findNext() }
                return
            default: break
            }
        }
        if event.keyCode == 53 && findBarHostingView != nil { hideFindBar(); return }
        super.keyDown(with: event)
    }

    // MARK: - Responder-chain actions

    @objc func addAnnotation(_ sender: Any?) { savePointAnnotationAtCurrentPosition() }
    @objc func showAnnotationSidebar(_ sender: Any?) { toggleAnnotationSidebar() }

    // MARK: - Point annotations (⌘D)

    private func savePointAnnotationAtCurrentPosition() {
        guard let state = bookState else { return }

        let offset = state.lastCharacterOffset
        let spineIndex = state.lastSpineIndex

        let sentenceJS = """
        (function() {
            var target = Math.max(0, \(offset));
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
            var remaining = target;
            var node;
            while ((node = walker.nextNode()) !== null) {
                if (remaining <= node.length) {
                    var nodes = [];
                    var bw = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
                    var n;
                    while ((n = bw.nextNode()) !== null) nodes.push(n);
                    var nodeIdx = nodes.indexOf(node);
                    var charIdx = remaining;
                    var collected = '', charPos = charIdx - 1, ni = nodeIdx;
                    while (ni >= 0 && collected.length < 150) {
                        var txt = nodes[ni].data;
                        var from = (ni === nodeIdx) ? charPos : txt.length - 1;
                        for (var i = from; i >= 0 && collected.length < 150; i--) {
                            var ch = txt[i];
                            if (ch === '.' || ch === '!' || ch === '?' || ch === '\\n') break;
                            collected = ch + collected;
                        }
                        if (collected.length < 150) ni--;
                    }
                    var before = collected.trimStart();
                    collected = ''; charPos = charIdx; ni = nodeIdx;
                    while (ni < nodes.length && collected.length < 150) {
                        var txt2 = nodes[ni].data;
                        var from2 = (ni === nodeIdx) ? charPos : 0;
                        for (var j = from2; j < txt2.length && collected.length < 150; j++) {
                            var ch2 = txt2[j];
                            collected += ch2;
                            if (ch2 === '.' || ch2 === '!' || ch2 === '?') break;
                        }
                        if (collected.length < 150 && !collected.match(/[.!?]$/)) ni++;
                        else break;
                    }
                    var after = collected.trimEnd();
                    return (before + after).trim().replace(/\\s+/g, ' ');
                }
                remaining -= node.length;
            }
            return '';
        })();
        """

        webView.evaluateJavaScript(sentenceJS) { [weak self] result, _ in
            guard let self else { return }
            let previewText = (result as? String) ?? ""

            let annotation = Annotation(
                spineIndex:   spineIndex,
                startChar:    offset,
                endChar:      offset,
                selectedText: previewText,
                colorHex:     "#FFD60A"
            )

            var existing = self.annotations
            if !existing.contains(where: {
                $0.startChar == offset && $0.spineIndex == spineIndex && $0.isPointAnnotation
            }) {
                existing.append(annotation)
                self.annotations = existing
                self.onAnnotationsChanged?(existing)
                Task { try? await AppDelegate.shared?.session.metaDB?.insertAnnotation(
                    annotation, calibreID: self.book.id) }
            }

            self.webView.evaluateJavaScript(
                "window.ambrosiaHighlight(\(offset));",
                completionHandler: nil
            )
            self.flushPosition()
            self.refreshSidebarIfVisible()
            self.showHUD("Bookmark saved")
        }
    }

    // MARK: - Ranged annotations (context menu → popover)

    @objc func addAnnotationFromSelection() {
        guard let pending = pendingAnnotation, !pending.selectedText.isEmpty else {
            showHUD("Select text first, then right-click")
            return
        }
        presentAnnotationPopover(for: pending)
        pendingAnnotation = nil
    }

    private func presentAnnotationPopover(for pending: Annotation) {
        annotationPopover?.close()

        let popoverView = AnnotationPopover(
            selectedText: pending.selectedText,
            onSave: { [weak self] note, colorHex in
                guard let self else { return }
                self.annotationPopover?.close()
                self.annotationPopover = nil

                var final = pending
                final.note     = note
                final.colorHex = colorHex

                var existing = self.annotations
                existing.append(final)
                self.annotations = existing
                self.onAnnotationsChanged?(existing)
                Task { try? await AppDelegate.shared?.session.metaDB?.insertAnnotation(
                    final, calibreID: self.book.id) }
                self.flushPosition()
                self.refreshSidebarIfVisible()

                if !final.isPointAnnotation {
                    HighlightBridge.clearHighlights(from: self.webView) {
                        HighlightBridge.restoreHighlights(
                            existing.filter { !$0.isPointAnnotation },
                            into: self.webView
                        )
                    }
                }
                self.showHUD("Annotation saved")
            },
            onCancel: { [weak self] in
                self?.annotationPopover?.close()
                self?.annotationPopover = nil
            }
        )

        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: popoverView)
        popover.behavior = .semitransient
        popover.contentSize = NSSize(width: 320, height: 300)
        annotationPopover = popover

        let anchor = pendingMenuAnchorPoint.map(webViewAnchorRect(point:))
            ?? webViewAnchorRect(clientX: pendingCursorX, clientY: pendingCursorY)
        pendingMenuAnchorPoint = nil
        popover.show(relativeTo: anchor, of: webView, preferredEdge: .minY)
    }

    // MARK: - Note popup

    private func presentNotePopover(note: String, clientX: CGFloat, clientY: CGFloat) {
        notePopover?.close()
        let noteView = NotePopoverView(
            note: note
        )
        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: noteView)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 260, height: 150)
        notePopover = popover

        let anchor = webViewAnchorRect(point: webViewPoint(clientX: clientX, clientY: clientY))
        popover.show(relativeTo: anchor, of: webView, preferredEdge: .minY)
    }

    private func webViewAnchorRect(clientX: CGFloat, clientY: CGFloat) -> CGRect {
        webViewAnchorRect(point: webViewPoint(clientX: clientX, clientY: clientY))
    }

    fileprivate func setPendingMenuAnchorPoint(_ point: CGPoint) {
        pendingMenuAnchorPoint = point
    }

    private func webViewAnchorRect(point: CGPoint) -> CGRect {
        let maxX = max(0, webView.bounds.width - 1)
        let maxY = max(0, webView.bounds.height - 1)
        let x = min(max(point.x, 0), maxX)
        let y = min(max(point.y, 0), maxY)
        return CGRect(x: x, y: y, width: 1, height: 1)
    }

    private func webViewPoint(clientX: CGFloat, clientY: CGFloat) -> CGPoint {
        CGPoint(x: clientX, y: clientY)
    }

    // MARK: - Restore annotations

    private func restoreAnnotations() {
        Task {
            let loaded = (try? await AppDelegate.shared?.session.metaDB?.annotations(for: book.id)) ?? []
            await MainActor.run {
                annotations = loaded
                onAnnotationsChanged?(loaded)
                let ranged = loaded.filter {
                    !$0.isPointAnnotation && (currentMode != .paginated || $0.spineIndex == currentSpineIndex)
                }
                HighlightBridge.restoreHighlights(ranged, into: webView)
                refreshSidebarIfVisible()
            }
        }
    }

    func currentAnnotationsForSidebar() -> [Annotation] {
        annotations
    }

    // MARK: - Jump to annotation

    func jumpToAnnotation(_ annotation: Annotation) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let offset = annotation.startChar

            if self.currentMode == .paginated {
                if annotation.spineIndex != self.currentSpineIndex {
                    self.pendingAnnotationJump = annotation
                    self.loadSpineItem(index: annotation.spineIndex, restorePage: 0)
                    return
                }

                let js = """
                if (window.ambrosiaNavigateToOffset) { window.ambrosiaNavigateToOffset(\(offset)); }
                if (window.ambrosiaHighlight) { window.ambrosiaHighlight(\(offset)); }
                """
                self.webView.evaluateJavaScript(js, completionHandler: nil)
                self.savePaginatedProgress()
                return
            }

            if offset > 0 || annotation.selectedText.isEmpty {
                self.scrollToCharOffset(offset)
            } else {
                self.performFindAndJump(annotation.selectedText)
            }
        }
    }

    private func scrollToCharOffset(_ offset: Int) {
        let js = """
        (function() {
            var target = \(offset);
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
            var remaining = target, node;
            while ((node = walker.nextNode()) !== null) {
                if (remaining <= node.length) {
                    var range = document.createRange();
                    range.setStart(node, remaining);
                    range.collapse(true);
                    var marker = document.createElement('span');
                    marker.style.cssText = 'display:inline;font-size:0;line-height:0;';
                    range.insertNode(marker);
                    var rect = marker.getBoundingClientRect();
                    var y = rect.top + window.scrollY - 80;
                    marker.parentNode.removeChild(marker);
                    window.scrollTo({ top: Math.max(0, y), behavior: 'smooth' });
                    return;
                }
                remaining -= node.length;
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        webView.evaluateJavaScript(
            "if (window.ambrosiaHighlight) window.ambrosiaHighlight(\(offset));",
            completionHandler: nil
        )
    }

    // MARK: - Find bar

    private func toggleFindBar() {
        if findBarHostingView != nil { hideFindBar() } else { showFindBar() }
    }

    func showLocalFind() {
        guard findBarHostingView == nil else { return }
        showFindBar()
    }

    func setLocalFindText(_ text: String) {
        guard findSearchText != text else { return }
        findSearchText = text
        performFind(findSearchText)
        publishLocalFindState()
    }

    func localFindNext() {
        findNext()
    }

    func localFindPrevious() {
        findPrevious()
    }

    func currentLocalFindState() -> LocalReaderFindState {
        LocalReaderFindState(
            query: findSearchText,
            matchCurrent: findMatchCurrent,
            matchTotal: findMatchTotal,
            isVisible: findBarHostingView != nil
        )
    }

    private func showFindBar(openSidebar: Bool = false) {
        if openSidebar {
            onOpenSearchSidebar?()
        }
        guard findBarHostingView == nil else {
            publishLocalFindState()
            return
        }
        let barView = FindBarView(
            searchText:   Binding(get: { self.findSearchText }, set: { self.setLocalFindText($0) }),
            matchCurrent: findMatchCurrent,
            matchTotal:   findMatchTotal,
            onNext:       { [weak self] in self?.findNext() },
            onPrevious:   { [weak self] in self?.findPrevious() },
            onClose:      { [weak self] in self?.hideFindBar() }
        )
        let hosting = NSHostingView(rootView: barView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosting.heightAnchor.constraint(equalToConstant: 44),
        ])
        findBarHostingView = hosting
        publishLocalFindState()
    }

    private func hideFindBar() {
        findBarHostingView?.removeFromSuperview()
        findBarHostingView = nil
        findSearchText    = ""
        findMatchCurrent  = 0
        findMatchTotal    = 0
        if #available(macOS 13.0, *) {
            webView.find("", configuration: WKFindConfiguration()) { _ in }
        }
        updateFindBar()
        publishLocalFindState()
    }

    private func repositionFindBar() { /* Auto Layout handles it */ }

    private func performFind(_ query: String) {
        guard #available(macOS 13.0, *) else { return }
        guard !query.isEmpty else {
            findMatchCurrent = 0; findMatchTotal = 0
            webView.find("", configuration: WKFindConfiguration()) { _ in }
            updateFindBar(); publishLocalFindState(); return
        }
        let config = WKFindConfiguration()
        config.caseSensitive = false; config.wraps = true; config.backwards = false
        updateLiteralMatchCount(for: query) { [weak self] total in
            guard let self else { return }
            self.findMatchTotal = total
            self.findMatchCurrent = total > 0 ? 1 : 0
            self.updateFindBar()
            self.publishLocalFindState()
        }
        webView.find(query, configuration: config) { [weak self] result in
            guard let self else { return }
            if !result.matchFound {
                self.findMatchCurrent = 0
            } else if self.findMatchTotal == 0 {
                self.findMatchTotal = 1
                self.findMatchCurrent = 1
            }
            self.updateFindBar()
            self.publishLocalFindState()
        }
    }

    private func findNext() {
        guard #available(macOS 13.0, *), !findSearchText.isEmpty else { return }
        let config = WKFindConfiguration()
        config.caseSensitive = false; config.wraps = true; config.backwards = false
        webView.find(findSearchText, configuration: config) { [weak self] result in
            guard let self else { return }
            if result.matchFound {
                self.findMatchCurrent = (self.findMatchCurrent % max(1, self.findMatchTotal)) + 1
            }
            self.updateFindBar()
            self.publishLocalFindState()
        }
    }

    private func findPrevious() {
        guard #available(macOS 13.0, *), !findSearchText.isEmpty else { return }
        let config = WKFindConfiguration()
        config.caseSensitive = false; config.wraps = true; config.backwards = true
        webView.find(findSearchText, configuration: config) { [weak self] result in
            guard let self else { return }
            if result.matchFound {
                self.findMatchCurrent = self.findMatchCurrent > 1
                    ? self.findMatchCurrent - 1 : self.findMatchTotal
            }
            self.updateFindBar()
            self.publishLocalFindState()
        }
    }

    private func updateLiteralMatchCount(for query: String, completion: @escaping (Int) -> Void) {
        findCountToken += 1
        let token = findCountToken
        guard let data = try? JSONSerialization.data(withJSONObject: [query]),
              let json = String(data: data, encoding: .utf8) else {
            completion(0)
            return
        }
        let js = """
        (() => {
            const query = \(json)[0].toLocaleLowerCase();
            if (!query) return 0;
            const text = (document.body ? document.body.innerText : document.documentElement.innerText || '').toLocaleLowerCase();
            let count = 0;
            let index = 0;
            while ((index = text.indexOf(query, index)) !== -1) {
                count += 1;
                index += Math.max(query.length, 1);
            }
            return count;
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] value, _ in
            guard let self, self.findCountToken == token else { return }
            if let number = value as? NSNumber {
                completion(number.intValue)
            } else if let int = value as? Int {
                completion(int)
            } else {
                completion(0)
            }
        }
    }

    private func performFindAndJump(_ text: String) {
        guard #available(macOS 13.0, *), !text.isEmpty else { return }
        let config = WKFindConfiguration()
        config.caseSensitive = false; config.wraps = true; config.backwards = false
        webView.find(text, configuration: config) { _ in }
    }

    private func updateFindBar() {
        guard let hosting = findBarHostingView else { return }
        hosting.rootView = FindBarView(
            searchText:   Binding(get: { self.findSearchText }, set: { self.setLocalFindText($0) }),
            matchCurrent: findMatchCurrent,
            matchTotal:   findMatchTotal,
            onNext:       { [weak self] in self?.findNext() },
            onPrevious:   { [weak self] in self?.findPrevious() },
            onClose:      { [weak self] in self?.hideFindBar() }
        )
    }

    private func publishLocalFindState() {
        onLocalFindStateChanged?(currentLocalFindState())
        refreshSidebarIfVisible()
    }

    // MARK: - Annotation sidebar

    func toggleAnnotationSidebar() {
        if let panel = sidebarPanel, panel.isVisible { panel.close(); return }
        openAnnotationSidebar()
    }

    private func openAnnotationSidebar() {
        guard let screenRect = readerScreenRect(),
              let readerWindow = view.window else { return }

        let sidebar = makeAnnotationSidebarView()
        let hosting = NSHostingView(rootView: sidebar)
        // Invariant #10: sizingOptions = [] lets Auto Layout (the panel's content
        // layout pass) own the hosting view's size. Without this NSHostingView
        // reports its SwiftUI intrinsic size, fights the window layout, and
        // collapses the panel — repositioning it to the left.
        hosting.sizingOptions = []
        sidebarHostingView = hosting

        // Anchor to the right edge of the *reader view's screen rect*, not the
        // enclosing window frame. In a standalone reader window both are the same,
        // but in the email split view the window frame's maxX is the library
        // window's right edge — which sits somewhere to the right of the reader
        // pane. Using the view's converted screen rect keeps the panel correctly
        // flush to the reader pane's right edge in both configurations.
        //
        // NSPanel(contentRect:) takes the *content* area (below the title bar), so
        // screenRect.height is used directly — the title bar is added on top of it.
        let contentRect = CGRect(
            x: screenRect.maxX,
            y: screenRect.minY,
            width: 260,
            height: screenRect.height
        )

        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Annotations"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.contentView = hosting  // frame is managed by window layout; sizingOptions=[] keeps hosting stable
        panel.orderFront(nil)
        sidebarPanel = panel

        // Observe window-level move/resize (handles whole-window drags and resizes).
        // Split-view-internal resizes are handled in viewDidLayout via syncSidebarPanel.
        removeReaderWindowObservers()
        let nc = NotificationCenter.default
        let move = nc.addObserver(forName: NSWindow.didMoveNotification, object: readerWindow, queue: .main) {
            [weak self, weak panel] _ in self?.syncSidebarPanel(panel)
        }
        let resize = nc.addObserver(forName: NSWindow.didResizeNotification, object: readerWindow, queue: .main) {
            [weak self, weak panel] _ in self?.syncSidebarPanel(panel)
        }
        let close = nc.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) {
            [weak self] _ in self?.removeReaderWindowObservers()
        }
        sidebarPanelObservers = [move, resize, close]
    }

    /// Returns the reader view's frame in screen coordinates.
    ///
    /// This is the correct anchor for the annotation panel in all hosting
    /// configurations. In a standalone reader window `view.window.frame` and
    /// this value are identical, but in email mode `ReaderViewController` is
    /// embedded as a child inside a split view: `view.window.frame` would return
    /// the whole library window's frame, placing the panel at the wrong x
    /// position whenever the split-view divider moves.
    private func readerScreenRect() -> NSRect? {
        guard let window = view.window else { return nil }
        let viewRectInWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(viewRectInWindow)
    }

    /// Repositions and resizes the annotation panel to stay flush with the right
    /// edge of the reader view in screen space. Called from both the window
    /// move/resize observers and from `viewDidLayout` (which fires on split-view
    /// divider drags that don't produce a window resize notification).
    func syncSidebarPanel(_ panel: NSPanel? = nil) {
        let target = panel ?? sidebarPanel
        guard let target, target.isVisible,
              let screenRect = readerScreenRect() else { return }
        let contentRect = CGRect(
            x: screenRect.maxX,
            y: screenRect.minY,
            width: target.frame.width,
            height: screenRect.height
        )
        let newFrame = NSPanel.frameRect(forContentRect: contentRect, styleMask: target.styleMask)
        target.setFrame(newFrame, display: true)
    }

    private func removeReaderWindowObservers() {
        sidebarPanelObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sidebarPanelObservers = []
    }

    private func makeAnnotationSidebarView() -> AnnotationSidebarView {
        AnnotationSidebarView(
            annotations: annotations,
            onJump: { [weak self] annotation in self?.jumpToAnnotation(annotation) },
            onDelete: { [weak self] id in
                self?.deleteAnnotation(id: id)
            }
        )
    }

    private func deleteAnnotation(id: UUID) {
        annotations = annotations.filter { $0.id != id }
        onAnnotationsChanged?(annotations)
        Task { try? await AppDelegate.shared?.session.metaDB?.deleteAnnotation(
            id: id, calibreID: book.id) }
        flushPosition()
        refreshSidebarIfVisible()
        HighlightBridge.removeHighlight(id: id, from: webView)
    }

    func deleteAnnotationFromSidebar(id: UUID) {
        deleteAnnotation(id: id)
    }

    private func refreshSidebarIfVisible() {
        guard let panel = sidebarPanel, panel.isVisible,
              let hosting = sidebarHostingView else { return }
        hosting.rootView = makeAnnotationSidebarView()
    }

    // MARK: - Helpers

    private static func cgFloat(from value: Any?) -> CGFloat {
        if let v = value as? CGFloat  { return v }
        if let v = value as? Double   { return CGFloat(v) }
        if let v = value as? Int      { return CGFloat(v) }
        if let v = value as? NSNumber { return CGFloat(truncating: v) }
        return 0
    }

    private static func double(from value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? NSNumber { return v.doubleValue }
        return nil
    }

    private static func nsColor(hex: String) -> NSColor? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let intValue = Int(value, radix: 16) else { return nil }
        return NSColor(
            red:   CGFloat((intValue >> 16) & 0xFF) / 255,
            green: CGFloat((intValue >>  8) & 0xFF) / 255,
            blue:  CGFloat( intValue        & 0xFF) / 255,
            alpha: 1
        )
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

    // MARK: - Context menu actions

    @objc func searchInBrowser() {
        webView.evaluateJavaScript("window.getSelection().toString()") { result, _ in
            guard let text = result as? String, !text.isEmpty else { return }
            var comps = URLComponents(string: "https://www.google.com/search")!
            comps.queryItems = [URLQueryItem(name: "q", value: text)]
            if let url = comps.url { NSWorkspace.shared.open(url) }
        }
    }

    @objc func shareSelection() {
        webView.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            guard let self, let text = result as? String, !text.isEmpty else { return }
            let formatted = "\u{201C}\(text)\u{201D}\n\n\u{2014} \(self.book.displayTitle), by \(self.book.displayAuthors)"
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(formatted, forType: .string)
                self.showHUD("Copied to clipboard")
            }
        }
    }

    // MARK: - HUD

    private func showHUD(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.isBezeled = false; label.isEditable = false
        label.backgroundColor = .clear; label.alignment = .center
        label.sizeToFit()

        let padding: CGFloat = 14, vPad: CGFloat = 8
        let pillW = label.frame.width + padding * 2
        let pillH = label.frame.height + vPad * 2

        let container = NSView(frame: CGRect(
            x: (view.bounds.width - pillW) / 2,
            y: view.bounds.height * 0.12,
            width: pillW, height: pillH
        ))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        container.layer?.cornerRadius = pillH / 2

        label.frame = CGRect(x: padding, y: vPad, width: label.frame.width, height: label.frame.height)
        container.addSubview(label)
        container.alphaValue = 0
        view.addSubview(container)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            container.animator().alphaValue = 1
        } completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    container.animator().alphaValue = 0
                } completionHandler: { container.removeFromSuperview() }
            }
        }
    }

    // MARK: - DEBUG harness

    #if DEBUG
    func runPaginationHarness() {
        // Pagination harness removed with the old geometry-based engine.
    }

    #endif
}

// MARK: - NotePopoverView

private struct NotePopoverView: View {
    let note: String

    var body: some View {
        ScrollView {
            Text(note)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(width: 260)
        .frame(maxHeight: 160)
    }
}

// MARK: - String UUID helper

private extension String {
    func inserting(dashes: Bool) -> String {
        guard dashes, count == 32 else { return self }
        var s = self
        for i in [20, 16, 12, 8] { s.insert("-", at: s.index(s.startIndex, offsetBy: i)) }
        return s
    }
}

// MARK: - ReaderMenuWebView

private class ReaderMenuWebView: WKWebView {

    weak var viewController: ReaderViewController?

    // NSView.acceptsFirstResponder is false by default. Without this override,
    // ReaderViewController.viewDidAppear's call to
    // view.window?.makeFirstResponder(webView) silently fails and keyDown
    // below never fires for arrow/space presses.
    override var acceptsFirstResponder: Bool { true }

    // Arrow keys and spacebar are consumed by WKWebView for its own scrolling
    // before keyDown ever reaches the view controller. In paginated mode we want
    // those keys for page turns, so we intercept them here first.
    override func keyDown(with event: NSEvent) {
        guard let vc = viewController else {
            super.keyDown(with: event)
            return
        }
        if vc.currentMode == .scroll {
            switch event.keyCode {
            case 126:
                scrollPageVertically(multiplier: -0.9)
                return
            case 125:
                scrollPageVertically(multiplier: 0.9)
                return
            default:
                super.keyDown(with: event)
                return
            }
        }
        guard vc.currentMode == .paginated else {
            super.keyDown(with: event)
            return
        }
        print("[PaginationKey] keyDown code=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "") modifiers=\(event.modifierFlags.rawValue) repeat=\(event.isARepeat)")
        switch event.keyCode {
        case 123, 126:       // ← ↑
            guard !event.isARepeat else { return }
            vc.goToPreviousPage()
        case 124, 125:       // → ↓
            guard !event.isARepeat else { return }
            vc.goToNextPage()
        case 49:             // Space
            guard !event.isARepeat else { return }
            if event.modifierFlags.contains(.shift) {
                vc.goToPreviousPage()
            } else {
                vc.goToNextPage()
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func scrollPageVertically(multiplier: CGFloat) {
        let distance = max(80, bounds.height * abs(multiplier))
        let direction = multiplier < 0 ? -distance : distance
        evaluateJavaScript("window.scrollBy({ top: \(Int(direction)), left: 0, behavior: 'auto' });", completionHandler: nil)
    }

    // Real paginated-mode scroll suppression happens in ReaderViewController's
    // window-level NSEvent local monitor (installScrollWheelMonitor), which
    // intercepts scrollWheel events before AppKit dispatch reaches this view
    // at all. This override is unreachable for that input path — WKWebView's
    // internal scrolling consumes trackpad/mouse wheel input itself without
    // calling up through a subclass override — but it's left as a passthrough
    // rather than removed, in case a future WebKit version changes that.
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let titlesToStrip: Set<String> = ["Copy Link with Highlight", "Share\u{2026}", "Share..."]
        for item in menu.items where titlesToStrip.contains(item.title) {
            menu.removeItem(item)
        }

        guard let vc = viewController else { super.willOpenMenu(menu, with: event); return }
        let menuPoint = convert(event.locationInWindow, from: nil)
        vc.setPendingMenuAnchorPoint(menuPoint)

        let prefs = ReaderPreferences.shared.contextMenu
        var idx = 0

        if prefs.showSearchInBrowser {
            let item = NSMenuItem(title: "Search in Browser",
                                  action: #selector(ReaderViewController.searchInBrowser),
                                  keyEquivalent: "")
            item.target = vc
            menu.insertItem(item, at: idx); idx += 1
        }

        if prefs.showAddAnnotation {
            let item = NSMenuItem(title: "Add Annotation\u{2026}",
                                  action: #selector(ReaderViewController.addAnnotationFromSelection),
                                  keyEquivalent: "")
            item.target = vc
            menu.insertItem(item, at: idx); idx += 1
        }

        let shareItem = NSMenuItem(title: "Share",
                                   action: #selector(ReaderViewController.shareSelection),
                                   keyEquivalent: "")
        shareItem.target = vc
        menu.insertItem(shareItem, at: idx); idx += 1

        if idx > 0 { menu.insertItem(.separator(), at: idx) }

        super.willOpenMenu(menu, with: event)
    }
}
