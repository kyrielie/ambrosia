import AppKit
import SwiftData

class ReaderWindowController: NSWindowController, NSWindowDelegate {

    private let target: ReadingTarget
    private let book: CalibreBook
    private let modelContainer: ModelContainer
    /// Recorded when the window loads; diffed on close to accumulate reading time.
    private var sessionStartDate: Date = Date()
    private var didApplyInitialWindowSize = false

    private static var openWindows: [String: ReaderWindowController] = [:]

    @MainActor
    static func saveFrontWindowSizeAsDefault() -> NSSize? {
        let readerWindows = Set(openWindows.values.compactMap(\.window))
        let frontWindow = NSApp.orderedWindows.first { readerWindows.contains($0) }
            ?? openWindows.values.compactMap(\.window).first

        guard let size = frontWindow?.frame.size else { return nil }
        let prefs = ReaderPreferences.shared
        prefs.defaultWindowWidth = size.width.rounded()
        prefs.defaultWindowHeight = size.height.rounded()
        prefs.useScreenFraction = false
        return size
    }

    @MainActor
    static func open(book: CalibreBook, modelContainer: ModelContainer) {
        open(target: .singleBook(book), modelContainer: modelContainer)
    }

    @MainActor
    static func open(target: ReadingTarget, modelContainer: ModelContainer) {
        if let existing = openWindows[target.windowKey] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let wc = ReaderWindowController(target: target, modelContainer: modelContainer)
        openWindows[target.windowKey] = wc
        wc.applyDefaultWindowSizeIfNeeded()
        wc.showWindow(nil)
    }

    private init(target: ReadingTarget, modelContainer: ModelContainer) {
        self.target         = target
        self.book           = target.primaryBook
        self.modelContainer = modelContainer

        // Create window with a placeholder size; actual size set in windowDidLoad
        // once NSScreen.main is reliable (it can be nil during init).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable],
            backing:     .buffered,
            defer:       false
        )
        window.title   = target.displayTitle
        window.minSize = NSSize(width: 600, height: 500)
        super.init(window: window)
        window.delegate = self

        let vc = ReaderViewController(target: target, modelContainer: modelContainer)
        window.contentViewController = vc

        // Update lastOpenedDate in BookState
        let calibreID = book.id
        Task.detached {
            let ctx = ModelContext(modelContainer)
            let state = LibraryQueryHelpers.stateForMutation(calibreID, in: ctx)
            state.lastOpenedDate = Date()
            try? ctx.save()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func windowDidLoad() {
        super.windowDidLoad()
        sessionStartDate = Date()
        applyDefaultWindowSizeIfNeeded()
    }

    private func applyDefaultWindowSizeIfNeeded() {
        guard !didApplyInitialWindowSize else { return }
        didApplyInitialWindowSize = true
        applyDefaultWindowSize()
    }

    /// Sets new reader windows to either the half-screen portrait preset or the
    /// persisted custom size from Preferences.
    private func applyDefaultWindowSize() {
        guard let window else { return }
        let rp      = ReaderPreferences.shared
        let screen  = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        let width: CGFloat
        let height: CGFloat
        if rp.useScreenFraction {
            // Portrait: half the screen width, 90% of screen height
            width  = (visible.width * 0.50).rounded()
            height = (visible.height * 0.90).rounded()
        } else {
            width  = rp.defaultWindowWidth
            height = rp.defaultWindowHeight
        }

        let x = visible.minX + (visible.width - width) / 2
        let y = visible.minY + (visible.height - height) / 2
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
    }

    @MainActor
    func windowWillClose(_ notification: Notification) {
        Self.openWindows.removeValue(forKey: target.windowKey)

        // Accumulate reading session time into BookState.totalReadingTimeSeconds
        let elapsed   = Date().timeIntervalSince(sessionStartDate)
        let calibreID = book.id
        let container = modelContainer
        Task.detached {
            let ctx = ModelContext(container)
            let state = LibraryQueryHelpers.stateForMutation(calibreID, in: ctx)
            state.totalReadingTimeSeconds += elapsed
            try? ctx.save()
        }
    }
}
