import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PreferencesWindowController

final class PreferencesWindowController: NSWindowController {

    static let shared = PreferencesWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 680),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title   = "Preferences"
        window.minSize = NSSize(width: 540, height: 500)
        window.center()
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.animationBehavior = .documentWindow
        super.init(window: window)
        // `AppDelegate.shared` is set in `AppDelegate.applicationDidFinishLaunching`,
        // which always runs well before `show()` (the only caller of this
        // initializer) can be reached -- so this guard should never trip in
        // practice, but a guard+fatalError documents that invariant and gives
        // a real crash message instead of a silent force-unwrap.
        guard let session = AppDelegate.shared?.session else {
            fatalError("PreferencesWindowController initialized before AppDelegate.shared.session was set")
        }
        window.contentView = NSHostingView(
            rootView: PreferencesRootView().environment(session)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @MainActor
    static func show() {
        shared.showWindow(nil)
        shared.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Root tabbed view

private struct PreferencesRootView: View {
    @ObservedObject private var prefs = ReaderPreferences.shared
    @State private var tab: PrefTab = PrefTab(rawValue: UserDefaults.standard.string(forKey: "lastPreferencesTab") ?? "") ?? .reader

    var body: some View {
        TabView(selection: $tab) {
            ReaderTab()
                .tabItem { Label("Reader", systemImage: "text.book.closed") }
                .tag(PrefTab.reader)

            LibraryTab()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(PrefTab.library)

            DataTab()
                .tabItem { Label("Data", systemImage: "externaldrive") }
                .tag(PrefTab.data)

            RSSTab()
                .tabItem { Label("RSS", systemImage: "dot.radiowaves.left.and.right") }
                .tag(PrefTab.rss)

            ShortcutsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(PrefTab.shortcuts)
        }
        .frame(width: 580)
        // Finding 11c: remember the last-open Preferences tab across launches,
        // the same way state restoration already applies to window position.
        .onChange(of: tab) { _, newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: "lastPreferencesTab")
        }
    }
}

private enum PrefTab: String { case reader, library, data, rss, shortcuts }

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Reader Tab
// ─────────────────────────────────────────────────────────────────────────────

private struct ReaderTab: View {
    @ObservedObject private var prefs = ReaderPreferences.shared
    @Namespace private var a11y

    // Reader colour local state
    @State private var readerBgColor: Color = Color(hex: ReaderPreferences.shared.readerBackgroundColor) ?? .white
    @State private var readerTextColor: Color = Color(hex: ReaderPreferences.shared.readerTextColor) ?? .black
    @State private var isPresentingSaveThemeSheet = false
    @State private var newThemeName = ""

    var body: some View {
        Form {

            // ── Typography ────────────────────────────────────────────────
            Section {
                fontFamilyRow
                stepperRow("Font size", int: $prefs.fontSize, range: 10...36, step: 1, unit: "pt")
                stepperRow("Line height", dbl: $prefs.lineHeight, range: 1.0...3.0, step: 0.1)
                stepperRow("Max line width", int: $prefs.maxWidth, range: 400...1400, step: 20, unit: "px")
                stepperRow("Horizontal padding", int: $prefs.paddingH, range: 0...120, step: 4, unit: "px")
                stepperRow("Vertical padding", int: $prefs.paddingV, range: 0...120, step: 4, unit: "px")
            } header: {
                Label("Typography", systemImage: "textformat").font(.headline)
            }

            // ── Reader colours ────────────────────────────────────────────
            Section {
                ColorPicker("Background", selection: $readerBgColor, supportsOpacity: false)
                    .onChange(of: readerBgColor) { _, newColor in
                        if let hex = newColor.hexString { prefs.readerBackgroundColor = hex }
                    }
                ColorPicker("Text", selection: $readerTextColor, supportsOpacity: false)
                    .onChange(of: readerTextColor) { _, newColor in
                        if let hex = newColor.hexString { prefs.readerTextColor = hex }
                    }
                themePresetRow(
                    onPick: { bg, fg in
                        prefs.readerBackgroundColor = bg
                        prefs.readerTextColor       = fg
                        readerBgColor   = Color(hex: bg) ?? .white
                        readerTextColor = Color(hex: fg) ?? .black
                    }
                )
            } header: {
                Label("Reader Colours", systemImage: "paintbrush").font(.headline)
            }
            .sheet(isPresented: $isPresentingSaveThemeSheet) {
                saveThemeSheet
            }

            // ── Default reading mode ──────────────────────────────────────
            Section {
                Picker("Default reading mode", selection: $prefs.defaultReadingMode) {
                    ForEach(ReadingMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Label("Reading Mode", systemImage: "book.pages").font(.headline)
            }

            // ── Reader cleanup and interaction ───────────────────────────
            Section {
                Toggle("Allow link clicks", isOn: $prefs.allowReaderLinkClicks)
                Toggle("Remove paragraph indents", isOn: $prefs.removeParagraphIndents)
            } header: {
                Label("Reader Content", systemImage: "doc.text.magnifyingglass").font(.headline)
            } footer: {
                Text("Links open in your browser. Paragraph indent cleanup overrides publisher first-line indentation without changing EPUB files.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // ── Find bar ──────────────────────────────────────────────────
            Section {
                Toggle("Automatically open Find bar for full-text search", isOn: $prefs.autoOpenFindBarForFullTextSearch)
            } header: {
                Label("Find", systemImage: "magnifyingglass").font(.headline)
            } footer: {
                Text(
                    "When on, opening a book from a full-text search (or editing that search " +
                    "while the book is open) shows the Find bar and jumps to your search phrase. " +
                    "Turn off to open books without the Find bar appearing automatically."
                )
                    .font(.caption).foregroundStyle(.secondary)
            }

            // ── Preferences update behaviour ──────────────────────────────
            Section {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Open reader windows reload immediately when any preference changes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("When Preferences Change", systemImage: "arrow.clockwise").font(.headline)
            }

            // ── Reset ─────────────────────────────────────────────────────
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults", role: .destructive) {
                        confirmResetReaderDefaults()
                    }
                    .disabled(prefs.isReaderCustomized == false)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
    }

    private func confirmResetReaderDefaults() {
        let alert = NSAlert()
        alert.messageText = "Restore Reader Defaults?"
        alert.informativeText = "Font, spacing, and color settings for the reader will be reset. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        prefs.resetReaderToDefaults()
        readerBgColor   = Color(hex: prefs.readerBackgroundColor) ?? .white
        readerTextColor = Color(hex: prefs.readerTextColor) ?? .black
    }

    // MARK: Font family row

    @ViewBuilder
    private var fontFamilyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Font family")
                Spacer()
                Text("Aa")
                    .font(.custom(prefs.displayFontFamily, size: 15))
                    .foregroundStyle(.secondary)
            }

            // 2-column grid of preset buttons
            let cols = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(ReaderPreferences.fontPresets, id: \.id) { preset in
                    let selected = prefs.fontFamily == preset.cssStack
                    Button { prefs.fontFamily = preset.cssStack } label: {
                        HStack {
                            Text(preset.label)
                                .font(.custom(preset.label, size: 13))
                                .lineLimit(1)
                            Spacer()
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(selected
                                        ? Color.accentColor.opacity(0.12)
                                        : Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(selected
                                            ? Color.accentColor.opacity(0.4)
                                            : Color(nsColor: .separatorColor),
                                        lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("More Fonts…") {
                    NSFontManager.shared.target = FontPanelCoordinator.shared
                    NSFontManager.shared.action = #selector(FontPanelCoordinator.changeFont(_:))
                    NSFontPanel.shared.orderFront(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Live preview
            Text("The quick brown fox jumps over the lazy dog.")
                .font(.custom(prefs.displayFontFamily, size: CGFloat(prefs.fontSize)))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(hex: prefs.readerBackgroundColor) ?? Color(nsColor: .textBackgroundColor))
                .foregroundStyle(Color(hex: prefs.readerTextColor) ?? Color(nsColor: .labelColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
    }

    // MARK: Shared helpers

    @ViewBuilder
    private func themePresetRow(onPick: @escaping (String, String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Preset")
                Spacer()
                ForEach(ReaderTheme.allCases) { theme in
                    Button(theme.label) { onPick(theme.bg, theme.fg) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if !prefs.savedThemes.isEmpty {
                HStack(spacing: 8) {
                    Text("Saved")
                    Spacer()
                    ForEach(prefs.savedThemes) { theme in
                        HStack(spacing: 2) {
                            Button(theme.name) { onPick(theme.bg, theme.fg) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button {
                                confirmDeleteTheme(theme)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete theme \(theme.name)")
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Save as New Theme…") {
                    newThemeName = ""
                    isPresentingSaveThemeSheet = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var saveThemeSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Current Theme")
                .font(.headline)
            TextField("Theme name", text: $newThemeName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresentingSaveThemeSheet = false
                }
                Button("Save") {
                    guard let bg = readerBgColor.hexString, let fg = readerTextColor.hexString else { return }
                    let trimmed = newThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = trimmed.isEmpty ? "Untitled Theme" : trimmed
                    prefs.savedThemes.append(ReaderPreferences.SavedTheme(id: UUID(), name: name, bg: bg, fg: fg))
                    isPresentingSaveThemeSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newThemeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private func confirmDeleteTheme(_ theme: ReaderPreferences.SavedTheme) {
        let alert = NSAlert()
        alert.messageText = "Delete Theme?"
        alert.informativeText = "\"\(theme.name)\" will be permanently deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        prefs.savedThemes.removeAll { $0.id == theme.id }
    }

    @ViewBuilder
    private func stepperRow(_ label: String, int value: Binding<Int>,
                            range: ClosedRange<Int>, step: Int, unit: String) -> some View {
        HStack {
            Text(label)
                .accessibilityLabeledPair(role: .label, id: label, in: a11y)
            Spacer()
            Stepper("\(value.wrappedValue) \(unit)", value: value, in: range, step: step)
                .accessibilityLabeledPair(role: .content, id: label, in: a11y)
        }
    }

    @ViewBuilder
    private func stepperRow(_ label: String, dbl value: Binding<Double>,
                            range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(label)
                .accessibilityLabeledPair(role: .label, id: label, in: a11y)
            Spacer()
            Stepper(String(format: "%.1f", value.wrappedValue), value: value, in: range, step: step)
                .accessibilityLabeledPair(role: .content, id: label, in: a11y)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Library Tab
// ─────────────────────────────────────────────────────────────────────────────

private struct LibraryTab: View {
    @ObservedObject private var prefs = ReaderPreferences.shared
    @Environment(\.colorScheme) private var systemScheme
    @Namespace private var a11y

    // Local colour state for the custom pickers
    @State private var lightBG: Color = Color(hex: ReaderPreferences.shared.libraryLightBackgroundColor) ?? .white
    @State private var lightText: Color = Color(hex: ReaderPreferences.shared.libraryLightTextColor)       ?? .black
    @State private var darkBG: Color = Color(hex: ReaderPreferences.shared.libraryDarkBackgroundColor)  ?? Color(nsColor: .windowBackgroundColor)
    @State private var darkText: Color = Color(hex: ReaderPreferences.shared.libraryDarkTextColor)        ?? Color(nsColor: .labelColor)

    private var effectiveIsDark: Bool {
        switch prefs.libraryAppearanceMode {
        case .system: return systemScheme == .dark
        case .light:  return false
        case .dark:   return true
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show skipped books", isOn: $prefs.showSkippedCollection)
            } header: {
                Label("Skipped Books", systemImage: "eye.slash").font(.headline)
            } footer: {
                Text("When off, skipped books are hidden from the library and the Skipped collection is hidden from collection pickers and menus.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Group series", isOn: $prefs.groupBySeries)
            } header: {
                Label("Series", systemImage: "link").font(.headline)
            } footer: {
                Text("Collapses multi-work series into one library row and hides member books already represented by the series.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hide Fanworks tag pill", isOn: $prefs.hideFanworksTagPill)
                Toggle("Show AO3 books only", isOn: $prefs.hideNonAO3PublisherBooks)
                Toggle("Hide anthology/merged books", isOn: $prefs.hideAnthologyBooks)
                Toggle("Deduplicate books", isOn: $prefs.hideDuplicateBooks)
                Toggle("Show collection pills in email view", isOn: $prefs.emailPillsShowCollections)
            } header: {
                Label("Library Rows", systemImage: "list.bullet.rectangle").font(.headline)
            } footer: {
                Text(
                    "AO3-only mode keeps books whose publisher is exactly Archive of Our Own. " +
                    "\"Hide anthology/merged books\" hides books whose description was written by " +
                    "Calibre's EPUB-merge plugin (starts with \"Anthology containing:\"). " +
                    "\"Deduplicate books\" hides stale copies: when a Calibre duplicate of the same " +
                    "AO3 work exists, keeps only the more recently updated copy (or an arbitrary " +
                    "one if update dates match) and hides the rest from the library, search, " +
                    "series grouping, and feeds. Collection pills apply to email view rows."
                )
                    .font(.caption).foregroundStyle(.secondary)
            }

            // ── Appearance (light / dark / system) ───────────────────────
            Section {
                Picker("Color scheme", selection: $prefs.libraryAppearanceMode) {
                    ForEach(LibraryAppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            } header: {
                Label("Appearance", systemImage: "circle.lefthalf.filled").font(.headline)
            } footer: {
                Text("Controls whether the library uses light or dark appearance, independently of the system setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // ── Background colour ─────────────────────────────────────────
            Section {
                Picker("Mode", selection: $prefs.libraryColorMode) {
                    ForEach(LibraryColorMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                switch prefs.libraryColorMode {
                case .systemDefault:
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text("Uses NSColor.windowBackgroundColor and NSColor.labelColor — adapts automatically to light/dark mode.")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                case .accentColor:
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text("Applies a subtle tint of your system accent color to the library background.")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                case .custom:
                    customColourPairs
                }

            } header: {
                Label("Background Color", systemImage: "paintbrush").font(.headline)
            }

            // ── Live preview ──────────────────────────────────────────────
            Section {
                LibraryPreviewRows(
                    bgColor: resolvedPreviewBG,
                    textColor: resolvedPreviewText,
                    accentMode: prefs.libraryColorMode == .accentColor
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Label("Preview", systemImage: "eye").font(.headline)
            }

            // ── Reset ─────────────────────────────────────────────────────
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults", role: .destructive) {
                        confirmResetLibraryDefaults()
                    }
                    .disabled(prefs.isLibraryCustomized == false)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
        .onAppear {
            syncLocalState()
        }
    }

    private func confirmResetLibraryDefaults() {
        let alert = NSAlert()
        alert.messageText = "Restore Library Defaults?"
        alert.informativeText = "Library appearance, colors, and row visibility settings will be reset. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        prefs.resetLibraryToDefaults()
        syncLocalState()
    }

    // MARK: Custom colour pair rows

    @ViewBuilder
    private var customColourPairs: some View {
        VStack(alignment: .leading, spacing: 12) {
            colourPairRow(
                label: "Light mode",
                bg: $lightBG, text: $lightText,
                onBGChange: { prefs.libraryLightBackgroundColor = $0 },
                onTextChange: { prefs.libraryLightTextColor = $0 }
            )
            Divider()
            colourPairRow(
                label: "Dark mode",
                bg: $darkBG, text: $darkText,
                onBGChange: { prefs.libraryDarkBackgroundColor = $0 },
                onTextChange: { prefs.libraryDarkTextColor = $0 }
            )
            HStack(spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(.secondary).font(.caption)
                Text("The active pair is chosen based on the color scheme setting above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func colourPairRow(
        label: String,
        bg: Binding<Color>, text: Binding<Color>,
        onBGChange: @escaping (String) -> Void,
        onTextChange: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.subheadline)
                .frame(width: 80, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text("Background").font(.caption).foregroundStyle(.tertiary)
                    .accessibilityLabeledPair(role: .label, id: "\(label)-bg", in: a11y)
                ColorPicker("", selection: bg, supportsOpacity: false).labelsHidden()
                    .accessibilityLabel("\(label) mode background color")
                    .accessibilityLabeledPair(role: .content, id: "\(label)-bg", in: a11y)
                    .onChange(of: bg.wrappedValue) { _, newColor in
                        if let hex = newColor.hexString { onBGChange(hex) }
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Text").font(.caption).foregroundStyle(.tertiary)
                    .accessibilityLabeledPair(role: .label, id: "\(label)-text", in: a11y)
                ColorPicker("", selection: text, supportsOpacity: false).labelsHidden()
                    .accessibilityLabel("\(label) mode text color")
                    .accessibilityLabeledPair(role: .content, id: "\(label)-text", in: a11y)
                    .onChange(of: text.wrappedValue) { _, newColor in
                        if let hex = newColor.hexString { onTextChange(hex) }
                    }
            }

            // Mini swatch
            RoundedRectangle(cornerRadius: 6)
                .fill(bg.wrappedValue)
                .frame(width: 64, height: 34)
                .overlay(
                    Text("Aa")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(text.wrappedValue)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
    }

    // MARK: Preview helpers

    private var resolvedPreviewBG: Color {
        switch prefs.libraryColorMode {
        case .systemDefault: return Color(nsColor: .windowBackgroundColor)
        case .accentColor:   return Color(nsColor: .controlAccentColor).opacity(0.08)
        case .custom:        return effectiveIsDark ? darkBG : lightBG
        }
    }

    private var resolvedPreviewText: Color {
        switch prefs.libraryColorMode {
        case .systemDefault, .accentColor: return Color(nsColor: .labelColor)
        case .custom:                      return effectiveIsDark ? darkText : lightText
        }
    }

    private func syncLocalState() {
        lightBG   = Color(hex: prefs.libraryLightBackgroundColor) ?? .white
        lightText = Color(hex: prefs.libraryLightTextColor)       ?? .black
        darkBG    = Color(hex: prefs.libraryDarkBackgroundColor)  ?? Color(nsColor: .windowBackgroundColor)
        darkText  = Color(hex: prefs.libraryDarkTextColor)        ?? Color(nsColor: .labelColor)
    }
}

// MARK: - Library Preview Rows

private struct LibraryPreviewRows: View {
    let bgColor: Color
    let textColor: Color
    let accentMode: Bool

    private let sampleTitles  = ["A Memory Called Empire", "The Left Hand of Darkness", "Piranesi"]
    private let sampleAuthors = ["Arkady Martine", "Ursula K. Le Guin", "Susanna Clarke"]
    private let sampleWidths  = [CGFloat(160), CGFloat(130), CGFloat(145)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { rowIndex in
                HStack(spacing: 10) {
                    // Cover stub
                    RoundedRectangle(cornerRadius: 3)
                        .fill(textColor.opacity(0.12))
                        .frame(width: 30, height: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        // Title stub
                        Capsule().fill(textColor.opacity(0.75))
                            .frame(width: sampleWidths[rowIndex], height: 10)
                        // Author stub
                        Capsule().fill(textColor.opacity(0.4))
                            .frame(width: sampleWidths[rowIndex] * 0.6, height: 8)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    accentMode
                        ? Color(nsColor: .controlAccentColor).opacity(0.08)
                        : bgColor
                )
                if rowIndex < 2 { Divider().padding(.leading, 54) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        .padding(.vertical, 4)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Data Tab
// ─────────────────────────────────────────────────────────────────────────────

/// Summarizes how much of the active library has AO3 metadata, using the
/// same three-set union (`existingAO3MetadataIDs`, `attemptedAO3ExtractionIDs`,
/// `existingBookIndexIDs`) that `LibrarySession.startAO3Extraction` uses to
/// compute what's still missing.
private enum AO3ExtractionStatus {
    case noLibrary
    case running(completed: Int, total: Int)
    case complete(extracted: Int, total: Int)
    case partial(extracted: Int, total: Int, pending: Int)
}

private struct DataTab: View {
    @Environment(LibrarySession.self) private var session
    @ObservedObject private var prefs = ReaderPreferences.shared
    @ObservedObject private var tagSeedConfig = AO3TagSeedDatabaseConfig.shared
    @State private var knownLibraries: [LibraryIndexEntry] = []
    @State private var tagSynonymCacheMessage: String?
    @State private var wordCountLabel: String = CustomColumnConfig.shared.wordCountLabel ?? "(none)"
    @State private var kudosLabel: String = CustomColumnConfig.shared.kudosLabel ?? "(none)"
    @State private var availableColumns: [String] = []
    @State private var ao3ExtractionStatus: AO3ExtractionStatus = .noLibrary

    var body: some View {
        Form {
            Section {
                if knownLibraries.isEmpty {
                    Text("No known libraries")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(knownLibraries) { entry in
                        libraryIndexRow(entry)
                    }
                }
            } header: {
                Label("Libraries", systemImage: "externaldrive").font(.headline)
            }

            Section {
                Toggle("Use AO3 tag synonyms", isOn: $tagSeedConfig.isEnabled)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let path = tagSeedConfig.databasePath, !path.isEmpty {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.callout)
                        } else {
                            Text("No database selected")
                                .font(.callout)
                        }
                        if let path = tagSeedConfig.databasePath, !path.isEmpty {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Button("Choose Database…") {
                        chooseTagSeedDatabase()
                    }
                    .controlSize(.small)
                }

                tagSeedStatusView

                Button("Clear imported synonym cache") {
                    clearTagSynonymCache()
                }
                .disabled(AppDelegate.shared?.session?.metaDB == nil)

                if let tagSynonymCacheMessage {
                    Text(tagSynonymCacheMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Tag Synonyms", systemImage: "tag").font(.headline)
            } footer: {
                Text("Uses an external ao3_tag_seeds.db. When off or invalid, tag search uses the Calibre tags already in the library.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Re-extract AO3 metadata") {
                        confirmReextract()
                    }
                    .disabled(AppDelegate.shared?.session?.isOpen != true)
                    Spacer()
                }
                ao3ExtractionStatusView
            } header: {
                Label("AO3 Metadata", systemImage: "text.magnifyingglass").font(.headline)
            } footer: {
                Text("Clears extracted AO3 metadata and series cache for the active library, then scans EPUB header pages again in the background.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if availableColumns.isEmpty {
                    Text("Open a Calibre library to see available custom columns.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    let opts = ["(none)"] + availableColumns
                    Picker("Word count column", selection: $wordCountLabel) {
                        ForEach(opts, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: wordCountLabel) { _, newLabel in
                        CustomColumnConfig.shared.wordCountLabel = newLabel == "(none)" ? nil : newLabel
                    }
                    Picker("Kudos column", selection: $kudosLabel) {
                        ForEach(opts, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: kudosLabel) { _, newLabel in
                        CustomColumnConfig.shared.kudosLabel = newLabel == "(none)" ? nil : newLabel
                    }
                }
            } header: {
                Label("Columns", systemImage: "tablecells").font(.headline)
            } footer: {
                Text("Maps Calibre custom column labels to word count and kudos. Labels are case-sensitive.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Fix garbled ampersands (&amp;) from Calibre", isOn: $prefs.correctCalibreAmpEntities)
            } header: {
                Label("Calibre Display Cleanup", systemImage: "wand.and.stars").font(.headline)
            } footer: {
                Text(
                    "Calibre sometimes stores &amp; instead of & in titles and descriptions; " +
                    "turn this on to display it correctly. Applies to displayed titles and " +
                    "descriptions only — stored Calibre metadata is not changed."
                )
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
        .onAppear {
            reloadKnownLibraries()
            tagSeedConfig.refreshValidation()
            Task { await loadAvailableColumns() }
            Task { await reloadAO3ExtractionStatus() }
            scheduleObservingExtraction()
        }
    }

    @ViewBuilder
    private var ao3ExtractionStatusView: some View {
        switch ao3ExtractionStatus {
        case .noLibrary:
            Label("Open a library to see extraction status.", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        case .running(let completed, let total):
            Label("Enriching library \(completed)/\(total)…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .complete(let extracted, let total):
            Label("\(extracted) of \(total) books have AO3 metadata", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .partial(let extracted, let total, let pending):
            Label("\(extracted) of \(total) books have AO3 metadata — \(pending) not yet processed",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var tagSeedStatusView: some View {
        switch tagSeedConfig.validationStatus {
        case .disabled:
            Label("Synonym matching is off.", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        case .notConfigured:
            Label("Choose an ao3_tag_seeds.db file to enable synonym matching.", systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        case .valid(let counts):
            Label(
                "\(counts.canonicalTags) canonical tags, \(counts.synonyms) synonyms, \(counts.hierarchyEdges) hierarchy edges",
                systemImage: "checkmark.circle"
            )
            .foregroundStyle(.green)
        case .invalid(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func libraryIndexRow(_ entry: LibraryIndexEntry) -> some View {
        let reachable = FileManager.default.fileExists(atPath: entry.lastKnownPath)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: reachable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(reachable ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.callout.weight(.medium))
                Text(entry.lastKnownPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Last opened \(entry.lastOpened)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !reachable {
                Button("Re-link…") {
                    relink(entry)
                }
                .controlSize(.small)
            }
        }
    }

    private func reloadKnownLibraries() {
        knownLibraries = LibraryIndexManager.shared.entries()
    }

    private func relink(_ entry: LibraryIndexEntry) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the new location for \(entry.displayName)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LibraryIndexManager.shared.relink(oldHash: entry.hash, newLibraryURL: url)
            reloadKnownLibraries()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could Not Re-link Library"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func chooseTagSeedDatabase() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
        panel.message = "Choose ao3_tag_seeds.db"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tagSeedConfig.chooseDatabase(url: url)
    }

    private func clearTagSynonymCache() {
        tagSynonymCacheMessage = nil
        guard let metaDB = AppDelegate.shared?.session?.metaDB else { return }
        Task {
            do {
                try await metaDB.clearAO3TagSynonymCacheAndReloadSeeds()
                tagSynonymCacheMessage = "Imported synonym cache cleared."
            } catch {
                tagSynonymCacheMessage = error.localizedDescription
            }
        }
    }

    private func loadAvailableColumns() async {
        guard let library = AppDelegate.shared?.session?.library else { return }
        availableColumns = await library.customColumns().map(\.label).sorted()
        wordCountLabel = CustomColumnConfig.shared.wordCountLabel ?? "(none)"
        kudosLabel = CustomColumnConfig.shared.kudosLabel ?? "(none)"
    }

    /// Recomputes the persistent extracted/total/pending counts. Called once
    /// on appear, and again whenever `extractionProgress.isRunning` flips
    /// back to false (a run just finished) — the same trigger the toolbar's
    /// fic-count label uses to snap back from `statusText` to a plain count.
    private func reloadAO3ExtractionStatus() async {
        guard let library = session.library, let metaDB = session.metaDB else {
            ao3ExtractionStatus = .noLibrary
            return
        }
        let allIDs = await library.allBookIDs()
        let extracted = (try? await metaDB.existingAO3MetadataIDs()) ?? []
        let attempted = (try? await metaDB.attemptedAO3ExtractionIDs()) ?? []
        let indexed = (try? await metaDB.existingBookIndexIDs()) ?? []
        let processed = extracted.union(attempted).union(indexed)
        let pending = allIDs.filter { !processed.contains($0) }.count
        let total = allIDs.count
        ao3ExtractionStatus = pending == 0
            ? .complete(extracted: extracted.count, total: total)
            : .partial(extracted: extracted.count, total: total, pending: pending)
    }

    /// Mirrors `LibraryWindowController.scheduleCounting()`: re-observes
    /// `extractionProgress` after every change so the status row updates
    /// live while a run is in progress, rather than only refreshing on tab
    /// re-open.
    private func scheduleObservingExtraction() {
        withObservationTracking {
            _ = session.extractionProgress.completed
            _ = session.extractionProgress.total
            _ = session.extractionProgress.isRunning
        } onChange: {
            Task { @MainActor in
                if session.extractionProgress.isRunning {
                    ao3ExtractionStatus = .running(
                        completed: session.extractionProgress.completed,
                        total: session.extractionProgress.total
                    )
                } else {
                    await reloadAO3ExtractionStatus()
                }
                scheduleObservingExtraction()
            }
        }
    }

    private func confirmReextract() {
        let alert = NSAlert()
        alert.messageText = "Re-extract AO3 Metadata?"
        alert.informativeText = "Existing extracted AO3 metadata and series cache rows for the active library will be deleted and rebuilt."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Re-extract")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AppDelegate.shared?.session?.reextractAO3Metadata()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - RSS Tab
// ─────────────────────────────────────────────────────────────────────────────

private struct RSSTab: View {
    @ObservedObject private var prefs = ReaderPreferences.shared
    @State private var rssCollections: [(id: String, name: String)] = []

    var body: some View {
        Form {
            Section {
                Toggle("Enable Daily Story feed", isOn: $prefs.feedServerEnableDailyStory)

                Toggle("Restart automatically when I reopen this library",
                       isOn: $prefs.feedServerAutoRestart)

                Text("""
                    Starting the feed server makes your library reachable by \
                    any device on your local network. Feeds are \
                    unauthenticated — anyone on the network who knows or \
                    guesses a feed URL can read it. The restart option above \
                    takes effect next time you start the server.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if rssCollections.isEmpty {
                    Text(rssCollections.isEmpty && AppDelegate.shared?.session?.isOpen == true
                            ? "No collections in the current library."
                            : "Open a library to configure per-collection publishing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Excluded collections are not served or listed in OPML:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(rssCollections, id: \.id) { col in
                        Toggle(col.name, isOn: Binding(
                            get: { !prefs.feedServerExcludedCollectionIDs.contains(col.id) },
                            set: { enabled in
                                if enabled {
                                    prefs.feedServerExcludedCollectionIDs.remove(col.id)
                                } else {
                                    prefs.feedServerExcludedCollectionIDs.insert(col.id)
                                }
                            }
                        ))
                    }
                }
            } header: {
                Label("RSS Feeds", systemImage: "dot.radiowaves.left.and.right").font(.headline)
            } footer: {
                Text("Daily Story serves one random book per day. Excluded collections return 404 to feed readers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
        .onAppear {
            loadRSSCollections()
        }
    }

    private func loadRSSCollections() {
        guard let store = AppDelegate.shared?.session?.collectionStore else { return }
        Task { @MainActor in
            let rows = (try? await store.collections()) ?? []
            rssCollections = rows.map { ($0.id, $0.name) }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Themes
// ─────────────────────────────────────────────────────────────────────────────

private enum ReaderTheme: String, CaseIterable, Identifiable {
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

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shortcuts Tab
// ─────────────────────────────────────────────────────────────────────────────

private struct ShortcutsTab: View {
    @ObservedObject private var prefs = ReaderPreferences.shared
    @State private var rejectionMessages: [RebindableAction: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(RebindableAction.allCases, id: \.self) { action in
                    shortcutRow(for: action)
                }
            } header: {
                Label("Reader Shortcuts", systemImage: "keyboard").font(.headline)
            } footer: {
                Text("Click a shortcut to record a new one. Cmd+C/V/X/Z, Cmd+Shift+Z, Cmd+, and Cmd+O are reserved and can't be reassigned.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults", role: .destructive) {
                        prefs.resetReaderShortcutsToDefaults()
                        rejectionMessages = [:]
                    }
                    .disabled(prefs.keyBindings == ReaderPreferences.defaultKeyBindingsForReset)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func shortcutRow(for action: RebindableAction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(action.displayName)
                Spacer()
                ShortcutRecorderView(
                    currentBinding: prefs.keyBindings[action],
                    onRecord: { candidate in
                        let result = validate(candidate, for: action, against: prefs.keyBindings)
                        if result.isValid {
                            prefs.keyBindings[action] = candidate
                            rejectionMessages[action] = nil
                        } else {
                            rejectionMessages[action] = result.rejectionMessage
                        }
                    }
                )
                .fixedSize()
                .accessibilityLabel("Record shortcut for \(action.displayName)")
                .accessibilityValue(prefs.keyBindings[action]?.displayString ?? "No shortcut")
            }
            if let message = rejectionMessages[action] {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// A "click to record" control backed by a local NSEvent key-down monitor
/// while focused. Captures the next keystroke, hands it to the caller for
/// validation, and displays either the current binding or "Recording…"/an
/// unbound placeholder. This is a bespoke NSViewRepresentable, so SwiftUI
/// does not auto-infer accessibility labels for it — callers must add
/// `.accessibilityLabel`/`.accessibilityValue` themselves (see shortcutRow
/// above), per the design plan's accessibility requirement.
struct ShortcutRecorderView: NSViewRepresentable {
    var currentBinding: KeyBinding?
    var onRecord: (KeyBinding) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onRecord = onRecord
        button.updateTitle(binding: currentBinding)
        return button
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.onRecord = onRecord
        nsView.updateTitle(binding: currentBinding)
    }

    final class RecorderButton: NSButton {
        var onRecord: ((KeyBinding) -> Void)?
        private var monitor: Any?
        private var isRecording = false

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            target = self
            action = #selector(startRecording)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        func updateTitle(binding: KeyBinding?) {
            guard !isRecording else { return }
            title = binding?.displayString ?? "Click to set"
        }

        @objc private func startRecording() {
            guard !isRecording else { return }
            isRecording = true
            title = "Recording…"
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                self.stopRecording(with: event)
                return nil
            }
        }

        private func stopRecording(with event: NSEvent) {
            isRecording = false
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard let character = event.charactersIgnoringModifiers?.lowercased(), !character.isEmpty else {
                title = "Click to set"
                return
            }
            var modifiers: Set<ModifierKey> = []
            if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
            if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
            if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
            let binding = KeyBinding(character: character, modifiers: modifiers)
            onRecord?(binding)
        }
    }
}

extension Color {
    init?(hex: String) {
        var normalized = hex.trimmingCharacters(in: .whitespaces)
        if normalized.hasPrefix("#") { normalized = String(normalized.dropFirst()) }
        if normalized.count == 3 { normalized = normalized.map { "\($0)\($0)" }.joined() }
        guard normalized.count == 6, let value = UInt64(normalized, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >>  8) & 0xFF) / 255,
            blue: Double( value        & 0xFF) / 255
        )
    }

    var hexString: String? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = NSColor(self).cgColor.converted(
                to: sRGB,
                intent: .defaultIntent, options: nil),
              let components = cg.components, components.count >= 3 else { return nil }
        return String(format: "#%02X%02X%02X", Int(components[0]*255), Int(components[1]*255), Int(components[2]*255))
    }
}
