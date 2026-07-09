import AppKit
import SwiftData
import Combine

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    var libraryWindowController: LibraryWindowController?
    var modelContainer: ModelContainer!
    var session: LibrarySession!

    private var keyBindingsSubscription: AnyCancellable?

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
        Task { await session.reopenIfNeeded() }

        libraryWindowController = LibraryWindowController(
            modelContainer: modelContainer,
            session: session
        )
        libraryWindowController?.showWindow(nil)

        syncReaderMenuShortcuts()
        keyBindingsSubscription = ReaderPreferences.shared.$keyBindings
            .sink { [weak self] _ in
                self?.syncReaderMenuShortcuts()
            }
    }

    // MARK: - Reader menu shortcut sync

    /// Sets `.keyEquivalent`/`.keyEquivalentModifierMask` directly on the
    /// "Reader" `NSMenu`'s items from `ReaderPreferences.shared.keyBindings`.
    /// Called once at launch and again whenever `keyBindings` changes, so
    /// the menu bar's displayed shortcut updates live without a relaunch —
    /// see the doc comment on `CommandMenu("Reader")` in AmbrosiaApp.swift
    /// for why this can't be done via SwiftUI's `.keyboardShortcut(...)`.
    /// An action absent from `keyBindings` (currently only possible for
    /// `showTOCSidebar`, which ships unbound by default) gets an empty
    /// `keyEquivalent`, which AppKit treats as "no shortcut displayed."
    func syncReaderMenuShortcuts() {
        guard let readerMenu = NSApp.mainMenu?.item(withTitle: "Reader")?.submenu else {
            #if DEBUG
            print("[AppDelegate] Could not locate \"Reader\" NSMenu for shortcut sync.")
            #endif
            return
        }
        let bindings = ReaderPreferences.shared.keyBindings
        for action in RebindableAction.allCases {
            guard let item = readerMenu.items.first(where: { $0.title == action.displayName }) else {
                #if DEBUG
                print("[AppDelegate] No NSMenuItem titled \"\(action.displayName)\" found in Reader menu.")
                #endif
                continue
            }
            if let binding = bindings[action] {
                item.keyEquivalent = binding.character
                item.keyEquivalentModifierMask = binding.keyEquivalentModifierMask
            } else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }
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

    func openReaderWindow(target: ReadingTarget, modelContext: ModelContext) {
        switch target {
        case .singleBook(let book):
            openReaderWindow(book: book, modelContext: modelContext)
        case .series(let series):
            guard let pathStr = LibraryRegistry.shared.activePath else {
                showOpenError("No library open.")
                return
            }
            let libraryRoot = URL(fileURLWithPath: pathStr)
            for book in series.works {
                guard let epubURL = book.epubURL(libraryRoot: libraryRoot),
                      FileManager.default.fileExists(atPath: epubURL.path) else {
                    showOpenError("EPUB file not found: \(book.displayTitle)")
                    return
                }
            }
            ReaderWindowController.open(target: target, modelContainer: modelContext.container)
        }
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
            Task { await self.session.open(url: url) }
        }
    }
}
