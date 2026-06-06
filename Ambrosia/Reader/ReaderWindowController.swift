import AppKit
import SwiftData

class ReaderWindowController: NSWindowController, NSWindowDelegate {

    private let book: CalibreBook
    private let modelContainer: ModelContainer

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

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 900),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable],
            backing:     .buffered,
            defer:       false
        )
        window.title   = book.displayTitle
        window.minSize = NSSize(width: 480, height: 400)
        window.center()
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

    @MainActor
    func windowWillClose(_ notification: Notification) {
        Self.openWindows.removeValue(forKey: book.id)
    }
}
