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
    /// Tracks the view controller for email mode so we can toggle isHidden on mode switch.
    private var emailVC: EmailLibraryViewController?
    /// Tracks ranking view controller if created.
    private var rankingVC: NSViewController?
    private var appearanceCancellable: AnyCancellable?

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
        applyViewMode(toolbarState.viewMode)
        startObservingViewMode()
        startObservingAppearance()
    }

    // MARK: - Appearance

    private func applyLibraryAppearance() {
        let appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
        view.appearance = appearance
        children.forEach { $0.view.appearance = appearance }
        listHostingView?.appearance = appearance
    }

    private func startObservingAppearance() {
        appearanceCancellable = ReaderPreferences.shared.$libraryAppearanceMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyLibraryAppearance()
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
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyViewMode(self.toolbarState.viewMode)
                self.scheduleViewModeObservation()
            }
        }
    }
}

// ReadingHistoryView, ReadingHistoryDisplayRow, ReadingHistoryRow, and HistoryPill
// were removed in Phase 22. The .ranking view mode now hosts ActivityFeedView.
