import AppKit
import SwiftData

class AppDelegate: NSObject, NSApplicationDelegate {
    var libraryWindowController: LibraryWindowController?
    var modelContainer: ModelContainer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Close the empty SwiftUI window
        NSApp.windows.first?.close()

        // Open library window
        libraryWindowController = LibraryWindowController()
        libraryWindowController?.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Menu bar remains; user can reopen window
    }
}
