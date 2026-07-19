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
            session.modelContainer = container
        } catch {
            #if DEBUG
            print("[Ambrosia] SwiftData store incompatible: \(error)")
            #endif
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
                session.modelContainer = container
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

                Divider()

                // Act on whichever work the focused reader window currently has
                // open (routed via the responder chain to
                // ReaderViewController.toggleLikeCurrentWork/
                // toggleReadLaterCurrentWork). No-ops if no reader window is
                // key, same as the "Reader" menu's actions below.
                Button("Like") {
                    NSApp.sendAction(#selector(ReaderViewController.toggleLikeCurrentWork(_:)),
                                     to: nil, from: nil)
                }

                Button("Read Later") {
                    NSApp.sendAction(#selector(ReaderViewController.toggleReadLaterCurrentWork(_:)),
                                     to: nil, from: nil)
                }
            }
            
            // Shortcuts for every item in this menu are rebindable from
            // Preferences → Shortcuts. Intentionally no `.keyboardShortcut(...)`
            // modifiers here: SwiftUI's `Commands` builder is evaluated once
            // when the Scene is built, with no reliable way for a `@Published`
            // change deep in ReaderPreferences to force it to re-evaluate and
            // redraw the menu bar's displayed key equivalent without a
            // relaunch. Instead, AppDelegate.syncReaderMenuShortcuts() locates
            // this menu by title at runtime and sets `.keyEquivalent`/
            // `.keyEquivalentModifierMask` directly on the resulting
            // NSMenuItems from ReaderPreferences.shared.keyBindings, live,
            // whenever a binding changes. Item titles below must match
            // RebindableAction.displayName exactly — that's how the sync
            // code finds each item.
            CommandGroup(after: .toolbar) {
                Button("Open AO3 Style Filter") {
                    guard let libraryWindowController = AppDelegate.shared?.libraryWindowController,
                          let toolbarState = libraryWindowController.toolbarStateForCommands,
                          let session = AppDelegate.shared?.session,
                          let metaDB = session.metaDB,
                          let library = session.library
                    else { return }
                    AO3FilterPopupWindowController.open(
                        toolbarState: toolbarState, metaDB: metaDB, library: library,
                        ftsLibrary: session.ftsLibrary, collectionStore: session.collectionStore,
                        membershipVersion: session.membershipVersion
                    )
                }

                Divider()

                // Clears the shared, in-memory-only remembered reader window
                // size and re-sizes every currently-open reader window back
                // to the half-screen-portrait default. See
                // ReaderWindowController.sessionWindowSize.
                Button("Reset Reader Window Size to Default") {
                    ReaderWindowController.resetAllToDefaultSize()
                }
            }

            CommandMenu("Reader") {
                Button("Toggle Reading Mode") {
                    NSApp.sendAction(#selector(ReaderViewController.toggleReadingMode(_:)),
                                     to: nil, from: nil)
                }

                Button("Add Annotation") {
                    NSApp.sendAction(#selector(ReaderViewController.addAnnotation(_:)),
                                     to: nil, from: nil)
                }

                Button("Show Annotations") {
                    if let libraryWindowController = AppDelegate.shared?.libraryWindowController,
                       libraryWindowController.window?.isKeyWindow == true {
                        libraryWindowController.showEmailAnnotationSidebar(nil)
                    } else {
                        NSApp.sendAction(#selector(ReaderViewController.showAnnotationSidebar(_:)),
                                         to: nil, from: nil)
                    }
                }

                Button("Show Table of Contents") {
                    if let libraryWindowController = AppDelegate.shared?.libraryWindowController,
                       libraryWindowController.window?.isKeyWindow == true {
                        libraryWindowController.showTOCInEmailSidebar(nil)
                    } else {
                        NSApp.sendAction(#selector(ReaderViewController.showTOCSidebar(_:)),
                                         to: nil, from: nil)
                    }
                }

                Divider()

                Button("Toggle Find Bar") {
                    NSApp.sendAction(#selector(ReaderViewController.toggleFindBarAction(_:)),
                                     to: nil, from: nil)
                }

                Button("Find Next") {
                    NSApp.sendAction(#selector(ReaderViewController.findNextAction(_:)),
                                     to: nil, from: nil)
                }

                Button("Find Previous") {
                    NSApp.sendAction(#selector(ReaderViewController.findPreviousAction(_:)),
                                     to: nil, from: nil)
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
