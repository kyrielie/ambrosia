import AppKit
import SwiftUI

// MARK: - AO3FilterPopupWindowController
//
// A separate `NSWindow`, modeled directly on `ReaderWindowController`
// (singleton-tracked, `NSWindow` built directly rather than a SwiftUI
// `Scene`/`WindowGroup`, `NSHostingController` as the content view
// controller, `setFrameAutosaveName` for persisted size/position,
// `NSWindowDelegate` for close-time cleanup). Since there is only ever one
// library open at a time, a single static optional is sufficient instead of
// a keyed dictionary.
@MainActor
final class AO3FilterPopupWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: AO3FilterPopupWindowController?

    static func open(toolbarState: LibraryToolbarState,
                      metaDB: AmbrosiaMetaDB,
                      library: CalibreLibrary,
                      ftsLibrary: CalibreFTSLibrary?,
                      collectionStore: CollectionStore?) {
        if let existing = shared {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            existing.loadTask?.cancel()
            existing.loadTask = Task { await existing.refreshIfDigestChanged(toolbarState: toolbarState) }
            return
        }
        let wc = AO3FilterPopupWindowController(toolbarState: toolbarState)
        shared = wc
        wc.showWindow(nil)
        wc.loadTask = Task {
            let facetController = await AO3FilterFacetController.make(
                toolbarState: toolbarState, metaDB: metaDB, library: library,
                ftsLibrary: ftsLibrary, collectionStore: collectionStore
            )
            guard !Task.isCancelled else { return }
            wc.installContent(state: wc.state, toolbarState: toolbarState, facetController: facetController)
        }
    }

    private let toolbarState: LibraryToolbarState
    private var state: AO3FilterPopupState
    private let hostingController: NSHostingController<AnyView>
    // §9: Neither the initial load Task in open() nor the reload Task in the
    // `existing` branch was retained anywhere windowWillClose could reach to
    // cancel it. Closing the window before AO3FilterFacetController.make(...)
    // finished (a multi-second call under NOT-heavy filters even after fix
    // plan §1/§2) let the task run to completion in the background and later
    // call installContent on a controller nobody was looking at — and if the
    // user reopened in the meantime, a second independent facetController.make()
    // started from scratch, discarding whatever progress the first one made.
    // See fix plan §3a.
    private var loadTask: Task<Void, Never>?

    private init(toolbarState: LibraryToolbarState) {
        self.toolbarState = toolbarState
        self.state = AO3FilterPopupState(capturedDigest: AO3FilterPopupDigest.current(toolbarState: toolbarState))
        self.hostingController = NSHostingController(rootView: AnyView(ProgressView("Loading filters…").padding()))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "AO3 Style Filter"
        window.minSize = NSSize(width: 360, height: 400)
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("AmbrosiaAO3FilterPopup")
        _ = window.setFrameUsingName("AmbrosiaAO3FilterPopup")
        window.contentViewController = hostingController
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func installContent(state: AO3FilterPopupState, toolbarState: LibraryToolbarState,
                                 facetController: AO3FilterFacetController) {
        hostingController.rootView = AnyView(
            AO3FilterPopupView(state: state, toolbarState: toolbarState, facetController: facetController,
                                onApply: { [weak self] in self?.applyDidCommit(toolbarState: toolbarState) })
        )
    }

    /// Discards checkbox state if the underlying search/filter changed since
    /// this popup's state was captured, and rebuilds a fresh facet
    /// controller/view against the new base filter.
    private func refreshIfDigestChanged(toolbarState: LibraryToolbarState) async {
        let liveDigest = AO3FilterPopupDigest.current(toolbarState: toolbarState)
        guard liveDigest != state.capturedDigest else { return }
        guard let session = AppDelegate.shared?.session,
              let metaDB = session.metaDB, let library = session.library else { return }
        state = AO3FilterPopupState(capturedDigest: liveDigest)
        let facetController = await AO3FilterFacetController.make(
            toolbarState: toolbarState, metaDB: metaDB, library: library,
            ftsLibrary: session.ftsLibrary, collectionStore: session.collectionStore
        )
        guard !Task.isCancelled else { return }
        installContent(state: state, toolbarState: toolbarState, facetController: facetController)
    }

    // §9: Runs after AO3FilterPopupView.apply() writes a fresh expression to
    // toolbarState. Two things need to happen, and in this order:
    //
    //   1. Resync state.capturedDigest to the *new* toolbarState synchronously,
    //      before any await. Cheap (string comparison), and closes the race
    //      where the user closes/reopens the popup while step 2 below is still
    //      in flight — refreshIfDigestChanged would otherwise see the old,
    //      pre-Apply digest, decide the toolbar changed "externally," and wipe
    //      the checkboxes that were just applied.
    //   2. Rebuild facetController (baseIDs, crossoverMap, statusMap, and the
    //      FilterBuilder's tagExpansions all need to reflect the newly-applied
    //      expression, not the pre-Apply one) and reinstall the view, the same
    //      way refreshIfDigestChanged already does for an external change —
    //      this is deliberately the same rebuild-and-reinstall shape rather
    //      than a partial in-place mutation of the existing controller, so
    //      there's only one code path that knows how to construct a correct
    //      AO3FilterFacetController.
    //
    // See fix plan §3b.
    private func applyDidCommit(toolbarState: LibraryToolbarState) {
        state.capturedDigest = AO3FilterPopupDigest.current(toolbarState: toolbarState)

        loadTask?.cancel()
        loadTask = Task {
            guard let session = AppDelegate.shared?.session,
                  let metaDB = session.metaDB, let library = session.library else { return }
            let facetController = await AO3FilterFacetController.make(
                toolbarState: toolbarState, metaDB: metaDB, library: library,
                ftsLibrary: session.ftsLibrary, collectionStore: session.collectionStore
            )
            guard !Task.isCancelled else { return }
            installContent(state: state, toolbarState: toolbarState, facetController: facetController)
        }
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        loadTask = nil
        Self.shared = nil
    }
}
