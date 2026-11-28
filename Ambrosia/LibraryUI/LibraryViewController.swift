import AppKit
import Combine
import SwiftUI

class LibraryViewController: NSViewController {
    private let session: LibrarySession

    /// Shared state between NSToolbar and all content views.
    /// Created here and vended upward to LibraryWindowController.
    let toolbarState: LibraryToolbarState

    /// Unified presentation controller for querying, paging, grouping, and metadata.
    let displayController: LibraryDisplayController

    /// Tracks the hosting view for list mode so we can toggle isHidden on mode switch.
    private var listHostingView: NSHostingView<AnyView>?
    /// Single presentation host for the shared filter drawer across all modes.
    private var filterSheetHost: NSHostingView<LibraryFilterSheetHost>?
    /// Tracks the view controller for email mode so we can toggle isHidden on mode switch.
    private var emailVC: EmailLibraryViewController?
    /// Tracks ranking view controller if created.
    private var rankingVC: NSViewController?
    private var appearanceCancellable: AnyCancellable?

    var hasEmbeddedReader: Bool {
        emailVC?.currentReaderVC != nil
    }

    var currentReaderVC: ReaderViewController? {
        emailVC?.currentReaderVC
    }

    var activeEmailVC: EmailLibraryViewController? {
        emailVC
    }

    init(session: LibrarySession) {
        self.session = session
        let ts = LibraryToolbarState()
        self.toolbarState = ts
        self.displayController = LibraryDisplayController(session: session, toolbarState: ts)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 740)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyLibraryAppearance()
        installFilterSheetHost()
        applyViewMode(toolbarState.viewMode)
        installDropTargetOverlay()
        startObservingViewMode()
        startObservingAppearance()
    }

    private var dropOverlayHost: NSHostingView<AnyView>?

    private func installDropTargetOverlay() {
        let dropView = EPUBDropTargetView { [weak self] urls in
            self?.setDropOverlayVisible(false)
            guard self?.session.activePath != nil else { return }
            AppDelegate.shared?.presentImportTriage(urls: urls)
        } onDragStateChange: { [weak self] isDragging in
            self?.setDropOverlayVisible(isDragging)
        }
        dropView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dropView, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            dropView.topAnchor.constraint(equalTo: view.topAnchor),
            dropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dropView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        let overlay = AnyView(
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)
                Text("Drop EPUBs to Import & Pre-Triage")
                    .font(.headline)
                Text("Ambrosia will check for duplicates and chapter updates before changing your library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.18))
        )
        let host = NSHostingView(rootView: overlay)
        host.sizingOptions = []
        host.isHidden = true
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host, positioned: .above, relativeTo: dropView)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        dropOverlayHost = host
    }

    private func setDropOverlayVisible(_ visible: Bool) {
        dropOverlayHost?.isHidden = !visible
        if visible, let host = dropOverlayHost {
            view.addSubview(host, positioned: .above, relativeTo: nil)
        }
    }

    // MARK: - Appearance

    private func applyLibraryAppearance() {
        let appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
        view.appearance = appearance
        children.forEach { $0.view.appearance = appearance }
        listHostingView?.appearance = appearance
        filterSheetHost?.appearance = appearance
    }

    private func installFilterSheetHost() {
        let root = LibraryFilterSheetHost(
            toolbarState: toolbarState,
            session: session,
            displayController: displayController
        )
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 0),
            host.heightAnchor.constraint(equalToConstant: 0),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        ])
        filterSheetHost = host
    }

    private func startObservingAppearance() {
        withObservationTracking {
            _ = ReaderPreferences.shared.libraryAppearanceMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyLibraryAppearance()
                self?.startObservingAppearance()
            }
        }
    }

    // MARK: - View mode switching

    /// The mode whose surface is currently installed; nil before the first apply.
    private var currentMode: LibraryViewMode?

    private func applyViewMode(_ mode: LibraryViewMode) {
        // A same-value observation callback must not tear down and rebuild a surface.
        guard mode != currentMode else { return }
        defer { currentMode = mode }

        switch mode {
        case .list:
            emailVC?.view.isHidden = true
            rankingVC?.view.isHidden = true
            if let hv = listHostingView {
                hv.isHidden = false
                view.addSubview(hv)
            } else {
                let root = AnyView(
                    LibraryRootView()
                        .environment(toolbarState)
                        .environment(session)
                        .environment(displayController)
                )
                let hv = NSHostingView(rootView: root)
                hv.sizingOptions = []
                hv.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
                hv.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(hv)
                NSLayoutConstraint.activate([
                    hv.topAnchor.constraint(equalTo: view.topAnchor),
                    hv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                    hv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    hv.trailingAnchor.constraint(equalTo: view.trailingAnchor)
                ])
                listHostingView = hv
            }

        case .email:
            listHostingView?.isHidden = true
            rankingVC?.view.isHidden = true
            if let evc = emailVC {
                evc.view.isHidden = false
                view.addSubview(evc.view)
            } else {
                let childVC = EmailLibraryViewController(
                    session: session,
                    toolbarState: toolbarState,
                    displayController: displayController
                )
                addChild(childVC)
                childVC.view.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
                childVC.view.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(childVC.view)
                NSLayoutConstraint.activate([
                    childVC.view.topAnchor.constraint(equalTo: view.topAnchor),
                    childVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                    childVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    childVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
                ])
                emailVC = childVC
            }

        case .ranking:
            listHostingView?.isHidden = true
            emailVC?.view.isHidden = true
            if let rvc = rankingVC {
                rvc.view.isHidden = false
                view.addSubview(rvc.view)
            } else {
                let placeholder = AnyView(
                    ActivityFeedView(session: session)
                        .environment(session)
                        .environment(toolbarState)
                )
                let childVC = NSHostingController(rootView: placeholder)
                addChild(childVC)
                childVC.view.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
                childVC.view.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(childVC.view)
                NSLayoutConstraint.activate([
                    childVC.view.topAnchor.constraint(equalTo: view.topAnchor),
                    childVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                    childVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    childVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
                ])
                rankingVC = childVC
            }
        }
    }

    // MARK: - Observation

    private func startObservingViewMode() {
        scheduleViewModeObservation()
    }

    private func scheduleViewModeObservation() {
        withObservationTracking {
            _ = toolbarState.viewMode
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyViewMode(self.toolbarState.viewMode)
                self.scheduleViewModeObservation()
            }
        }
    }
}

private struct LibraryFilterSheetHost: View {
    let toolbarState: LibraryToolbarState
    let session: LibrarySession
    let displayController: LibraryDisplayController

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: Binding(
                get: { toolbarState.showFilterDrawer },
                set: { toolbarState.showFilterDrawer = $0 }
            )) {
                FilterDrawerView(
                    expression: Binding(
                        get: { toolbarState.filterExpression },
                        set: { toolbarState.filterExpression = $0 }
                    ),
                    onApply: {
                        displayController.applyFilterRules()
                    },
                    onClear: {
                        toolbarState.filterExpression = FilterExpression()
                        toolbarState.activeFilterResult = nil
                        toolbarState.cancelLibraryFilterApplication()
                        displayController.scheduleLoadPage()
                    },
                    onDismiss: { toolbarState.showFilterDrawer = false }
                )
                .environment(toolbarState)
                .environment(session)
                .preferredColorScheme(ReaderPreferences.shared.resolvedLibraryColorScheme)
            }
    }
}

// ReadingHistoryView, ReadingHistoryDisplayRow, ReadingHistoryRow, and HistoryPill
// were removed in Phase 22. The .ranking view mode now hosts ActivityFeedView.

private final class EPUBDropTargetView: NSView {
    private let onDropURLs: ([URL]) -> Void
    private let onDragStateChange: (Bool) -> Void

    init(onDropURLs: @escaping ([URL]) -> Void, onDragStateChange: @escaping (Bool) -> Void) {
        self.onDropURLs = onDropURLs
        self.onDragStateChange = onDragStateChange
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = extractSupportedURLs(from: sender)
        guard !urls.isEmpty else { return [] }
        onDragStateChange(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragStateChange(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragStateChange(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragStateChange(false)
        let urls = extractSupportedURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDropURLs(urls)
        return true
    }

    private func extractSupportedURLs(from info: NSDraggingInfo) -> [URL] {
        guard let items = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return []
        }
        return items.filter { url in
            if url.pathExtension.lowercased() == "epub" { return true }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }
}
