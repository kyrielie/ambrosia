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

            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Search Library Body Text…") {
                    FTSSearchResultsWindowController.show()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Menu("Find") {
                    Button("Find…") {
                        if let readerWindow = NSApp.keyWindow?.windowController as? ReaderWindowController {
                            readerWindow.readerViewController?.performFindAction(nil)
                        } else {
                            AppDelegate.shared?.libraryWindowController?.focusSearchField(nil)
                        }
                    }
                    .keyboardShortcut("f", modifiers: [.command])

                    Button("Search Library Body Text…") {
                        FTSSearchResultsWindowController.show()
                    }
                    .keyboardShortcut("f", modifiers: [.command, .shift])

                    Button("Find Next") {
                        NSApp.sendAction(#selector(ReaderViewController.findNextAction(_:)),
                                         to: nil, from: nil)
                    }
                    .keyboardShortcut("g", modifiers: [.command])

                    Button("Find Previous") {
                        NSApp.sendAction(#selector(ReaderViewController.findPreviousAction(_:)),
                                         to: nil, from: nil)
                    }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("Open Library…") {
                    AppDelegate.shared?.chooseLibraryFolder()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Scan Library for New Books…") {
                    AppDelegate.shared?.scanLibraryForNewBooks()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(session.activePath == nil)

                Menu("Recent Libraries") {
                    RecentLibrariesMenuContent(session: session)
                }

                Button("Close Library") {
                    AppDelegate.shared?.closeCurrentLibrary()
                }
                .disabled(session.activePath == nil)

                Divider()

                Button("Open in External Reader") {
                    AppDelegate.shared?.openCurrentOrSelectedInExternalReader()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Reveal in Finder") {
                    AppDelegate.shared?.revealCurrentOrLibraryInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])

                Divider()

                Menu("Export") {
                    Button("Export EPUBs…") {
                        AppDelegate.shared?.libraryWindowController?.triggerEPUBExport()
                    }
                    Button("Export CSV…") {
                        AppDelegate.shared?.libraryWindowController?.triggerCSVExport()
                    }
                    Button("Export Annotations…") {
                        AppDelegate.shared?.libraryWindowController?.triggerAnnotationExport()
                    }
                    Divider()
                    Button("RSS Feed Server…") {
                        AppDelegate.shared?.libraryWindowController?.showRSSPanel()
                    }
                }
            }

            CommandGroup(after: .toolbar) {
                Menu("View Mode") {
                    Button("List View") {
                        AppDelegate.shared?.libraryWindowController?.toolbarStateForCommands?.viewMode = .list
                    }
                    .keyboardShortcut("1", modifiers: [.command])

                    Button("Reading / Email View") {
                        AppDelegate.shared?.libraryWindowController?.toolbarStateForCommands?.viewMode = .email
                    }
                    .keyboardShortcut("2", modifiers: [.command])

                    Button("Ranking View") {
                        AppDelegate.shared?.libraryWindowController?.toolbarStateForCommands?.viewMode = .ranking
                    }
                    .keyboardShortcut("3", modifiers: [.command])
                }

                Menu("Appearance") {
                    ForEach(LibraryAppearanceMode.allCases) { mode in
                        Button {
                            ReaderPreferences.shared.libraryAppearanceMode = mode
                        } label: {
                            if ReaderPreferences.shared.libraryAppearanceMode == mode {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }

                    Divider()

                    Button("Toggle Dark/Light Mode") {
                        ReaderPreferences.shared.toggleLibraryAppearance()
                    }
                    .keyboardShortcut("t", modifiers: [.command, .control])
                }

                Divider()

                Button("Reload Library") {
                    AppDelegate.shared?.reloadCurrentLibrary()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Clear All Filters") {
                    AppDelegate.shared?.libraryWindowController?.clearAllFilters()
                }
                .disabled(AppDelegate.shared?.libraryWindowController?.toolbarStateForCommands?.hasActiveFilter != true)

                Divider()

                Button("Toggle Sidebar") {
                    AppDelegate.shared?.libraryWindowController?.performSidebarToggleFromMenu()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])

                Button("Toggle AO3 Style Filter") {
                    guard let libraryWindowController = AppDelegate.shared?.libraryWindowController,
                          let toolbarState = libraryWindowController.toolbarStateForCommands else { return }
                    toolbarState.showAO3FilterSidebar.toggle()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])

                Button("Toggle Advanced Filter Drawer") {
                    guard let libraryWindowController = AppDelegate.shared?.libraryWindowController,
                          let toolbarState = libraryWindowController.toolbarStateForCommands else { return }
                    toolbarState.showFilterDrawer.toggle()
                }
                .keyboardShortcut("d", modifiers: [.command, .option])

                Toggle("Group by Series", isOn: Binding(
                    get: { ReaderPreferences.shared.groupBySeries },
                    set: { ReaderPreferences.shared.groupBySeries = $0 }
                ))
            }

            CommandGroup(after: .windowArrangement) {
                Divider()

                Button("Main Library") {
                    AppDelegate.shared?.showLibraryWindow()
                }
                .keyboardShortcut("0", modifiers: [.command, .option])

                Button("Contents Panel") {
                    if let libraryWindowController = AppDelegate.shared?.libraryWindowController,
                       libraryWindowController.window?.isKeyWindow == true {
                        libraryWindowController.showTOCInEmailSidebar(nil)
                    } else {
                        NSApp.sendAction(#selector(ReaderViewController.showTOCSidebar(_:)),
                                         to: nil, from: nil)
                    }
                }
                .disabled(AppDelegate.shared?.hasActiveReader != true)

                Button("Annotations Panel") {
                    if let libraryWindowController = AppDelegate.shared?.libraryWindowController,
                       libraryWindowController.window?.isKeyWindow == true {
                        libraryWindowController.showEmailAnnotationSidebar(nil)
                    } else {
                        NSApp.sendAction(#selector(ReaderViewController.showAnnotationSidebar(_:)),
                                         to: nil, from: nil)
                    }
                }
                .disabled(AppDelegate.shared?.hasActiveReader != true)
            }

            CommandMenu("Reader") {
                Menu("Navigation") {
                    Button("Next Page") {
                        NSApp.sendAction(#selector(ReaderViewController.goToNextPageAction(_:)),
                                         to: nil, from: nil)
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])

                    Button("Previous Page") {
                        NSApp.sendAction(#selector(ReaderViewController.goToPreviousPageAction(_:)),
                                         to: nil, from: nil)
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])

                    Divider()

                    Button("Next Chapter") {
                        NSApp.sendAction(#selector(ReaderViewController.nextChapterAction(_:)),
                                         to: nil, from: nil)
                    }
                    .keyboardShortcut("]", modifiers: [.command])

                    Button("Previous Chapter") {
                        NSApp.sendAction(#selector(ReaderViewController.previousChapterAction(_:)),
                                         to: nil, from: nil)
                    }
                    .keyboardShortcut("[", modifiers: [.command])

                    Divider()

                    Button("Beginning of Work") {
                        NSApp.sendAction(#selector(ReaderViewController.goToBeginningOfWorkAction(_:)),
                                         to: nil, from: nil)
                    }
                    .keyboardShortcut("[", modifiers: [.command, .option])

                    Button("End of Work") {
                        NSApp.sendAction(#selector(ReaderViewController.goToEndOfWorkAction(_:)),
                                         to: nil, from: nil)
                    }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                }
                .disabled(AppDelegate.shared?.hasActiveReader != true)

                Menu("Reader Text & Themes") {
                    Button("Increase Font Size") {
                        ReaderPreferences.shared.increaseFontSize()
                    }
                    .keyboardShortcut("=", modifiers: [.command])

                    Button("Decrease Font Size") {
                        ReaderPreferences.shared.decreaseFontSize()
                    }
                    .keyboardShortcut("-", modifiers: [.command])

                    Button("Reset Font Size") {
                        ReaderPreferences.shared.resetFontSize()
                    }
                    .keyboardShortcut("0", modifiers: [.command])

                    Divider()

                    Menu("Appearance Mode") {
                        ForEach(AppearanceMode.allCases) { mode in
                            Button {
                                ReaderPreferences.shared.appearanceMode = mode
                            } label: {
                                if ReaderPreferences.shared.appearanceMode == mode {
                                    Label(mode.displayName, systemImage: "checkmark")
                                } else {
                                    Text(mode.displayName)
                                }
                            }
                        }
                    }

                    Menu("Theme") {
                        ForEach(ReaderTheme.allCases) { theme in
                            Button {
                                ReaderPreferences.shared.applyTheme(theme)
                            } label: {
                                if ReaderPreferences.shared.selectedTheme == theme {
                                    Label(theme.label, systemImage: "checkmark")
                                } else {
                                    Text(theme.label)
                                }
                            }
                        }
                    }

                    Menu("Text Alignment") {
                        ForEach(ThemeTextAlignment.allCases) { align in
                            Button {
                                ReaderPreferences.shared.textAlignment = align
                            } label: {
                                if ReaderPreferences.shared.textAlignment == align {
                                    Label(align.label, systemImage: "checkmark")
                                } else {
                                    Text(align.label)
                                }
                            }
                        }
                    }

                    Menu("Columns (Paged Mode)") {
                        ForEach(ColsPerScreen.allCases, id: \.self) { cols in
                            Button {
                                ReaderPreferences.shared.colsPerScreen = cols
                            } label: {
                                if ReaderPreferences.shared.colsPerScreen == cols {
                                    Label(cols.label, systemImage: "checkmark")
                                } else {
                                    Text(cols.label)
                                }
                            }
                        }
                    }

                    Menu("AO3 Work Layout Order") {
                        ForEach(AO3WorkLayoutOrder.allCases, id: \.self) { order in
                            Button {
                                ReaderPreferences.shared.ao3WorkLayoutOrder = order
                            } label: {
                                if ReaderPreferences.shared.ao3WorkLayoutOrder == order {
                                    Label(order.label, systemImage: "checkmark")
                                } else {
                                    Text(order.label)
                                }
                            }
                        }
                    }
                }

                Divider()

                Button("Toggle Reading Mode") {
                    NSApp.sendAction(#selector(ReaderViewController.toggleReadingMode(_:)),
                                     to: nil, from: nil)
                }
                .disabled(AppDelegate.shared?.hasActiveReader != true)

                Button("Show Table of Contents") {
                    if let libraryWindowController = AppDelegate.shared?.libraryWindowController,
                       libraryWindowController.window?.isKeyWindow == true {
                        libraryWindowController.showTOCInEmailSidebar(nil)
                    } else {
                        NSApp.sendAction(#selector(ReaderViewController.showTOCSidebar(_:)),
                                         to: nil, from: nil)
                    }
                }
                .disabled(AppDelegate.shared?.hasActiveReader != true)

                Button("Show Annotations") {
                    if let libraryWindowController = AppDelegate.shared?.libraryWindowController,
                       libraryWindowController.window?.isKeyWindow == true {
                        libraryWindowController.showEmailAnnotationSidebar(nil)
                    } else {
                        NSApp.sendAction(#selector(ReaderViewController.showAnnotationSidebar(_:)),
                                         to: nil, from: nil)
                    }
                }
                .disabled(AppDelegate.shared?.hasActiveReader != true)

                Button("Add Annotation") {
                    NSApp.sendAction(#selector(ReaderViewController.addAnnotation(_:)),
                                     to: nil, from: nil)
                }
                .disabled(AppDelegate.shared?.hasActiveReader != true)

                Divider()

                Button("Toggle Find Bar") {
                    NSApp.sendAction(#selector(ReaderViewController.toggleFindBarAction(_:)),
                                     to: nil, from: nil)
                }
                .disabled(AppDelegate.shared?.hasActiveReader != true)

                Button("Find Next") {
                    NSApp.sendAction(#selector(ReaderViewController.findNextAction(_:)),
                                     to: nil, from: nil)
                }
                .disabled(AppDelegate.shared?.hasActiveReader != true)

                Button("Find Previous") {
                    NSApp.sendAction(#selector(ReaderViewController.findPreviousAction(_:)),
                                     to: nil, from: nil)
                }
                .disabled(AppDelegate.shared?.hasActiveReader != true)

                Divider()

                Button("Like This Work") {
                    NSApp.sendAction(#selector(ReaderViewController.toggleLikeCurrentWork(_:)),
                                     to: nil, from: nil)
                }
                .disabled(AppDelegate.shared?.hasActiveReader != true)

                Button("Add to Read Later") {
                    NSApp.sendAction(#selector(ReaderViewController.toggleReadLaterCurrentWork(_:)),
                                     to: nil, from: nil)
                }
                .disabled(AppDelegate.shared?.hasActiveReader != true)

                Divider()

                // Clears the shared, in-memory-only remembered reader window
                // size and re-sizes every currently-open reader window back
                // to the half-screen-portrait default.
                Button("Reset Reader Window Size to Default") {
                    ReaderWindowController.resetAllToDefaultSize()
                }
                .disabled(AppDelegate.shared?.hasActiveReader != true)
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
