import AppKit

class LibraryWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ambrosia"
        window.center()
        self.init(window: window)

        let vc = LibraryViewController()
        window.contentViewController = vc
    }
}
