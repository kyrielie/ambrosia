import AppKit
import WebKit

// MARK: - PaginationEngine
//
// Manages per-spine horizontal CSS multi-column layout in the visible WKWebView.
//
// DESIGN — no hidden measurement WebView:
//   CSS multi-column does not require a separate layout pass. The browser reflows
//   the spine's HTML into columns automatically once column-width and column-gap
//   are applied to document.body. There is nothing to measure upfront — column
//   count is read from scrollWidth after layout settles.
//
//   The previous PaginationEngine used a hidden WKWebView + binary-search to
//   find vertical page boundaries. That approach is retired. Column boundaries
//   are implicit in the CSS layout; scrollWidth / colAndGap gives the total count.
//
// SPINE LOADING:
//   Call loadSpine(html:baseURL:) to load a new spine item.
//   The engine applies CSS multi-column in webView(_:didFinish:) once layout is ready.
//   On completion it calls the spineDidLoad callback with the total column count.
//
//   On nextSpineItem / prevSpineItem messages from JS, the engine calls the
//   spineNavigationHandler so ReaderViewController can load the adjacent spine.
//
// COLUMN LAYOUT MATH (computed from WKWebView.bounds at layout time):
//   gap      = max(1, marginLeft + marginRight)   from ReaderPreferences
//   colSize  = (viewportWidth + gap) / colsPerScreen − gap
//   The +gap / −gap dance ensures: colSize * n + (n−1) * gap = viewportWidth exactly.
//
// KEY REPEAT SUPPRESSION:
//   Swift intercepts keyDown in ReaderViewController. The engine exposes
//   handleKeyDown(_:) which ReaderViewController calls directly — the WKWebView
//   never sees raw keystrokes. One physical keypress = one JS call, no exceptions.
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

// MARK: - PaginationEngine

final class PaginationEngine: NSObject {

    // MARK: - Public callbacks

    /// Called after a spine finishes loading and CSS layout is applied.
    /// Receives the total number of columns in the spine.
    var spineDidLoad: ((Int) -> Void)?

    /// Called when JS requests navigation to the next or previous spine item.
    /// `forward: true` → next spine, `forward: false` → previous spine.
    var spineNavigationHandler: ((_ forward: Bool) -> Void)?

    /// Called after every column navigation (page turn or restore).
    /// Receives (currentColumn, totalColumns) so ReaderViewController can
    /// update BookState progress and the toolbar position indicator.
    var positionDidChange: ((_ column: Int, _ total: Int) -> Void)?

    // MARK: - Private state

    private weak var webView: WKWebView?
    private var colsPerScreen: Int = 1
    private var colSize: CGFloat   = 0
    private var gap: CGFloat       = 0
    private var colAndGap: CGFloat = 0

    /// Whether the current spine has finished loading and ambrosiaSetup has been called.
    private var isReady = false

    /// Pending fraction to restore once the spine finishes loading.
    /// Set by the caller before loadSpine when returning to a previously read position.
    var pendingFraction: Double? = nil

    // MARK: - Init

    /// - Parameter webView: The visible reader WKWebView. Weak reference — the engine
    ///   does not own the web view.
    init(webView: WKWebView) {
        self.webView = webView
        super.init()
    }

    // MARK: - Configuration

    /// Update the columns-per-screen setting. Takes effect on the next loadSpine call.
    func setColsPerScreen(_ n: ColsPerScreen) {
        colsPerScreen = n.rawValue
    }

    // MARK: - Spine loading

    /// Load a new spine item. The engine will apply CSS multi-column layout in
    /// webViewDidFinishNavigation and call spineDidLoad when ready.
    ///
    /// - Parameters:
    ///   - html: The merged HTML string from EPUBParser for this spine item.
    ///   - baseURL: The EPUB's content base URL (for relative image paths).
    ///   - restoreFraction: If non-nil, the engine scrolls to this saved progress
    ///     fraction (0–1) instead of column 0 after loading.
    func loadSpine(html: String, baseURL: URL?, restoreFraction: Double? = nil) {
        isReady = false
        pendingFraction = restoreFraction
        webView?.loadHTMLString(html, baseURL: baseURL)
    }

    // MARK: - Layout (called from WKNavigationDelegate in ReaderViewController)

    /// Apply CSS multi-column layout and inject PaginationJS.
    /// ReaderViewController must call this from webView(_:didFinish:).
    func applyLayout() {
        guard let wv = webView else { return }

        // Compute column geometry from the web view's current bounds.
        let viewWidth = wv.bounds.width
        computeColumnGeometry(viewportWidth: viewWidth)

        // Inject PaginationJS and call ambrosiaSetup. Column count is read back
        // after a short delay because WebKit updates CSS column layout
        // asynchronously after the style mutation.
        let js = """
        \(PaginationJS.script)
        window.ambrosiaSetup(\(colSize), \(gap), \(colsPerScreen));
        """

        wv.evaluateJavaScript(js) { [weak self] _, error in
            guard let self else { return }
            if let error {
                print("[PaginationEngine] applyLayout JS error: \(error)")
                self.spineDidLoad?(1)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                wv.evaluateJavaScript("window.ambrosiaPaginationMetrics();") { result, error in
                    if let error {
                        print("[PaginationEngine] column count JS error: \(error)")
                        self.spineDidLoad?(1)
                        return
                    }

                    var totalCols = 1
                    #if DEBUG
                    if let metrics = result as? String {
                        print("[PaginationEngine] metrics \(metrics)")
                        if let data = metrics.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let columns = json["columns"] as? NSNumber {
                            totalCols = columns.intValue
                        }
                    }
                    #else
                    if let metrics = result as? String,
                       let data = metrics.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let columns = json["columns"] as? NSNumber {
                        totalCols = columns.intValue
                    }
                    #endif

                    self.isReady = true

                    if let frac = self.pendingFraction {
                        self.pendingFraction = nil
                        self.scrollToFraction(frac)
                    }
                    self.spineDidLoad?(totalCols)
                }
            }
        }
    }

    /// Re-apply layout after a window resize. ReaderViewController calls this from
    /// its resize handler (debounced — do not call on every frame).
    /// Preserves the current progress fraction across the resize.
    func reapplyLayout() {
        guard let wv = webView, isReady else { return }

        // Read current fraction before invalidating layout.
        wv.evaluateJavaScript("window.ambrosiaProgressFraction();") { [weak self] result, _ in
            guard let self else { return }
            let frac = (result as? Double) ?? 0.0
            self.pendingFraction = frac
            self.isReady = false
            self.applyLayout()
        }
    }

    // MARK: - Keyboard navigation
    //
    // ReaderViewController calls handleKeyDown(_:) from its keyDown override.
    // The WKWebView never receives these events — see ReaderViewController for
    // the key-repeat suppression logic.

    enum NavigationKey {
        case forward   // right arrow, down arrow, space
        case backward  // left arrow, up arrow
    }

    func handleKeyDown(_ key: NavigationKey) {
        guard isReady else { return }
        switch key {
        case .forward:
            webView?.evaluateJavaScript("window.ambrosiaNextPage();",
                                        completionHandler: nil)
        case .backward:
            webView?.evaluateJavaScript("window.ambrosiaPrevPage();",
                                        completionHandler: nil)
        }
    }

    // MARK: - Programmatic navigation

    func scrollToColumn(_ column: Int) {
        guard isReady else { return }
        webView?.evaluateJavaScript(
            "window.ambrosiaScrollToColumn(\(column));",
            completionHandler: nil
        )
    }

    func scrollToFraction(_ fraction: Double) {
        guard isReady else { return }
        let clamped = max(0.0, min(1.0, fraction))
        webView?.evaluateJavaScript(
            "window.ambrosiaScrollToFraction(\(clamped));",
            completionHandler: nil
        )
    }

    func scrollToOffset(_ charOffset: Int) {
        guard isReady else { return }
        webView?.evaluateJavaScript(
            "window.ambrosiaNavigateToOffset(\(charOffset));",
            completionHandler: nil
        )
    }

    // MARK: - Progress query

    /// Ask JS for the current progress fraction and deliver it asynchronously.
    func queryProgress(completion: @escaping (Double, Int, Int) -> Void) {
        guard isReady, let wv = webView else {
            completion(0, 0, 1)
            return
        }
        let js = "JSON.stringify({ f: window.ambrosiaProgressFraction(), c: window.ambrosiaCurrentColumn(), t: window.ambrosiaColumnCount() });"
        wv.evaluateJavaScript(js) { result, _ in
            guard let str = result as? String,
                  let data = str.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double]
            else {
                completion(0, 0, 1)
                return
            }
            let frac  = dict["f"] ?? 0
            let col   = Int(dict["c"] ?? 0)
            let total = Int(dict["t"] ?? 1)
            completion(frac, col, total)
        }
    }

    // MARK: - Column geometry

    private func computeColumnGeometry(viewportWidth: CGFloat) {
        // Gap: use reader horizontal padding, minimum 1px to avoid WebKit
        // scrolling bugs with zero-width column gaps.
        let prefs = ReaderPreferences.shared
        let horizontalPadding = CGFloat(prefs.paddingH * 2)
        gap = max(1, horizontalPadding)

        let n = CGFloat(colsPerScreen)

        if n == 1 {
            colSize = viewportWidth - gap
        } else {
            // Adjust gap so columns fit pixel-perfectly:
            //   colSize * n + (n-1) * gap = viewportWidth
            //   overhang = (viewportWidth + gap) % n
            let raw = viewportWidth + gap
            let overhang = raw.truncatingRemainder(dividingBy: n)
            if overhang != 0 { gap += n - overhang }
            colSize = (viewportWidth + gap) / n - gap
        }

        colAndGap = colSize + gap
    }
}

// MARK: - ReaderViewController integration notes
//
// The following additions are needed in ReaderViewController.
// They are described here rather than in a separate file so the engine
// and its host are documented together.
//
// 1. MESSAGE HANDLER REGISTRATION
//    Register "pageAction" and "positionUpdate" handlers at WKWebViewConfiguration
//    construction time (before WKWebView init — invariant 7).
//    PaginationEngine does not register these itself because ReaderViewController
//    owns the WKWebViewConfiguration and the message routing.
//
//    In userContentController(_:didReceive:):
//
//      case "pageAction":
//          guard let body = message.body as? String,
//                let data = body.data(using: .utf8),
//                let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
//                let action = dict["action"] as? String else { return }
//          switch action {
//          case "nextSpineItem": loadNextSpine()
//          case "prevSpineItem": loadPrevSpine()
//          default: break
//          }
//
//      case "positionUpdate":
//          guard let body = message.body as? String,
//                let data = body.data(using: .utf8),
//                let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
//          else { return }
//          let fraction = dict["fraction"] as? Double ?? 0
//          let column   = dict["column"]   as? Int    ?? 0
//          let total    = dict["totalColumns"] as? Int ?? 1
//          paginationEngine.positionDidChange?(column, total)
//          saveProgress(fraction: fraction)
//
// 2. NAVIGATION DELEGATE
//    In webView(_:didFinish:):
//        paginationEngine.applyLayout()
//
// 3. KEY REPEAT SUPPRESSION
//    WKWebView swallows keyDown by default. To intercept:
//    - Subclass WKWebView or use a parent NSView that overrides keyDown.
//    - The critical property is NSEvent.isARepeat. When true, drop the event.
//
//    override func keyDown(with event: NSEvent) {
//        // Drop key-repeat events — one physical press = one page turn.
//        guard !event.isARepeat else { return }
//
//        switch event.keyCode {
//        case 124, 125:   // right arrow (124), down arrow (125)
//            paginationEngine.handleKeyDown(.forward)
//        case 123, 126:   // left arrow (123), up arrow (126)
//            paginationEngine.handleKeyDown(.backward)
//        case 49:         // space bar
//            paginationEngine.handleKeyDown(.forward)
//        default:
//            super.keyDown(with: event)
//        }
//    }
//
//    NOTE: WKWebView does not forward keyDown to its superview by default.
//    The cleanest approach is to make the NSWindow's firstResponder the parent
//    NSViewController (not the WKWebView) and call acceptsFirstResponder = true.
//    Alternatively, override keyDown in a WKWebView subclass and forward
//    non-pagination keys up the responder chain via super.keyDown(with:).
//
// 4. RESIZE HANDLING
//    On NSView.setFrameSize or window resize notification:
//    Debounce with ~150ms before calling paginationEngine.reapplyLayout().
//    Do not call on every frame — reapplyLayout reads the current fraction,
//    recomputes geometry, re-injects JS, and restores position.
//
// 5. SCROLLBAR SUPPRESSION
//    After WKWebView is added to the hierarchy:
//        webView.enclosingScrollView?.hasHorizontalScroller = false
//        webView.enclosingScrollView?.hasVerticalScroller   = false
//        webView.enclosingScrollView?.horizontalScrollElasticity = .none
//        webView.enclosingScrollView?.verticalScrollElasticity   = .none
//    JS also sets document.documentElement overflow:hidden but the native
//    scrollview suppression is needed as a belt-and-suspenders.
