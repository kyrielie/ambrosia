import AppKit
import SwiftUI

/// Detects a real double-click landing on a `List`'s underlying `NSTableView`
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
/// This type replaces that gesture. It only reacts to `.leftMouseUp` with
/// `clickCount == 2` — i.e. strictly *after* AppKit has already resolved
/// selection from the first click of the pair — so single-click, shift-click,
/// and cmd-click selection are routed to `NSTableView` completely untouched.
/// It also skips events landing on a button/control (tag pills, like /
/// read-later toggles, the series index disclosure button, etc.) so their own
/// click behavior isn't hijacked into "open."
///
/// Install as a transparent `.background` on the `List` (see
/// `LibraryRootView.itemList`), not as a per-row modifier — a single monitor
/// per list, not one per row.
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
        // trusting the one-shot AppKit lifecycle hook alone.
        nsView.installMonitorIfNeeded()
    }

    final class CatcherView: NSView {
        var onDoubleClick: ((Int) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            teardownMonitor()
            installMonitorIfNeeded()
        }

        func installMonitorIfNeeded() {
            guard monitor == nil, let window else { return }
            // Local monitor: only ever sees events destined for our own
            // window, and — critically — we never consume the event (always
            // return it unchanged), so nothing about normal AppKit event
            // dispatch (selection, button clicks, etc.) is affected.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                self?.handleMouseUp(event, in: window)
                return event
            }
        }

        private func teardownMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        private func handleMouseUp(_ event: NSEvent, in window: NSWindow) {
            guard event.window === window, event.clickCount == 2 else { return }
            guard let contentView = window.contentView else { return }
            let windowPoint = event.locationInWindow
            guard let hit = contentView.hitTest(windowPoint) else { return }

            var probe: NSView? = hit
            while let current = probe {
                // NSTableView must be checked *before* the NSControl bailout
                // below: NSTableView is itself an NSControl subclass, so if
                // the order were reversed, the walk would match "is
                // NSControl" the moment it reached the table view and return
                // before ever reaching the NSTableView branch -- silently
                // swallowing every double-click. Do not reorder these.
                if let tableView = current as? NSTableView {
                    let localPoint = tableView.convert(windowPoint, from: nil)
                    let row = tableView.row(at: localPoint)
                    guard row >= 0 else { return }
                    onDoubleClick?(row)
                    return
                }
                // A double-click on any button/control inside the row (tag
                // pill, like toggle, series index button, ...) is that
                // control's own business, not ours.
                if current is NSControl { return }
                probe = current.superview
            }
        }
    }
}
