import AppKit
import WebKit

// MARK: - PaginationEngine
//
// Thin Swift coordinator for horizontal CSS multi-column paged mode.
//
// DESIGN — CSS pre-loaded, no Swift-side geometry math:
//   Column layout CSS is baked into the HTML string by ReaderViewController
//   (via ReaderPreferences.paginatedColumnCSS) before loadHTMLString is ever
//   called. By the time webView(_:didFinish:) fires, column layout is already
//   settled — there is no post-load evaluateJavaScript race and no delay to
//   wait out. This engine's job is limited to: injecting PaginationJS, telling
//   it how many columns fit on screen, restoring the requested position once
//   the total column count is known, and exposing navigation/query methods.
//
//   Geometry (column width, column gap) is read by JS from
//   getComputedStyle(document.documentElement) — never passed in from Swift.
//   See invariant 4 in the build plan.
//
// RESIZE:
//   Because column CSS is baked into the HTML, a resize requires a full spine
//   reload with updated viewport geometry, not just re-running JS. See
//   ReaderViewController's resize handler, which reads currentFraction and
//   calls loadSpineItem(index:restorePosition:.fraction(_:)) again.
//
// KEY REPEAT SUPPRESSION:
//   Swift intercepts keyDown in ReaderViewController. The engine exposes
//   handleKeyDown(_:) which ReaderViewController calls directly — the WKWebView
//   never sees raw keystrokes. One physical keypress = one page turn.
//
// THREAD SAFETY: All public methods must be called on the main thread.

// MARK: - ColsPerScreen preference

enum ColsPerScreen: Int, CaseIterable {
    case one   = 1
    case two   = 2
    case three = 3

    var label: String {
        switch self {
        case .one:   return "1 column"
        case .two:   return "2 columns"
        case .three: return "3 columns"
        }
    }
}

// MARK: - RestorePosition
//
// Replaces the old ambiguous `restorePage: Int?` parameter, which silently
// conflated page index with fraction.

enum RestorePosition {
    case start              // column 0
    case end                // last column
    case fraction(Double)   // 0.0–1.0, saved progress
}

// MARK: - PaginationEngine

final class PaginationEngine: NSObject {

    // MARK: Callbacks

    /// Called after a spine finishes loading, CSS layout is already settled,
    /// and the requested restore position has been applied. Receives the
    /// total number of columns in the spine.
    var spineDidLoad: ((Int) -> Void)?

    /// Called when JS requests navigation to the next or previous spine item.
    var spineNavigationHandler: ((_ forward: Bool) -> Void)?

    /// Called after every column navigation (page turn or restore).
    var positionDidChange: ((_ column: Int, _ total: Int) -> Void)?

    // MARK: State

    private weak var webView: WKWebView?
    private var colsPerScreen: Int = 1
    private var pendingRestorePosition: RestorePosition = .start
    private(set) var isReady = false

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
    }

    func setColsPerScreen(_ cols: ColsPerScreen) {
        colsPerScreen = cols.rawValue
    }

    // MARK: Called from webView(_:didFinish:) — after CSS is already applied

    /// Injects PaginationJS and restores the requested position. The column
    /// CSS is already baked into the loaded HTML, so no delay is needed to
    /// wait for layout to settle.
    func applyLayout(restorePosition: RestorePosition) {
        guard let webViewRef = webView else { return }
        isReady = false
        pendingRestorePosition = restorePosition

        let setupJS = """
        \(PaginationJS.script)
        window.ambrosiaSetup(\(colsPerScreen));
        window.ambrosiaPaginationMetrics();
        """

        webViewRef.evaluateJavaScript(setupJS) { [weak self] result, error in
            guard let self else { return }
            if let error {
                #if DEBUG
                print("[PaginationEngine] JS error: \(error)")
                #endif
                self.spineDidLoad?(1)
                return
            }

            var totalCols = 1
            if let str = result as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cols = json["columns"] as? NSNumber {
                totalCols = cols.intValue
            }

            self.isReady = true

            switch self.pendingRestorePosition {
            case .start:
                self.scrollToColumn(0)
            case .end:
                self.scrollToColumn(totalCols - 1)
            case .fraction(let fraction):
                self.scrollToFraction(fraction)
            }

            self.spineDidLoad?(totalCols)
        }
    }

    /// Reads the current progress fraction. Used before a resize-triggered
    /// spine reload, so the reload can request .fraction(f) as its restore
    /// position. Does NOT reapply layout itself — see invariant 8.
    func currentFraction(completion: @escaping (Double) -> Void) {
        guard isReady, let webViewRef = webView else { completion(0); return }
        webViewRef.evaluateJavaScript("window.ambrosiaProgressFraction();") { result, _ in
            completion((result as? Double) ?? 0)
        }
    }

    // MARK: Navigation

    enum NavigationKey { case forward, backward }

    func handleKeyDown(_ key: NavigationKey) {
        guard isReady else { return }
        switch key {
        case .forward:  webView?.evaluateJavaScript("window.ambrosiaNextPage();", completionHandler: nil)
        case .backward: webView?.evaluateJavaScript("window.ambrosiaPrevPage();", completionHandler: nil)
        }
    }

    func scrollToColumn(_ column: Int) {
        guard isReady else { return }
        webView?.evaluateJavaScript("window.ambrosiaScrollToColumn(\(column));", completionHandler: nil)
    }

    func scrollToFraction(_ fraction: Double) {
        guard isReady else { return }
        let clamped = max(0, min(1, fraction))
        webView?.evaluateJavaScript("window.ambrosiaScrollToFraction(\(clamped));", completionHandler: nil)
    }

    func scrollToOffset(_ charOffset: Int) {
        guard isReady else { return }
        webView?.evaluateJavaScript("window.ambrosiaNavigateToOffset(\(charOffset));", completionHandler: nil)
    }

    func scrollToAnchor(_ id: String) {
        guard isReady else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: [id]),
              let json = String(data: data, encoding: .utf8) else { return }
        let literal = String(json.dropFirst().dropLast())
        webView?.evaluateJavaScript("window.ambrosiaScrollToAnchor(\(literal));", completionHandler: nil)
    }

    func queryProgress(completion: @escaping (_ fraction: Double, _ column: Int, _ total: Int) -> Void) {
        guard isReady, let webViewRef = webView else { completion(0, 0, 1); return }
        let progressJS = """
        JSON.stringify({
            f: window.ambrosiaProgressFraction(),
            c: window.ambrosiaCurrentColumn(),
            t: window.ambrosiaColumnCount()
        });
        """
        webViewRef.evaluateJavaScript(progressJS) { result, _ in
            guard let str = result as? String,
                  let data = str.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double]
            else { completion(0, 0, 1); return }
            completion(dict["f"] ?? 0, Int(dict["c"] ?? 0), Int(dict["t"] ?? 1))
        }
    }
}

// MARK: - ReaderViewController integration notes
//
// 1. MESSAGE HANDLER REGISTRATION
//    "pageAction" and "positionUpdate" (plus highlightAdded/highlightTapped)
//    are registered on WKWebViewConfiguration.userContentController before
//    the WKWebView is constructed (invariant 6). PaginationEngine does not
//    register these itself — ReaderViewController owns the configuration and
//    the message routing.
//
// 2. NAVIGATION DELEGATE
//    In webView(_:didFinish:), when currentMode == .paginated:
//        paginationEngine.applyLayout(restorePosition: pendingRestorePosition)
//    pendingRestorePosition is set on ReaderViewController before
//    loadHTMLString is called (see loadSpineItem).
//
// 3. KEY REPEAT SUPPRESSION
//    NSEvent.isARepeat must be checked before forwarding to handleKeyDown(_:).
//    One physical keypress = one page turn.
//
// 4. RESIZE HANDLING
//    Debounce on view layout / window resize. Read paginationEngine's
//    currentFraction, then call ReaderViewController.loadSpineItem(index:
//    restorePosition: .fraction(f)) — a full spine reload, because the column
//    CSS is baked into the HTML (invariant 8).
//
// 5. SCROLLBAR SUPPRESSION
//    After the WKWebView is added to the view hierarchy (enclosingScrollView
//    is nil until then — invariant 7):
//        webView.enclosingScrollView?.hasHorizontalScroller = false
//        webView.enclosingScrollView?.hasVerticalScroller   = false
//        webView.enclosingScrollView?.horizontalScrollElasticity = .none
//        webView.enclosingScrollView?.verticalScrollElasticity   = .none
