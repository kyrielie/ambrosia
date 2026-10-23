import SwiftUI
import AppKit

@main
struct AmbrosiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    let session = LibrarySession()

    init() {
        appDelegate.session = session
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .environment(session)
        .commands {
            // ── Ambrosia → Preferences… (⌘,) ─────────────────────────────
            CommandGroup(replacing: .appSettings) {
                Button("Preferences…") {
                    PreferencesWindowController.show()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            // Dead menu items: no NSDocument (no Save/Save As/Revert target),
            // no NSPrintOperation usage anywhere (no Print target), and the
            // app's real find is a hand-rolled WKWebView.find(...) under
            // Reader ▸ Find — this drops AppKit's unused NSTextFinder-backed
            // Edit ▸ Find submenu so there isn't a second, dead Find sitting
            // next to the working one.
            CommandGroup(replacing: .saveItem) { }
            CommandGroup(replacing: .printItem) { }
            CommandGroup(replacing: .textEditing) { }

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
                    guard let anchorWindow = libraryWindowController.window else { return }
                    AO3FilterPopupWindowController.open(
                        anchorWindow: anchorWindow,
                        toolbarState: toolbarState,
                        dependencies: AO3FilterPopupWindowController.LibraryDependencies(
                            metaDB: metaDB, library: library,
                            ftsLibrary: session.ftsLibrary, collectionStore: session.collectionStore
                        ),
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
