import SwiftUI
import SwiftData

@main
struct AmbrosiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    let sharedModelContainer: ModelContainer
    let session = LibrarySession()

    init() {
        // Schema contains only app-owned state. Calibre metadata is never copied.
        let schema = Schema([
            BookState.self,
            Collection.self,
            ReadingGoal.self,
        ])
        let config = ModelConfiguration("Ambrosia", schema: schema, isStoredInMemoryOnly: false)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            sharedModelContainer = container
            appDelegate.modelContainer = container
            appDelegate.session = session
        } catch {
            // Schema changed (old Book/Author/ReadingState entities removed).
            // Delete the stale store and start fresh — only BookState is lost.
            print("[Ambrosia] SwiftData store incompatible, resetting: \(error)")
            let fm = FileManager.default
            if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let storeDir = appSupport.appendingPathComponent("Ambrosia")
                let candidates = (try? fm.contentsOfDirectory(at: storeDir,
                                       includingPropertiesForKeys: nil)) ?? []
                for candidate in candidates where candidate.lastPathComponent.hasPrefix("Ambrosia") {
                    try? fm.removeItem(at: candidate)
                }
            }
            do {
                let container = try ModelContainer(for: schema, configurations: [config])
                sharedModelContainer = container
                appDelegate.modelContainer = container
                appDelegate.session = session
            } catch {
                fatalError("Could not create ModelContainer after reset: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Color.clear.frame(width: 0, height: 0)
        }
        .modelContainer(sharedModelContainer)
        .environment(session)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Calibre Library…") {
                    AppDelegate.shared?.chooseLibraryFolder()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Menu("Recent Libraries") {
                    RecentLibrariesMenuContent(session: session)
                }
            }

            CommandMenu("Reader") {
                Button("Add Bookmark") {
                    NSApp.sendAction(#selector(ReaderViewController.addBookmark(_:)),
                                     to: nil, from: nil)
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("Show Bookmarks") {
                    NSApp.sendAction(#selector(ReaderViewController.showBookmarkSidebar(_:)),
                                     to: nil, from: nil)
                }
                .keyboardShortcut("b", modifiers: [.command])
            }
        }
    }
}

/// Recent libraries submenu — reads LibraryRegistry at render time.
struct RecentLibrariesMenuContent: View {
    let session: LibrarySession
    @State private var paths: [String] = LibraryRegistry.shared.knownPaths

    var body: some View {
        if paths.isEmpty {
            Text("No recent libraries")
                .foregroundStyle(.secondary)
        } else {
            ForEach(paths, id: \.self) { path in
                let name    = LibraryRegistry.shared.displayName(for: path)
                let isActive = path == session.activePath
                let valid   = LibraryRegistry.shared.isValid(path)
                Button {
                    guard !isActive else { return }
                    session.open(url: URL(fileURLWithPath: path))
                } label: {
                    if isActive {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(valid ? name : "⚠ \(name) (not found)")
                    }
                }
                .disabled(isActive || !valid)
            }

            Divider()

            Button("Clear Recent Libraries") {
                LibraryRegistry.shared.knownPaths = []
                paths = []
            }
        }
    }
}
