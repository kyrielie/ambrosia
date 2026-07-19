import AppKit
import SwiftUI

/// Detects a double-click on a row in a `List`'s underlying `NSTableView`
/// and reports the double-clicked row index, without ever intercepting
/// `mouseDown`.
///
/// `BookListRow` and `SeriesListRow` used to attach `.simultaneousGesture(
/// TapGesture(count: 2)...)` directly to row content to open a work on
/// double-click. That gesture recognizer sits in front of `NSTableView`'s own
/// mouseDown-driven selection handling — even as a "simultaneous" gesture, it
/// still competes at the AppKit level, and a count-2 recognizer specifically
/// has to wait out the double-click interval before "failing," which delayed
/// or ate the click `List(selection:)` needed for click / shift-click /
/// cmd-click selection. Arrow-key selection was unaffected because it's
/// driven entirely by `List`'s own key-event pipeline, never through a
/// gesture recognizer — which is exactly the split that was reported
/// ("arrow key navigation/selection works though").
///
/// An `NSEvent.addLocalMonitorForEvents(matching:)` monitor was tried next,
/// but `NSTableView` handles row mouseDown/mouseUp inside its own internal
/// mouse-tracking loop rather than through the normal
/// `NSApplication.sendEvent:` pipeline that local event monitors observe —
/// confirmed by instrumentation showing the monitor never received a single
/// event for clicks landing on rows, only for events routed through the
/// ordinary responder chain (e.g. the click that activates the window).
///
/// This type instead uses `NSTableView`'s own built-in double-click support:
/// `target`/`doubleAction` is invoked by AppKit itself, from inside that same
/// internal tracking loop, once a double-click on a row has resolved — so it
/// reliably fires and needs no hit-testing or `NSControl` filtering of its
/// own (AppKit already routes clicks on embedded controls, e.g. tag pills,
/// to those controls first and does not invoke `doubleAction` for them).
///
/// Install as a transparent `.background` on the `List` (see
/// `LibraryRootView.itemList`), not as a per-row modifier — a single
/// attachment per list, not one per row. The underlying `NSTableView` isn't
/// necessarily attached the moment this view is; `installIfNeeded` is
/// re-tried both from `viewDidMoveToWindow` and from every `updateNSView`
/// call until it succeeds.
struct LibraryListDoubleClickMonitor: NSViewRepresentable {
    var onDoubleClick: (_ row: Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
        // §fix: `List` doesn't reliably re-propagate `viewDidMoveToWindow` to
        // content attached via `.background()` — when this representable is
        // first created, its ancestor `NSHostingView` may not yet be attached
        // to a real `NSWindow` (see LibraryViewController.applyViewMode,
        // which builds/reuses that hosting view independently of window
        // attachment timing), and no second `viewDidMoveToWindow` call ever
        // arrives to retry. `updateNSView` re-runs on every SwiftUI body
        // evaluation (i.e. constantly, since `items` changes on every page
        // load), so it's used here as a resilient retry point instead of
        // trusting the one-shot AppKit lifecycle hook alone. Also needed
        // because `List`'s `NSTableView` itself may not exist yet the moment
        // this representable's NSView is created.
        nsView.installIfNeeded()
    }

    final class CatcherView: NSView {
        var onDoubleClick: ((Int) -> Void)?
        private weak var installedTableView: NSTableView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installIfNeeded()
        }

        func installIfNeeded() {
            guard installedTableView == nil, let tableView = findEnclosingTableView() else { return }
            tableView.target = self
            tableView.doubleAction = #selector(handleDoubleClick(_:))
            installedTableView = tableView
        }

        /// Walks up from this view (a sibling of `List`'s content, attached
        /// via `.background`) to the enclosing `NSScrollView`, then reads its
        /// `documentView` — which is the `NSTableView` for a `List` on macOS.
        private func findEnclosingTableView() -> NSTableView? {
            var probe: NSView? = self
            while let current = probe {
                if let scrollView = current as? NSScrollView, let tableView = scrollView.documentView as? NSTableView {
                    return tableView
                }
                probe = current.superview
            }
            return nil
        }

        @objc private func handleDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0 else { return }
            onDoubleClick?(row)
        }
    }
}
