import SwiftUI
import AppKit

// MARK: - FilterValueTextField

struct FilterValueTextField: View {

    let placeholder: String
    @Binding var text: String
    let field: FilterField
    let library: CalibreLibrary?
    let onSelect: (String) -> Void

    @State private var suggestions: [String] = []
    @State private var showSuggestions = false
    @State private var fetchTask: Task<Void, Never>? = nil
    /// Most recently selected suggestion value. scheduleFetch skips queries
    /// whose trimmed text equals this, preventing the panel reopening after
    /// a selection even if an in-flight Task delivers results asynchronously.
    @State private var lastSelectedValue: String = ""

    private static let minimumQueryLength = 2
    private static let suggestionLimit    = 7

    var body: some View {
        if supportsAutocomplete {
            autocompleteTextField
        } else {
            plainTextField
        }
    }

    private var plainTextField: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
    }

    private var autocompleteTextField: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            .onChange(of: text, initial: false) { _, newValue in
                scheduleFetch(for: newValue)
            }
            .overlay(alignment: .bottom) {
                SuggestionAnchorView(
                    suggestions: suggestions,
                    showSuggestions: showSuggestions,
                    field: field,
                    onSelect: { selected in
                        fetchTask?.cancel()
                        fetchTask = nil
                        lastSelectedValue = selected
                        showSuggestions = false
                        suggestions = []
                        onSelect(selected)
                    }
                )
                .frame(width: 0, height: 0)
            }
    }

    private var supportsAutocomplete: Bool {
        switch field {
        case .tag, .authorName, .title: return true
        default:                         return false
        }
    }

    private func scheduleFetch(for query: String) {
        fetchTask?.cancel()
        fetchTask = nil

        let trimmed = query.trimmingCharacters(in: .whitespaces)

        if trimmed == lastSelectedValue {
            showSuggestions = false
            suggestions = []
            return
        }

        guard trimmed.count >= Self.minimumQueryLength, let library else {
            if showSuggestions { showSuggestions = false; suggestions = [] }
            return
        }

        let capturedField = field
        let capturedLimit = Self.suggestionLimit

        fetchTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return }
            let results: [String]
            switch capturedField {
            case .tag:        results = await library.tagSuggestions(prefix: trimmed, limit: capturedLimit)
            case .authorName: results = await library.authorSuggestions(prefix: trimmed, limit: capturedLimit)
            case .title:      results = await library.titleSuggestions(prefix: trimmed, limit: capturedLimit)
            default:          results = []
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                suggestions     = results
                showSuggestions = !results.isEmpty
            }
        }
    }
}

// MARK: - SuggestionAnchorView
//
// Zero-size NSViewRepresentable placed at .bottom of the TextField overlay.
// Its NSView superview is the NSHostingView that lays out the TextField —
// so superview.frame converted to screen coordinates gives us the TextField's
// exact on-screen rect, with no GeometryReader coordinate-space conversion
// required.
//
// Coordinate space notes:
//   SwiftUI .global space  : origin top-left of the window content area.
//   NSView/AppKit          : origin bottom-left of the screen, Y up.
//   convertToScreen()      : converts an NSRect in window coords to screen coords.
//
// Prior attempts used geo.frame(in: .global), which returns window-content-area
// coords (not screen coords), so the panel appeared near (0,0) on screen.

private struct SuggestionAnchorView: NSViewRepresentable {

    let suggestions: [String]
    let showSuggestions: Bool
    let field: FilterField
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        if showSuggestions && !suggestions.isEmpty {
            coordinator.show(
                suggestions: suggestions,
                field: field,
                anchorView: nsView,
                onSelect: onSelect
            )
        } else {
            coordinator.hide()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // Only remove the mouse monitor — do NOT call hide() or any AppKit
        // window method here.  dismantleNSView fires during SwiftUI tree
        // teardown, at which point the window hierarchy may be partially
        // released.  Any call through panel.parent or anchorView.window
        // at this point risks a use-after-free trap.
        #if DEBUG
        print("[FilterSuggestions] dismantleNSView — removing mouse monitor only")
        #endif
        coordinator.removeMouseMonitor()
    }

    // MARK: - Coordinator

    final class Coordinator {

        private var panel: NSPanel?
        private var hostingController: NSHostingController<FilterSuggestionListView>?
        private var mouseMonitor: Any?
        private static let panelWidth: CGFloat = 260

        deinit { removeMouseMonitor() }

        func show(
            suggestions: [String],
            field: FilterField,
            anchorView: NSView,
            onSelect: @escaping (String) -> Void
        ) {
            let content = FilterSuggestionListView(
                suggestions: suggestions,
                field: field,
                onSelect: { [weak self] value in
                    #if DEBUG
                    print("[FilterSuggestions] suggestion selected: '\(value)' — hiding panel")
                    #endif
                    self?.hide()
                    onSelect(value)
                }
            )

            if let existing = panel, existing.isVisible, let hc = hostingController {
                hc.rootView = content
                reposition(panel: existing, anchorView: anchorView)
                return
            }

            hide()

            guard let parentWindow = anchorView.window else {
                #if DEBUG
                print("[FilterSuggestions] show: anchorView has no window — aborting")
                #endif
                return
            }

            let hc = NSHostingController(rootView: content)
            hc.view.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200)
            hc.view.layoutSubtreeIfNeeded()
            let fitting = hc.sizeThatFits(in: NSSize(width: Self.panelWidth, height: 500))
            #if DEBUG
            print("[FilterSuggestions] show: fitting size \(fitting), \(suggestions.count) suggestions")
            #endif

            let newPanel = NSPanel(
                contentRect: NSRect(origin: .zero, size: fitting),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.appearance = parentWindow.appearance
            newPanel.contentViewController = hc
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            newPanel.level = .popUpMenu
            hc.view.wantsLayer = true
            hc.view.layer?.backgroundColor = CGColor.clear

            hostingController = hc
            panel = newPanel

            reposition(panel: newPanel, anchorView: anchorView)
            parentWindow.addChildWindow(newPanel, ordered: .above)
            newPanel.orderFront(nil)
            installMouseMonitor(panel: newPanel, anchorView: anchorView)

            // Restore first-responder after orderFront — matches LWC lines 529-532.
            if let fieldEditor = parentWindow.firstResponder as? NSTextView {
                let target: NSResponder = (fieldEditor.delegate as? NSTextField) ?? fieldEditor
                parentWindow.makeFirstResponder(target)
                let len = (fieldEditor.string as NSString).length
                fieldEditor.selectedRange = NSRange(location: len, length: 0)
            }
        }

        func hide() {
            removeMouseMonitor()
            // orderOut is sufficient — AppKit detaches the child relationship
            // automatically.  We never call removeChildWindow to avoid trapping
            // on a partially-released parent window during teardown.
            panel?.orderOut(nil)
            panel = nil
            hostingController = nil
        }

        // MARK: Positioning
        //
        // The anchor NSView is zero-size and embedded via .overlay(alignment: .bottom)
        // on the TextField.  Its superview in the NSView hierarchy is the
        // NSHostingView that hosts the SwiftUI TextField.  That NSHostingView's
        // frame in window coords is exactly the TextField's layout rect.
        //
        // We walk up one level: anchorView.superview → NSHostingView.
        // Then: hostingView.convert(hostingView.bounds, to: nil) → window rect.
        // Then: window.convertToScreen(windowRect) → screen rect (AppKit coords,
        //       origin bottom-left, Y up).
        //
        // The panel top goes at fieldOnScreen.minY (= field's bottom edge in
        // AppKit, because AppKit Y is up): origin.y = fieldOnScreen.minY - height - gap.

        private func reposition(panel: NSPanel, anchorView: NSView) {
            guard let anchorWindow = anchorView.window else {
                #if DEBUG
                print("[FilterSuggestions] reposition: no window")
                #endif
                return
            }

            // Walk up from the zero-size anchor to its hosting superview.
            // superview is the NSHostingView for the TextField overlay content.
            // superview.superview is the NSHostingView for the whole TextField.
            // We want the outermost NSHostingView that spans the TextField.
            // In practice, anchorView.superview.superview gives us the right frame.
            // If the hierarchy is shallower, fall back to anchorView.superview.
            let fieldView: NSView
            if let sv2 = anchorView.superview?.superview {
                fieldView = sv2
            } else if let sv1 = anchorView.superview {
                fieldView = sv1
            } else {
                fieldView = anchorView
            }

            fieldView.layoutSubtreeIfNeeded()
            anchorWindow.layoutIfNeeded()

            let fieldInWindow  = fieldView.convert(fieldView.bounds, to: nil)
            let fieldOnScreen  = anchorWindow.convertToScreen(fieldInWindow)

            #if DEBUG
            print("[FilterSuggestions] reposition: fieldOnScreen=\(fieldOnScreen)")
            #endif

            let fitting: NSSize = hostingController.map {
                $0.sizeThatFits(in: NSSize(width: Self.panelWidth, height: 500))
            } ?? panel.frame.size
            let panelWidth  = max(Self.panelWidth, fieldOnScreen.width)
            let panelHeight = fitting.height

            let screenVisible = anchorWindow.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? fieldOnScreen
            let clampedX = min(
                max(fieldOnScreen.minX, screenVisible.minX),
                max(screenVisible.minX, screenVisible.maxX - panelWidth)
            )
            // fieldOnScreen.minY is the field's bottom edge in AppKit coords (Y up).
            // Place panel top at field bottom, shifted down by gap.
            let originY = fieldOnScreen.minY - panelHeight - 4

            #if DEBUG
            print("[FilterSuggestions] reposition: panel frame x=\(clampedX) y=\(originY) w=\(panelWidth) h=\(panelHeight)")
            #endif

            panel.setFrame(
                NSRect(x: clampedX, y: originY, width: panelWidth, height: panelHeight),
                display: true
            )
        }

        // MARK: Mouse monitor

        private func installMouseMonitor(panel: NSPanel, anchorView: NSView) {
            removeMouseMonitor()
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self, weak panel] event in
                guard let panel else { return event }
                if event.window === panel { return event }
                self?.hide()
                return event
            }
        }

        func removeMouseMonitor() {
            if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        }
    }
}

// MARK: - FilterSuggestionListView

private struct FilterSuggestionListView: View {

    let suggestions: [String]
    let field: FilterField
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, value in
                Button { onSelect(value) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: fieldIcon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .center)
                        Text(value)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                if index < suggestions.count - 1 {
                    Divider().padding(.leading, 32)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
        .padding(4)
    }

    private var fieldIcon: String {
        switch field {
        case .tag:        return "tag"
        case .authorName: return "person"
        case .title:      return "book"
        default:          return "magnifyingglass"
        }
    }
}
