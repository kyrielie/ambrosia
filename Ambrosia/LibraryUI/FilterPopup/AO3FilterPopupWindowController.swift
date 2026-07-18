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
            Task { await existing.refreshIfDigestChanged(toolbarState: toolbarState) }
            return
        }
        let wc = AO3FilterPopupWindowController(toolbarState: toolbarState)
        shared = wc
        wc.showWindow(nil)
        Task {
            let facetController = await AO3FilterFacetController.make(
                toolbarState: toolbarState, metaDB: metaDB, library: library,
                ftsLibrary: ftsLibrary, collectionStore: collectionStore
            )
            wc.installContent(state: wc.state, toolbarState: toolbarState, facetController: facetController)
        }
    }

    private let toolbarState: LibraryToolbarState
    private var state: AO3FilterPopupState
    private let hostingController: NSHostingController<AnyView>

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
            AO3FilterPopupView(state: state, toolbarState: toolbarState, facetController: facetController)
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
        installContent(state: state, toolbarState: toolbarState, facetController: facetController)
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}
