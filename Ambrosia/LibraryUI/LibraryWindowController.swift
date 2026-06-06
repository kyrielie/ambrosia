import AppKit
import SwiftData

class LibraryWindowController: NSWindowController {

    init(modelContainer: ModelContainer, session: LibrarySession) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ambrosia"
        window.minSize = NSSize(width: 700, height: 500)
        window.center()
        super.init(window: window)
        window.contentViewController = LibraryViewController(
            modelContainer: modelContainer,
            session: session
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
