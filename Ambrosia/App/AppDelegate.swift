import AppKit
import SwiftData

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    var libraryWindowController: LibraryWindowController?
    var modelContainer: ModelContainer!
    var session: LibrarySession!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Hide the WindowGroup ghost window that SwiftUI creates for Color.clear.
        // We must NOT close() it — closing triggers deallocation and SwiftUI will
        // recreate a new window the next time applicationShouldHandleReopen fires
        // (because returning true signals the scene manager to restore windows).
        // Hiding with orderOut keeps it alive and invisible so the scene stays satisfied.
        if let ghostWindow = NSApp.windows.first {
            ghostWindow.isExcludedFromWindowsMenu = true
            ghostWindow.orderOut(nil)
        }

        // Reopen last used library silently on launch
        session.reopenIfNeeded()

        libraryWindowController = LibraryWindowController(
            modelContainer: modelContainer,
            session: session
        )
        libraryWindowController?.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon when all windows are closed re-shows the library window.
    /// Returns false — we handle reopen entirely ourselves. Returning true would tell
    /// SwiftUI's WindowGroup scene manager to restore its scene windows, which recreates
    /// the ghost window we hid at launch.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                        hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            libraryWindowController?.showWindow(nil)
            libraryWindowController?.window?.makeKeyAndOrderFront(nil)
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up temp image directories created by EPUBParser.extractImages
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ambrosia")
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Reader windows

    /// Opens a reader window for the given book.
    /// Deduplication (one window per book.id) is handled by ReaderWindowController.open.
    /// EPUB path validation happens here so we can show a user-facing error early.
    func openReaderWindow(book: CalibreBook, modelContext: ModelContext) {
        guard let pathStr = LibraryRegistry.shared.activePath else {
            showOpenError("No library open.")
            return
        }
        let libraryRoot = URL(fileURLWithPath: pathStr)

        guard let epubURL = book.epubURL(libraryRoot: libraryRoot),
              FileManager.default.fileExists(atPath: epubURL.path) else {
            showOpenError("EPUB file not found: \(book.displayTitle)")
            return
        }

        // ReaderWindowController.open is the single source of truth for
        // deduplication (keyed by book.id) and window lifecycle.
        ReaderWindowController.open(book: book, modelContainer: modelContext.container)
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
