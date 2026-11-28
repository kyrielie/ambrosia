import SwiftUI
import AppKit

@main
struct AmbrosiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var readerMenuState = ReaderMenuState.shared

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
            // ── Ambrosia → Settings… (⌘,) ────────────────────────────────
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    PreferencesWindowController.show()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandGroup(replacing: .help) {
                Button("Ambrosia Help") {
                    if let url = URL(string: "https://github.com/kyrielie/ambrosia") {
                        NSWorkspace.shared.open(url)
                    }
                }
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

                Menu("Find") {
                    Button("Find…") {
                        if let readerWindow = NSApp.keyWindow?.windowController as? ReaderWindowController {
                            readerWindow.readerViewController?.performFindAction(nil)
                        } else if let libraryWindow = NSApp.keyWindow?.windowController as? LibraryWindowController,
                                  libraryWindow.toolbarStateForCommands?.viewMode == .email,
                                  let rvc = libraryWindow.currentReaderVC {
                            rvc.performFindAction(nil)
                        } else {
                            AppDelegate.shared?.libraryWindowController?.focusSearchField(nil)
                        }
                    }
                    .keyboardShortcut("f", modifiers: [.command])

                    Button("Search Library Body Text…") {
                        FTSSearchResultsWindowController.show()
                    }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(
                        !(
                            (AppDelegate.shared?.session.hasFulltextIndex == true
                             && ReaderPreferences.shared.enableFullTextSearch)
                            || AppDelegate.shared?.session.hasPassageIndex == true
                        )
                    )

                    Button("Find Next") {
                        NSApp.sendAction(#selector(ReaderViewController.findNextAction(_:)),
                                         to: nil, from: nil)
                    }
                    .keyboardShortcut("g", modifiers: [.command])
                    .disabled(!readerMenuState.isReaderFocused)

                    Button("Find Previous") {
                        NSApp.sendAction(#selector(ReaderViewController.findPreviousAction(_:)),
                                         to: nil, from: nil)
                    }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!readerMenuState.isReaderFocused)
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

                Button("Import Books…") {
                    AppDelegate.shared?.importBooksFromPanel()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
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
                .disabled(session.activePath == nil)

                Button("Reveal in Finder") {
                    AppDelegate.shared?.revealCurrentOrLibraryInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(session.activePath == nil)

                Button("Manage Duplicate AO3 Works…") {
                    LibraryHealthWindowController.show(tab: .duplicates)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(session.activePath == nil)

                Button("Library Health & File Management…") {
                    LibraryHealthWindowController.show()
                }
                .disabled(session.activePath == nil)

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
                    Button {
                        AppDelegate.shared?.libraryWindowController?.toolbarStateForCommands?.viewMode = .list
                    } label: {
                        if readerMenuState.libraryViewMode == .list {
                            Label("List View", systemImage: "checkmark")
                        } else {
                            Text("List View")
                        }
                    }
                    .keyboardShortcut("1", modifiers: [.command])

                    Button {
                        AppDelegate.shared?.libraryWindowController?.toolbarStateForCommands?.viewMode = .email
                    } label: {
                        if readerMenuState.libraryViewMode == .email {
                            Label("Reading / Email View", systemImage: "checkmark")
                        } else {
                            Text("Reading / Email View")
                        }
                    }
                    .keyboardShortcut("2", modifiers: [.command])

                    Button {
                        AppDelegate.shared?.libraryWindowController?.toolbarStateForCommands?.viewMode = .ranking
                    } label: {
                        if readerMenuState.libraryViewMode == .ranking {
                            Label("Activity", systemImage: "checkmark")
                        } else {
                            Text("Activity")
                        }
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

                Button("Show Failed Metadata Extractions") {
                    AppDelegate.shared?.showLibraryWindow()
                    AppDelegate.shared?.libraryWindowController?.showFailedExtractions()
                }
                .disabled(session.activePath == nil)

                Button("Error Log…") {
                    AppDelegate.shared?.showLibraryWindow()
                    AppDelegate.shared?.libraryWindowController?.showErrorLog()
                }
                .disabled(session.activePath == nil)

                Divider()

                Button("Toggle Sidebar") {
                    AppDelegate.shared?.libraryWindowController?.performSidebarToggleFromMenu()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])

                Button("Toggle AO3 Style Filter") {
                    AppDelegate.shared?.libraryWindowController?.toggleAO3FilterWindow()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(session.activePath == nil)

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
            }

            CommandMenu("Reader") {
                Button("Get Info…") {
                    NSApp.sendAction(#selector(ReaderWindowController.showBookInfoAction(_:)),
                                     to: nil, from: nil)
                }
                .keyboardShortcut("i", modifiers: [.command])
                .disabled(!readerMenuState.isReaderFocused)

                Divider()

                Menu("Navigation") {
                    Button("Next Page") {
                        NSApp.sendAction(#selector(ReaderViewController.goToNextPageAction(_:)),
                                         to: nil, from: nil)
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                    .disabled(!readerMenuState.canGoNextPage)

                    Button("Previous Page") {
                        NSApp.sendAction(#selector(ReaderViewController.goToPreviousPageAction(_:)),
                                         to: nil, from: nil)
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                    .disabled(!readerMenuState.canGoPreviousPage)

                    Divider()

                    Button("Next Chapter") {
                        NSApp.sendAction(#selector(ReaderViewController.nextChapterAction(_:)),
                                         to: nil, from: nil)
                    }
                    .keyboardShortcut("]", modifiers: [.command])
                    .disabled(!readerMenuState.canGoNextChapter)

                    Button("Previous Chapter") {
                        NSApp.sendAction(#selector(ReaderViewController.previousChapterAction(_:)),
                                         to: nil, from: nil)
                    }
                    .keyboardShortcut("[", modifiers: [.command])
                    .disabled(!readerMenuState.canGoPreviousChapter)

                    Divider()

                    Button("Beginning of Work") {
                        NSApp.sendAction(#selector(ReaderViewController.goToBeginningOfWorkAction(_:)),
                                         to: nil, from: nil)
                    }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                    .disabled(!readerMenuState.isReaderFocused)

                    Button("End of Work") {
                        NSApp.sendAction(#selector(ReaderViewController.goToEndOfWorkAction(_:)),
                                         to: nil, from: nil)
                    }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                    .disabled(!readerMenuState.isReaderFocused)
                }
                .disabled(!readerMenuState.isReaderFocused)

                Menu("Reader Text & Themes") {
                    Button("Increase Font Size") {
                        ReaderPreferences.shared.increaseFontSize()
                    }
                    .keyboardShortcut("=", modifiers: [.command])
                    .disabled(!readerMenuState.isReaderFocused)

                    Button("Decrease Font Size") {
                        ReaderPreferences.shared.decreaseFontSize()
                    }
                    .keyboardShortcut("-", modifiers: [.command])
                    .disabled(!readerMenuState.isReaderFocused)

                    Button("Reset Font Size") {
                        ReaderPreferences.shared.resetFontSize()
                    }
                    .keyboardShortcut("0", modifiers: [.command])
                    .disabled(!readerMenuState.isReaderFocused)

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
                            .disabled(!readerMenuState.isReaderFocused)
                        }
                    }
                    .disabled(!readerMenuState.isReaderFocused)

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
                            .disabled(!readerMenuState.isReaderFocused)
                        }
                    }
                    .disabled(!readerMenuState.isReaderFocused)

                    Menu("Highlight Palette") {
                        ForEach(HighlightPalette.allCases) { palette in
                            Button {
                                ReaderPreferences.shared.highlightPalette = palette
                            } label: {
                                if ReaderPreferences.shared.highlightPalette == palette {
                                    Label(palette.displayName, systemImage: "checkmark")
                                } else {
                                    Text(palette.displayName)
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
                            .disabled(!readerMenuState.isReaderFocused)
                        }
                    }
                    .disabled(!readerMenuState.isReaderFocused)

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
                            .disabled(!readerMenuState.isReaderFocused)
                        }
                    }
                    .disabled(!readerMenuState.isReaderFocused)

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
                            .disabled(!readerMenuState.isReaderFocused)
                        }
                    }
                    .disabled(!readerMenuState.isReaderFocused)
                }
                .disabled(!readerMenuState.isReaderFocused)

                Divider()

                Button("Toggle Reading Mode") {
                    NSApp.sendAction(#selector(ReaderViewController.toggleReadingMode(_:)),
                                     to: nil, from: nil)
                }
                .disabled(!readerMenuState.isReaderFocused)

                Button("Show Table of Contents") {
                    if let libraryWindowController = AppDelegate.shared?.libraryWindowController,
                       libraryWindowController.window?.isKeyWindow == true {
                        libraryWindowController.showTOCInEmailSidebar(nil)
                    } else {
                        NSApp.sendAction(#selector(ReaderViewController.showTOCSidebar(_:)),
                                         to: nil, from: nil)
                    }
                }
                .disabled(!readerMenuState.isReaderFocused)

                Button("Show Annotations") {
                    if let libraryWindowController = AppDelegate.shared?.libraryWindowController,
                       libraryWindowController.window?.isKeyWindow == true {
                        libraryWindowController.showEmailAnnotationSidebar(nil)
                    } else {
                        NSApp.sendAction(#selector(ReaderViewController.showAnnotationSidebar(_:)),
                                         to: nil, from: nil)
                    }
                }
                .disabled(!readerMenuState.isReaderFocused)

                Button("Add Annotation") {
                    NSApp.sendAction(#selector(ReaderViewController.addAnnotation(_:)),
                                     to: nil, from: nil)
                }
                .disabled(!readerMenuState.isReaderFocused)

                Divider()

                Button("Toggle Find Bar") {
                    NSApp.sendAction(#selector(ReaderViewController.toggleFindBarAction(_:)),
                                     to: nil, from: nil)
                }
                .disabled(!readerMenuState.isReaderFocused)

                Divider()

                Button(readerMenuState.isCurrentWorkLiked ? "Unlike This Work" : "Like This Work") {
                    NSApp.sendAction(#selector(ReaderViewController.toggleLikeCurrentWork(_:)),
                                     to: nil, from: nil)
                }
                .disabled(!readerMenuState.isReaderFocused)

                Button(readerMenuState.isCurrentWorkInReadLater ? "Remove from Read Later" : "Add to Read Later") {
                    NSApp.sendAction(#selector(ReaderViewController.toggleReadLaterCurrentWork(_:)),
                                     to: nil, from: nil)
                }
                .disabled(!readerMenuState.isReaderFocused)

                if readerMenuState.isSeriesReader {
                    Button(readerMenuState.seriesLikeState == .full ? "Unlike Series" : "Like Series") {
                        NSApp.sendAction(#selector(ReaderViewController.toggleLikeCurrentSeries(_:)), to: nil, from: nil)
                    }
                    Button(readerMenuState.seriesReadLaterState == .full ? "Remove Series from Read Later" : "Add Series to Read Later") {
                        NSApp.sendAction(#selector(ReaderViewController.toggleReadLaterCurrentSeries(_:)), to: nil, from: nil)
                    }
                }

                Divider()

                // Clears the shared, in-memory-only remembered reader window
                // size and re-sizes every currently-open reader window back
                // to the half-screen-portrait default.
                Button("Reset Reader Window Size to Default") {
                    ReaderWindowController.resetAllToDefaultSize()
                }
                .disabled(!readerMenuState.isReaderFocused)
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
                    AppDelegate.shared?.openLibraryAtURL(URL(fileURLWithPath: path))
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
