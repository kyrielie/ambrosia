import SwiftUI

// MARK: - AO3FilterSidebarView
//
// In-window collapsible sidebar hosting the authentic AO3-style filter.
// Sits alongside the library list in `LibraryRootView`, matching the layout
// of AO3's web interface. Users can also detach this sidebar into an
// independent floating window via the "Detach" button.

struct AO3FilterSidebarView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(LibraryToolbarState.self) private var toolbarState
    @Environment(LibraryDisplayController.self) private var displayController

    @State private var state: AO3FilterPopupState
    @State private var facetController: AO3FilterFacetController?
    @State private var loadTask: Task<Void, Never>?
    @State private var hostingWindow: NSWindow?

    init(initialDigest: String = "") {
        _state = State(initialValue: AO3FilterPopupState(capturedDigest: initialDigest))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sidebar Header
            HStack(spacing: 8) {
                Label("Filters", systemImage: "line.3.horizontal.decrease")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                // Detach button (open as separate floating window)
                Button {
                    detachToWindow()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open in separate window")

                // Collapse sidebar button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        toolbarState.showAO3FilterSidebar = false
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide filter sidebar")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Filter content
            if let facetController {
                AO3FilterPopupView(
                    state: state,
                    toolbarState: toolbarState,
                    facetController: facetController,
                    membershipVersion: session.membershipVersion,
                    onApply: {
                        handleApply()
                    }
                )
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading filters…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 320, idealWidth: 350, maxWidth: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .background(WindowAccessorView { win in
            if hostingWindow !== win {
                hostingWindow = win
            }
        })
        .task(id: toolbarState.filterExpression) {
            await reloadFacetController()
        }
        .task(id: session.membershipVersion) {
            await reloadFacetController()
        }
    }

    private func handleApply() {
        displayController.applyFilterRules()
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            guard let metaDB = session.metaDB, let library = session.library else { return }
            facetController = await AO3FilterFacetController.make(
                toolbarState: toolbarState,
                metaDB: metaDB,
                library: library,
                ftsLibrary: session.ftsLibrary,
                collectionStore: session.collectionStore
            )
        }
    }

    private func reloadFacetController() async {
        guard let metaDB = session.metaDB, let library = session.library else { return }
        let liveDigest = AO3FilterPopupDigest.current(toolbarState: toolbarState)
        if liveDigest != state.capturedDigest {
            let newState = AO3FilterPopupState(capturedDigest: liveDigest)
            newState.syncPassthrough(from: toolbarState.filterExpression)
            state = newState
        }
        let controller = await AO3FilterFacetController.make(
            toolbarState: toolbarState,
            metaDB: metaDB,
            library: library,
            ftsLibrary: session.ftsLibrary,
            collectionStore: session.collectionStore
        )
        await MainActor.run {
            self.facetController = controller
        }
    }

    private func detachToWindow() {
        guard let window = hostingWindow ?? NSApp.keyWindow,
              let metaDB = session.metaDB,
              let library = session.library else { return }

        // Hide inline sidebar
        withAnimation(.easeInOut(duration: 0.2)) {
            toolbarState.showAO3FilterSidebar = false
        }

        // Open floating window controller
        AO3FilterPopupWindowController.open(
            anchorWindow: window,
            toolbarState: toolbarState,
            dependencies: AO3FilterPopupWindowController.LibraryDependencies(
                metaDB: metaDB,
                library: library,
                ftsLibrary: session.ftsLibrary,
                collectionStore: session.collectionStore
            ),
            membershipVersion: session.membershipVersion
        )
    }
}

// MARK: - WindowAccessorView helper

private struct WindowAccessorView: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView else { return }
            onWindow(nsView.window)
        }
    }
}
