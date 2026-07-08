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

// MARK: - WeakScriptMessageHandler
//
// WKUserContentController.add(_:name:) retains its handler strongly. Registering
// `self` (a view controller) directly creates a closed reference cycle:
// ReaderViewController -> WKWebView -> configuration -> userContentController -> self.
// Registering this weak-referencing proxy instead avoids that cycle regardless of
// whether every future registration site remembers to call
// removeScriptMessageHandler(forName:) during teardown.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

class ReaderViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {

    // MARK: - Dependencies

    let target: ReadingTarget
    let book: CalibreBook
    let modelContainer: ModelContainer
    var onReaderContentReady: (() -> Void)?
    private(set) var isReaderContentReady = false

    // MARK: - Private: reader state

    private var webView: ReaderMenuWebView!
    /// One EPUBParser per work in the reading target, in ReadingTarget order.
    /// A `.singleBook` target has exactly one entry. Populated once by
    /// loadEPUB(); never mutated after (EPUBParser is a struct, so "the
    /// active work" is selected by index via `spineMap`, not by swapping a
    /// class reference). See ambrosia_series_fix_plan.md Task 2a.
    private var workParsers: [EPUBParser] = []
    private var workImageBaseURLs: [URL] = []
    private var workAO3Records: [AO3MetadataRecord?] = []
    /// Flattens workParsers' spines into one global ordering. Rebuilt once,
    /// whenever workParsers changes (i.e. in loadEPUB()).
    private var spineMap = SeriesSpineMap(workIDs: [], spineCounts: [])
    /// The EPUBParser for whichever work currently owns `currentSpineIndex`
    /// (paginated mode: the one spine item currently loaded; scroll mode:
    /// used only for link-navigation lookups against the active work).
    private var parser: EPUBParser? {
        guard let ref = spineMap.ref(atGlobalIndex: currentSpineIndex),
              workParsers.indices.contains(ref.workIndex) else {
            return workParsers.first
        }
        return workParsers[ref.workIndex]
    }
    /// AO3 metadata for the primary book, fetched asynchronously after the
    /// parser loads. Threaded into mergedHTML for endmatter emission.
    private var ao3Record: AO3MetadataRecord?

    fileprivate var currentMode: ReadingMode = .scroll
    private var currentHTML: String = ""

    private var currentSpineIndex: Int = 0
    private var pendingAnnotationJump: Annotation?
    /// Set when an in-book link (TOC chapter, footnote) targets a fragment in
    /// a spine item other than the one currently loaded. Consumed once from
    /// PaginationEngine.spineDidLoad after the target spine finishes loading.
    private var pendingLinkFragment: String?
    private var paginationEngine: PaginationEngine?

    /// Set once the view has completed its first AppKit layout pass. Gates
    /// loadSpineItem so paginated geometry is never computed against a
    /// transient .zero/partial bounds (see Known Issue #3).
    private var isLayoutReady = false
    /// A spine load requested before the first layout pass completed.
    /// Replayed once isLayoutReady flips true.
    private var pendingSpineLoad: (index: Int, restorePosition: RestorePosition)?

    /// Set by loadSpineItem before loadHTMLString is called, and consumed once
    /// in webView(_:didFinish:) to tell the pagination engine what to restore to.
    private var pendingRestorePosition: RestorePosition = .start

    /// Accumulated horizontal scroll-wheel/trackpad delta for the current
    /// gesture. Reset on .began, summed on .changed, consumed on .ended.
    private var swipeAccumulatedDeltaX: CGFloat = 0

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
    /// Local NSEvent monitor for arrow keys / space in paginated mode. Needed
    /// for the same reason as scrollWheelMonitor above: :root has
    /// `overflow-x: scroll` (required for horizontal column scrolling), and
    /// WebKit applies its own default keyboard-scroll action for Left/Right
    /// arrow keys directly in the web content process — independent of the
    /// AppKit responder chain — which fired *in addition to* our page-turn
    /// call from ReaderMenuWebView.keyDown, producing a small extra native
    /// nudge on top of the intended column snap. Up/Down don't show this
    /// because :root's overflow-y is hidden, so there's no vertical
    /// scroll surface for WebKit's default action to grab onto. A local
    /// monitor sees the event before it's ever dispatched to the web view,
    /// so returning nil here reliably prevents WebKit's native handling from
    /// running at all.
    private var keyDownMonitor: Any?

    // Annotation sidebar
    private var sidebarPanel: NSPanel?
    private var sidebarHostingView: NSHostingView<AnnotationSidebarView>?
    private var sidebarPanelObservers: [NSObjectProtocol] = []

    // Table of contents sidebar
    private var tocPanel: NSPanel?
    private var tocHostingView: NSHostingView<TOCSidebarView>?
    private var tocPanelObservers: [NSObjectProtocol] = []

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
    private var saveContext: ModelContext { modelContainer.mainContext }
    private var bookStates: [Int: BookState] = [:]
    /// The calibreID of whichever work currently owns `currentSpineIndex`.
    /// Falls back to the reading target's primary book before spineMap is
    /// populated (i.e. before loadEPUB() completes).
    private var activeCalibreID: Int {
        spineMap.workID(atGlobalIndex: currentSpineIndex) ?? book.id
    }
    /// The BookState for the currently active work. Resolved fresh from
    /// `bookStates` on every access (not cached in a single stored property)
    /// so that crossing a work boundary in a series transparently retargets
    /// reads/writes to that work's own row — the per-work-keying design in
    /// ambrosia_series_fix_plan.md Task 2c. Assigning through this (e.g.
    /// `bookState?.lastSpineIndex = x`) mutates the same cached class
    /// instance `bookState(for:)` returns, so this being get-only is fine.
    private var bookState: BookState? {
        bookState(for: activeCalibreID)
    }
    /// Fetches (or creates) the BookState row for a specific calibreID,
    /// caching it in `bookStates`. Every work touched during a reading
    /// session — not just the target's primary book — gets its own row here.
    private func bookState(for calibreID: Int) -> BookState {
        if let cached = bookStates[calibreID] { return cached }
        let all = (try? saveContext.fetch(FetchDescriptor<BookState>())) ?? []
        let state: BookState
        if let existing = all.first(where: { $0.calibreID == calibreID }) {
            state = existing
        } else {
            state = BookState(calibreID: calibreID)
            saveContext.insert(state)
            try? saveContext.save()
        }
        bookStates[calibreID] = state
        return state
    }
    private var annotations: [Annotation] = []
    /// The calibreID that owns each in-memory annotation. Populated by
    /// restoreAnnotations() and kept in sync on insert/delete. Annotation
    /// itself carries no calibreID (it's a Codable struct shared with the
    /// JS bridge and sidebar), so this is tracked alongside it rather than
    /// added as a field threaded through every call site. See Task 2c step 8.
    private var annotationCalibreID: [UUID: Int] = [:]
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

        let scriptMessageHandler = WeakScriptMessageHandler(target: self)
        config.userContentController.add(scriptMessageHandler, name: "positionUpdate")
        config.userContentController.add(scriptMessageHandler, name: "pageAction")
        config.userContentController.add(scriptMessageHandler, name: "highlightAdded")
        config.userContentController.add(scriptMessageHandler, name: "highlightTapped")
        config.userContentController.add(scriptMessageHandler, name: "consoleLog")   // JS console → Xcode log

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Self.nsColor(hex: ReaderPreferences.shared.readerBackgroundColor)?.cgColor

        webView = ReaderMenuWebView(frame: .zero, configuration: config)
        webView.viewController = self
        webView.navigationDelegate = self
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif
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
        engine.spineDidLoad = { [weak self] totalCols in
            guard let self else { return }
            // Re-inject highlights for the newly loaded spine item.
            let ranged = self.annotations
                .filter { !$0.isPointAnnotation && self.annotationBelongsToCurrentSpineItem($0) }
            HighlightBridge.restoreHighlights(ranged, into: self.webView)
            self.performPendingAnnotationJumpIfNeeded()
            if let fragment = self.pendingLinkFragment {
                self.pendingLinkFragment = nil
                self.paginationEngine?.scrollToAnchor(fragment)
            }
            self.savePaginatedProgress()
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

        // enclosingScrollView is nil until the WKWebView is part of a view
        // hierarchy — this must run after addSubview, never before (invariant 7).
        webView.enclosingScrollView?.hasHorizontalScroller = false
        webView.enclosingScrollView?.hasVerticalScroller   = false
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
        installKeyDownMonitor()
    }

    deinit {
        if let m = scrollWheelMonitor { NSEvent.removeMonitor(m) }
        if let m = keyDownMonitor { NSEvent.removeMonitor(m) }
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
            guard let self,
                  self.currentMode == .paginated,
                  event.window === self.view.window else { return event }

            switch event.phase {
            case .began:
                self.swipeAccumulatedDeltaX = 0
                return nil
            case .changed:
                self.swipeAccumulatedDeltaX += event.scrollingDeltaX
                return nil
            case .ended:
                let dx = self.swipeAccumulatedDeltaX
                self.swipeAccumulatedDeltaX = 0
                // Threshold: 30pt total swipe, not per-event sample.
                if abs(dx) > 30 {
                    dx < 0 ? self.goToNextPage() : self.goToPreviousPage()
                }
                return nil
            default:
                // Momentum phase, cancelled phase — swallow without acting.
                return event.momentumPhase.isEmpty ? event : nil
            }
        }
    }

    private func removeScrollWheelMonitor() {
        if let m = scrollWheelMonitor {
            NSEvent.removeMonitor(m)
            scrollWheelMonitor = nil
        }
    }

    /// Intercepts Left/Right/Up/Down/Space at the AppKit event-monitor level,
    /// before WebKit's internal keyboard-scroll handling ever sees the event.
    /// See keyDownMonitor's doc comment for why this is necessary — the same
    /// bypass issue documented for scrollWheel applies here for the
    /// horizontal axis. ReaderMenuWebView.keyDown still handles these keys in
    /// scroll mode (vertical paging) and passes everything else through
    /// normally; this monitor only acts in paginated mode.
    private func installKeyDownMonitor() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.currentMode == .paginated,
                  event.window === self.view.window else { return event }

            switch event.keyCode {
            case 123, 126:       // ← ↑
                guard !event.isARepeat else { return nil }
                self.goToPreviousPage()
                return nil
            case 124, 125:       // → ↓
                guard !event.isARepeat else { return nil }
                self.goToNextPage()
                return nil
            case 49:              // Space
                guard !event.isARepeat else { return nil }
                if event.modifierFlags.contains(.shift) {
                    self.goToPreviousPage()
                } else {
                    self.goToNextPage()
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyDownMonitor() {
        if let m = keyDownMonitor {
            NSEvent.removeMonitor(m)
            keyDownMonitor = nil
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !isLayoutReady {
            isLayoutReady = true
            if let pending = pendingSpineLoad {
                pendingSpineLoad = nil
                if currentMode == .paginated {
                    loadSpineItem(index: pending.index, restorePosition: pending.restorePosition)
                } else {
                    #if DEBUG
                    print("[ReaderVC] viewDidLayout: dropped stale pendingSpineLoad, currentMode=\(currentMode)")
                    #endif
                }
            }
        }
        repositionFindBar()
        // Sync the annotation panel whenever the reader view's bounds change.
        // Window move/resize notifications cover whole-window geometry changes,
        // but NSSplitView divider drags change the reader pane's screen rect
        // without firing a window resize notification, so we handle them here.
        syncSidebarPanel()
        syncTOCPanel()
        // Resize is more expensive than a plain reapply: because column CSS is
        // baked into the HTML, a resize requires reloading the spine item, not
        // just re-running JS (invariant 8). Read the current fraction before
        // the reload invalidates it, then reload with that fraction as the
        // restore target — loadSpineItem recomputes column CSS from the new
        // webView.bounds at the moment it's called.
        //
        // Paginated-only: loadSpineItem() injects paginatedColumnCSS (which sets
        // `overflow-x: scroll !important` on `html`), so calling it while in
        // scroll mode would silently replace the merged scroll-mode document
        // with a single paginated spine item and force horizontal scrolling.
        // paginationEngine is created unconditionally in loadView() (non-nil in
        // both modes), so `paginationEngine?.` alone does not guard against
        // firing in scroll mode — the explicit currentMode checks below do.
        guard currentMode == .paginated else {
            #if DEBUG
            print("[ReaderVC] viewDidLayout: skipping resize reload, currentMode=\(currentMode)")
            #endif
            return
        }
        resizeDebounce.schedule { [weak self] in
            guard let self, self.currentMode == .paginated else { return }
            self.paginationEngine?.currentFraction { fraction in
                guard self.currentMode == .paginated else { return }
                #if DEBUG
                print("[ReaderVC] viewDidLayout: resize reload -> loadSpineItem index=\(self.currentSpineIndex) fraction=\(fraction)")
                #endif
                self.loadSpineItem(
                    index: self.currentSpineIndex,
                    restorePosition: .fraction(fraction)
                )
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        removeScrollWheelMonitor()
        removeKeyDownMonitor()
        saveTimer?.invalidate()
        saveTimer = nil
        removeReaderWindowObservers()
        sidebarPanel?.close()
        tocPanel?.close()
        annotationPopover?.close()
        notePopover?.close()
        hideFindBar()
        flushPosition(final: true)
    }

    // MARK: - EPUB loading

    /// Per-work data produced by parsing the reading target's EPUB(s) from
    /// disk. `workIDs[i]` is the calibreID owning `parsers[i]`.
    private struct LoadedWorks {
        let parsers: [EPUBParser]
        let imageBaseURLs: [URL]
        let ao3Records: [AO3MetadataRecord?]
        let workIDs: [Int]
    }

    private func loadEPUB() async {
        guard let pathStr = LibraryRegistry.shared.activePath else {
            await MainActor.run { self.showError("No library open.") }; return
        }
        let libraryRoot = URL(fileURLWithPath: pathStr)
        do {
            let record = await fetchAO3Record()
            let loaded = try await loadWorks(for: target, libraryRoot: libraryRoot, primaryAO3Record: record)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.ao3Record         = record
                self.workParsers       = loaded.parsers
                self.workImageBaseURLs = loaded.imageBaseURLs
                self.workAO3Records    = loaded.ao3Records
                self.spineMap = SeriesSpineMap(
                    workIDs: loaded.workIDs,
                    spineCounts: loaded.parsers.map { $0.spine.count }
                )
                do {
                    self.currentHTML = try self.buildScrollHTML()
                    self.loadCurrentHTML()
                } catch {
                    self.showError(error.localizedDescription)
                }
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

    /// Parses every work's EPUB from disk and extracts its images. Pure I/O —
    /// does not touch `self`'s stored properties (those are assigned once,
    /// on the main actor, by loadEPUB()).
    private func loadWorks(for target: ReadingTarget, libraryRoot: URL, primaryAO3Record: AO3MetadataRecord?) async throws -> LoadedWorks {
        switch target {
        case .singleBook(let book):
            guard let epubURL = book.epubURL(libraryRoot: libraryRoot),
                  FileManager.default.fileExists(atPath: epubURL.path) else {
                throw NSError(domain: "Ambrosia.Reader", code: 1, userInfo: [NSLocalizedDescriptionKey: "EPUB file not found: \(book.displayTitle)"])
            }
            var p = EPUBParser(epubURL: epubURL)
            try p.parse()
            p.ao3Record = primaryAO3Record
            let imgBase = try EPUBParser.extractImages(from: epubURL, calibreID: book.id)
            return LoadedWorks(parsers: [p], imageBaseURLs: [imgBase], ao3Records: [primaryAO3Record], workIDs: [book.id])

        case .series(let series):
            // Batch-fetch ao3 records for all works so each gets its own endmatter.
            let allIDs = series.works.map(\.id)
            let metaDB = await MainActor.run { AppDelegate.shared?.session.metaDB }
            let recordMap = (try? await metaDB?.ao3Metadata(for: allIDs)) ?? [:]

            var parsers: [EPUBParser] = []
            var imageBases: [URL] = []
            var records: [AO3MetadataRecord?] = []
            for work in series.works {
                guard let epubURL = work.epubURL(libraryRoot: libraryRoot),
                      FileManager.default.fileExists(atPath: epubURL.path) else {
                    throw NSError(domain: "Ambrosia.Reader", code: 2, userInfo: [NSLocalizedDescriptionKey: "EPUB file not found: \(work.displayTitle)"])
                }
                var p = EPUBParser(epubURL: epubURL)
                try p.parse()
                let record = recordMap[work.id]
                p.ao3Record = record
                let imageBase = try EPUBParser.extractImages(from: epubURL, calibreID: work.id)
                parsers.append(p)
                imageBases.append(imageBase)
                records.append(record)
            }
            return LoadedWorks(parsers: parsers, imageBaseURLs: imageBases, ao3Records: records, workIDs: series.works.map(\.id))
        }
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Rebuilds the scroll-mode merged HTML for the current target from the
    /// already-parsed `workParsers` (no disk re-read). Used both by the
    /// initial load and by reloadHTML() (style-only preference changes), so
    /// a series' full multi-work content is rebuilt correctly on every
    /// preference change instead of only the first work's — the previous
    /// reloadHTML() went through `parser.mergedHTML(...)` where `parser` was
    /// only ever the first work, silently dropping the rest of the series on
    /// any font/color/spacing change. See ambrosia_series_fix_plan.md Task 2c.
    ///
    /// Each work's own content is wrapped in a `.ambrosia-work` container
    /// tagged with its calibreID. This lets scroll-mode JS (HighlightBridge,
    /// position-save) scope character-offset counting to a single work
    /// instead of the whole multi-work merge — required so offsets stored
    /// for a work read as part of a series match what the same work would
    /// record read standalone (Task 2c's per-work keying design). A
    /// single-book target's one work isn't wrapped; its content already *is*
    /// the whole document, so document.body is already the correct scope
    /// (see HighlightBridge's ambrosiaWorkRootFor fallback).
    private func buildScrollHTML() throws -> String {
        guard case .series(let series) = target else {
            guard let p = workParsers.first else { return "" }
            return try p.mergedHTML(userCSS: ReaderPreferences.shared.css, ao3Record: workAO3Records.first ?? nil)
        }

        var parts: [String] = []
        var spineIndexOffset = 0
        for (offset, p) in workParsers.enumerated() {
            guard series.works.indices.contains(offset) else { continue }
            let work = series.works[offset]
            let record = workAO3Records.indices.contains(offset) ? workAO3Records[offset] : nil
            let displayIndex = series.displayIndex(for: work) ?? offset + 1
            let breakHTML = """
            <div class="ambrosia-series-break"><h2>Work \(displayIndex): \(Self.escapeHTML(work.displayTitle))</h2></div>
            """
            // Running count of spine items already emitted by prior works, so
            // each work's data-spine-index range is disjoint in the merged
            // document (Task 2c step 9). imageBaseOverride rewrites this
            // work's own <img>/<image> references to absolute file:// URLs
            // under its own extracted-images directory, since a single
            // relative baseURL on the whole merged document can only ever
            // resolve one work's images — see EPUBParser.rewriteImageReferences.
            let workImageBase = workImageBaseURLs.indices.contains(offset) ? workImageBaseURLs[offset] : nil
            let workHTML = try p.mergedHTML(userCSS: ReaderPreferences.shared.css, ao3Record: record, spineIndexOffset: spineIndexOffset, imageBaseOverride: workImageBase)
            let wrappedWorkHTML = """
            <div class="ambrosia-work" data-work-calibre-id="\(work.id)">
            \(workHTML)
            </div>
            """
            parts.append(breakHTML + wrappedWorkHTML)
            spineIndexOffset += p.spine.count
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - HTML reload

    func reloadHTML() {
        guard !workParsers.isEmpty else { return }
        do {
            currentHTML = try buildScrollHTML()
            loadCurrentHTML()
        } catch {
            #if DEBUG
            print("[ReaderVC] reloadHTML error: \(error)")
            #endif
        }
    }

    /// Loads `currentHTML` into the webView, prepending column CSS if in paginated mode.
    private func loadCurrentHTML() {
        isReaderContentReady = false
        if currentMode == .paginated {
            loadPaginatedHTML()
        } else {
            webView.loadHTMLString(currentHTML, baseURL: workImageBaseURLs.first)
        }
    }

    // MARK: - Paginated HTML loading

    /// Determines the global spine index + fraction to resume into for a
    /// (possibly multi-work) reading target: the first work in series order
    /// whose own BookState isn't fully read, falling back to the last work
    /// if every work is already finished. This intentionally introduces no
    /// new series-level persisted state (per ambrosia_series_fix_plan.md
    /// Task 2c's per-work recommendation) — it composes entirely from each
    /// work's own BookState, so reading a work standalone and reading it as
    /// part of a series share the same progress row.
    private func resumeSpinePosition() -> (globalIndex: Int, fraction: Double) {
        guard !spineMap.workIDs.isEmpty else { return (0, 0) }
        var candidateWorkIndex = spineMap.workIDs.count - 1
        for (workIndex, calibreID) in spineMap.workIDs.enumerated() {
            if bookState(for: calibreID).totalReadPercent < 1.0 {
                candidateWorkIndex = workIndex
                break
            }
        }
        let calibreID = spineMap.workIDs[candidateWorkIndex]
        let state = bookState(for: calibreID)
        let localSpineCount = workParsers.indices.contains(candidateWorkIndex) ? workParsers[candidateWorkIndex].spine.count : 1
        let localIndex = min(max(0, state.lastSpineIndex), max(0, localSpineCount - 1))
        let globalIndex = spineMap.globalIndex(workIndex: candidateWorkIndex, localIndex: localIndex) ?? 0
        return (globalIndex, min(max(state.lastScrollOffset, 0), 1))
    }

    /// Builds the HTML string for paginated mode by prepending a <style> block
    /// containing the column layout CSS, then loads it. The column CSS is sized
    /// to the current webView bounds. If bounds aren't ready yet, defers briefly.
    private func loadPaginatedHTML() {
        let (globalIndex, fraction) = resumeSpinePosition()
        loadSpineItem(index: globalIndex, restorePosition: .fraction(fraction))
    }

    /// Loads a single spine item in paginated mode, addressed by its global
    /// spine index (series-wide; see GlobalSpineRef). Resolves the owning
    /// work via spineMap, loads that work's own HTML/image base, and updates
    /// that work's own BookState.lastSpineIndex (local, not global — Task
    /// 2c). The column layout CSS is computed from the webView's current
    /// bounds and injected into the HTML string BEFORE loadHTMLString is
    /// called, so the browser never renders an un-paginated flash (invariant
    /// 2). Column geometry is always recomputed here — never cached — so a
    /// resize-triggered reload picks up the new viewport size automatically.
    private func loadSpineItem(index: Int, restorePosition: RestorePosition = .fraction(0)) {
        guard let ref = spineMap.ref(atGlobalIndex: index),
              workParsers.indices.contains(ref.workIndex) else { return }
        let workParser = workParsers[ref.workIndex]
        guard ref.localIndex >= 0, ref.localIndex < workParser.spine.count else { return }

        guard isLayoutReady, view.window != nil else {
            pendingSpineLoad = (index, restorePosition)
            return
        }

        currentSpineIndex = index
        let calibreID = spineMap.workIDs[ref.workIndex]
        bookState(for: calibreID).lastSpineIndex = ref.localIndex

        let item = workParser.spine[ref.localIndex]
        do {
            let bounds = webView.bounds
            let colCSS = ReaderPreferences.shared.paginatedColumnCSS(
                viewportWidth: bounds.width,
                viewportHeight: bounds.height
            )
            #if DEBUG
            print("[Pagination] loadSpineItem globalIndex=\(index) work=\(ref.workIndex) local=\(ref.localIndex) bounds=\(bounds) backingScale=\(view.window?.backingScaleFactor ?? -1) restorePosition=\(restorePosition)")
            #endif
            let baseCSS = ReaderPreferences.shared.css(paginated: true)
            let combinedCSS = baseCSS + "\n" + colCSS

            let html = try workParser.html(for: item, userCSS: combinedCSS, globalSpineIndex: index)
            isReaderContentReady = false
            paginationEngine?.setColsPerScreen(ReaderPreferences.shared.colsPerScreen)
            pendingRestorePosition = restorePosition
            let imageBase = workImageBaseURLs.indices.contains(ref.workIndex) ? workImageBaseURLs[ref.workIndex] : nil
            webView.loadHTMLString(html, baseURL: imageBase)
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
            // saveCurrentPositionSync (scroll-mode branch) just updated
            // self.currentSpineIndex to the fresh global position and wrote
            // it into the owning work's BookState, so it's safe to resume
            // from directly here rather than re-deriving via
            // resumeSpinePosition()'s cross-work heuristic (which is for
            // the cold-start case, before any position is known).
            let maxGlobal = max(0, self.spineMap.count - 1)
            let savedSpine = min(max(0, self.currentSpineIndex), maxGlobal)
            let restorePosition: RestorePosition = .fraction(self.bookState?.lastScrollOffset ?? 0)
            self.loadSpineItem(index: savedSpine, restorePosition: restorePosition)
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
            // CSS was pre-loaded. Just inject JS and restore position.
            paginationEngine?.applyLayout(restorePosition: pendingRestorePosition)
        } else {
            restoreScrollPosition()
            injectScrollTracker()
        }

        HighlightBridge.injectSelectionListener(into: webView)
        restoreAnnotations()

        startAutoSave()
        isReaderContentReady = true
        onReaderContentReady?()
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!, withError error: Error) {
        #if DEBUG
        print("[ReaderVC] Navigation failed: \(error.localizedDescription)")
        #endif
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

        if url.scheme == "about" {
            decisionHandler(.allow)
            return
        }

        if url.scheme == "file" {
            // In-book links (a "Table of Contents" chapter linking to other
            // chapters, footnote/endnote cross-references, etc.) resolve
            // relative to `baseURL`, which is the active work's own entry in
            // `workImageBaseURLs` — the temp directory extracted images live
            // in, NOT the spine XHTML (spine content is read straight out of
            // the EPUB zip archive and never written to disk as standalone
            // files). Letting WKWebView
            // navigate to that resolved file:// URL directly always fails,
            // since the target chapter file doesn't exist there. Resolve the
            // link against the known spine instead and route it through the
            // normal spine-loading pipeline. Anything that isn't a
            // recognisable spine link (a genuine broken/missing file
            // reference) is cancelled rather than allowed to navigate to a
            // guaranteed-dead file:// URL.
            navigateToInternalLink(url)
            decisionHandler(.cancel)
            return
        }

        if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.cancel)
    }

    /// Resolves an in-book file:// link (from a TOC chapter, footnote, etc.)
    /// against the known EPUB spine by filename, then navigates to it through
    /// the normal spine-loading pipeline instead of letting WKWebView load
    /// the (nonexistent) file:// URL directly. No-ops silently if the link
    /// doesn't match any spine item.
    private func navigateToInternalLink(_ url: URL) {
        guard let ref = spineMap.ref(atGlobalIndex: currentSpineIndex),
              workParsers.indices.contains(ref.workIndex) else { return }
        let workParser = workParsers[ref.workIndex]
        let requestedFilename = url.lastPathComponent
        let fragment = url.fragment

        // A TOC/footnote link inside one EPUB only ever references files
        // within that same work's own manifest, so the search is scoped to
        // the currently active work — no cross-work link resolution needed.
        guard let localTargetIndex = workParser.spine.firstIndex(where: {
            URL(fileURLWithPath: $0.href).lastPathComponent == requestedFilename
        }), let targetIndex = spineMap.globalIndex(workIndex: ref.workIndex, localIndex: localTargetIndex) else {
            return
        }

        switch currentMode {
        case .paginated:
            if targetIndex == currentSpineIndex {
                if let fragment { paginationEngine?.scrollToAnchor(fragment) }
            } else {
                pendingLinkFragment = fragment
                loadSpineItem(index: targetIndex, restorePosition: .start)
            }
        case .scroll:
            let js: String
            if let fragment {
                // Prefer the element's own id (ids are preserved from the
                // original spine content in mergedHTML); fall back to the
                // wrapping <section data-spine-index> if the id isn't found.
                // targetIndex here is the global index — matches the
                // globally-unique data-spine-index values mergedHTML emits
                // (Task 2c step 9).
                js = """
                (function() {
                    var el = document.getElementById(\(Self.jsStringLiteral(fragment)));
                    if (!el) el = document.querySelector('[data-spine-index="\(targetIndex)"]');
                    if (el) el.scrollIntoView({ block: 'start' });
                })();
                """
            } else {
                js = """
                (function() {
                    var el = document.querySelector('[data-spine-index="\(targetIndex)"]');
                    if (el) el.scrollIntoView({ block: 'start' });
                })();
                """
            }
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private static func jsStringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        // json is a single-element JSON array like ["the string"] — slicing
        // off the brackets gives a properly quoted/escaped JS string literal
        // without hand-rolled escaping.
        return String(json.dropFirst().dropLast())
    }

    // MARK: - Scroll mode: position save/restore

    /// Given a target Y coordinate (document/page coordinates, not viewport-
    /// relative), finds the `section[data-spine-index]` it falls in and
    /// returns `{spineIndex, fraction}`, where fraction is progress within
    /// that section only, clamped to [0, 1]. This is the same unit paginated
    /// mode already uses for `lastScrollOffset` (progress within the current
    /// spine item); scroll mode's save/restore paths below use it too so both
    /// modes agree on what a saved fraction means when switching between them
    /// (ambrosia_reader_fix_plan.md Task 2 Phase A).
    private static let spineFractionJS = """
    function ambrosiaSpineFraction(targetY) {
        var sections = document.querySelectorAll('section[data-spine-index]');
        var best = null;
        for (var i = 0; i < sections.length; i++) {
            var el = sections[i];
            if (el.offsetTop <= targetY) { best = el; } else { break; }
        }
        if (!best) best = sections[0];
        if (!best) return { spineIndex: 0, fraction: 0 };
        var idx = parseInt(best.getAttribute('data-spine-index'), 10) || 0;
        var top = best.offsetTop;
        var height = best.offsetHeight || 1;
        var fraction = (targetY - top) / height;
        fraction = Math.max(0, Math.min(1, fraction));
        return { spineIndex: idx, fraction: fraction };
    }
    // Scopes character-offset counting to the enclosing .ambrosia-work
    // container (present only in a merged series read), so offsets stay
    // local to the owning work instead of cumulative across the whole
    // series merge. Falls back to document.body for a single-book read.
    // Mirrors HighlightBridge.selectionListenerJS's copy of this same
    // function — the two must stay in sync (see Task 2c).
    function ambrosiaWorkRootFor(el) {
        var node = el;
        while (node) {
            if (node.classList && node.classList.contains('ambrosia-work')) return node;
            node = node.parentElement;
        }
        return document.body;
    }
    """

    private func restoreScrollPosition() {
        let (globalIndex, fraction) = resumeSpinePosition()
        guard globalIndex >= 0 else { return }
        let clampedFraction = max(0.0, min(1.0, fraction))
        let js = """
        (function() {
            var el = document.querySelector('section[data-spine-index="\(globalIndex)"]');
            if (!el) return;
            var targetY = el.offsetTop + \(clampedFraction) * (el.offsetHeight || 1);
            window.scrollTo(0, targetY);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func injectScrollTracker() {
        let js = """
        (function() {
            \(Self.spineFractionJS)
            function sendPosition() {
                var doc = document.documentElement;
                var maxScroll = Math.max(1, doc.scrollHeight - window.innerHeight);
                var globalPercent = Math.max(0, Math.min(1, window.scrollY / maxScroll));
                var spine = ambrosiaSpineFraction(window.scrollY);
                window.webkit.messageHandlers.positionUpdate.postMessage(
                    JSON.stringify({
                        scrollY: window.scrollY,
                        percent: globalPercent,
                        spineIndex: spine.spineIndex,
                        fraction: spine.fraction
                    })
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
    //
    // Position restore is now handled by PaginationEngine.applyLayout(restorePosition:),
    // called from webView(_:didFinish:) with pendingRestorePosition — there is no
    // separate restore step here.

    private func performPendingAnnotationJumpIfNeeded() {
        guard let annotation = pendingAnnotationJump,
              currentMode == .paginated,
              annotationBelongsToCurrentSpineItem(annotation) else { return }

        pendingAnnotationJump = nil
        let offset = annotation.startChar
        let js = """
        if (window.ambrosiaNavigateToOffset) { window.ambrosiaNavigateToOffset(\(offset)); }
        if (window.ambrosiaHighlight) { window.ambrosiaHighlight(\(offset)); }
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        savePaginatedProgress()
    }

    /// True if `annotation` belongs to whichever work/local-spine-item
    /// `currentSpineIndex` currently resolves to — i.e. it's visible on the
    /// single spine item paginated mode has loaded right now. Resolves via
    /// annotationCalibreID + spineMap rather than comparing
    /// annotation.spineIndex (work-local) directly against currentSpineIndex
    /// (global). See ambrosia_series_fix_plan.md Task 2c.
    private func annotationBelongsToCurrentSpineItem(_ annotation: Annotation) -> Bool {
        guard let ref = spineMap.ref(atGlobalIndex: currentSpineIndex),
              workParsers.indices.contains(ref.workIndex) else { return false }
        let calibreID = spineMap.workIDs[ref.workIndex]
        return annotationCalibreID[annotation.id] == calibreID && annotation.spineIndex == ref.localIndex
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
        guard currentSpineIndex + 1 < spineMap.count else { return }
        savePaginatedProgress()
        let crossesWork = spineMap.isLastItemInWork(currentSpineIndex)
        loadSpineItem(index: currentSpineIndex + 1, restorePosition: .start)
        if crossesWork { announceWorkBoundaryIfNeeded() }
    }

    private func loadPreviousSpineItem() {
        guard currentSpineIndex > 0 else { return }
        savePaginatedProgress()
        let crossesWork = spineMap.isFirstItemInWork(currentSpineIndex)
        loadSpineItem(index: currentSpineIndex - 1, restorePosition: .end)
        if crossesWork { announceWorkBoundaryIfNeeded() }
    }

    /// Paged mode has no visible "ambrosia-series-break" marker the way
    /// scroll mode's merged HTML does (each spine item is loaded as its own
    /// standalone document, so there's nothing to inject a marker into ahead
    /// of time) — a HUD toast is the paged-mode equivalent visible boundary
    /// cue, shown after loadSpineItem has already updated currentSpineIndex
    /// to the new work. See ambrosia_series_fix_plan.md Task 2b step 5.
    private func announceWorkBoundaryIfNeeded() {
        guard case .series(let series) = target,
              let ref = spineMap.ref(atGlobalIndex: currentSpineIndex),
              series.works.indices.contains(ref.workIndex) else { return }
        let work = series.works[ref.workIndex]
        let index = series.displayIndex(for: work) ?? ref.workIndex + 1
        showHUD("Now reading Work \(index): \(work.displayTitle)")
    }

    private func savePaginatedProgress() {
        guard currentMode == .paginated else { return }
        paginationEngine?.queryProgress { [weak self] fraction, col, total in
            guard let self else { return }
            // total==1 with col==0 means ambrosiaSetup hasn't run yet — don't
            // write 100% progress from a spurious 1.0 fraction.
            guard total > 1 || col > 0 else { return }
            guard let ref = self.spineMap.ref(atGlobalIndex: self.currentSpineIndex) else { return }
            let calibreID = self.spineMap.workIDs[ref.workIndex]
            let state = self.bookState(for: calibreID)
            state.lastSpineIndex = ref.localIndex
            state.lastScrollOffset = fraction
            state.totalReadPercent = fraction
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
                \(Self.spineFractionJS)
                var targetY = window.scrollY + 20;
                var spine = ambrosiaSpineFraction(targetY);
                var bestSection = document.querySelector('section[data-spine-index="' + spine.spineIndex + '"]');
                var workRoot = ambrosiaWorkRootFor(bestSection || document.body);
                var walker = document.createTreeWalker(workRoot, NodeFilter.SHOW_TEXT, null);
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
                        return { spineIndex: spine.spineIndex, fraction: spine.fraction, charOffset: cumulative + lo };
                    }
                    cumulative += node.length;
                }
                return { spineIndex: spine.spineIndex, fraction: spine.fraction, charOffset: cumulative };
            })();
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, let dict = result as? [String: Any] else {
                    completion(); return
                }
                let globalSpineIndex = dict["spineIndex"] as? Int ?? self.currentSpineIndex
                let fraction = Self.double(from: dict["fraction"]) ?? 0
                let charOffset = dict["charOffset"] as? Int ?? 0
                if let ref = self.spineMap.ref(atGlobalIndex: globalSpineIndex) {
                    self.currentSpineIndex = globalSpineIndex
                    let calibreID = self.spineMap.workIDs[ref.workIndex]
                    let state = self.bookState(for: calibreID)
                    state.lastSpineIndex      = ref.localIndex
                    state.lastScrollOffset    = min(max(fraction, 0), 1)
                    state.lastCharacterOffset = charOffset
                }
                completion()
            }
        }
    }

    private func saveCurrentPage() {
        savePaginatedProgress()
    }

    private func ensureBookState() {
        _ = bookState(for: book.id)
    }

    /// Writes spine/scroll progress into the correct work's own BookState,
    /// resolving `globalIndex` (series-wide) to that work's calibreID +
    /// local spine index via spineMap, and updates `currentSpineIndex` so
    /// `bookState` (and anything else keyed off "the active work") stays in
    /// sync with the position just reported. See Task 2c.
    private func applySpineProgress(globalIndex: Int, fraction: Double, totalPercent: Double?) {
        guard let ref = spineMap.ref(atGlobalIndex: globalIndex) else { return }
        currentSpineIndex = globalIndex
        let calibreID = spineMap.workIDs[ref.workIndex]
        let state = bookState(for: calibreID)
        state.lastSpineIndex = ref.localIndex
        state.lastScrollOffset = min(max(fraction, 0), 1)
        if let totalPercent {
            state.totalReadPercent = min(max(totalPercent, 0), 1)
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
        // Uses whichever work is active at session start. If the read later
        // crosses into a different work (Task 2b), updateReadingHistory
        // below still reports against bookState.calibreID (the *current*
        // active work), which will disagree with the calibreID this session
        // was opened under — reading_history has no notion of "session
        // spans multiple works." Out of scope for ambrosia_series_fix_plan.md;
        // noting it here rather than silently accepting a wrong session id.
        let calibreID = activeCalibreID
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
                #if DEBUG
                print("[ReadingHistory] Start failed: \(error)")
                #endif
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
                #if DEBUG
                print("[ReadingHistory] \(final ? "Final update" : "Update") failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        switch message.name {

        case "consoleLog":
            #if DEBUG
            if let body = message.body as? String {
                print("[JS] \(body)")
            }
            #endif

        case "positionUpdate":
            guard let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            // Paginated mode's own progress tracking posts "fraction" as a
            // whole-book value historically; keep that path untouched. Scroll
            // mode's injectScrollTracker now posts spineIndex/fraction
            // (spine-relative, matching paginated mode's unit, and globally
            // unique across a series merge — Task 2c step 9) plus a
            // separate whole-book "percent" for totalReadPercent/progress UI.
            if json["spineIndex"] != nil, let fraction = Self.double(from: json["fraction"]) {
                if let globalSpineIndex = json["spineIndex"] as? Int {
                    applySpineProgress(globalIndex: globalSpineIndex, fraction: fraction, totalPercent: Self.double(from: json["percent"]))
                }
            } else if let fraction = Self.double(from: json["fraction"]) {
                applySpineProgress(globalIndex: currentSpineIndex, fraction: fraction, totalPercent: fraction)
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

    @objc func toggleReadingMode(_ sender: Any?) {
        switch currentMode {
        case .scroll:
            switchToPaginatedMode()
        case .paginated:
            switchToScrollMode()
        }
    }

    @objc func addAnnotation(_ sender: Any?) { savePointAnnotationAtCurrentPosition() }
    @objc func showAnnotationSidebar(_ sender: Any?) { toggleAnnotationSidebar() }
    @objc func showTOCSidebar(_ sender: Any?) { toggleTOCSidebar() }

    // MARK: - Point annotations (⌘D)

    private func savePointAnnotationAtCurrentPosition() {
        guard let state = bookState else { return }

        let offset = state.lastCharacterOffset
        let spineIndex = state.lastSpineIndex   // work-local (Task 2c)
        let calibreID = activeCalibreID

        let sentenceJS = """
        (function() {
            var target = Math.max(0, \(offset));
            // Scope to the active work's own container, since `offset` is
            // local to that work, not to the whole (possibly multi-work)
            // merged document. Falls back to document.body when no such
            // container exists (single-book read, or paginated mode, where
            // document.body already contains only the active work's own
            // spine item). See ambrosia_series_fix_plan.md Task 2c.
            var workRoot = document.querySelector('[data-work-calibre-id="\(calibreID)"]') || document.body;
            var walker = document.createTreeWalker(workRoot, NodeFilter.SHOW_TEXT, null);
            var remaining = target;
            var node;
            while ((node = walker.nextNode()) !== null) {
                if (remaining <= node.length) {
                    var nodes = [];
                    var bw = document.createTreeWalker(workRoot, NodeFilter.SHOW_TEXT, null);
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
                    && self.annotationCalibreID[$0.id] == calibreID
            }) {
                existing.append(annotation)
                self.annotations = existing
                self.annotationCalibreID[annotation.id] = calibreID
                self.onAnnotationsChanged?(existing)
                Task { try? await AppDelegate.shared?.session.metaDB?.insertAnnotation(
                    annotation, calibreID: calibreID) }
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

        // pending.spineIndex arrives from JS (selectionListenerJS's
        // ambrosiaResolveSpineIndex / window.currentSpineIndex) as a GLOBAL
        // series-wide index; resolve it to the owning work's calibreID and
        // that work's own LOCAL spine index before storing, per Task 2c's
        // per-work keying (startChar/endChar are already work-local, since
        // HighlightBridge's getCharOffset scopes to the enclosing
        // .ambrosia-work container).
        let resolvedRef = spineMap.ref(atGlobalIndex: pending.spineIndex)
        let calibreID = resolvedRef.flatMap { spineMap.workIDs.indices.contains($0.workIndex) ? spineMap.workIDs[$0.workIndex] : nil } ?? book.id
        let localSpineIndex = resolvedRef?.localIndex ?? pending.spineIndex

        let popoverView = AnnotationPopover(
            selectedText: pending.selectedText,
            onSave: { [weak self] note, colorHex in
                guard let self else { return }
                self.annotationPopover?.close()
                self.annotationPopover = nil

                var final = pending
                final.spineIndex = localSpineIndex
                final.note     = note
                final.colorHex = colorHex

                var existing = self.annotations
                existing.append(final)
                self.annotations = existing
                self.annotationCalibreID[final.id] = calibreID
                self.onAnnotationsChanged?(existing)
                Task { try? await AppDelegate.shared?.session.metaDB?.insertAnnotation(
                    final, calibreID: calibreID) }
                self.flushPosition()
                self.refreshSidebarIfVisible()

                if !final.isPointAnnotation {
                    HighlightBridge.clearHighlights(from: self.webView) {
                        let ranged = existing
                            .filter { !$0.isPointAnnotation }
                        HighlightBridge.restoreHighlights(ranged, into: self.webView)
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

    /// Loads and merges annotations from every work in the (possibly
    /// multi-work) reading target, keeping ownership in `annotationCalibreID`.
    /// The merged flat list feeds the sidebar exactly as a single-book read
    /// would — AnnotationSidebarView needs no changes, since it's agnostic
    /// to which work each entry came from. See ambrosia_series_fix_plan.md
    /// Task 2c step 8.
    private func restoreAnnotations() {
        Task {
            let workIDs = spineMap.workIDs.isEmpty ? [book.id] : spineMap.workIDs
            var merged: [Annotation] = []
            var owners: [UUID: Int] = [:]
            for calibreID in workIDs {
                let loaded = (try? await AppDelegate.shared?.session.metaDB?.annotations(for: calibreID)) ?? []
                for annotation in loaded {
                    merged.append(annotation)
                    owners[annotation.id] = calibreID
                }
            }
            await MainActor.run {
                annotations = merged
                annotationCalibreID = owners
                onAnnotationsChanged?(merged)
                let ranged = merged
                    .filter { !$0.isPointAnnotation && (currentMode != .paginated || annotationBelongsToCurrentSpineItem($0)) }
                HighlightBridge.restoreHighlights(ranged, into: webView)
                refreshSidebarIfVisible()
                refreshTOCSidebarIfVisible()
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
            // annotation.spineIndex is work-local; resolve which work owns
            // it (via annotationCalibreID) to find the corresponding global
            // spine index for paginated navigation. Falls back to treating
            // it as already-global if ownership isn't known (shouldn't
            // normally happen once restoreAnnotations has run).
            let calibreID = self.annotationCalibreID[annotation.id]
            let workIndex = calibreID.flatMap { self.spineMap.workIDs.firstIndex(of: $0) }
            let globalIndex = workIndex.flatMap { self.spineMap.globalIndex(workIndex: $0, localIndex: annotation.spineIndex) }
                ?? annotation.spineIndex

            if self.currentMode == .paginated {
                if globalIndex != self.currentSpineIndex {
                    self.pendingAnnotationJump = annotation
                    self.loadSpineItem(index: globalIndex, restorePosition: .start)
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
                self.scrollToCharOffset(offset, workCalibreID: calibreID)
            } else {
                self.performFindAndJump(annotation.selectedText)
            }
        }
    }

    /// - Parameter workCalibreID: scopes the treewalker to that work's
    ///   `.ambrosia-work` container (present only in a series merge), since
    ///   `offset` is local to the owning work, not the whole merged
    ///   document. Falls back to document.body when nil or not found
    ///   (single-book read), reproducing the offset exactly as before this
    ///   fix. See ambrosia_series_fix_plan.md Task 2c.
    private func scrollToCharOffset(_ offset: Int, workCalibreID: Int? = nil) {
        let workRootJS = workCalibreID.map {
            "document.querySelector('[data-work-calibre-id=\"\($0)\"]') || document.body"
        } ?? "document.body"
        let js = """
        (function() {
            var target = \(offset);
            var workRoot = \(workRootJS);
            var walker = document.createTreeWalker(workRoot, NodeFilter.SHOW_TEXT, null);
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
        // Invariant 9 — matches AnnotationSidebarView's/TOCSidebarView's own hosting:
        // frame is fully owned by the constraints below, so SwiftUI's own
        // intrinsic/min/max sizing must be disabled rather than fought with.
        hosting.sizingOptions = []
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

    /// WKWebView.find(_:configuration:) highlights the match but does not
    /// scroll to it in paged mode — the highlight can land in a column that's
    /// currently off-screen. After a successful find, query the selection's X
    /// position and snap to its column.
    private func snapFoundSelectionToColumn() {
        guard currentMode == .paginated else { return }
        webView.evaluateJavaScript("""
        (function() {
            var sel = window.getSelection();
            if (!sel || sel.rangeCount === 0) return -1;
            var rect = sel.getRangeAt(0).getBoundingClientRect();
            var docX = rect.left + window.scrollX;
            return window._colAndGap > 0 ? Math.max(0, Math.floor(docX / window._colAndGap)) : -1;
        })()
        """) { [weak self] result, _ in
            if let col = result as? Int, col >= 0 {
                self?.paginationEngine?.scrollToColumn(col)
            }
        }
    }

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
            } else {
                if self.findMatchTotal == 0 {
                    self.findMatchTotal = 1
                    self.findMatchCurrent = 1
                }
                self.snapFoundSelectionToColumn()
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
                self.snapFoundSelectionToColumn()
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
                self.snapFoundSelectionToColumn()
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
        // Invariant 9: sizingOptions = [] lets Auto Layout (the panel's content
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
        let calibreID = annotationCalibreID[id] ?? book.id
        annotations = annotations.filter { $0.id != id }
        annotationCalibreID.removeValue(forKey: id)
        onAnnotationsChanged?(annotations)
        Task { try? await AppDelegate.shared?.session.metaDB?.deleteAnnotation(
            id: id, calibreID: calibreID) }
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

    // MARK: - Table of contents sidebar

    func toggleTOCSidebar() {
        if let panel = tocPanel, panel.isVisible { panel.close(); return }
        openTOCSidebar()
    }

    private func openTOCSidebar() {
        guard let screenRect = readerScreenRect(), let readerWindow = view.window else { return }

        let sidebar = makeTOCSidebarView()
        let hosting = NSHostingView(rootView: sidebar)
        hosting.sizingOptions = []   // Invariant 9 — matches AnnotationSidebarView's own hosting.
        tocHostingView = hosting

        // Anchored to the left edge, independent of the annotation panel on
        // the right — both can be open simultaneously in standalone mode.
        let contentRect = CGRect(
            x: screenRect.minX - 260,
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
        panel.title = "Contents"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.contentView = hosting
        panel.orderFront(nil)
        tocPanel = panel

        let nc = NotificationCenter.default
        let move = nc.addObserver(forName: NSWindow.didMoveNotification, object: readerWindow, queue: .main) {
            [weak self, weak panel] _ in self?.syncTOCPanel(panel)
        }
        let resize = nc.addObserver(forName: NSWindow.didResizeNotification, object: readerWindow, queue: .main) {
            [weak self, weak panel] _ in self?.syncTOCPanel(panel)
        }
        let close = nc.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) {
            [weak self] _ in self?.removeTOCWindowObservers()
        }
        tocPanelObservers = [move, resize, close]
    }

    func syncTOCPanel(_ panel: NSPanel? = nil) {
        let target = panel ?? tocPanel
        guard let target, target.isVisible, let screenRect = readerScreenRect() else { return }
        let contentRect = CGRect(
            x: screenRect.minX - target.frame.width,
            y: screenRect.minY,
            width: target.frame.width,
            height: screenRect.height
        )
        let newFrame = NSPanel.frameRect(forContentRect: contentRect, styleMask: target.styleMask)
        target.setFrame(newFrame, display: true)
    }

    private func removeTOCWindowObservers() {
        tocPanelObservers.forEach { NotificationCenter.default.removeObserver($0) }
        tocPanelObservers = []
    }

    private func makeTOCSidebarView() -> TOCSidebarView {
        TOCSidebarView(
            entries: globalTOC,
            currentSpineIndex: currentSpineIndex,
            onJump: { [weak self] entry in self?.jumpToTOCEntry(entry) }
        )
    }

    private func refreshTOCSidebarIfVisible() {
        guard let panel = tocPanel, panel.isVisible, let hosting = tocHostingView else { return }
        hosting.rootView = makeTOCSidebarView()
    }

    /// Flattens every work's own `EPUBParser.toc` (spine-local) into one
    /// series-wide list of `TOCPanelEntry` (spine-global), via `spineMap` —
    /// the same GlobalSpineRef mapping used for navigation and BookState/
    /// annotation resolution (Task 2a/2c). `workTitle` is set to that work's
    /// display title only on entries belonging to a `.series` target, so
    /// TOCSidebarView's section-header grouping activates automatically;
    /// for `.singleBook` every entry's `workTitle` is nil and the sidebar
    /// renders a flat list, identical to a standalone read.
    var globalTOC: [TOCPanelEntry] {
        guard !workParsers.isEmpty else { return [] }
        var seriesWorks: [CalibreBook]?
        if case .series(let series) = target { seriesWorks = series.works }

        var result: [TOCPanelEntry] = []
        for (workIndex, parser) in workParsers.enumerated() {
            let workTitle = seriesWorks.flatMap { works in
                works.indices.contains(workIndex) ? works[workIndex].displayTitle : nil
            }
            for entry in parser.toc {
                guard let globalIndex = spineMap.globalIndex(workIndex: workIndex, localIndex: entry.spineIndex) else { continue }
                result.append(TOCPanelEntry(
                    id: "\(workIndex)-\(entry.id)",
                    title: entry.title,
                    spineIndex: globalIndex,
                    depth: entry.depth,
                    workTitle: workTitle
                ))
            }
        }
        return result
    }

    /// Exposed for the email-mode split-view sidebar (EmailLibraryViewController),
    /// which builds its own TOCSidebarView outside of the floating-panel path above.
    var globalTOCEntries: [TOCPanelEntry] { globalTOC }
    var currentSpineIndexValue: Int { currentSpineIndex }

    /// `entry.spineIndex` is already global (see `globalTOC`), so this needs
    /// no further resolution — unlike `jumpToAnnotation`, which has to map a
    /// work-local `Annotation.spineIndex` back to a global index via
    /// `annotationCalibreID` first.
    func jumpToTOCEntry(_ entry: TOCPanelEntry) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.currentMode == .paginated {
                if entry.spineIndex != self.currentSpineIndex {
                    self.loadSpineItem(index: entry.spineIndex, restorePosition: .start)
                }
                return
            }
            if entry.spineIndex != self.currentSpineIndex {
                self.webView.evaluateJavaScript(
                    "document.querySelector('[data-spine-index=\"\(entry.spineIndex)\"]')?.scrollIntoView({block:'start'});",
                    completionHandler: nil
                )
            }
        }
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

    // Arrow keys and spacebar are consumed by WKWebView for its own scrolling
    // before keyDown ever reaches the view controller. In scroll mode we want
    // Up/Down for vertical paging, so we intercept them here. In paginated
    // mode, page turns are handled by ReaderViewController's local
    // NSEvent keyDown monitor (installKeyDownMonitor) instead of here — that
    // monitor runs before WebKit's own default keyboard-scroll action fires,
    // which this override alone cannot prevent (see keyDownMonitor's doc
    // comment). Do not duplicate that handling here.
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
        super.keyDown(with: event)
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
