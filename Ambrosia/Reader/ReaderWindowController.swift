import AppKit
import SwiftData

class ReaderWindowController: NSWindowController, NSWindowDelegate {

    private let book: CalibreBook
    private let modelContainer: ModelContainer
    /// Recorded when the window loads; diffed on close to accumulate reading time.
    private var sessionStartDate: Date = Date()

    private static var openWindows: [Int: ReaderWindowController] = [:]

    @MainActor
    static func open(book: CalibreBook, modelContainer: ModelContainer) {
        if let existing = openWindows[book.id] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let wc = ReaderWindowController(book: book, modelContainer: modelContainer)
        openWindows[book.id] = wc
        wc.showWindow(nil)
    }

    private init(book: CalibreBook, modelContainer: ModelContainer) {
        self.book           = book
        self.modelContainer = modelContainer

        // Create window with a placeholder size; actual size set in windowDidLoad
        // once NSScreen.main is reliable (it can be nil during init).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable],
            backing:     .buffered,
            defer:       false
        )
        window.title   = book.displayTitle
        window.minSize = NSSize(width: 600, height: 500)
        super.init(window: window)
        window.delegate = self

        let vc = ReaderViewController(book: book, modelContainer: modelContainer)
        window.contentViewController = vc

        // Update lastOpenedDate in BookState
        let calibreID = book.id
        Task.detached {
            let ctx = ModelContext(modelContainer)
            var desc = FetchDescriptor<BookState>(
                predicate: #Predicate { $0.calibreID == calibreID }
            )
            desc.fetchLimit = 1
            if let state = try? ctx.fetch(desc).first {
                state.lastOpenedDate = Date()
            } else {
                let state = BookState(calibreID: calibreID)
                state.lastOpenedDate = Date()
                ctx.insert(state)
            }
            try? ctx.save()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func windowDidLoad() {
        super.windowDidLoad()
        sessionStartDate = Date()
        applyDefaultWindowSize()
    }

    /// E1 — Sets the window to half the screen width, portrait height (90% of screen).
    /// Called from windowDidLoad where NSScreen.main is guaranteed non-nil.
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
        Self.openWindows.removeValue(forKey: book.id)

        // Accumulate reading session time into BookState.totalReadingTimeSeconds
        let elapsed   = Date().timeIntervalSince(sessionStartDate)
        let calibreID = book.id
        let container = modelContainer
        Task.detached {
            let ctx  = ModelContext(container)
            var desc = FetchDescriptor<BookState>(
                predicate: #Predicate { $0.calibreID == calibreID }
            )
            desc.fetchLimit = 1
            if let state = try? ctx.fetch(desc).first {
                state.totalReadingTimeSeconds += elapsed
            } else {
                let state = BookState(calibreID: calibreID)
                state.totalReadingTimeSeconds = elapsed
                ctx.insert(state)
            }
            try? ctx.save()
        }
    }
}
