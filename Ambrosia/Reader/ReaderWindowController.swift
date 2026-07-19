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
        wc.showWindow(nil)
    }

    private init(target: ReadingTarget, modelContainer: ModelContainer) {
        self.target         = target
        self.book           = target.primaryBook
        self.modelContainer = modelContainer

        // Create window with a placeholder size; actual size is set once the
        // window is actually shown (see the showWindow(_:) override below),
        // since window.screen is nil until then.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable],
            backing:     .buffered,
            defer:       false
        )
        window.title   = target.displayTitle
        window.minSize = NSSize(width: 600, height: 500)
        // AppKit's automatic window-restoration ("Resume") is on by default
        // for every NSWindow (isRestorable == true) and runs independently
        // of the per-book setFrameAutosaveName/setFrameUsingName restore
        // just below. Since this window has no restoration identifier or
        // registered NSWindowRestoration class, the system can't actually
        // rebuild it on relaunch -- see the
        // "restoreWindowWithIdentifier:state:completionHandler: Unable to
        // find className=(null)" log line -- but it still runs, still
        // tries to persist/apply its own snapshot of the window's frame at
        // launch, and can race with or clobber the per-book restore below.
        // Disable it outright: per-book frame persistence is already
        // handled correctly and exclusively by setFrameAutosaveName /
        // setFrameUsingName.
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self

        // Finding 1: restore this window's individual frame if one was saved
        // for this book/target, keyed the same way `openWindows` already is.
        // If there's no saved frame (first time opening this book), the
        // placeholder size above stands until applyDefaultWindowSizeIfNeeded
        // runs from the showWindow(_:) override below.
        let autosaveName = "AmbrosiaReaderWindow.\(target.windowKey)"
        window.setFrameAutosaveName(autosaveName)
        if window.setFrameUsingName(autosaveName) {
            didApplyInitialWindowSize = true
        }

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
    }

    // Sizing must happen here rather than in windowDidLoad(): this window is
    // constructed via super.init(window:) rather than loaded from a nib, so
    // AppKit considers it already "loaded" and never actually calls
    // windowDidLoad(). showWindow(_:) is the call site open() already uses to
    // display the window, and — critically — by the time super.showWindow(_:)
    // returns, the window has been ordered onto a real NSScreen, so
    // window.screen below is no longer nil. Previously the only call to
    // applyDefaultWindowSizeIfNeeded() ran in open(), before showWindow(nil),
    // when window.screen was always nil and sizing silently fell back to
    // NSScreen.main / NSScreen.screens[0] -- not reliably the screen the user
    // is actually working on (multi-monitor setups, docking/undocking, etc.).
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        applyDefaultWindowSizeIfNeeded()
    }

    private func applyDefaultWindowSizeIfNeeded() {
        guard !didApplyInitialWindowSize else { return }
        didApplyInitialWindowSize = true
        applyDefaultWindowSize()
    }

    /// Sets new reader windows to a half-screen portrait size. This only runs
    /// for windows with no saved per-book frame (see the setFrameUsingName
    /// check in init); a book that's been opened before keeps its own
    /// remembered frame regardless. There is no customizable-default-size
    /// preference anymore — half-screen-portrait is the only formula.
    private func applyDefaultWindowSize() {
        guard let window else { return }
        let screen  = window.screen ?? Self.screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        let width  = (visible.width * 0.50).rounded()
        let height = (visible.height * 0.90).rounded()

        let x = visible.minX + (visible.width - width) / 2
        let y = visible.minY + (visible.height - height) / 2
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
    }

    /// Best-effort fallback for the rare case window.screen is still nil after
    /// showWindow(_:) returns (e.g. a screen was disconnected mid-launch).
    /// Prefers the display the user's pointer is currently on, since that's a
    /// better proxy for "where the user is working" than NSScreen.main, which
    /// merely reflects whatever window currently has key status.
    private static func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
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
