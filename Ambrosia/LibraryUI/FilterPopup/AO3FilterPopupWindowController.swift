import AppKit
import SwiftUI

// MARK: - AO3FilterPopupWindowController
//
// An `NSPanel` docked to the right edge of the library window, modeled on
// `ReaderViewController`'s annotation/TOC sidebar panels
// (`isFloatingPanel`/`.level = .floating`, tracks the anchor window's
// didMove/didResize to stay flush, `NSHostingController` as the content view
// controller, `NSWindowDelegate` for close-time cleanup). Previously this was
// a fully independent `NSWindow` positioned by `setFrameAutosaveName`, with
// no relationship to the library window — wherever AppKit's cascade or the
// user's last drag left it. Only the panel's width is persisted (in
// UserDefaults, not a frame autosave); position and height are always
// re-derived from the anchor window, so there's nothing to drift. Since
// there is only ever one library open at a time, a single static optional
// is sufficient instead of a keyed dictionary.
@MainActor
final class AO3FilterPopupWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: AO3FilterPopupWindowController?

    private static let widthDefaultsKey = "AmbrosiaAO3FilterPopupWidth"
    private static let defaultWidth: CGFloat = 420
    private static let minWidth: CGFloat = 360

    /// The data-access dependencies `open()` needs only to hand straight
    /// through to `AO3FilterFacetController.make`, grouped together since
    /// they're always sourced from the same `LibrarySession` and passed as
    /// one unit at both call sites.
    struct LibraryDependencies {
        var metaDB: AmbrosiaMetaDB
        var library: CalibreLibrary
        var ftsLibrary: CalibreFTSLibrary?
        var collectionStore: CollectionStore?
    }

    static func open(anchorWindow: NSWindow,
                     toolbarState: LibraryToolbarState,
                     dependencies: LibraryDependencies,
                     membershipVersion: Int) {
        let metaDB = dependencies.metaDB
        let library = dependencies.library
        let ftsLibrary = dependencies.ftsLibrary
        let collectionStore = dependencies.collectionStore
        if let existing = shared {
            existing.anchorWindow = anchorWindow
            existing.installAnchorObservers()
            existing.syncPanelPosition()
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            existing.loadTask?.cancel()
            existing.loadTask = Task {
                await existing.refreshIfDigestChanged(toolbarState: toolbarState, membershipVersion: membershipVersion)
            }
            return
        }
        let wc = AO3FilterPopupWindowController(toolbarState: toolbarState, anchorWindow: anchorWindow)
        shared = wc
        wc.installAnchorObservers()
        wc.syncPanelPosition()
        wc.showWindow(nil)
        wc.loadTask = Task {
            let facetController = await AO3FilterFacetController.make(
                toolbarState: toolbarState, metaDB: metaDB, library: library,
                ftsLibrary: ftsLibrary, collectionStore: collectionStore
            )
            guard !Task.isCancelled else { return }
            wc.installContent(state: wc.state, toolbarState: toolbarState,
                              facetController: facetController, membershipVersion: membershipVersion)
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

    /// The library window this panel docks to. Weak — the panel closes
    /// itself (via windowWillClose) well before the library window could be
    /// deallocated, but there's no reason to hold it strongly either way.
    private weak var anchorWindow: NSWindow?
    private var anchorObservers: [NSObjectProtocol] = []

    private init(toolbarState: LibraryToolbarState, anchorWindow: NSWindow) {
        self.toolbarState = toolbarState
        self.anchorWindow = anchorWindow
        self.state = AO3FilterPopupState(capturedDigest: AO3FilterPopupDigest.current(toolbarState: toolbarState))
        self.hostingController = NSHostingController(rootView: AnyView(ProgressView("Loading filters…").padding()))

        let width = Self.persistedWidth()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        panel.title = "AO3 Style Filter"
        panel.minSize = NSSize(width: Self.minWidth, height: 400)
        panel.isFloatingPanel = true
        panel.level = .floating
        super.init(window: panel)
        panel.delegate = self
        panel.contentViewController = hostingController
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func installContent(state: AO3FilterPopupState, toolbarState: LibraryToolbarState,
                                facetController: AO3FilterFacetController, membershipVersion: Int) {
        hostingController.rootView = AnyView(
            AO3FilterPopupView(state: state, toolbarState: toolbarState, facetController: facetController,
                               membershipVersion: membershipVersion,
                               onApply: { [weak self] in self?.applyDidCommit(toolbarState: toolbarState) })
        )
    }

    // MARK: - Docking

    private static func persistedWidth() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: widthDefaultsKey)
        return stored >= minWidth ? stored : defaultWidth
    }

    private func installAnchorObservers() {
        removeAnchorObservers()
        guard let anchorWindow else { return }
        let nc = NotificationCenter.default
        let move = nc.addObserver(forName: NSWindow.didMoveNotification, object: anchorWindow, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.syncPanelPosition()
            }
        }
        let resize = nc.addObserver(forName: NSWindow.didResizeNotification, object: anchorWindow, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.syncPanelPosition()
            }
        }
        anchorObservers = [move, resize]
    }

    private func removeAnchorObservers() {
        anchorObservers.forEach { NotificationCenter.default.removeObserver($0) }
        anchorObservers = []
    }

    /// Docks the panel flush to the anchor window's right edge, matching its
    /// full height. Falls back to the left edge, then clamps into the
    /// screen's visible frame, if there isn't room on the right — same
    /// clamping shape as the search-suggestion popup's `repositionPanel(_:)`
    /// in `LibraryWindowController`.
    private func syncPanelPosition() {
        guard let panel = window as? NSPanel, let anchorWindow else { return }
        let anchorFrame = anchorWindow.frame
        let width = panel.frame.width
        let screenFrame = anchorWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchorFrame

        let rightX = anchorFrame.maxX
        let leftX = anchorFrame.minX - width
        let x: CGFloat
        if rightX + width <= screenFrame.maxX {
            x = rightX
        } else if leftX >= screenFrame.minX {
            x = leftX
        } else {
            x = min(max(rightX, screenFrame.minX), max(screenFrame.minX, screenFrame.maxX - width))
        }

        let contentRect = CGRect(x: x, y: anchorFrame.minY, width: width, height: anchorFrame.height)
        let newFrame = NSPanel.frameRect(forContentRect: contentRect, styleMask: panel.styleMask)
        panel.setFrame(newFrame, display: true)
    }

    /// Discards checkbox state if the underlying search/filter changed since
    /// this popup's state was captured, and rebuilds a fresh facet
    /// controller/view against the new base filter.
    private func refreshIfDigestChanged(toolbarState: LibraryToolbarState, membershipVersion: Int) async {
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
        installContent(state: state, toolbarState: toolbarState, facetController: facetController,
                       membershipVersion: membershipVersion)
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
            installContent(state: state, toolbarState: toolbarState, facetController: facetController,
                           membershipVersion: session.membershipVersion)
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel = window else { return }
        UserDefaults.standard.set(panel.frame.width, forKey: Self.widthDefaultsKey)
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        loadTask = nil
        removeAnchorObservers()
        Self.shared = nil
    }
}
