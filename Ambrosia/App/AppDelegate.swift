import AppKit
import SwiftData

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    var libraryWindowController: LibraryWindowController?
    /// Retains open reader windows so they are not deallocated on return from openReader().
    var readerWindows: [NSWindow] = []
    var modelContainer: ModelContainer!
    var session: LibrarySession!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.windows.first?.close()

        // Reopen last used library silently on launch
        session.reopenIfNeeded()

        libraryWindowController = LibraryWindowController(
            modelContainer: modelContainer,
            session: session
        )
        libraryWindowController?.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        // Clean up temp image directory created by EPUBLoader
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ambrosia")
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Reader windows

    /// Opens a reader window for the given book and retains it.
    func openReaderWindow(book: CalibreBook, modelContext: ModelContext) {
        guard let pathStr = LibraryRegistry.shared.activePath else {
            print("[Open] ERROR — no library path"); return
        }
        let libraryRoot = URL(fileURLWithPath: pathStr)
        print("[Open] Library root: \(libraryRoot.path)")

        guard let epubURL = book.epubURL(libraryRoot: libraryRoot) else {
            print("[Open] ERROR — could not resolve EPUB for: \(book.relativePath)")
            showOpenError("EPUB not found: " + book.displayTitle)
            return
        }
        print("[Open] File resolved: \(epubURL.path)")

        guard FileManager.default.fileExists(atPath: epubURL.path) else {
            print("[Open] ERROR — file missing at \(epubURL.path)")
            showOpenError("File not found: \(epubURL.lastPathComponent)")
            return
        }
        print("[Open] File exists")

        // Check if already open
        let existingTitle = book.displayTitle
        if let existing = readerWindows.first(where: { $0.title == existingTitle }) {
            existing.makeKeyAndOrderFront(nil)
            print("[Open] Brought existing window to front")
            return
        }

        let vc = ReaderViewController(book: book, modelContainer: modelContext.container)
        print("[Open] ReaderViewController initialized")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = book.displayTitle
        // Set preferred size before assigning contentViewController so the window
        // does not collapse to the WKWebView's zero intrinsic content size.
        vc.preferredContentSize = NSSize(width: 900, height: 700)
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 900, height: 700))
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        window.makeKeyAndOrderFront(nil)
        readerWindows.append(window)

        // Remove from array when closed
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.readerWindows.removeAll { $0 === window }
                print("[Open] Reader window closed")
            }
        }

        // Update last opened date
        let cid = book.id
        let allStates = (try? modelContext.fetch(FetchDescriptor<BookState>())) ?? []
        let existing2 = allStates.first { $0.calibreID == cid }
        if let s = existing2 {
            s.lastOpenedDate = Date()
        } else {
            let s = BookState(calibreID: cid)
            s.lastOpenedDate = Date()
            modelContext.insert(s)
        }
        try? modelContext.save()

        print("[Open] Reader presented")
    }

    private func showOpenError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could Not Open Book"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Library selection

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Library"
        panel.message = "Choose a Calibre library folder (must contain metadata.db)."

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            // Validate before opening
            let dbPath = url.appendingPathComponent("metadata.db").path
            guard FileManager.default.isReadableFile(atPath: dbPath) else {
                let alert = NSAlert()
                alert.messageText = "Not a Calibre Library"
                alert.informativeText = "No readable metadata.db found in \(url.lastPathComponent)."
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            self.session.open(url: url)
        }
    }
}
