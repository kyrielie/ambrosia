import AppKit
import WebKit
import SwiftData
import SwiftUI
import Combine

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

    let book: CalibreBook
    let modelContainer: ModelContainer

    // MARK: - Private: reader state

    private var webView: ReaderMenuWebView!
    private var parser: EPUBParser?
    private var imageBaseURL: URL?

    fileprivate var currentMode: ReadingMode = .scroll
    private var currentHTML: String = ""

    // Paginated mode — geometry is computed after didFinish by measuring scrollWidth
    private var paginationGeometry: PaginationEngine.Geometry = .init(pageWidth: 0, pageHeight: 0, pageCount: 0)
    private var currentPageIndex: Int = 0
    private let paginationEngine = PaginationEngine()

    // Resize debounce
    private let resizeDebounce = DebounceTimer(delay: 0.3)

    // Annotation sidebar
    private var sidebarPanel: NSPanel?
    private var sidebarHostingView: NSHostingView<AnnotationSidebarView>?

    // Pending annotation captured at mouseup
    private var pendingAnnotation: Annotation?
    private var pendingCursorX: CGFloat = 0
    private var pendingCursorPageY: CGFloat = 0

    // Active popovers
    private var annotationPopover: NSPopover?
    private var notePopover: NSPopover?

    // Preferences subscription
    private var prefsCancellable: AnyCancellable?

    // Find bar
    private var findBarHostingView: NSHostingView<FindBarView>?
    private var findSearchText: String = "" {
        didSet { performFind(findSearchText) }
    }
    private var findMatchCurrent: Int = 0
    private var findMatchTotal: Int = 0

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
    private var annotations: [Annotation] = []

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
        webView.translatesAutoresizingMaskIntoConstraints = false

        // Disable bounce scroll — in paginated mode horizontal bounce looks wrong
        webView.enclosingScrollView?.horizontalScrollElasticity = .none
        webView.enclosingScrollView?.verticalScrollElasticity   = .none

        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
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

    override func viewDidLayout() {
        super.viewDidLayout()
        repositionFindBar()
        guard currentMode == .paginated, !paginationGeometry.isEmpty else { return }
        let newW = webView.bounds.width
        let newH = webView.bounds.height
        guard abs(newW - paginationGeometry.pageWidth)  > 1 ||
              abs(newH - paginationGeometry.pageHeight) > 1 else { return }
        resizeDebounce.schedule { [weak self] in
            self?.repaginatePreservingPosition()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        saveTimer?.invalidate()
        saveTimer = nil
        sidebarPanel?.close()
        annotationPopover?.close()
        notePopover?.close()
        hideFindBar()
        flushPosition()
    }

    // MARK: - EPUB loading

    private func loadEPUB() async {
        guard let pathStr = LibraryRegistry.shared.activePath else {
            await MainActor.run { self.showError("No library open.") }; return
        }
        let libraryRoot = URL(fileURLWithPath: pathStr)
        guard let epubURL = book.epubURL(libraryRoot: libraryRoot),
              FileManager.default.fileExists(atPath: epubURL.path) else {
            await MainActor.run { self.showError("EPUB file not found: \(self.book.displayTitle)") }; return
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
                self.loadCurrentHTML()
            }
        } catch {
            await MainActor.run { self.showError(error.localizedDescription) }
        }
    }

    // MARK: - HTML reload

    func reloadHTML() {
        guard let p = parser else { return }
        do {
            let html = try p.mergedHTML(userCSS: ReaderPreferences.shared.css)
            currentHTML = html
            paginationGeometry = PaginationEngine.Geometry(pageWidth: 0, pageHeight: 0, pageCount: 0)
            loadCurrentHTML()
        } catch {
            print("[ReaderVC] reloadHTML error: \(error)")
        }
    }

    /// Loads `currentHTML` into the webView, prepending column CSS if in paginated mode.
    private func loadCurrentHTML() {
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
        let vw = webView.bounds.width
        let vh = webView.bounds.height

        guard vw > 50, vh > 50, view.window != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.currentMode == .paginated else { return }
                self.loadPaginatedHTML()
            }
            return
        }

        // Inject column CSS into the HTML. We do a simple insertion before </head>
        // rather than rebuilding the document — EPUBParser.mergedHTML already has a
        // well-formed <head>. Column CSS must come after user CSS so it wins on
        // specificity for the properties we need to control (column-width, height, etc.)
        let colCSS = PaginationEngine.columnCSS(viewportWidth: vw, viewportHeight: vh)
        let colStyleBlock = "<style>\n\(colCSS)\n</style>"

        let paginatedHTML: String
        if let range = currentHTML.range(of: "</head>", options: .caseInsensitive) {
            var html = currentHTML
            html.insert(contentsOf: colStyleBlock, at: range.lowerBound)
            paginatedHTML = html
        } else {
            paginatedHTML = colStyleBlock + currentHTML
        }

        webView.loadHTMLString(paginatedHTML, baseURL: imageBaseURL)
    }

    // MARK: - Preferences subscription

    private func subscribeToPreferences() {
        prefsCancellable = ReaderPreferences.shared.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now()) {
                    self?.reloadHTML()
                }
            }
    }

    // MARK: - Mode switching

    func switchToScrollMode() {
        saveCurrentPositionSync { [weak self] in
            guard let self else { return }
            self.currentMode = .paginated  // temporarily keep paginated so save logic works
            self.currentMode = .scroll
            self.paginationGeometry = PaginationEngine.Geometry(pageWidth: 0, pageHeight: 0, pageCount: 0)
            self.reloadHTML()
        }
    }

    func switchToPaginatedMode() {
        saveCurrentPositionSync { [weak self] in
            guard let self else { return }
            self.currentMode = .paginated
            self.loadPaginatedHTML()
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Route JS console.log → Xcode output via webkit.messageHandlers.consoleLog
        let consoleBridgeJS = """
        (function() {
            var _origLog  = console.log.bind(console);
            var _origWarn = console.warn.bind(console);
            var _origErr  = console.error.bind(console);
            function _fwd(prefix, args) {
                var msg = prefix + Array.prototype.slice.call(args).join(' ');
                try { window.webkit.messageHandlers.consoleLog.postMessage(msg); } catch(e) {}
            }
            console.log   = function() { _origLog.apply(console, arguments);  _fwd('',       arguments); };
            console.warn  = function() { _origWarn.apply(console, arguments); _fwd('[WARN] ', arguments); };
            console.error = function() { _origErr.apply(console, arguments);  _fwd('[ERR] ',  arguments); };
        })();
        """
        webView.evaluateJavaScript(consoleBridgeJS, completionHandler: nil)
        // Inject PaginationJS utilities (highlight, charOffset, etc.) on every load.
        // In paginated mode this also sets _ambrosiaPageStart/End sentinels so
        // HighlightBridge works unchanged.
        webView.evaluateJavaScript(PaginationJS.script, completionHandler: nil)
        HighlightBridge.injectSelectionListener(into: webView)
        restoreAnnotations()

        switch currentMode {
        case .scroll:
            restoreScrollPosition()
            injectScrollTracker()
            startAutoSave()

        case .paginated:
            // Delay measurement slightly — didFinish fires before WebKit commits
            // compositing, so scrollWidth can be stale (too small or zero) if we
            // measure immediately. 80ms is enough for the layout pass to settle
            // without being perceptible to the user.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, self.currentMode == .paginated else { return }
                let vw = self.webView.bounds.width
                let vh = self.webView.bounds.height
                self.paginationEngine.measurePageCount(
                    in: self.webView,
                    viewportWidth: vw,
                    viewportHeight: vh
                ) { [weak self] geo in
                    guard let self else { return }
                    if geo.isEmpty {
                        // Layout still not ready — retry once more after a longer delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                            guard let self, self.currentMode == .paginated else { return }
                            self.paginationEngine.measurePageCount(
                                in: self.webView,
                                viewportWidth: self.webView.bounds.width,
                                viewportHeight: self.webView.bounds.height,
                                completion: { [weak self] retryGeo in
                                    guard let self else { return }
                                    print("[Pagination] retry measurePageCount → pageCount=\(retryGeo.pageCount) pageWidth=\(Int(retryGeo.pageWidth))")
                                    self.paginationGeometry = retryGeo
                                    self.restorePaginatedPosition()
                                    self.startAutoSave()
                                }
                            )
                        }
                        return
                    }
                    print("[Pagination] measurePageCount → pageCount=\(geo.pageCount) pageWidth=\(Int(geo.pageWidth))")
                    self.paginationGeometry = geo
                    self.restorePaginatedPosition()
                    self.startAutoSave()
                }
            }
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

    // MARK: - Paginated mode: position restore

    private func restorePaginatedPosition() {
        let savedOffset = bookState?.lastCharacterOffset ?? 0
        guard savedOffset > 0 else {
            // No saved position — start at page 0
            currentPageIndex = 0
            updateProgressForCurrentPage()
            return
        }

        PaginationEngine.pageIndex(
            forCharOffset: savedOffset,
            in: webView,
            pageWidth: paginationGeometry.pageWidth
        ) { [weak self] pageIdx in
            guard let self else { return }
            self.currentPageIndex = max(0, min(pageIdx, self.paginationGeometry.pageCount - 1))
            PaginationEngine.scrollTo(
                pageIndex: self.currentPageIndex,
                in: self.webView,
                pageWidth: self.paginationGeometry.pageWidth
            )
            self.updateProgressForCurrentPage()
        }
    }

    // MARK: - Paginated mode: repaginate on resize

    /// Called when the window is resized. Saves position, reloads with new column CSS.
    private func repaginatePreservingPosition() {
        guard currentMode == .paginated else { return }
        saveCurrentPositionSync { [weak self] in
            guard let self else { return }
            self.paginationGeometry = PaginationEngine.Geometry(pageWidth: 0, pageHeight: 0, pageCount: 0)
            self.loadPaginatedHTML()
        }
    }

    // MARK: - Page navigation

    func goToNextPage() {
        print("[Pagination] goToNextPage — currentPage=\(currentPageIndex) pageCount=\(paginationGeometry.pageCount) mode=\(currentMode)")
        guard currentMode == .paginated,
              !paginationGeometry.isEmpty,
              currentPageIndex < paginationGeometry.pageCount - 1 else { return }
        currentPageIndex += 1
        PaginationEngine.scrollTo(
            pageIndex: currentPageIndex,
            in: webView,
            pageWidth: paginationGeometry.pageWidth
        )
        updateProgressForCurrentPage()
        saveCurrentPage()
    }

    func goToPreviousPage() {
        print("[Pagination] goToPreviousPage — currentPage=\(currentPageIndex) pageCount=\(paginationGeometry.pageCount) mode=\(currentMode)")
        guard currentMode == .paginated, currentPageIndex > 0 else { return }
        currentPageIndex -= 1
        PaginationEngine.scrollTo(
            pageIndex: currentPageIndex,
            in: webView,
            pageWidth: paginationGeometry.pageWidth
        )
        updateProgressForCurrentPage()
        saveCurrentPage()
    }

    private func updateProgressForCurrentPage() {
        guard !paginationGeometry.isEmpty else { return }
        bookState?.totalReadPercent = Double(currentPageIndex + 1) / Double(paginationGeometry.pageCount)
    }

    // MARK: - Position save helpers

    /// Saves the current reading position synchronously-ish from the current mode's state,
    /// then calls the completion. In paginated mode this is immediate (no JS needed).
    /// In scroll mode it fires an evaluateJavaScript call.
    private func saveCurrentPositionSync(completion: @escaping () -> Void) {
        if currentMode == .paginated {
            saveCurrentPage()
            completion()
        } else {
            let js = """
            (function() {
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
                        return { scrollY: window.scrollY, charOffset: cumulative + lo };
                    }
                    cumulative += node.length;
                }
                return { scrollY: window.scrollY, charOffset: cumulative };
            })();
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, let dict = result as? [String: Any] else {
                    completion(); return
                }
                let scrollY = Self.cgFloat(from: dict["scrollY"])
                let charOffset = dict["charOffset"] as? Int ?? 0
                self.bookState?.lastScrollOffset    = Double(scrollY)
                self.bookState?.lastCharacterOffset = charOffset
                completion()
            }
        }
    }

    private func saveCurrentPage() {
        guard currentMode == .paginated, !paginationGeometry.isEmpty else { return }
        // In paginated mode we save the scrollLeft as lastScrollOffset (for fast
        // restore without JS) and compute a char offset via pageIndex for
        // cross-mode position portability.
        let sl = CGFloat(currentPageIndex) * paginationGeometry.pageWidth
        bookState?.lastScrollOffset    = Double(sl)
        bookState?.lastCharacterOffset = 0  // will be updated asynchronously below
        bookState?.lastSpineIndex      = 0

        // Async char offset save — for annotation jump-back and cross-mode restore.
        // We read the char at the top-left of the current page by checking what
        // text is at scrollLeft = currentPageIndex * pageWidth.
        let targetX = Int(sl)
        let js = """
        (function() {
            var savedLeft = document.documentElement.scrollLeft;
            // Use window.scrollTo for writes — scrollLeft assignment is silently
            // dropped by WKWebView in standards-mode documents.
            window.scrollTo({ left: \(targetX), top: 0, behavior: 'instant' });
            var vw = \(Int(paginationGeometry.pageWidth));
            var vh = \(Int(paginationGeometry.pageHeight));
            // Find topmost visible text in this column
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
            var cumulative = 0, node, best = 0;
            while ((node = walker.nextNode()) !== null) {
                var range = document.createRange();
                range.selectNodeContents(node);
                var rects = range.getClientRects();
                for (var i = 0; i < rects.length; i++) {
                    var r = rects[i];
                    if (r.left >= -1 && r.left < vw && r.top >= 0 && r.top < vh) {
                        best = cumulative;
                        window.scrollTo({ left: savedLeft, top: 0, behavior: 'instant' });
                        return best;
                    }
                }
                cumulative += node.length;
            }
            window.scrollTo({ left: savedLeft, top: 0, behavior: 'instant' });
            return best;
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            if let offset = result as? Int {
                self?.bookState?.lastCharacterOffset = offset
            }
            self?.flushPosition()
        }
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

        case "consoleLog":
            if let body = message.body as? String {
                print("[JS] \(body)")
            }

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
            if let annotation = HighlightBridge.decodeAnnotation(from: message) {
                pendingAnnotation = annotation
                if let body = message.body as? String,
                   let data = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let cursorX    = Self.cgFloat(from: json["cursorX"])
                    let cursorPageY = Self.cgFloat(from: json["cursorPageY"])
                    pendingCursorX    = cursorX > 0 ? cursorX : webView.bounds.midX
                    pendingCursorPageY = cursorPageY > 0 ? cursorPageY : webView.bounds.midY
                }
            }

        case "highlightTapped":
            guard let (idStr, clientX, pageY) = HighlightBridge.decodeTap(from: message) else { return }
            let idWithDashes = idStr.inserting(dashes: true)
            guard let uuid = UUID(uuidString: idWithDashes),
                  let annotation = annotations.first(where: { $0.id == uuid }),
                  let note = annotation.note, !note.isEmpty
            else { return }
            DispatchQueue.main.async { [weak self] in
                self?.presentNotePopover(note: note, clientX: clientX, pageY: pageY)
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

        let offset: Int
        if currentMode == .paginated {
            offset = state.lastCharacterOffset
        } else {
            offset = Int(state.lastScrollOffset)
        }
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

        let cx  = pendingCursorX
        let cpy = pendingCursorPageY
        // In paginated mode scrollLeft is non-zero; in scroll mode scrollY is non-zero.
        // The JS here reads whichever dimension is relevant to convert pageY to clientY.
        webView.evaluateJavaScript("({ scrollY: window.scrollY, scrollX: document.documentElement.scrollLeft })") { [weak self] result, _ in
            guard let self else { return }
            let dict   = result as? [String: Any] ?? [:]
            let scrollY = Self.cgFloat(from: dict["scrollY"])
            let clientY = cpy - scrollY
            let viewX   = cx
            let viewY   = self.webView.bounds.height - clientY
            let anchor  = CGRect(x: viewX, y: viewY, width: 1, height: 1)
            popover.show(relativeTo: anchor, of: self.webView, preferredEdge: .maxY)
        }
    }

    // MARK: - Note popup

    private func presentNotePopover(note: String, clientX: CGFloat, pageY: CGFloat) {
        notePopover?.close()
        let noteView = NotePopoverView(note: note)
        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: noteView)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 240, height: 80)
        notePopover = popover

        webView.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
            guard let self else { return }
            let scrollY = Self.cgFloat(from: result)
            let clientY = pageY - scrollY
            let viewX   = clientX
            let viewY   = self.webView.bounds.height - clientY
            let anchor  = CGRect(x: viewX, y: viewY, width: 1, height: 1)
            popover.show(relativeTo: anchor, of: self.webView, preferredEdge: .maxY)
        }
    }

    // MARK: - Restore annotations

    private func restoreAnnotations() {
        Task {
            let loaded = (try? await AppDelegate.shared?.session.metaDB?.annotations(for: book.id)) ?? []
            await MainActor.run {
                annotations = loaded
                let ranged = loaded.filter { !$0.isPointAnnotation }
                HighlightBridge.restoreHighlights(ranged, into: webView)
                refreshSidebarIfVisible()
            }
        }
    }

    // MARK: - Jump to annotation

    func jumpToAnnotation(_ annotation: Annotation) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.window?.makeKeyAndOrderFront(nil)

            let offset = annotation.startChar

            if self.currentMode == .paginated, !self.paginationGeometry.isEmpty {
                PaginationEngine.pageIndex(
                    forCharOffset: offset,
                    in: self.webView,
                    pageWidth: self.paginationGeometry.pageWidth
                ) { [weak self] pageIdx in
                    guard let self else { return }
                    self.currentPageIndex = max(0, min(pageIdx, self.paginationGeometry.pageCount - 1))
                    PaginationEngine.scrollTo(
                        pageIndex: self.currentPageIndex,
                        in: self.webView,
                        pageWidth: self.paginationGeometry.pageWidth
                    )
                    self.webView.evaluateJavaScript(
                        "if (window.ambrosiaHighlight) window.ambrosiaHighlight(\(offset));",
                        completionHandler: nil
                    )
                }
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

    private func showFindBar() {
        guard findBarHostingView == nil else { return }
        let barView = FindBarView(
            searchText:   Binding(get: { self.findSearchText }, set: { self.findSearchText = $0 }),
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
    }

    private func repositionFindBar() { /* Auto Layout handles it */ }

    private func performFind(_ query: String) {
        guard #available(macOS 13.0, *) else { return }
        guard !query.isEmpty else {
            findMatchCurrent = 0; findMatchTotal = 0
            webView.find("", configuration: WKFindConfiguration()) { _ in }
            updateFindBar(); return
        }
        let config = WKFindConfiguration()
        config.caseSensitive = false; config.wraps = true; config.backwards = false
        webView.find(query, configuration: config) { [weak self] result in
            guard let self else { return }
            self.findMatchTotal   = result.matchFound ? 1 : 0
            self.findMatchCurrent = result.matchFound ? 1 : 0
            self.updateFindBar()
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
            searchText:   Binding(get: { self.findSearchText }, set: { self.findSearchText = $0 }),
            matchCurrent: findMatchCurrent,
            matchTotal:   findMatchTotal,
            onNext:       { [weak self] in self?.findNext() },
            onPrevious:   { [weak self] in self?.findPrevious() },
            onClose:      { [weak self] in self?.hideFindBar() }
        )
    }

    // MARK: - Annotation sidebar

    func toggleAnnotationSidebar() {
        if let panel = sidebarPanel, panel.isVisible { panel.close(); return }
        openAnnotationSidebar()
    }

    private func openAnnotationSidebar() {
        guard let windowFrame = view.window?.frame else { return }
        let sidebar = makeAnnotationSidebarView()
        let hosting = NSHostingView(rootView: sidebar)
        hosting.frame = CGRect(x: 0, y: 0, width: 260, height: windowFrame.height)
        sidebarHostingView = hosting

        let panel = NSPanel(
            contentRect: CGRect(x: windowFrame.maxX, y: windowFrame.minY, width: 260, height: windowFrame.height),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        panel.title = "Annotations"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.contentView = hosting
        panel.orderFront(nil)
        sidebarPanel = panel
    }

    private func makeAnnotationSidebarView() -> AnnotationSidebarView {
        AnnotationSidebarView(
            annotations: annotations,
            onJump: { [weak self] annotation in self?.jumpToAnnotation(annotation) },
            onDelete: { [weak self] id in
                guard let self else { return }
                annotations = annotations.filter { $0.id != id }
                Task { try? await AppDelegate.shared?.session.metaDB?.deleteAnnotation(
                    id: id, calibreID: self.book.id) }
                self.flushPosition()
                self.refreshSidebarIfVisible()
                HighlightBridge.removeHighlight(id: id, from: self.webView)
            }
        )
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
        guard !paginationGeometry.isEmpty else {
            print("[Harness] No pagination geometry — is paginated mode active?")
            return
        }
        print("[Harness] pageCount=\(paginationGeometry.pageCount) pageWidth=\(Int(paginationGeometry.pageWidth)) pageHeight=\(Int(paginationGeometry.pageHeight))")
        webView.evaluateJavaScript("document.documentElement.scrollWidth") { result, _ in
            let sw = result as? Int ?? 0
            print("[Harness] scrollWidth=\(sw) — computed pages=\(Int((Double(sw) / Double(self.paginationGeometry.pageWidth)).rounded()))")
        }
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
        .frame(width: 240)
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

    // Arrow keys and spacebar are consumed by WKWebView for its own scrolling
    // before keyDown ever reaches the view controller. In paginated mode we want
    // those keys for page turns, so we intercept them here first.
    override func keyDown(with event: NSEvent) {
        guard let vc = viewController, vc.currentMode == .paginated else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 123, 126:       // ← ↑
            vc.goToPreviousPage()
        case 124, 125:       // → ↓
            vc.goToNextPage()
        case 49:             // Space
            if event.modifierFlags.contains(.shift) { vc.goToPreviousPage() }
            else { vc.goToNextPage() }
        default:
            super.keyDown(with: event)
        }
    }

    // Block trackpad/mouse horizontal scroll in paginated mode.
    // html is overflow-x: scroll so the user could otherwise swipe to mid-column
    // positions between page boundaries. All navigation must go through goToNextPage
    // / goToPreviousPage so we stay on exact page boundaries.
    override func scrollWheel(with event: NSEvent) {
        guard let vc = viewController, vc.currentMode == .paginated else {
            super.scrollWheel(with: event)
            return
        }
        // Allow vertical scrolling to fall through only if there's no horizontal
        // component — WKWebView uses scrollWheel for inertia etc., so we must not
        // swallow events with a non-zero deltaX or the momentum phase will stall.
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            // Predominantly horizontal swipe — absorb it; page turns are keyboard-only.
            return
        }
        // Purely vertical scroll (e.g. two-finger scroll on a landscape book) — pass through.
        super.scrollWheel(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let titlesToStrip: Set<String> = ["Copy Link with Highlight", "Share\u{2026}", "Share..."]
        for item in menu.items where titlesToStrip.contains(item.title) {
            menu.removeItem(item)
        }

        guard let vc = viewController else { super.willOpenMenu(menu, with: event); return }

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
