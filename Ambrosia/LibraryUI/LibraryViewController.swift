import AppKit
import SwiftUI
import SwiftData

class LibraryViewController: NSViewController {
    private let modelContainer: ModelContainer
    private let session: LibrarySession

    /// Shared state between NSToolbar and all content views.
    /// Created here and vended upward to LibraryWindowController.
    let toolbarState = LibraryToolbarState()

    /// Tracks the hosting view for list mode so we can remove it on mode switch.
    private var listHostingView: NSHostingView<AnyView>?

    init(modelContainer: ModelContainer, session: LibrarySession) {
        self.modelContainer = modelContainer
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 740)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyViewMode(toolbarState.viewMode)
        startObservingViewMode()
    }

    // MARK: - View mode switching

    private func applyViewMode(_ mode: LibraryViewMode) {
        // Remove existing child VCs
        children.forEach {
            $0.view.removeFromSuperview()
            $0.removeFromParent()
        }
        // Remove any NSHostingView used directly (list mode)
        listHostingView?.removeFromSuperview()
        listHostingView = nil

        switch mode {
        case .list:
            // Use NSHostingView directly so we control sizing entirely via constraints.
            //
            // The {inf, 88} intrinsicContentSize crash happens because NSHostingView's
            // default sizingOptions (.intrinsicContentSize) makes Auto Layout ask SwiftUI
            // for its natural size during a layout pass triggered by state changes (e.g.
            // a tag tap mutating toolbarState).  SwiftUI returns {inf, 88} because it
            // hasn't been given a concrete width yet, and AppKit rejects the size.
            //
            // Fix: set sizingOptions = [] so the hosting view is purely constraint-driven
            // and never participates in intrinsic-size negotiation.
            let root = AnyView(
                LibraryRootView()
                    .environment(toolbarState)
                    .modelContainer(modelContainer)
                    .environment(session)
            )
            let hv = NSHostingView(rootView: root)
            hv.sizingOptions = []                             // ← the real fix
            hv.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hv)
            NSLayoutConstraint.activate([
                hv.topAnchor.constraint(equalTo: view.topAnchor),
                hv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                hv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            listHostingView = hv

        case .email:
            let childVC = EmailLibraryViewController(
                modelContainer: modelContainer,
                session: session,
                toolbarState: toolbarState
            )
            addChild(childVC)
            childVC.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(childVC.view)
            NSLayoutConstraint.activate([
                childVC.view.topAnchor.constraint(equalTo: view.topAnchor),
                childVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                childVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                childVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])

        case .ranking:
            let placeholder = AnyView(
                Text("Ranking view coming in D3")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            )
            let childVC = NSHostingController(rootView: placeholder)
            addChild(childVC)
            childVC.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(childVC.view)
            NSLayoutConstraint.activate([
                childVC.view.topAnchor.constraint(equalTo: view.topAnchor),
                childVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                childVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                childVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
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
