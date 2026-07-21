import AppKit
import SwiftData

class ReaderWindowController: NSWindowController, NSWindowDelegate {

    private let target: ReadingTarget
    private let book: CalibreBook
    private let modelContainer: ModelContainer
    /// Recorded when the window loads; diffed on close to accumulate reading time.
    private var sessionStartDate: Date = Date()
    private var didApplyInitialWindowSize = false
    /// True only while this controller itself is setting the window's frame
    /// (applyDefaultWindowSize), so windowDidResize can tell an AppKit-driven
    /// user resize apart from our own programmatic one and avoid feeding our
    /// own resize back into sessionWindowSize.
    private var isApplyingProgrammaticResize = false

    private static var openWindows: [String: ReaderWindowController] = [:]
    /// The size the user last resized a reader window to, shared across all
    /// books for the lifetime of the app process. Deliberately in-memory only
    /// (not UserDefaults-backed): a fresh launch always starts from the
    /// half-screen-portrait default, per product requirement. Reset to nil
    /// by resetAllToDefaultSize(), wired to the View menu's "Reset Reader
    /// Window Size to Default" command.
    private static var sessionWindowSize: NSSize?

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
        // of this controller's own sizing logic below. Since this window has
        // no restoration identifier or registered NSWindowRestoration class,
        // the system can't actually rebuild it on relaunch -- see the
        // "restoreWindowWithIdentifier:state:completionHandler: Unable to
        // find className=(null)" log line -- but it still runs, still tries
        // to persist/apply its own snapshot of the window's frame at launch,
        // and can race with or clobber our sizing. Disable it outright.
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self

        // Deliberately NOT using NSWindow's setFrameAutosaveName/
        // setFrameUsingName here. That mechanism persists to UserDefaults
        // indefinitely, keyed per book -- which contradicts the desired
        // behavior (default size on every relaunch, shared across books
        // within a session) and, worse, permanently pins a book to whatever
        // frame it last had, including any bad/degenerate frame saved while
        // a sizing bug was active. Window sizing here is instead driven
        // entirely by sessionWindowSize (see applyDefaultWindowSize below),
        // which lives only in memory for the lifetime of the app process.
        let vc = ReaderViewController(target: target, modelContainer: modelContainer)
        window.contentViewController = vc

        // Update lastOpenedDate in BookState
        let calibreID = book.id
        // Explicit .userInitiated: this runs on Swift's cooperative thread
        // pool at whatever priority Task.detached defaults to (.medium) if
        // left unspecified, which can run at a lower QoS than the
        // main-actor (.userInteractive) work opening this window. If
        // ModelContainer's internal locking is ever contended between this
        // save and main-thread SwiftData access, a lower-priority thread
        // holding that lock while a user-interactive thread waits on it is
        // a priority inversion (Thread Performance Checker's "Hang Risk").
        // Raising this detached task's priority doesn't remove the
        // contention, but keeps it from running at a lower QoS than the
        // thread that might wait on it.
        Task.detached(priority: .userInitiated) {
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

    /// Sizes a new reader window. If the user has already resized a reader
    /// window earlier in this session, every subsequently-opened book reuses
    /// that same size (Self.sessionWindowSize); otherwise this falls back to
    /// the half-screen-portrait default. Either way the result is centered
    /// on the target screen. There is no customizable-default-size
    /// preference — half-screen-portrait is the only default formula, and
    /// sessionWindowSize is the only thing that overrides it, for the
    /// current app session only (never persisted across relaunch).
    private func applyDefaultWindowSize() {
        guard let window else { return }
        let screen  = window.screen ?? Self.screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        let size: NSSize
        if let remembered = Self.sessionWindowSize {
            size = remembered
        } else {
            let width  = (visible.width * 0.50).rounded()
            let height = (visible.height * 0.90).rounded()
            size = NSSize(width: width, height: height)
        }

        let x = visible.minX + (visible.width - size.width) / 2
        let y = visible.minY + (visible.height - size.height) / 2

        isApplyingProgrammaticResize = true
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        isApplyingProgrammaticResize = false
    }

    /// Wired to the View menu's "Reset Reader Window Size to Default"
    /// command via resetAllToDefaultSize(). Re-applies the half-screen-
    /// portrait formula to this specific window right now.
    @MainActor
    fileprivate func resetToDefaultSize() {
        applyDefaultWindowSize()
    }

    /// Clears the session-remembered size and immediately re-sizes every
    /// currently-open reader window back to the half-screen-portrait
    /// default. Called from the View menu.
    @MainActor
    static func resetAllToDefaultSize() {
        sessionWindowSize = nil
        for wc in openWindows.values {
            wc.resetToDefaultSize()
        }
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

    /// Captures the user's manual resizes (drag or the green zoom button)
    /// into Self.sessionWindowSize, so the next book opened in this session
    /// reuses that size. isApplyingProgrammaticResize guards against feeding
    /// our own applyDefaultWindowSize()/resetToDefaultSize() calls back into
    /// this, which would otherwise immediately overwrite a real user resize
    /// with whatever default/remembered size we just set.
    ///
    /// Also gated on didApplyInitialWindowSize: assigning
    /// window.contentViewController during init() (before showWindow(_:) has
    /// run applyDefaultWindowSizeIfNeeded) can itself trigger an incidental,
    /// arbitrary-sized resize. At that point isApplyingProgrammaticResize is
    /// still false, so without this guard that incidental resize would
    /// silently stomp Self.sessionWindowSize with garbage moments before
    /// showWindow(_:) reads it back out.
    @MainActor
    func windowDidResize(_ notification: Notification) {
        guard didApplyInitialWindowSize, !isApplyingProgrammaticResize, let window else { return }
        Self.sessionWindowSize = window.frame.size
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
