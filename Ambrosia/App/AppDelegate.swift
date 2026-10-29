import AppKit
import Combine

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    var libraryWindowController: LibraryWindowController?
    var session: LibrarySession!

    private var keyBindingsSubscription: AnyCancellable?

    /// True when the process is an XCTest host, i.e. `xcodebuild test` (or
    /// Xcode's Test navigator) launched Ambrosia.app to inject AmbrosiaTests
    /// into it -- AmbrosiaTests is app-hosted (TEST_HOST points at the real
    /// Ambrosia.app binary), so `applicationDidFinishLaunching` still runs
    /// on every test invocation. Without this guard, every test run would
    /// silently reopen and display whatever real Calibre library the
    /// machine last had open (via `LibraryRegistry.shared.activePath` in
    /// `UserDefaults`), which is both slow and not what any unit test here
    /// exercises -- every test that needs a library builds its own isolated
    /// temp fixture (see `CalibreTestFixture`) instead.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Tabbing the Library window together with independent Reader windows
        // doesn't make sense for this app; NSWindow.allowsAutomaticWindowTabbing
        // defaults to true, so it must be explicitly turned off.
        NSWindow.allowsAutomaticWindowTabbing = false

        guard !Self.isRunningTests else { return }

        // Reopen last used library silently on launch
        Task { await session.reopenIfNeeded() }

        libraryWindowController = LibraryWindowController(
            session: session
        )
        libraryWindowController?.showWindow(nil)

        syncReaderMenuShortcuts()
        startObservingKeyBindings()
    }

    private func startObservingKeyBindings() {
        withObservationTracking {
            _ = ReaderPreferences.shared.keyBindings
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncReaderMenuShortcuts()
                self?.startObservingKeyBindings()
            }
        }
    }

    // MARK: - Reader menu shortcut sync

    /// Sets `.keyEquivalent`/`.keyEquivalentModifierMask` on menu items across
    /// `NSApp.mainMenu` from `ReaderPreferences.shared.keyBindings`.
    /// Called once at launch and again whenever `keyBindings` changes, so
    /// the menu bar's displayed shortcut updates live without a relaunch.
    func syncReaderMenuShortcuts() {
        guard let mainMenu = NSApp.mainMenu else {
            #if DEBUG
            print("[AppDelegate] Could not locate NSApp.mainMenu for shortcut sync.")
            #endif
            return
        }
        let bindings = ReaderPreferences.shared.keyBindings
        var actionForTitle: [String: RebindableAction] = [:]
        for action in RebindableAction.allCases {
            actionForTitle[action.displayName] = action
        }
        // Also map standard Edit ▸ Find item if titled "Find…"
        actionForTitle["Find…"] = .toggleFindBar

        applyBindings(actionForTitle: actionForTitle, bindings: bindings, to: mainMenu)
    }

    private func applyBindings(
        actionForTitle: [String: RebindableAction],
        bindings: [RebindableAction: KeyBinding],
        to menu: NSMenu
    ) {
        for item in menu.items {
            if let action = actionForTitle[item.title] {
                if let binding = bindings[action] {
                    item.keyEquivalent = binding.character
                    item.keyEquivalentModifierMask = binding.keyEquivalentModifierMask
                } else {
                    item.keyEquivalent = ""
                    item.keyEquivalentModifierMask = []
                }
            }
            if let submenu = item.submenu {
                applyBindings(actionForTitle: actionForTitle, bindings: bindings, to: submenu)
            }
        }
    }

    // MARK: - Library & Window management

    func closeCurrentLibrary() {
        session?.close()
        LibraryRegistry.shared.activePath = nil
        libraryWindowController?.window?.close()
        libraryWindowController = nil
    }

    func showLibraryWindow() {
        if libraryWindowController == nil, let session {
            libraryWindowController = LibraryWindowController(session: session)
        }
        libraryWindowController?.showWindow(nil)
        libraryWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func openCurrentOrSelectedInExternalReader() {
        if let readerWindow = NSApp.keyWindow?.windowController as? ReaderWindowController,
           let readerVC = readerWindow.readerViewController {
            let calibreID = readerVC.activeCalibreID
            openExternalReader(forCalibreID: calibreID)
            return
        }
        Task { [weak self] in
            guard let self, let library = self.session?.library else { return }
            let allIDs = await library.allBookIDs()
            if let firstID = allIDs.first {
                await MainActor.run {
                    self.openExternalReader(forCalibreID: firstID)
                }
            }
        }
    }

    private func openExternalReader(forCalibreID calibreID: Int) {
        Task { [weak self] in
            guard let self, let library = self.session?.library else { return }
            guard let epubURL = await library.epubURL(calibreID: calibreID),
                  FileManager.default.fileExists(atPath: epubURL.path) else { return }

            let appPath = ReaderPreferences.shared.customReaderAppPath
            if !appPath.isEmpty && FileManager.default.fileExists(atPath: appPath) {
                let appURL = URL(fileURLWithPath: appPath)
                NSWorkspace.shared.open(
                    [epubURL],
                    withApplicationAt: appURL,
                    configuration: NSWorkspace.OpenConfiguration(),
                    completionHandler: nil
                )
            } else {
                NSWorkspace.shared.open(epubURL)
            }
        }
    }

    func revealInFinder(book: CalibreBook) {
        revealInFinder(books: [book])
    }

    func revealInFinder(books: [CalibreBook]) {
        guard let pathStr = LibraryRegistry.shared.activePath else { return }
        let libraryRoot = URL(fileURLWithPath: pathStr)
        let urls = books.compactMap { $0.epubURL(libraryRoot: libraryRoot) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            NSWorkspace.shared.activateFileViewerSelecting([libraryRoot])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func revealCurrentOrLibraryInFinder() {
        if let readerWindow = NSApp.keyWindow?.windowController as? ReaderWindowController,
           let readerVC = readerWindow.readerViewController {
            let calibreID = readerVC.activeCalibreID
            Task { [weak self] in
                guard let self, let library = self.session?.library else { return }
                if let epubURL = await library.epubURL(calibreID: calibreID),
                   FileManager.default.fileExists(atPath: epubURL.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([epubURL])
                    return
                }
                if let pathStr = LibraryRegistry.shared.activePath {
                    let url = URL(fileURLWithPath: pathStr)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            return
        }
        if let pathStr = LibraryRegistry.shared.activePath {
            let url = URL(fileURLWithPath: pathStr)
            NSWorkspace.shared.activateFileViewerSelecting([url])
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
        guard !Self.isRunningTests else { return }

        // Persist search history before quitting. LibrarySession.close() also
        // does this, but close() additionally tears down extractionTask, stops
        // the feed server, and clears membership caches — none of which is
        // necessary or safe to run synchronously during termination, so save
        // directly instead of calling close(). Force-quit bypasses this, same
        // as it bypasses the rest of applicationWillTerminate.
        session?.cancelExtractionTaskIfRunning()
        if let path = LibraryRegistry.shared.activePath {
            SearchActivityLog.shared.save(libraryHash: Ambrosia.libraryHash(for: URL(fileURLWithPath: path)))
        }
        // Clean up temp image directories created by EPUBParser.extractImages
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ambrosia")
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Reader windows

    /// Opens a reader window for the given book.
    /// Deduplication (one window per book.id) is handled by ReaderWindowController.open.
    /// EPUB path validation happens here so we can show a user-facing error early.
    func openReaderWindow(
        book: CalibreBook,
        jumpToSnippet: FTSOccurrenceSnippet? = nil,
        searchQuery: String? = nil
    ) {
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

        // Record last opened date in AmbrosiaMetaDB regardless of reader choice
        let bookID = book.id
        Task { [weak self] in
            if let metaDB = self?.session.metaDB {
                try? await metaDB.markBookOpened(calibreID: bookID)
            }
        }

        switch ReaderPreferences.shared.preferredReader {
        case .inbuilt:
            // ReaderWindowController.open is the single source of truth for
            // deduplication (keyed by book.id) and window lifecycle.
            ReaderWindowController.open(book: book, jumpToSnippet: jumpToSnippet, searchQuery: searchQuery)
        case .systemDefault:
            NSWorkspace.shared.open(epubURL)
        case .customApp:
            let appPath = ReaderPreferences.shared.customReaderAppPath
            let appURL = URL(fileURLWithPath: appPath)
            if !appPath.isEmpty && FileManager.default.fileExists(atPath: appPath) {
                NSWorkspace.shared.open([epubURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                    if let error {
                        Task { @MainActor [weak self] in
                            self?.showOpenError("Failed to open with \(ReaderPreferences.shared.customReaderAppName): \(error.localizedDescription)")
                        }
                    }
                }
            } else {
                // Fall back to system default if custom app path was moved or missing
                NSWorkspace.shared.open(epubURL)
            }
        }
    }

    func openReaderWindow(
        target: ReadingTarget,
        jumpToSnippet: FTSOccurrenceSnippet? = nil,
        searchQuery: String? = nil
    ) {
        switch target {
        case .singleBook(let book):
            openReaderWindow(book: book, jumpToSnippet: jumpToSnippet, searchQuery: searchQuery)
        case .series(let series):
            guard let pathStr = LibraryRegistry.shared.activePath else {
                showOpenError("No library open.")
                return
            }
            let libraryRoot = URL(fileURLWithPath: pathStr)
            var epubURLs: [URL] = []
            for book in series.works {
                guard let epubURL = book.epubURL(libraryRoot: libraryRoot),
                      FileManager.default.fileExists(atPath: epubURL.path) else {
                    showOpenError("EPUB file not found: \(book.displayTitle)")
                    return
                }
                epubURLs.append(epubURL)
            }

            switch ReaderPreferences.shared.preferredReader {
            case .inbuilt:
                ReaderWindowController.open(target: target)
            case .systemDefault:
                if let first = epubURLs.first {
                    NSWorkspace.shared.open(first)
                }
            case .customApp:
                let appPath = ReaderPreferences.shared.customReaderAppPath
                let appURL = URL(fileURLWithPath: appPath)
                if !appPath.isEmpty && FileManager.default.fileExists(atPath: appPath), let first = epubURLs.first {
                    NSWorkspace.shared.open([first], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                        if let error {
                            Task { @MainActor [weak self] in
                                self?.showOpenError("Failed to open with \(ReaderPreferences.shared.customReaderAppName): \(error.localizedDescription)")
                            }
                        }
                    }
                } else if let first = epubURLs.first {
                    NSWorkspace.shared.open(first)
                }
            }
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
