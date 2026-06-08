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
// Annotation flow:
//   mouseup → highlightAdded → store pendingAnnotation (NO UI shown)
//   "Add Annotation…" menu item → addAnnotationFromSelection() → present popover
//   ⌘D → savePointAnnotationAtCurrentPosition() → immediate save + sentence preview
//
// Find bar: ⌘F / ⌘G / ⇧⌘G. Uses WKFindConfiguration (macOS 13+).
//
// Highlight click: spans with notes post "highlightTapped"; Swift shows note popover.
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

    private var currentMode: ReadingMode = .scroll
    private var currentHTML: String = ""

    // Paginated mode
    private var pages: [PaginationEngine.PageBoundary] = []
    private var currentPageIndex: Int = 0
    private var paginationEngine: PaginationEngine?

    // Resize debounce
    private let resizeDebounce = DebounceTimer(delay: 0.3)

    // Annotation sidebar
    private var sidebarPanel: NSPanel?
    private var sidebarHostingView: NSHostingView<AnnotationSidebarView>?

    // Pending annotation captured at mouseup — presented in popover only when menu item fires
    private var pendingAnnotation: Annotation?
    // Cursor position at mouseup in CSS coordinates (pageY = document-relative)
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
        config.userContentController.add(self, name: "highlightAdded")   // capture selection only
        config.userContentController.add(self, name: "highlightTapped")  // note popup trigger

        webView = ReaderMenuWebView(frame: .zero, configuration: config)
        webView.viewController = self
        webView.navigationDelegate = self
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        ensureBookState()
        currentMode = .scroll
        subscribeToPreferences()

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.loadEPUB()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        repositionFindBar()
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
                self.webView.loadHTMLString(html, baseURL: imgBase)
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
            webView.loadHTMLString(html, baseURL: imageBaseURL)
        } catch {
            print("[ReaderVC] reloadHTML error: \(error)")
        }
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
        currentMode = .scroll
        saveCurrentCharOffset { [weak self] _ in self?.reloadHTML() }
    }

    func switchToPaginatedMode() {
        currentMode = .paginated
        paginateCurrentContent()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(PaginationJS.script, completionHandler: nil)
        HighlightBridge.injectSelectionListener(into: webView)
        restoreAnnotations()

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

    // MARK: - Paginated mode

    private func paginateCurrentContent() {
        guard !currentHTML.isEmpty else { return }
        let pageHeight = max(1, webView.bounds.height - 2.0)
        let engine = PaginationEngine(parentView: view)
        paginationEngine = engine
        engine.paginate(html: currentHTML, pageHeight: pageHeight, baseURL: imageBaseURL) { [weak self] boundaries in
            guard let self else { return }
            self.paginationEngine = nil
            if boundaries.isEmpty {
                self.switchToScrollMode(); return
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
            engine.paginate(html: self.currentHTML, pageHeight: pageHeight, baseURL: self.imageBaseURL) { [weak self] boundaries in
                guard let self else { return }
                self.paginationEngine = nil
                guard !boundaries.isEmpty else { return }
                self.pages = boundaries
                self.currentPageIndex = self.pageIndex(forCharOffset: savedOffset)
                self.renderCurrentPage()
                self.webView.evaluateJavaScript("window.ambrosiaHighlight(\(savedOffset));", completionHandler: nil)
            }
        }
    }

    func renderCurrentPage() {
        guard !pages.isEmpty else { return }
        let idx  = max(0, min(currentPageIndex, pages.count - 1))
        let page = pages[idx]
        webView.evaluateJavaScript("window.ambrosiaRenderPage(\(page.startChar), \(page.endChar));", completionHandler: nil)
        bookState?.totalReadPercent = Double(idx + 1) / Double(pages.count)
    }

    func goToNextPage() {
        guard currentMode == .paginated, currentPageIndex < pages.count - 1 else { return }
        currentPageIndex += 1; renderCurrentPage(); saveCurrentPage()
    }

    func goToPreviousPage() {
        guard currentMode == .paginated, currentPageIndex > 0 else { return }
        currentPageIndex -= 1; renderCurrentPage(); saveCurrentPage()
    }

    // MARK: - Char offset helpers

    private func pageIndex(forCharOffset offset: Int) -> Int {
        guard !pages.isEmpty else { return 0 }
        for (i, page) in pages.enumerated() { if offset < page.endChar { return i } }
        return pages.count - 1
    }

    private func saveCurrentCharOffset(completion: @escaping (Int) -> Void) {
        if currentMode == .paginated {
            let offset = pages.isEmpty ? 0 : pages[max(0, currentPageIndex)].startChar
            bookState?.lastCharacterOffset = offset
            completion(offset)
        } else {
            webView.evaluateJavaScript("[window.scrollY, document.body.scrollHeight]") { [weak self] result, _ in
                guard let arr = result as? [Double], arr.count == 2, arr[1] > 0 else { completion(0); return }
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
            // Store pending annotation — do NOT show popover yet.
            // Popover is shown only when "Add Annotation…" menu item fires.
            if let annotation = HighlightBridge.decodeAnnotation(from: message) {
                pendingAnnotation = annotation
                if let body = message.body as? String,
                   let data = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    pendingCursorX     = json["cursorX"]     as? CGFloat ?? webView.bounds.midX
                    pendingCursorPageY = json["cursorPageY"] as? CGFloat ?? webView.bounds.midY
                }
            }

        case "highlightTapped":
            // User clicked a highlight span that has a note — show note popover.
            guard let (idStr, clientX, pageY) = HighlightBridge.decodeTap(from: message) else { return }
            let idWithDashes = idStr.inserting(dashes: true)
            guard let uuid = UUID(uuidString: idWithDashes),
                  let annotation = bookState?.annotations.first(where: { $0.id == uuid }),
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
            case "d":
                savePointAnnotationAtCurrentPosition(); return
            case "b":
                toggleAnnotationSidebar(); return
            case "f":
                toggleFindBar(); return
            case "g":
                if event.modifierFlags.contains(.shift) { findPrevious() }
                else { findNext() }
                return
            default:
                break
            }
        }
        if event.keyCode == 53 && findBarHostingView != nil {   // Escape
            hideFindBar(); return
        }

        guard currentMode == .paginated else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123, 126: goToPreviousPage()
        case 124, 125: goToNextPage()
        case 49:       goToNextPage()
        default:       super.keyDown(with: event)
        }
    }

    // MARK: - Responder-chain actions

    @objc func addAnnotation(_ sender: Any?) {
        savePointAnnotationAtCurrentPosition()
    }

    @objc func showAnnotationSidebar(_ sender: Any?) {
        toggleAnnotationSidebar()
    }

    // MARK: - Point annotations (⌘D — immediate save with sentence preview)

    private func savePointAnnotationAtCurrentPosition() {
        guard let state = bookState else { return }

        let offset: Int
        if currentMode == .paginated, !pages.isEmpty {
            offset = pages[max(0, currentPageIndex)].startChar
        } else {
            offset = Int(state.lastScrollOffset)
        }

        let spineIndex = state.lastSpineIndex

        // CHANGE 2: Extract surrounding sentence from the live DOM as preview text.
        let sentenceJS = """
        (function() {
            var target = \(offset);
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
            var remaining = target;
            var node;
            while ((node = walker.nextNode()) !== null) {
                if (remaining <= node.length) {
                    // Collect text around this position: 300 chars total
                    var before = '';
                    var after  = '';

                    // Collect chars before (walk backwards through text)
                    var beforeWalker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
                    var nodes = [];
                    var n;
                    while ((n = beforeWalker.nextNode()) !== null) nodes.push(n);

                    var nodeIdx = nodes.indexOf(node);
                    var charIdx = remaining;

                    // Scan backwards for sentence start
                    var collected = '';
                    var charPos = charIdx - 1;
                    var ni = nodeIdx;
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
                    before = collected.trimStart();

                    // Scan forwards for sentence end
                    collected = '';
                    charPos = charIdx;
                    ni = nodeIdx;
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
                    after = collected.trimEnd();

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

            guard let state = self.bookState else { return }
            var existing = state.annotations
            if !existing.contains(where: { $0.startChar == offset && $0.spineIndex == spineIndex && $0.isPointAnnotation }) {
                existing.append(annotation)
                state.annotations = existing
            }

            self.webView.evaluateJavaScript("window.ambrosiaHighlight(\(offset));", completionHandler: nil)
            self.flushPosition()
            self.refreshSidebarIfVisible()
            self.showHUD("Bookmark saved")
        }
    }

    // MARK: - Ranged annotations (context menu → popover)

    // CHANGE 1: Popover is presented HERE (menu action), not at mouseup.
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
                guard let self, let state = self.bookState else { return }
                self.annotationPopover?.close()
                self.annotationPopover = nil

                var final = pending
                final.note     = note
                final.colorHex = colorHex

                var existing = state.annotations
                existing.append(final)
                state.annotations = existing
                self.flushPosition()
                self.refreshSidebarIfVisible()

                // Restore using the full set so overlap detection works correctly —
                // the new span may overlap an already-rendered span.
                // Re-running restoreHighlights is safe: each span checks `if (document.getElementById(...)) return`
                // so existing spans are skipped; only the new one is inserted.
                if !final.isPointAnnotation {
                    HighlightBridge.restoreHighlights(existing.filter { !$0.isPointAnnotation }, into: self.webView)
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

        // Anchor to cursor position captured at mouseup.
        // cursorPageY is document-relative; subtract scrollY to get viewport-relative clientY,
        // then flip because NSView is bottom-up.
        let cx = pendingCursorX
        let cpy = pendingCursorPageY
        webView.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
            guard let self else { return }
            let scrollY = (result as? CGFloat) ?? 0
            let clientY = cpy - scrollY
            let viewX   = cx
            let viewY   = self.webView.bounds.height - clientY
            let anchor  = CGRect(x: viewX - 4, y: viewY - 4, width: 8, height: 8)
            popover.show(relativeTo: anchor, of: self.webView, preferredEdge: .maxY)
        }
    }

    // MARK: - Note popup (highlight click)

    // FIX 3: Note popup — convert pageY (document-relative) to NSView coords.
    private func presentNotePopover(note: String, clientX: CGFloat, pageY: CGFloat) {
        notePopover?.close()

        let noteView = NotePopoverView(note: note)
        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: noteView)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 240, height: 80)
        notePopover = popover

        // pageY is document-relative. Subtract scrollY to get viewport-relative clientY.
        // NSView is bottom-up, so flip: viewY = webView.height - clientY.
        webView.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
            guard let self else { return }
            let scrollY  = (result as? CGFloat) ?? 0
            let clientY  = pageY - scrollY
            let viewX    = clientX
            let viewY    = self.webView.bounds.height - clientY
            let anchor   = CGRect(x: viewX - 4, y: viewY - 4, width: 8, height: 8)
            popover.show(relativeTo: anchor, of: self.webView, preferredEdge: .maxY)
        }
    }

    // MARK: - Restore annotations after page load

    private func restoreAnnotations() {
        guard let state = bookState else { return }
        let ranged = state.annotations.filter { !$0.isPointAnnotation }
        HighlightBridge.restoreHighlights(ranged, into: webView)
    }

    // MARK: - Jump to annotation (from sidebar)
    // CHANGE 4: Uses char offset (primary, unambiguous). Falls back to find for
    // point annotations with selectedText when offset is 0.

    func jumpToAnnotation(_ annotation: Annotation) {
        // Always dispatch on main thread — taps from the floating NSPanel sidebar
        // can arrive on SwiftUI's render thread. Also bring the reader window to
        // front so the scroll is actually visible to the user.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.window?.makeKeyAndOrderFront(nil)

            let offset = annotation.startChar

            if self.currentMode == .paginated {
                self.currentPageIndex = self.pageIndex(forCharOffset: offset)
                self.renderCurrentPage()
                self.webView.evaluateJavaScript(
                    "if (window.ambrosiaHighlight) window.ambrosiaHighlight(\(offset));",
                    completionHandler: nil)
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
        webView.evaluateJavaScript("if (window.ambrosiaHighlight) window.ambrosiaHighlight(\(offset));", completionHandler: nil)
    }

    // MARK: - Find bar (⌘F)
    // CHANGE 3: find bar docked at bottom of reader, uses WKWebView.find().

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

        let barHeight: CGFloat = 44
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosting.heightAnchor.constraint(equalToConstant: barHeight),
        ])

        findBarHostingView = hosting
    }

    private func hideFindBar() {
        findBarHostingView?.removeFromSuperview()
        findBarHostingView = nil
        findSearchText   = ""
        findMatchCurrent = 0
        findMatchTotal   = 0
        // Clear find highlights
        if #available(macOS 13.0, *) {
            webView.find("", configuration: WKFindConfiguration()) { _ in }
        }
    }

    private func repositionFindBar() {
        // NSHostingView with Auto Layout handles this automatically; nothing to do.
    }

    private func performFind(_ query: String) {
        guard #available(macOS 13.0, *) else { return }
        guard !query.isEmpty else {
            findMatchCurrent = 0; findMatchTotal = 0
            webView.find("", configuration: WKFindConfiguration()) { _ in }
            updateFindBar()
            return
        }

        let config = WKFindConfiguration()
        config.caseSensitive   = false
        config.wraps           = true
        config.backwards       = false

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
        config.caseSensitive = false
        config.wraps         = true
        config.backwards     = false
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
        config.caseSensitive = false
        config.wraps         = true
        config.backwards     = true
        webView.find(findSearchText, configuration: config) { [weak self] result in
            guard let self else { return }
            if result.matchFound {
                self.findMatchCurrent = self.findMatchCurrent > 1
                    ? self.findMatchCurrent - 1
                    : self.findMatchTotal
            }
            self.updateFindBar()
        }
    }

    private func performFindAndJump(_ text: String) {
        guard #available(macOS 13.0, *), !text.isEmpty else { return }
        let config = WKFindConfiguration()
        config.caseSensitive = false
        config.wraps         = true
        config.backwards     = false
        webView.find(text, configuration: config) { _ in }
    }

    private func updateFindBar() {
        guard let hosting = findBarHostingView else { return }
        let barView = FindBarView(
            searchText:   Binding(get: { self.findSearchText }, set: { self.findSearchText = $0 }),
            matchCurrent: findMatchCurrent,
            matchTotal:   findMatchTotal,
            onNext:       { [weak self] in self?.findNext() },
            onPrevious:   { [weak self] in self?.findPrevious() },
            onClose:      { [weak self] in self?.hideFindBar() }
        )
        hosting.rootView = barView
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
            annotations: bookState?.annotations ?? [],
            onJump: { [weak self] annotation in
                self?.jumpToAnnotation(annotation)
            },
            onDelete: { [weak self] id in
                guard let self, let state = self.bookState else { return }
                state.annotations = state.annotations.filter { $0.id != id }
                self.flushPosition()
                self.refreshSidebarIfVisible()
                // Remove the live DOM span so the highlight disappears immediately
                // without requiring a page reload.
                HighlightBridge.removeHighlight(id: id, from: self.webView)
            }
        )
    }

    private func refreshSidebarIfVisible() {
        guard let panel = sidebarPanel, panel.isVisible,
              let hosting = sidebarHostingView else { return }
        hosting.rootView = makeAnnotationSidebarView()
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
        // Build a pill-shaped container with a centred label.
        // Using a separate container avoids the NSTextField left-alignment issue
        // where insetBy expands the frame but the text stays left-aligned.
        let label = NSTextField(labelWithString: message)
        label.font            = .systemFont(ofSize: 13, weight: .medium)
        label.textColor       = .white
        label.isBezeled       = false
        label.isEditable      = false
        label.backgroundColor = .clear
        label.alignment       = .center
        label.sizeToFit()

        let padding: CGFloat = 14
        let vPad:    CGFloat = 8
        let pillW = label.frame.width  + padding * 2
        let pillH = label.frame.height + vPad * 2

        let container = NSView(frame: CGRect(
            x: (view.bounds.width - pillW) / 2,
            y: view.bounds.height * 0.12,
            width: pillW, height: pillH
        ))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        container.layer?.cornerRadius    = pillH / 2

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

    // MARK: - Pagination harness (DEBUG)

    #if DEBUG
    func runPaginationHarness() {
        guard let p = parser else { print("[Harness] No parser"); return }
        let paginatedTotal = pages.reduce(0) { $0 + $1.charCount }
        var expectedTotal = 0
        for item in p.spine {
            if let text = try? p.plainText(for: item) { expectedTotal += text.utf16.count }
        }
        let diff = abs(paginatedTotal - expectedTotal)
        print(diff <= 5
            ? "[Harness] ✅ PASS — paginated=\(paginatedTotal) expected=\(expectedTotal) diff=\(diff)"
            : "[Harness] ❌ FAIL — paginated=\(paginatedTotal) expected=\(expectedTotal) diff=\(diff)")
    }
    #endif
}

// MARK: - NotePopoverView

/// Minimal read-only view shown when a highlight span with a note is clicked.
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
    /// Converts a 32-char hex UUID string (no dashes) back to standard UUID format.
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
