import SwiftUI
import SwiftData
import AppKit

@main
struct AmbrosiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    let sharedModelContainer: ModelContainer
    let session = LibrarySession()

    init() {
        // Schema contains only app-owned state. Calibre metadata is never copied.
        let schema = Schema([
            BookState.self,
            ReadingGoal.self,
        ])
        let config = ModelConfiguration("Ambrosia", schema: schema, isStoredInMemoryOnly: false)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            sharedModelContainer = container
            appDelegate.modelContainer = container
            appDelegate.session = session
        } catch {
            print("[Ambrosia] SwiftData store incompatible: \(error)")
            let alert = NSAlert()
            alert.messageText = "Could Not Open Reading State"
            alert.informativeText = "Ambrosia could not open its reading-state database. No files were deleted. The app will run with temporary reading state until this is resolved.\n\n\(error.localizedDescription)"
            alert.alertStyle = .critical
            alert.runModal()

            let fallback = ModelConfiguration("AmbrosiaRecovery", schema: schema, isStoredInMemoryOnly: true)
            do {
                let container = try ModelContainer(for: schema, configurations: [fallback])
                sharedModelContainer = container
                appDelegate.modelContainer = container
                appDelegate.session = session
            } catch {
                fatalError("Could not create temporary ModelContainer: \(error)")
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
            // ── Ambrosia → Preferences… (⌘,) ─────────────────────────────
            CommandGroup(replacing: .appSettings) {
                Button("Preferences…") {
                    PreferencesWindowController.show()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            
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
                Button("Add Annotation") {
                    NSApp.sendAction(#selector(ReaderViewController.addAnnotation(_:)),
                                     to: nil, from: nil)
                }
                .keyboardShortcut("d", modifiers: [.command])
                
                Button("Show Annotations") {
                    if let libraryWindowController = AppDelegate.shared?.libraryWindowController,
                       libraryWindowController.window?.isKeyWindow == true {
                        libraryWindowController.showEmailAnnotationSidebar(nil)
                    } else {
                        NSApp.sendAction(#selector(ReaderViewController.showAnnotationSidebar(_:)),
                                         to: nil, from: nil)
                    }
                }
                .keyboardShortcut("b", modifiers: [.command])

                Button("Show Table of Contents") {
                    if let libraryWindowController = AppDelegate.shared?.libraryWindowController,
                       libraryWindowController.window?.isKeyWindow == true {
                        libraryWindowController.showTOCInEmailSidebar(nil)
                    } else {
                        NSApp.sendAction(#selector(ReaderViewController.showTOCSidebar(_:)),
                                         to: nil, from: nil)
                    }
                }
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
                    Task { await session.open(url: URL(fileURLWithPath: path)) }
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
