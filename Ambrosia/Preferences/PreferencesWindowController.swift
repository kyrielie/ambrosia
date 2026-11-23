import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PreferencesTabViewController

final class PreferencesTabViewController: NSTabViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar
        canPropagateSelectedChildViewControllerTitle = false
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let identifier = tabViewItem?.identifier as? String {
            UserDefaults.standard.set(identifier, forKey: "lastPreferencesTab")
        }
    }
}

// MARK: - PreferencesWindowController

final class PreferencesWindowController: NSWindowController {

    static let shared = PreferencesWindowController()

    private init() {
        // `AppDelegate.shared` is set in `AppDelegate.applicationDidFinishLaunching`,
        // which always runs well before `show()` (the only caller of this
        // initializer) can be reached -- so this guard should never trip in
        // practice, but a guard+fatalError documents that invariant and gives
        // a real crash message instead of a silent force-unwrap.
        guard let session = AppDelegate.shared?.session else {
            fatalError("PreferencesWindowController initialized before AppDelegate.shared.session was set")
        }

        let tabVC = PreferencesTabViewController()
        tabVC.tabStyle = .toolbar

        let tabs: [(id: PrefTab, label: String, icon: String, view: AnyView)] = [
            (.reader, "Reader", "text.book.closed", AnyView(ReaderTab().environment(session).frame(width: 720).preventInitialButtonFocus())),
            (.library, "Library", "books.vertical", AnyView(LibraryTab().environment(session).frame(width: 720).preventInitialButtonFocus())),
            (.data, "Data", "externaldrive", AnyView(DataTab().environment(session).frame(width: 720).preventInitialButtonFocus())),
            (.rss, "RSS", "dot.radiowaves.left.and.right", AnyView(RSSTab().environment(session).frame(width: 720).preventInitialButtonFocus())),
            (.shortcuts, "Shortcuts", "keyboard", AnyView(ShortcutsTab().environment(session).frame(width: 720).preventInitialButtonFocus())),
            (.docs, "Documentation", "book.pages", AnyView(DocsTab().environment(session).frame(width: 720).preventInitialButtonFocus()))
        ]

        for (id, label, icon, view) in tabs {
            let hosting = NSHostingController(rootView: view)
            let item = NSTabViewItem(viewController: hosting)
            item.identifier = id.rawValue
            item.label = label
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)
            tabVC.addTabViewItem(item)
        }

        let savedTab = UserDefaults.standard.string(forKey: "lastPreferencesTab") ?? PrefTab.reader.rawValue
        if let index = tabs.firstIndex(where: { $0.id.rawValue == savedTab }) {
            tabVC.selectedTabViewItemIndex = index
        }

        let window = NSWindow(contentViewController: tabVC)
        window.title   = "Preferences"
        window.minSize = NSSize(width: 700, height: 500)
        window.setContentSize(NSSize(width: 720, height: 680))
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.toolbarStyle = .preference
        window.animationBehavior = .documentWindow
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @MainActor
    static func show() {
        shared.showWindow(nil)
        shared.window?.makeKeyAndOrderFront(nil)
        shared.window?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum PrefTab: String { case reader, library, data, rss, shortcuts, docs }

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Reader Tab
// ─────────────────────────────────────────────────────────────────────────────

private struct ReaderTab: View {
    @Bindable private var prefs = ReaderPreferences.shared
    @Namespace private var a11y

    // Reader colour local state
    @State private var readerBgColor: Color = Color(hex: ReaderPreferences.shared.readerBackgroundColor) ?? .white
    @State private var readerTextColor: Color = Color(hex: ReaderPreferences.shared.readerTextColor) ?? .black
    @State private var isPresentingSaveThemeSheet = false
    @State private var newThemeName = ""

    var body: some View {
        Form {

            // ── Reader Application ────────────────────────────────────────
            Section {
                Picker("Open EPUBs in", selection: $prefs.preferredReader) {
                    ForEach(PreferredReaderOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)

                if prefs.preferredReader == .customApp {
                    HStack {
                        Text(prefs.customReaderAppName.isEmpty ? "No application chosen" : prefs.customReaderAppName)
                            .foregroundStyle(prefs.customReaderAppName.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button("Choose…") {
                            chooseCustomReaderApp()
                        }
                    }
                }
            } header: {
                Label("Reader Application", systemImage: "app.badge").font(.headline)
            } footer: {
                Text(
                    "Choose whether double-clicking a work opens it in Ambrosia's built-in reader " +
                    "(tailored to AO3 EPUBs), your system default reader, or a custom application."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            // ── Typography ────────────────────────────────────────────────
            Section {
                fontFamilyRow
                sliderRow(
                    "Font size",
                    int: $prefs.fontSize,
                    range: 10...36,
                    step: 1,
                    unit: "pt",
                    defaultValue: ReaderPreferences.defaultFontSize
                )
                sliderRow(
                    "Line height",
                    dbl: $prefs.lineHeight,
                    range: 1.0...3.0,
                    step: 0.1,
                    unit: "em",
                    defaultValue: ReaderPreferences.defaultLineHeight
                )
                Picker("Text alignment", selection: $prefs.textAlignment) {
                    ForEach(ThemeTextAlignment.allCases) { align in
                        Text(align.label).tag(align)
                    }
                }
                .pickerStyle(.menu)

                Picker("Paragraph indent", selection: $prefs.paragraphIndentMode) {
                    ForEach(ParagraphIndentMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                let isIndentEnabled = prefs.paragraphIndentMode == .indented
                let indentDisabledText = prefs.paragraphIndentMode == .bookDefault ? "Book" : "None"
                let indentBinding = Binding<Double>(
                    get: { prefs.paragraphIndent ?? 1.5 },
                    set: { prefs.paragraphIndent = $0 }
                )
                sliderRow(
                    "Indent size",
                    dbl: indentBinding,
                    range: 0.25...3.0,
                    step: 0.25,
                    fractionDigits: 2,
                    unit: "em",
                    disabledText: indentDisabledText,
                    isEnabled: isIndentEnabled,
                    defaultValue: ReaderPreferences.defaultParagraphIndent
                )
                sliderRow(
                    "Max line width",
                    int: $prefs.maxWidth,
                    range: 400...1400,
                    step: 20,
                    unit: "px",
                    defaultValue: ReaderPreferences.defaultMaxWidth
                )
                sliderRow(
                    "Horizontal padding",
                    int: $prefs.paddingH,
                    range: 0...120,
                    step: 4,
                    unit: "px",
                    defaultValue: ReaderPreferences.defaultPaddingH
                )
                sliderRow(
                    "Vertical padding",
                    int: $prefs.paddingV,
                    range: 0...120,
                    step: 4,
                    unit: "px",
                    defaultValue: ReaderPreferences.defaultPaddingV
                )

                // Live typography preview placed below controls
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
            } header: {
                Label("Typography", systemImage: "textformat").font(.headline)
            }

            // ── Reader colours ────────────────────────────────────────────
            Section {
                Picker("Appearance mode", selection: $prefs.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
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

            // ── AO3 Work Presentation ─────────────────────────────────────
            Section {
                Picker("Layout order", selection: $prefs.ao3WorkLayoutOrder) {
                    ForEach(AO3WorkLayoutOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
            } header: {
                Label("AO3 Work Presentation", systemImage: "text.badge.star").font(.headline)
            } footer: {
                Text("Choose whether to display tags before title (AO3 web order), title first, or the original AO3 EPUB order.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // ── Reader cleanup and interaction ───────────────────────────
            Section {
                Toggle("Allow link clicks", isOn: $prefs.allowReaderLinkClicks)
                Toggle("Trim leading whitespace used as indents", isOn: $prefs.removeParagraphIndents)
                Toggle("Collapse empty spacer paragraphs", isOn: $prefs.collapseSpacerParagraphs)
            } header: {
                Label("Reader Content", systemImage: "doc.text.magnifyingglass").font(.headline)
            } footer: {
                Text(
                    "Links open in your browser. " +
                    "Trimming removes spaces some converters use as fake first-line indents (use Paragraph indent for the real gap). " +
                    "Collapsing spacer paragraphs removes the blank lines some converters insert between paragraphs. " +
                    "Neither changes EPUB files."
                )
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

    private func chooseCustomReaderApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.message = "Select an EPUB reader application"
        if panel.runModal() == .OK, let url = panel.url {
            prefs.customReaderAppPath = url.path
        }
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
    private func sliderRow(
        _ label: String,
        int value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        unit: String,
        defaultValue: Int? = nil
    ) -> some View {
        HStack {
            Text(label)
                .accessibilityLabeledPair(role: .label, id: label, in: a11y)
            Spacer()
            TypographySliderControl(
                value: value,
                range: range,
                step: step,
                unit: unit,
                defaultValue: defaultValue.map(Double.init),
                accessibilityLabel: label
            )
            .frame(width: 480)
            .accessibilityLabeledPair(role: .content, id: label, in: a11y)
        }
    }

    @ViewBuilder
    private func sliderRow(
        _ label: String,
        dbl value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        fractionDigits: Int = 1,
        unit: String = "",
        disabledText: String? = nil,
        isEnabled: Bool = true,
        defaultValue: Double? = nil
    ) -> some View {
        HStack {
            Text(label)
                .accessibilityLabeledPair(role: .label, id: label, in: a11y)
            Spacer()
            TypographySliderControl(
                value: value,
                range: range,
                step: step,
                fractionDigits: fractionDigits,
                unit: unit,
                disabledText: disabledText,
                isEnabled: isEnabled,
                defaultValue: defaultValue,
                accessibilityLabel: label
            )
            .frame(width: 480)
            .accessibilityLabeledPair(role: .content, id: label, in: a11y)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Library Tab
// ─────────────────────────────────────────────────────────────────────────────

private struct LibraryTab: View {
    @Bindable private var prefs = ReaderPreferences.shared
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
                Toggle("Default searches to relevance descending", isOn: $prefs.defaultSearchSortToRelevance)
            } header: {
                Label("Search Sorting", systemImage: "arrow.up.arrow.down.circle").font(.headline)
            } footer: {
                Text(
                    "When enabled, performing a search automatically sorts results by relevance descending " +
                    "(highest match score first) and restores your previous sort order when the search is cleared."
                )
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
                if prefs.hideDuplicateBooks {
                    Button("Manage Duplicate Works…") {
                        AppDelegate.shared?.libraryWindowController?.toolbarStateForCommands?.showDuplicateManager = true
                    }
                    .controlSize(.small)
                }
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

            Section {
                HStack {
                    Text("Export Mode")
                    Spacer()
                    Text("Direct Copy (Archival)")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            } header: {
                Label("EPUB Export", systemImage: "square.and.arrow.up").font(.headline)
            } footer: {
                Text(
                    "Directly copies original EPUBs 1:1 preserving series organization and metadata. " +
                    "To normalize exported EPUBs into modern EPUB 3 packages, use the decoupled " +
                    "scripts/modernize_epubs.py command line tool."
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

private enum StorageScope: String, CaseIterable, Identifiable {
    case active
    case all

    var id: String { rawValue }
}

private struct DataTab: View {
    @Environment(LibrarySession.self) private var session
    @Bindable private var prefs = ReaderPreferences.shared
    @Bindable private var tagSeedConfig = AO3TagSeedDatabaseConfig.shared
    @State private var knownLibraries: [LibraryIndexEntry] = []
    @State private var tagSynonymCacheMessage: String?
    @State private var wordCountLabel: String = CustomColumnConfig.shared.wordCountLabel ?? "(none)"
    @State private var kudosLabel: String = CustomColumnConfig.shared.kudosLabel ?? "(none)"
    @State private var availableColumns: [String] = []
    @State private var ao3ExtractionStatus: AO3ExtractionStatus = .noLibrary
    @State private var storageBreakdown: LibraryStorageBreakdown?
    @State private var isCalculatingStorage: Bool = false
    @State private var isIndexingFTS: Bool = false
    @State private var ftsActionMessage: String?
    @State private var semanticIndexMessage: String?
    @State private var isIndexingSemantic: Bool = false
    @State private var semanticProgressCompleted: Int = 0
    @State private var semanticProgressTotal: Int = 0
    @State private var semanticIndexedCount: Int = 0
    @State private var semanticStorageBytes: Int64 = 0
    @State private var passageDBStatus: PassageDatabaseStatus?
    @State private var isQueryModelAvailable: Bool = false
    @State private var passageActionMessage: String?
    @State private var showClearPassageConfirmation: Bool = false
    @State private var libraryFootprints: [String: LibraryStorageBreakdown] = [:]
    @State private var showDiagnosticsSheet: Bool = false
    @State private var storageScope: StorageScope = .active

    private var totalAllLibrariesFootprint: LibraryStorageBreakdown? {
        guard !libraryFootprints.isEmpty else { return nil }
        return LibraryStorageBreakdown.combining(Array(libraryFootprints.values))
    }

    private var activeScopeLabel: String {
        let activeHash = session.activeURL.map { Ambrosia.libraryHash(for: $0) }
        if let entry = knownLibraries.first(where: {
            $0.lastKnownPath == session.activePath || (activeHash != nil && $0.hash == activeHash)
        }) {
            return "Active (\(entry.displayName))"
        }
        return "Active Library"
    }

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

                HStack {
                    Button {
                        AppDelegate.shared?.chooseLibraryFolder()
                    } label: {
                        Label("Open Library…", systemImage: "folder.badge.plus")
                    }

                    if knownLibraries.contains(where: { !FileManager.default.fileExists(atPath: $0.lastKnownPath) }) {
                        Spacer()
                        Button("Remove Missing…") {
                            removeMissingLibraries()
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Label("Libraries", systemImage: "externaldrive").font(.headline)
            }

            Section {
                if knownLibraries.count > 1 {
                    Picker("Scope", selection: $storageScope) {
                        Text(activeScopeLabel).tag(StorageScope.active)
                        Text("All Libraries (\(knownLibraries.count))").tag(StorageScope.all)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.bottom, 2)
                }

                switch storageScope {
                case .active:
                    if let breakdown = storageBreakdown {
                        storageBreakdownView(breakdown, scope: .active)
                    } else if isCalculatingStorage {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Calculating storage footprint…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No library open to calculate storage.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                case .all:
                    if let breakdown = totalAllLibrariesFootprint {
                        storageBreakdownView(breakdown, scope: .all)
                    } else if knownLibraries.isEmpty {
                        Text("No known libraries to calculate storage.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Calculating total storage across libraries…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let ftsActionMessage {
                    HStack(spacing: 6) {
                        if DatabaseMaintenanceCoordinator.shared.isMaintenanceInProgress {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(ftsActionMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Storage Footprint", systemImage: "internaldrive").font(.headline)
            } footer: {
                Text(
                    "Full-text search indexes every chapter word for typographic search cards and multi-snippets, " +
                    "which commonly exceeds the compressed EPUB file size."
                )
                .font(.caption).foregroundStyle(.secondary)
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

                    Button("View Diagnostics…") {
                        showDiagnosticsSheet = true
                    }
                    .disabled(AppDelegate.shared?.session?.isOpen != true)
                    .controlSize(.small)
                }
                ao3ExtractionStatusView
            } header: {
                Label("AO3 Metadata", systemImage: "text.magnifyingglass").font(.headline)
            } footer: {
                Text("Clears extracted AO3 metadata and series cache for the active library, then scans EPUB header pages again in the background.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if AppDelegate.shared?.session?.isOpen != true {
                    Text("Open a library to configure custom columns.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if availableColumns.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No custom columns found in this library.")
                            .font(.callout)
                        Text("Ambrosia calculates word counts and extracts AO3 kudos directly from EPUB files, so Calibre custom columns are optional.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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

            Section {
                Toggle("Enable Calibre full-text search", isOn: $prefs.enableFullTextSearch)
                Toggle("Automatically open Find bar in Reader", isOn: $prefs.autoOpenFindBarForFullTextSearch)
                Toggle("Default searches to relevance descending", isOn: $prefs.defaultSearchSortToRelevance)

                if session.isOpen {
                    HStack {
                        Text("Calibre FTS Database")
                        Spacer()
                        Text(session.hasFulltextIndex ? "Available" : "Not Found")
                            .foregroundStyle(session.hasFulltextIndex ? Color.secondary : Color.orange)
                    }
                    .font(.callout)

                    if prefs.enableFullTextSearch {
                        HStack {
                            Button(DatabaseMaintenanceCoordinator.shared.isIndexingFTS
                                ? "Indexing…"
                                : (session.hasFulltextIndex ? "Index Unindexed Works" : "Build Full-Text Search Index")) {
                                indexUnindexedBooks()
                            }
                            .disabled(!session.isOpen || DatabaseMaintenanceCoordinator.shared.isMaintenanceInProgress)
                            .controlSize(.small)

                            if session.hasFulltextIndex {
                                Button("Clear Index") {
                                    clearFTSIndex()
                                }
                                .disabled(!session.isOpen || DatabaseMaintenanceCoordinator.shared.isMaintenanceInProgress)
                                .controlSize(.small)
                            }

                            Spacer()

                            if let ftsActionMessage {
                                HStack(spacing: 6) {
                                    if DatabaseMaintenanceCoordinator.shared.isMaintenanceInProgress {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                    Text(ftsActionMessage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Label("Full-Text Search (FTS)", systemImage: "doc.text.magnifyingglass").font(.headline)
            } footer: {
                Text(
                    "Searches book body text using Calibre's SQLite FTS5 index. When disabled or unavailable, " +
                    "the toolbar search button is hidden. Building the index is strictly opt-in."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Enable on-device semantic search", isOn: $prefs.enableSemanticSearch)

                HStack {
                    Text("Embedding Engine")
                    Spacer()
                    Text("Apple NaturalLanguage (384-dim)")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                if session.isOpen {
                    HStack {
                        Text("Vector Index Status")
                        Spacer()
                        if isIndexingSemantic {
                            Text("Indexing (\(semanticProgressCompleted)/\(semanticProgressTotal))…")
                                .foregroundStyle(.secondary)
                        } else if semanticIndexedCount > 0 {
                            let sizeStr = ByteCountFormatter.string(fromByteCount: semanticStorageBytes, countStyle: .file)
                            if semanticIndexedCount >= session.totalCount && session.totalCount > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("\(semanticIndexedCount) works indexed (\(sizeStr))")
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.orange)
                                    Text("\(semanticIndexedCount) of \(session.totalCount) works indexed (\(sizeStr))")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text("Not Indexed (0 of \(session.totalCount) works)")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.callout)

                    if isIndexingSemantic {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: Double(semanticProgressCompleted), total: Double(max(1, semanticProgressTotal)))
                            HStack {
                                Text("Generating embeddings on Neural Engine…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(semanticProgressCompleted) / \(semanticProgressTotal)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if prefs.enableSemanticSearch {
                        HStack {
                            if semanticIndexedCount < session.totalCount && !isIndexingSemantic {
                                Button(semanticIndexedCount == 0 ? "Build Semantic Index" : "Index Unindexed Works") {
                                    indexSemanticWorks(incremental: semanticIndexedCount > 0)
                                }
                                .controlSize(.small)
                            }

                            Button("Rebuild Index") {
                                indexSemanticWorks(incremental: false)
                            }
                            .disabled(!session.isOpen || isIndexingSemantic)
                            .controlSize(.small)

                            if semanticIndexedCount > 0 {
                                Button("Clear Index") {
                                    clearSemanticIndex()
                                }
                                .disabled(!session.isOpen || isIndexingSemantic)
                                .controlSize(.small)
                            }

                            Spacer()

                            if let semanticIndexMessage {
                                Text(semanticIndexMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Label("Semantic Search", systemImage: "sparkles").font(.headline)
            } footer: {
                Text(
                    "Synthesizes work profiles and embeds them locally using Apple Neural Engine sentence embeddings. " +
                    "Enables conceptual trope and vibe discovery via semantic: queries with zero external network access."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if session.isOpen {
                    HStack {
                        Text("Passage Database")
                        Spacer()
                        if let status = passageDBStatus, status.isLoaded {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                let sizeStr = ByteCountFormatter.string(fromByteCount: status.storageBytes, countStyle: .file)
                                Text("Available · \(status.chunkCount.formatted()) scenes (\(sizeStr))")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                                Text("Not Found")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .font(.callout)

                    if let status = passageDBStatus, status.isLoaded {
                        HStack {
                            Text("Indexed Scope")
                            Spacer()
                            Text("\(status.bookCount.formatted()) of \(session.totalCount.formatted()) works")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)

                        HStack {
                            Text("Embedding Model")
                            Spacer()
                            let modelLabel = status.modelID.isEmpty ? "Qwen/Qwen3-Embedding-0.6B" : status.modelID
                            Text("\(modelLabel) (\(status.dimension)-dim FP16)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }

                    HStack {
                        Text("CoreML Query Embedder")
                        Spacer()
                        if isQueryModelAvailable {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Ready (Neural Engine / Metal)")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                                Text("Model Not Found")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .font(.callout)

                    HStack(spacing: 8) {
                        if let status = passageDBStatus, status.isLoaded {
                            Button("Reveal in Finder") {
                                revealPassageDBInFinder()
                            }
                            .controlSize(.small)

                            Button("Clear Database…") {
                                showClearPassageConfirmation = true
                            }
                            .controlSize(.small)
                            .disabled(DatabaseMaintenanceCoordinator.shared.isMaintenanceInProgress)
                        } else {
                            Button("Import Database…") {
                                importPassageDatabase()
                            }
                            .controlSize(.small)
                            .disabled(DatabaseMaintenanceCoordinator.shared.isMaintenanceInProgress)

                            Button("Copy CLI Command") {
                                copyIngestionCLICommand()
                            }
                            .controlSize(.small)
                        }

                        Button("Refresh") {
                            Task {
                                session.reloadPassageDB()
                                await reloadPassageStatus()
                                await reloadStorageBreakdown()
                            }
                        }
                        .controlSize(.small)

                        Spacer()

                        if let passageActionMessage {
                            Text(passageActionMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                } else {
                    Text("Open a library to view or manage its semantic passage database.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Full-Text Semantic Search (Passages)", systemImage: "sparkle.magnifyingglass").font(.headline)
            } footer: {
                Text(
                    "Stores packed Float16 passage vectors and chapter offset anchors in ambrosia_semantic_passages.db for fine-grained scene search. " +
                    "Run scripts/ambrosia_embed_cli.py or package the library with scripts/pack_embed_task.sh to generate the database on another machine."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Export Format")
                    Spacer()
                    Text("Direct Copy (Archival EPUB)")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                Button("Export EPUBs…") {
                    AppDelegate.shared?.libraryWindowController?.triggerEPUBExport()
                }
                .controlSize(.small)
            } header: {
                Label("EPUB Export", systemImage: "square.and.arrow.up").font(.headline)
            } footer: {
                Text(
                    "Ambrosia exports original EPUB files directly 1:1 preserving series organization and metadata. " +
                    "To normalize and modernize an exported folder into modern EPUB 3 containers conforming to " +
                    "the epub-otwarchive specification, run scripts/modernize_epubs.py from terminal."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
        .onAppear {
            if session.activeURL == nil && !knownLibraries.isEmpty {
                storageScope = .all
            }
            reloadKnownLibraries()
            tagSeedConfig.refreshValidation()
            Task { await loadAvailableColumns() }
            Task { await reloadAO3ExtractionStatus() }
            Task { await reloadSemanticStatus() }
            Task { await reloadPassageStatus() }
            Task { await reloadStorageBreakdown() }
            scheduleObservingExtraction()
        }
        .onChange(of: session.activePath) { _, newPath in
            if newPath != nil {
                storageScope = .active
            }
            reloadKnownLibraries()
            Task {
                await loadAvailableColumns()
                await reloadAO3ExtractionStatus()
                await reloadSemanticStatus()
                await reloadPassageStatus()
                await reloadStorageBreakdown()
            }
        }
        .sheet(isPresented: $showDiagnosticsSheet) {
            AO3ExtractionDiagnosticsSheet(session: session)
        }
        .confirmationDialog(
            "Delete Semantic Passage Database?",
            isPresented: $showClearPassageConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Database", role: .destructive) {
                clearPassageDatabase()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will delete ambrosia_semantic_passages.db and all computed passage vectors for this library.")
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
    private func storageBreakdownView(_ breakdown: LibraryStorageBreakdown, scope: StorageScope) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Proportional stacked bar
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let props = breakdown.proportions
                HStack(spacing: 2) {
                    if props.epubs > 0 {
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: max(totalWidth * props.epubs, 4))
                    }
                    if props.fts > 0 {
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: max(totalWidth * props.fts, 4))
                    }
                    if props.calibre > 0 {
                        Rectangle()
                            .fill(Color.purple)
                            .frame(width: max(totalWidth * props.calibre, 4))
                    }
                    if props.ambrosia > 0 {
                        Rectangle()
                            .fill(Color.gray)
                            .frame(width: max(totalWidth * props.ambrosia, 4))
                    }
                    if props.semantic > 0 {
                        Rectangle()
                            .fill(Color.indigo)
                            .frame(width: max(totalWidth * props.semantic, 4))
                    }
                    if props.passages > 0 {
                        Rectangle()
                            .fill(Color.teal)
                            .frame(width: max(totalWidth * props.passages, 4))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 12)
            .padding(.vertical, 4)

            // Storage component rows
            storageRow(
                label: "EPUB Books",
                size: breakdown.formattedEpubsSize,
                color: .blue,
                icon: "books.vertical.fill"
            )
            storageRow(
                label: scope == .active ? "Full-Text Search Index" : "Full-Text Search Indexes",
                size: breakdown.formattedFTSDBSize,
                color: .orange,
                icon: "text.magnifyingglass"
            )
            storageRow(
                label: scope == .active ? "Calibre Database (metadata.db)" : "Calibre Databases",
                size: breakdown.formattedCalibreDBSize,
                color: .purple,
                icon: "cylinder.split.1x2"
            )
            storageRow(
                label: scope == .active ? "Ambrosia Metadata (ambrosia_meta.db)" : "Ambrosia Metadata",
                size: breakdown.formattedAmbrosiaMetaDBSize,
                color: .gray,
                icon: "gearshape"
            )
            if breakdown.semanticVectorsSizeBytes > 0 {
                storageRow(
                    label: scope == .active ? "Semantic Vector Index" : "Semantic Vector Indexes",
                    size: breakdown.formattedSemanticVectorsSize,
                    color: .indigo,
                    icon: "sparkles"
                )
            }
            if breakdown.passageDBSizeBytes > 0 {
                storageRow(
                    label: scope == .active
                        ? "Semantic Passage Database (ambrosia_semantic_passages.db)"
                        : "Semantic Passage Databases",
                    size: breakdown.formattedPassageDBSize,
                    color: .teal,
                    icon: "text.quote"
                )
            }

            Divider()

            HStack {
                Text(scope == .active ? "Total Active Storage" : "Total Combined Storage")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(breakdown.formattedTotal)
                    .font(.callout.weight(.bold))
            }

            if scope == .active, knownLibraries.count > 1, let total = totalAllLibrariesFootprint, total.totalSizeBytes > 0 {
                let pct = percentageOfTotal(activeBytes: breakdown.totalSizeBytes, totalBytes: total.totalSizeBytes)
                Text("Represents \(pct) of \(total.formattedTotal) total across \(knownLibraries.count) libraries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if scope == .all {
                Text("Combined footprint across \(knownLibraries.count) libraries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if scope == .active {
                HStack(spacing: 12) {
                    Button(DatabaseMaintenanceCoordinator.shared.isIndexingFTS ? "Indexing…" : "Index Unindexed Works") {
                        indexUnindexedBooks()
                    }
                    .controlSize(.small)
                    .disabled(!session.isOpen || DatabaseMaintenanceCoordinator.shared.isMaintenanceInProgress)
                    .help("Scans for unindexed EPUBs in this library and indexes their text in the background, matching Calibre's behavior.")

                    Button(DatabaseMaintenanceCoordinator.shared.isCompacting ? "Compacting…" : "Compact & Vacuum") {
                        compactAndVacuumDatabases()
                    }
                    .controlSize(.small)
                    .disabled(!session.isOpen || DatabaseMaintenanceCoordinator.shared.isMaintenanceInProgress)
                    .help("Optimizes search index segment trees, flushes WAL logs, and vacuums databases to reclaim unused disk space.")

                    Button("Clear Search Index") {
                        clearFTSIndex()
                    }
                    .controlSize(.small)
                    .disabled(!session.isOpen || DatabaseMaintenanceCoordinator.shared.isMaintenanceInProgress)
                    .help("Deletes full-text-search.db to reclaim disk space.")

                    if breakdown.passageDBSizeBytes > 0 {
                        Button("Clear Passage DB") {
                            showClearPassageConfirmation = true
                        }
                        .controlSize(.small)
                        .disabled(!session.isOpen || DatabaseMaintenanceCoordinator.shared.isMaintenanceInProgress)
                        .help("Deletes ambrosia_semantic_passages.db to reclaim disk space.")
                    }

                    Button("Manage Duplicate Works…") {
                        AppDelegate.shared?.libraryWindowController?.toolbarStateForCommands?.showDuplicateManager = true
                    }
                    .controlSize(.small)
                    .disabled(DatabaseMaintenanceCoordinator.shared.isMaintenanceInProgress)
                    .help("Reviews version differences across duplicate AO3 works and migrates reading state.")
                }
                .padding(.top, 4)
            }
        }
    }

    private func percentageOfTotal(activeBytes: Int64, totalBytes: Int64) -> String {
        guard totalBytes > 0 else { return "0%" }
        let pct = (Double(activeBytes) / Double(totalBytes)) * 100.0
        return String(format: "%.0f%%", pct)
    }

    private func storageRow(label: String, size: String, color: Color, icon: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Label(label, systemImage: icon)
                .font(.callout)
            Spacer()
            Text(size)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func reloadStorageBreakdown() async {
        guard let url = session.activeURL else {
            storageBreakdown = nil
            return
        }
        isCalculatingStorage = true
        let result = await LibraryStorageCalculator.calculate(libraryURL: url)
        await MainActor.run {
            self.storageBreakdown = result
            self.isCalculatingStorage = false
        }
    }

    private func indexUnindexedBooks() {
        guard let url = session.activeURL else { return }
        ftsActionMessage = "Indexing works in background…"
        Task {
            let cancellation = IngestionCancellation()
            await DatabaseMaintenanceCoordinator.shared.withMaintenance(
                kind: .indexingFTS,
                detail: url.lastPathComponent,
                onCancel: {
                    cancellation.cancel()
                },
                work: {
                    let count = (try? await Task.detached(priority: .userInitiated) {
                        try CalibreFTSWriter.indexLibrary(at: url, isCancelled: { cancellation.isCancelled })
                    }.value) ?? 0

                    ftsActionMessage = cancellation.isCancelled
                        ? "Indexing cancelled (\(count) works indexed)."
                        : "Indexing complete (\(count) works indexed)."
                    if let url = session.activeURL {
                        await session.open(url: url)
                        await self.reloadStorageBreakdown()
                    }
                }
            )
        }
    }

    private func compactAndVacuumDatabases() {
        guard let url = session.activeURL else { return }
        ftsActionMessage = "Compacting and vacuuming databases…"
        Task {
            await DatabaseMaintenanceCoordinator.shared.withMaintenance(
                kind: .compactAndVacuum,
                detail: url.lastPathComponent
            ) {
                let beforeBreakdown = await LibraryStorageCalculator.calculate(libraryURL: url)
                _ = try? await Task.detached(priority: .userInitiated) {
                    try CalibreFTSWriter.compactAndVacuum(libraryURL: url)
                    try PassageDatabase.compactAndVacuum(libraryURL: url)
                }.value
                if let metaDB = session.metaDB {
                    try? await metaDB.vacuumAndCheckpoint()
                }
                let afterBreakdown = await LibraryStorageCalculator.calculate(libraryURL: url)
                let reclaimed = max(0, beforeBreakdown.totalSizeBytes - afterBreakdown.totalSizeBytes)
                let formattedReclaimed = ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file)
                ftsActionMessage = reclaimed > 0
                    ? "Compaction complete. Reclaimed \(formattedReclaimed) of disk space."
                    : "Compaction complete. Databases are already fully compacted."
                await reloadStorageBreakdown()
                reloadKnownLibraries()
            }
        }
    }

    private func clearFTSIndex() {
        guard let url = session.activeURL else { return }
        let ftsFile = url.appendingPathComponent("full-text-search.db")
        let walFile = url.appendingPathComponent("full-text-search.db-wal")
        let shmFile = url.appendingPathComponent("full-text-search.db-shm")
        try? FileManager.default.removeItem(at: ftsFile)
        try? FileManager.default.removeItem(at: walFile)
        try? FileManager.default.removeItem(at: shmFile)
        ftsActionMessage = "Full-text search index cleared."
        Task {
            await session.open(url: url)
            await reloadStorageBreakdown()
        }
    }

    @ViewBuilder
    private func libraryIndexRow(_ entry: LibraryIndexEntry) -> some View {
        let reachable = FileManager.default.fileExists(atPath: entry.lastKnownPath)
        let isActive = (entry.lastKnownPath == session.activePath)
            || (session.activeURL.map { Ambrosia.libraryHash(for: $0) } == entry.hash)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: reachable ? (isActive ? "checkmark.circle.fill" : "circle") : "exclamationmark.triangle.fill")
                .foregroundStyle(reachable ? (isActive ? Color.green : Color.secondary) : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .font(.callout.weight(.medium))
                    if isActive {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text(entry.lastKnownPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Last opened \(entry.lastOpened)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let footprint = libraryFootprints[entry.hash] {
                    Text(
                        "\(footprint.formattedTotal) (EPUBs: \(footprint.formattedEpubsSize) · " +
                        "Search: \(footprint.formattedFTSDBSize) · Calibre: \(footprint.formattedCalibreDBSize))"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if reachable {
                    if !isActive {
                        Button("Switch") {
                            AppDelegate.shared?.openLibraryAtURL(URL(fileURLWithPath: entry.lastKnownPath), activateLibraryWindow: false)
                            reloadKnownLibraries()
                        }
                        .controlSize(.small)
                    }
                } else {
                    Button("Locate…") {
                        relink(entry)
                    }
                    .controlSize(.small)
                }

                Button {
                    confirmRemoval(of: entry)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove library from list")
            }
        }
        .contextMenu {
            if reachable {
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: entry.lastKnownPath)
                }
                if !isActive {
                    Button("Switch to Library") {
                        AppDelegate.shared?.openLibraryAtURL(URL(fileURLWithPath: entry.lastKnownPath), activateLibraryWindow: false)
                        reloadKnownLibraries()
                    }
                }
                Divider()
            } else {
                Button("Locate Library…") {
                    relink(entry)
                }
                Divider()
            }

            Button("Remove from List…") {
                confirmRemoval(of: entry)
            }
        }
    }

    private func confirmRemoval(of entry: LibraryIndexEntry) {
        let isActive = (entry.lastKnownPath == session.activePath)
            || (session.activeURL.map { Ambrosia.libraryHash(for: $0) } == entry.hash)

        let alert = NSAlert()
        alert.messageText = "Remove \"\(entry.displayName)\"?"
        var message = "This will remove the library from Ambrosia's list of known libraries and recent menus."
        if isActive {
            message += "\n\nBecause this library is currently open, closing it will return to the empty library screen."
        }
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove from List")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove & Delete Cached Data")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            removeLibrary(entry, deleteMetadata: false, closeIfActive: isActive)
        case .alertThirdButtonReturn:
            removeLibrary(entry, deleteMetadata: true, closeIfActive: isActive)
        default:
            break
        }
    }

    private func removeMissingLibraries() {
        let missing = knownLibraries.filter { !FileManager.default.fileExists(atPath: $0.lastKnownPath) }
        guard !missing.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Remove \(missing.count) Missing " + (missing.count == 1 ? "Library?" : "Libraries?")
        alert.informativeText = "This will remove all missing or unreachable libraries from Ambrosia's list and delete their cached metadata."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove Missing")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for entry in missing {
            let isActive = (entry.lastKnownPath == session.activePath)
                || (session.activeURL.map { Ambrosia.libraryHash(for: $0) } == entry.hash)
            removeLibrary(entry, deleteMetadata: true, closeIfActive: isActive)
        }
    }

    private func removeLibrary(_ entry: LibraryIndexEntry, deleteMetadata: Bool, closeIfActive: Bool) {
        if closeIfActive {
            AppDelegate.shared?.closeCurrentLibrary()
        }
        LibraryIndexManager.shared.remove(hash: entry.hash, deleteAppSupportMetadata: deleteMetadata)
        LibraryRegistry.shared.remove(entry.lastKnownPath)
        reloadKnownLibraries()
    }

    private func reloadKnownLibraries() {
        knownLibraries = LibraryIndexManager.shared.entries()
        for entry in knownLibraries {
            let path = entry.lastKnownPath
            let entryHash = entry.hash
            if FileManager.default.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                Task {
                    let footprint = await LibraryStorageCalculator.calculate(libraryURL: url)
                    await MainActor.run {
                        self.libraryFootprints[entryHash] = footprint
                    }
                }
            }
        }
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
                _ = try? await metaDB.syncTagCanonicalMapIfNeeded()
                tagSynonymCacheMessage = "Imported synonym cache cleared."
            } catch {
                tagSynonymCacheMessage = error.localizedDescription
            }
        }
    }

    private func loadAvailableColumns() async {
        guard let library = AppDelegate.shared?.session?.library else {
            availableColumns = []
            wordCountLabel = "(none)"
            kudosLabel = "(none)"
            return
        }
        let cols = await library.customColumns().map(\.label).sorted()
        availableColumns = cols
        if cols.isEmpty {
            wordCountLabel = "(none)"
            kudosLabel = "(none)"
            CustomColumnConfig.shared.wordCountLabel = nil
            CustomColumnConfig.shared.kudosLabel = nil
            return
        }
        await CustomColumnConfig.shared.autoDetect(using: library)
        if let currentWC = CustomColumnConfig.shared.wordCountLabel, cols.contains(currentWC) {
            wordCountLabel = currentWC
        } else {
            wordCountLabel = "(none)"
            CustomColumnConfig.shared.wordCountLabel = nil
        }
        if let currentKudos = CustomColumnConfig.shared.kudosLabel, cols.contains(currentKudos) {
            kudosLabel = currentKudos
        } else {
            kudosLabel = "(none)"
            CustomColumnConfig.shared.kudosLabel = nil
        }
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

    private func reloadSemanticStatus() async {
        guard let url = session.activeURL else {
            semanticIndexedCount = 0
            semanticStorageBytes = 0
            return
        }
        let engine = session.semanticEngine ?? SemanticSearchEngine(storageURL: url)
        let status = await engine.status(in: url)
        semanticIndexedCount = status.indexedCount
        semanticStorageBytes = status.storageBytes
    }

    private func indexSemanticWorks(incremental: Bool) {
        guard let url = session.activeURL, let library = session.library else { return }
        isIndexingSemantic = true
        semanticIndexMessage = nil
        Task {
            await DatabaseMaintenanceCoordinator.shared.withMaintenance(
                kind: .semanticIndexing,
                detail: url.lastPathComponent
            ) {
                let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], seriesTerms: [], plainTerms: [])
                let books = await library.fetchAllMatchingBooks(ids: nil, query: emptyQuery, sort: .title, ascending: true)
                let engine = session.semanticEngine ?? SemanticSearchEngine(storageURL: url)
                let alreadyIndexed = incremental ? await engine.indexedIDSet() : []
                let booksToIndex = incremental ? books.filter { !alreadyIndexed.contains($0.id) } : books

                guard !booksToIndex.isEmpty else {
                    isIndexingSemantic = false
                    semanticIndexMessage = "All \(books.count) works already indexed."
                    await reloadSemanticStatus()
                    return
                }

                semanticProgressCompleted = 0
                semanticProgressTotal = booksToIndex.count

                let metaDB = session.metaDB
                let ao3Map = (try? await metaDB?.ao3Metadata(for: booksToIndex.map(\.id))) ?? [:]
                var docs: [(id: Int, text: String)] = []
                docs.reserveCapacity(booksToIndex.count)

                for book in booksToIndex {
                    let ao3 = ao3Map[book.id]
                    let doc = WorkEmbeddingSynthesizer.synthesize(book: book, ao3: ao3)
                    docs.append((id: book.id, text: doc))
                }

                await engine.index(documents: docs, incremental: incremental) { completed, total in
                    Task { @MainActor in
                        semanticProgressCompleted = completed
                        semanticProgressTotal = total
                    }
                }

                isIndexingSemantic = false
                await reloadSemanticStatus()
                await reloadStorageBreakdown()
                semanticIndexMessage = "Successfully indexed \(docs.count) works."
            }
        }
    }

    private func clearSemanticIndex() {
        guard let url = session.activeURL else { return }
        Task {
            if let engine = session.semanticEngine {
                await engine.clear(in: url)
            } else {
                let engine = SemanticSearchEngine()
                await engine.clear(in: url)
            }
            await reloadSemanticStatus()
            await reloadStorageBreakdown()
            semanticIndexMessage = "Semantic index cleared."
        }
    }

    private func reloadPassageStatus() async {
        guard let db = session.passageDB else {
            await MainActor.run {
                self.passageDBStatus = nil
            }
            let modelAvail = await PassageQueryEmbedder.shared.isModelAvailable
            await MainActor.run {
                self.isQueryModelAvailable = modelAvail
            }
            return
        }
        let status = await db.status()
        let modelAvail = await PassageQueryEmbedder.shared.isModelAvailable
        await MainActor.run {
            self.passageDBStatus = status
            self.isQueryModelAvailable = modelAvail
        }
    }

    private func revealPassageDBInFinder() {
        guard let url = session.activeURL else { return }
        let dbURL = url.appendingPathComponent("ambrosia_semantic_passages.db")
        if FileManager.default.fileExists(atPath: dbURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([dbURL])
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        }
    }

    private func importPassageDatabase() {
        guard let targetDir = session.activeURL else { return }
        let panel = NSOpenPanel()
        panel.title = "Select ambrosia_semantic_passages.db"
        panel.prompt = "Import Database"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
        if panel.runModal() == .OK, let sourceURL = panel.url {
            let destURL = targetDir.appendingPathComponent("ambrosia_semantic_passages.db")
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                passageActionMessage = "Successfully imported semantic passage database."
                session.reloadPassageDB()
                Task {
                    await reloadPassageStatus()
                    await reloadStorageBreakdown()
                }
            } catch {
                passageActionMessage = "Failed to import database: \(error.localizedDescription)"
            }
        }
    }

    private func clearPassageDatabase() {
        guard let url = session.activeURL else { return }
        let dbFile = url.appendingPathComponent("ambrosia_semantic_passages.db")
        let walFile = url.appendingPathComponent("ambrosia_semantic_passages.db-wal")
        let shmFile = url.appendingPathComponent("ambrosia_semantic_passages.db-shm")
        try? FileManager.default.removeItem(at: dbFile)
        try? FileManager.default.removeItem(at: walFile)
        try? FileManager.default.removeItem(at: shmFile)
        passageActionMessage = "Semantic passage database deleted."
        session.reloadPassageDB()
        Task {
            await reloadPassageStatus()
            await reloadStorageBreakdown()
        }
    }

    private func copyIngestionCLICommand() {
        guard let url = session.activeURL else { return }
        let cmd = "python3 scripts/ambrosia_embed_cli.py --library \"\(url.path)\" --model Qwen/Qwen3-Embedding-0.6B --batch-size 32"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        passageActionMessage = "Copied CLI command to clipboard."
    }
}

// MARK: - AO3 Extraction Diagnostics Sheet

private struct AO3ExtractionDiagnosticsSheet: View {
    let session: LibrarySession
    @Environment(\.dismiss) private var dismiss
    @State private var diagnostics: [AO3ExtractionDiagnostic] = []
    @State private var bookDetails: [Int: (title: String, authors: String)] = [:]
    @State private var filterFailuresOnly = false
    @State private var isLoading = true

    var filteredDiagnostics: [AO3ExtractionDiagnostic] {
        if filterFailuresOnly {
            return diagnostics.filter { $0.status == "failed" || $0.reason.localizedCaseInsensitiveContains("error") }
        }
        return diagnostics
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AO3 Extraction Diagnostics")
                        .font(.headline)
                    let failureCount = diagnostics.filter {
                        $0.status == "failed" || $0.reason.localizedCaseInsensitiveContains("error")
                    }.count
                    let nonAO3Count = diagnostics.count - failureCount
                    Text("\(diagnostics.count) total books without AO3 metadata (\(failureCount) errors, \(nonAO3Count) non-AO3/skipped)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("View in Library") {
                    AppDelegate.shared?.showLibraryWindow()
                    AppDelegate.shared?.libraryWindowController?.showFailedExtractions()
                    dismiss()
                }
                .controlSize(.small)
                .disabled(filteredDiagnostics.isEmpty)

                Toggle("Show failures only", isOn: $filterFailuresOnly)
                    .toggleStyle(.checkbox)
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if isLoading {
                Spacer()
                ProgressView("Loading diagnostics…")
                Spacer()
            } else if filteredDiagnostics.isEmpty {
                Spacer()
                Text(filterFailuresOnly ? "No hard parsing errors found." : "All books in this library have AO3 metadata.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filteredDiagnostics) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                if let info = bookDetails[item.calibreID] {
                                    Text(info.title)
                                        .font(.callout.weight(.medium))
                                    if !info.authors.isEmpty {
                                        Text("by \(info.authors)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text(item.epubFilename ?? "Calibre ID \(item.calibreID)")
                                        .font(.callout.weight(.medium))
                                }
                            }
                            Spacer()
                            let isFailed = item.status == "failed" || item.reason.localizedCaseInsensitiveContains("error")
                            let badgeText: String = {
                                if isFailed { return "Failed" }
                                if item.reason.localizedCaseInsensitiveContains("no epub") { return "No EPUB" }
                                if item.reason.localizedCaseInsensitiveContains("preface") { return "No AO3 Preface" }
                                return item.status.capitalized
                            }()
                            Text(badgeText)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(isFailed ? Color.red.opacity(0.15) : Color.orange.opacity(0.15))
                                .foregroundStyle(isFailed ? Color.red : Color.orange)
                                .clipShape(Capsule())
                        }

                        Text("Reason: \(item.reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let filename = item.epubFilename,
                           let info = bookDetails[item.calibreID],
                           filename != info.title {
                            Text("File: \(filename)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        if let path = item.epubPath {
                            Text(path)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        HStack(spacing: 8) {
                            Text("Calibre ID: \(item.calibreID)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if let checked = item.spineItemsChecked {
                                Text("· Spine items scanned: \(checked)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("Open in Reader") {
                                Task {
                                    if let book = await session.library?.booksForIDs([item.calibreID]).first {
                                        await MainActor.run {
                                            AppDelegate.shared?.openReaderWindow(book: book)
                                        }
                                    }
                                }
                            }
                            .controlSize(.mini)
                            Button("Show in Finder") {
                                Task {
                                    var resolved = item.epubPath
                                    if resolved == nil {
                                        resolved = await session.library?.epubURL(calibreID: item.calibreID)?.path
                                    }
                                    if let resolved, FileManager.default.fileExists(atPath: resolved) {
                                        await MainActor.run {
                                            _ = NSWorkspace.shared.selectFile(resolved, inFileViewerRootedAtPath: "")
                                        }
                                    }
                                }
                            }
                            .controlSize(.mini)
                            Button("Copy Details") {
                                let details = """
                                Calibre ID: \(item.calibreID)
                                Status: \(item.status)
                                Reason: \(item.reason)
                                File: \(item.epubPath ?? item.epubFilename ?? "none")
                                Date: \(item.attemptedAt)
                                """
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(details, forType: .string)
                            }
                            .controlSize(.mini)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 440)
        .task {
            var items: [AO3ExtractionDiagnostic] = []
            if let metaDB = session.metaDB {
                items = (try? await metaDB.allAO3Diagnostics(failedOnly: false)) ?? []
            }
            diagnostics = items.sorted { $0.calibreID < $1.calibreID }
            if let library = session.library {
                let books = await library.booksForIDs(diagnostics.map(\.calibreID))
                var map: [Int: (title: String, authors: String)] = [:]
                for book in books {
                    map[book.id] = (title: book.title, authors: book.authors.joined(separator: ", "))
                }
                bookDetails = map
            }
            isLoading = false
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - RSS Tab
// ─────────────────────────────────────────────────────────────────────────────

private struct RSSTab: View {
    @Bindable private var prefs = ReaderPreferences.shared
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
// MARK: - Shortcuts Tab
// ─────────────────────────────────────────────────────────────────────────────

private struct ShortcutsTab: View {
    @Bindable private var prefs = ReaderPreferences.shared
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
                Text(
                    "Click a shortcut to record a new one. Standard system and menu shortcuts "
                    + "(Cmd+C/V/X/Z, Cmd+Shift+Z, Cmd+,, Cmd+O, Cmd+W, Cmd+Q, Cmd+M, Cmd+0-3) are reserved and can't be reassigned."
                )
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

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Documentation Tab
// ─────────────────────────────────────────────────────────────────────────────

private struct DocsTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                docHeader

                docSection(
                    title: "Quick Search & Scoped Prefixes",
                    icon: "magnifyingglass",
                    description: "Type directly in the toolbar search field (Cmd+F). Combine multiple tokens separated by spaces."
                ) {
                    syntaxRow(syntax: "tag:Romance", description: "Matches works with the tag (or synonyms)")
                    syntaxRow(syntax: "author:Alice", description: "Matches author name")
                    syntaxRow(syntax: "title:Secret", description: "Matches title substring")
                    syntaxRow(syntax: "series:Trilogy", description: "Matches series name")
                    syntaxRow(syntax: "status:Complete", description: "Filters by status: Complete or InProgress")
                    syntaxRow(syntax: "words:>50k", description: "Filters word count: >50k, <20k, or 10k-50k")
                    syntaxRow(syntax: "tag:\"Slow Burn\"", description: "Use double quotes for multi-word phrases")
                }

                docSection(
                    title: "Precision Operators (Calibre Parity)",
                    icon: "equal.circle",
                    description: "Strict matching and regular expression evaluation powered by SQLite REGEXP."
                ) {
                    syntaxRow(syntax: "tag:=Romance", description: "Exact tag equality; avoids matching 'Romantic Comedy'")
                    syntaxRow(syntax: "title:=\"Exact Title\"", description: "Matches title exactly with case-insensitivity")
                    syntaxRow(syntax: "author:=\"Jane Doe\"", description: "Matches exact author name")
                    syntaxRow(syntax: "title:~\"^The \"", description: "Regex match: titles starting with 'The '")
                    syntaxRow(syntax: "tag:~\"^Chapter \\d+\"", description: "Regex match: matches numbered chapter tags")
                    syntaxRow(syntax: "author:~\"^[A-M]\"", description: "Regex match: authors with surname in A-M")
                    syntaxRow(syntax: "-tag:=Angst", description: "Negation: excludes works with the exact tag")
                    syntaxRow(syntax: "-author:Voldemort", description: "Negation: excludes works by this author")
                }

                docSection(
                    title: "Full-Text & Semantic Search",
                    icon: "sparkles",
                    description: "Deep content search across book body text and on-device conceptual discovery."
                ) {
                    syntaxRow(
                        syntax: "fulltext:\"secret agent\"",
                        description: "Searches body text using Calibre's FTS5 index (full-text-search.db)"
                    )
                    syntaxRow(
                        syntax: "Shift+Cmd+F",
                        description: "Opens dedicated Full-Text Search window with typographic snippet cards"
                    )
                    syntaxRow(
                        syntax: "semantic:vibe or trope",
                        description: "On-device sentence embeddings finding works by trope, mood, or narrative vibe"
                    )
                }

                docSection(
                    title: "Filter Drawer (Shift+Cmd+D)",
                    icon: "line.3.horizontal.decrease.circle",
                    description: "Visual rule builder supporting nested groups, custom boolean conjunctions (AND/OR), and advanced comparison operators."
                ) {
                    syntaxRow(syntax: "matches whole word", description: "Enforces regex word boundaries (\\b) on tags, authors, or titles")
                    syntaxRow(syntax: "matches regex", description: "Executes custom regular expressions against database fields")
                    syntaxRow(syntax: "max / min rating", description: "Evaluates AO3 rating hierarchy (General < Teen < Mature < Explicit)")
                }

                docSection(
                    title: "Keyboard Shortcuts Quick Reference",
                    icon: "command",
                    description: "Standard keyboard shortcuts available throughout the application."
                ) {
                    syntaxRow(syntax: "Cmd+F", description: "Focus library search field")
                    syntaxRow(syntax: "Shift+Cmd+F", description: "Open Search Library Body Text window")
                    syntaxRow(syntax: "Shift+Cmd+D", description: "Toggle Filter Drawer")
                    syntaxRow(syntax: "Cmd+1 / Cmd+2", description: "Switch between List view and Email view")
                    syntaxRow(syntax: "Cmd+,", description: "Open Preferences")
                    syntaxRow(syntax: "Space", description: "Toggle Quick Look / Book Info inspector")
                    syntaxRow(syntax: "Esc", description: "Dismiss search completions, filter drawer, or popover")
                }
            }
            .padding(20)
        }
    }

    private var docHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.pages")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ambrosia Search & Query Guide")
                    .font(.title2.weight(.bold))
                Text("A comprehensive reference for quick search syntax, precision operators, and keyboard navigation.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 6)
    }

    private func docSection<Content: View>(
        title: String,
        icon: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                content()
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }

    private func syntaxRow(syntax: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(syntax)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(width: 190, alignment: .leading)

            Text(description)
                .font(.callout)
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(
            Divider()
                .padding(.horizontal, 8),
            alignment: .bottom
        )
    }
}
