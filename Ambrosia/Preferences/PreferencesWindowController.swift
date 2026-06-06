import AppKit
import SwiftUI

// MARK: - PreferencesWindowController

/// Singleton NSWindowController hosting the SwiftUI preferences form.
/// Open via ⌘, or the Ambrosia → Preferences… menu item.
///
/// All changes write directly to ReaderPreferences.shared (UserDefaults-backed).
/// ReaderViewController subscribes to that singleton via Combine and calls
/// reloadHTML() automatically — the preferences window does not need to
/// know about open reader windows.
final class PreferencesWindowController: NSWindowController {

    static let shared = PreferencesWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask:   [.titled, .closable, .miniaturizable],
            backing:     .buffered,
            defer:       false
        )
        window.title   = "Preferences"
        window.minSize = NSSize(width: 460, height: 480)
        window.center()
        window.isReleasedWhenClosed = false   // singleton — keep alive
        super.init(window: window)
        window.contentView = NSHostingView(rootView: PreferencesView())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the preferences window, bringing it to front.
    @MainActor
    static func show() {
        shared.showWindow(nil)
        shared.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - PreferencesView

/// SwiftUI Form presenting all user-configurable reading and library settings.
private struct PreferencesView: View {

    @ObservedObject private var prefs = ReaderPreferences.shared

    // Custom column config — backed by UserDefaults via CustomColumnConfig.shared
    @State private var wordCountLabel: String = CustomColumnConfig.shared.wordCountLabel ?? ""
    @State private var kudosLabel:     String = CustomColumnConfig.shared.kudosLabel ?? ""

    // Available custom columns from the open library (populated on appear)
    @State private var availableColumns: [String] = []

    // Colour pickers need hex-string ↔ NSColor bridging
    @State private var bgColor:   Color = Color(hex: ReaderPreferences.shared.backgroundColor) ?? .white
    @State private var textColor: Color = Color(hex: ReaderPreferences.shared.textColor) ?? .black

    // Common system font families for the picker
    private let fontFamilies: [String] = [
        "Georgia, serif",
        "\"Times New Roman\", Times, serif",
        "Palatino, \"Palatino Linotype\", serif",
        "\"Book Antiqua\", Palatino, serif",
        "-apple-system, sans-serif",
        "Helvetica, Arial, sans-serif",
        "\"SF Pro Text\", -apple-system, sans-serif",
        "Verdana, Geneva, sans-serif",
        "\"Trebuchet MS\", sans-serif",
        "\"Courier New\", Courier, monospace",
        "\"SF Mono\", Menlo, monospace",
    ]

    var body: some View {
        ScrollView {
            Form {
                // ── Reading ──────────────────────────────────────────────────
                Section {
                    Picker("Font family", selection: $prefs.fontFamily) {
                        ForEach(fontFamilies, id: \.self) { family in
                            Text(familyDisplayName(family)).tag(family)
                        }
                    }
                    .onChange(of: prefs.fontFamily) { }  // triggers @Published → Combine

                    HStack {
                        Text("Font size")
                        Spacer()
                        Stepper("\(prefs.fontSize) pt",
                                value: $prefs.fontSize, in: 10...36, step: 1)
                    }

                    HStack {
                        Text("Line height")
                        Spacer()
                        Stepper(String(format: "%.1f", prefs.lineHeight),
                                value: $prefs.lineHeight, in: 1.0...3.0, step: 0.1)
                    }

                    HStack {
                        Text("Max width")
                        Spacer()
                        Stepper("\(prefs.maxWidth) px",
                                value: $prefs.maxWidth, in: 400...1400, step: 20)
                    }

                    HStack {
                        Text("Horizontal padding")
                        Spacer()
                        Stepper("\(prefs.paddingH) px",
                                value: $prefs.paddingH, in: 0...120, step: 4)
                    }

                    HStack {
                        Text("Vertical padding")
                        Spacer()
                        Stepper("\(prefs.paddingV) px",
                                value: $prefs.paddingV, in: 0...120, step: 4)
                    }

                } header: {
                    Label("Reading", systemImage: "text.book.closed")
                        .font(.headline)
                }

                // ── Colours ───────────────────────────────────────────────────
                Section {
                    ColorPicker("Background colour", selection: $bgColor, supportsOpacity: false)
                        .onChange(of: bgColor) {
                            if let hex = bgColor.hexString { prefs.backgroundColor = hex }
                        }

                    ColorPicker("Text colour", selection: $textColor, supportsOpacity: false)
                        .onChange(of: textColor) {
                            if let hex = textColor.hexString { prefs.textColor = hex }
                        }

                    // Preset themes
                    HStack(spacing: 8) {
                        Text("Preset")
                        Spacer()
                        ForEach(Theme.allCases) { theme in
                            Button(theme.label) {
                                applyTheme(theme)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                } header: {
                    Label("Colours", systemImage: "paintbrush")
                        .font(.headline)
                }

                // ── Calibre custom columns ────────────────────────────────────
                Section {
                    if availableColumns.isEmpty {
                        Text("No Calibre library open, or library has no custom columns.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        let colOptions = ["(none)"] + availableColumns

                        Picker("Word count column", selection: $wordCountLabel) {
                            ForEach(colOptions, id: \.self) { Text($0).tag($0) }
                        }
                        .onChange(of: wordCountLabel) {
                            CustomColumnConfig.shared.wordCountLabel =
                                wordCountLabel == "(none)" ? nil : wordCountLabel
                        }

                        Picker("Kudos column", selection: $kudosLabel) {
                            ForEach(colOptions, id: \.self) { Text($0).tag($0) }
                        }
                        .onChange(of: kudosLabel) {
                            CustomColumnConfig.shared.kudosLabel =
                                kudosLabel == "(none)" ? nil : kudosLabel
                        }
                    }
                } header: {
                    Label("Calibre Custom Columns", systemImage: "tablecells")
                        .font(.headline)
                } footer: {
                    Text("These map Calibre custom column labels to word count and kudos fields in the library view.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // ── Reset ─────────────────────────────────────────────────────
                Section {
                    Button("Restore Defaults", role: .destructive) {
                        prefs.resetToDefaults()
                        bgColor   = Color(hex: prefs.backgroundColor) ?? .white
                        textColor = Color(hex: prefs.textColor) ?? .black
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .formStyle(.grouped)
            .padding(8)
        }
        .onAppear { loadAvailableColumns() }
    }

    // MARK: - Helpers

    private func familyDisplayName(_ css: String) -> String {
        // Extract the first font name from the CSS stack, remove quotes
        let first = css.components(separatedBy: ",").first ?? css
        return first.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private func loadAvailableColumns() {
        guard let library = AppDelegate.shared?.session?.library else { return }
        availableColumns = library.customColumns().map(\.label).sorted()
        // Sync picker state with persisted values
        wordCountLabel = CustomColumnConfig.shared.wordCountLabel ?? "(none)"
        kudosLabel     = CustomColumnConfig.shared.kudosLabel ?? "(none)"
    }

    private func applyTheme(_ theme: Theme) {
        prefs.backgroundColor = theme.bg
        prefs.textColor       = theme.fg
        bgColor   = Color(hex: theme.bg) ?? .white
        textColor = Color(hex: theme.fg) ?? .black
    }
}

// MARK: - Themes

private enum Theme: String, CaseIterable, Identifiable {
    case parchment, night, paper, slate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .parchment: return "Parchment"
        case .night:     return "Night"
        case .paper:     return "Paper"
        case .slate:     return "Slate"
        }
    }
    var bg: String {
        switch self {
        case .parchment: return "#FFFDF6"
        case .night:     return "#1C1C1E"
        case .paper:     return "#FFFFFF"
        case .slate:     return "#2C2C2E"
        }
    }
    var fg: String {
        switch self {
        case .parchment: return "#1A1A1A"
        case .night:     return "#E5E5EA"
        case .paper:     return "#111111"
        case .slate:     return "#EBEBF5"
        }
    }
}

// MARK: - Color ↔ hex helpers

private extension Color {
    /// Initialise from a CSS hex string like "#FFFDF6" or "#FFF".
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        if h.count == 3 {
            h = h.map { "\($0)\($0)" }.joined()
        }
        guard h.count == 6,
              let value = UInt64(h, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >>  8) & 0xFF) / 255
        let b = Double( value        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// Returns a 7-character "#RRGGBB" string, or nil if the colour
    /// can't be converted (e.g. dynamic system colours).
    var hexString: String? {
        guard let cgColor = NSColor(self).cgColor.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!,
            intent: .defaultIntent, options: nil),
              let comps = cgColor.components, comps.count >= 3
        else { return nil }
        let r = Int(comps[0] * 255)
        let g = Int(comps[1] * 255)
        let b = Int(comps[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
