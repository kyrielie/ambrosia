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
    func applicationWillTerminate(_ notification: Notification) {}

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
