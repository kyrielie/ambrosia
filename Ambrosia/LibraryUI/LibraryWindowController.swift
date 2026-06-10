import AppKit
import Combine
import SwiftUI
import SwiftData

// MARK: - Toolbar item identifiers

extension NSToolbarItem.Identifier {
    static let librarySearch        = NSToolbarItem.Identifier("ambrosia.library.search")
    static let libraryFilter        = NSToolbarItem.Identifier("ambrosia.library.filter")
    static let librarySort          = NSToolbarItem.Identifier("ambrosia.library.sort")
    static let libraryCollections   = NSToolbarItem.Identifier("ambrosia.library.collections")
    static let libraryReadingGoal   = NSToolbarItem.Identifier("ambrosia.library.readinggoal")
    static let libraryExport        = NSToolbarItem.Identifier("ambrosia.library.export")
    static let libraryViewMode      = NSToolbarItem.Identifier("ambrosia.library.viewmode")
    static let libraryTitle         = NSToolbarItem.Identifier("ambrosia.library.title")
    static let librarySidebarToggle = NSToolbarItem.Identifier("ambrosia.library.sidebartoggle")
}

// MARK: - LibraryWindowController

class LibraryWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {

    private weak var toolbarState: LibraryToolbarState?
    private weak var session: LibrarySession?
    private var viewModeControl: NSSegmentedControl?
    private var sortMenuToolbarItem: NSMenuToolbarItem?
    private var ficCountLabel: NSTextField?
    private var readCountLabel: NSTextField?
    private var appearanceCancellable: AnyCancellable?

    // The search toolbar item — kept strongly so we can anchor the popover.
    private var searchToolbarItem: NSSearchToolbarItem?

    // MARK: - Suggestion panel
    //
    // A non-activating NSPanel child window replaces NSPopover because
    // NSPopover.show() transfers key focus away from the search field, causing
    // keystrokes to be dropped while the suggestion list is visible.
    //
    // NSPanel with .nonactivatingPanel style mask never takes key focus, so the
    // user can keep typing while suggestions update — the same mechanism used by
    // Xcode's completion list and Spotlight's suggestion area.
    //
    // The panel is positioned by converting the search field's frame to screen
    // coordinates. We hold a direct strong reference to the NSSearchField so
    // this conversion is always reliable, regardless of toolbar item hierarchy.

    private var suggestionPanel: NSPanel?
    private var suggestionHostingVC: NSHostingController<SearchSuggestionsView>?
    private let suggestionDebouncer = DebounceTimer(delay: 0.2)

    // MARK: - Init

    init(modelContainer: ModelContainer, session: LibrarySession) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ambrosia"
        window.titleVisibility = .hidden
        window.toolbarStyle    = .unified
        window.minSize = NSSize(width: 700, height: 500)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        let libraryVC = LibraryViewController(
            modelContainer: modelContainer,
            session: session
        )
        window.contentViewController = libraryVC

        self.session    = session
        toolbarState    = libraryVC.toolbarState
        configureToolbar(window: window)
        applyLibraryAppearance()
        startObservingAppearance()
        startObservingCounts()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Appearance

    private func applyLibraryAppearance() {
        let appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
        window?.appearance = appearance
        window?.contentView?.appearance = appearance
        suggestionPanel?.appearance = appearance
    }

    private func startObservingAppearance() {
        appearanceCancellable = ReaderPreferences.shared.$libraryAppearanceMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyLibraryAppearance()
            }
    }

    // MARK: - Toolbar setup

    private func configureToolbar(window: NSWindow) {
        let toolbar = NSToolbar(identifier: "LibraryToolbar3")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration  = true
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.librarySidebarToggle, .libraryTitle, .librarySearch, .libraryFilter, .librarySort,
         .flexibleSpace,
         .libraryCollections, .libraryReadingGoal, .libraryExport,
         .space,
         .libraryViewMode]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.librarySidebarToggle, .librarySearch, .libraryFilter, .librarySort,
         .libraryCollections, .libraryReadingGoal, .libraryExport,
         .libraryViewMode, .libraryTitle,
         .space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {

        case .librarySearch:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.toolTip = "Search — or type tag:, author:, series:, title:, status: to add a filter"
            item.resignsFirstResponderWithCancel = true
            item.searchField.delegate = self
            item.searchField.placeholderString = "Search, or tag: / author: / series: / status:"
            // Action fires on every keypress — we debounce manually in the delegate
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldChanged(_:))
            searchToolbarItem = item
            return item

        case .librarySidebarToggle:
            return makeIconItem(identifier, label: "Sidebar",
                                image: "sidebar.left", action: #selector(triggerSidebarToggle))

        case .libraryTitle:
            return makeTitleItem(identifier)

        case .libraryFilter:
            return makeIconItem(identifier, label: "Filter",
                                image: "line.3.horizontal.decrease.circle",
                                action: #selector(toggleFilter))

        case .librarySort:
            return makeSortItem(identifier)

        case .libraryCollections:
            return makeIconItem(identifier, label: "Collections",
                                image: "tray.2", action: #selector(showCollections))

        case .libraryReadingGoal:
            return makeIconItem(identifier, label: "Goal",
                                image: "target", action: #selector(showReadingGoal))

        case .libraryExport:
            return makeIconItem(identifier, label: "Export",
                                image: "arrow.up.doc", action: #selector(triggerExport))

        case .libraryViewMode:
            return makeViewModeItem(identifier)

        default:
            return nil
        }
    }

    // MARK: - Item builders

    private func makeIconItem(_ identifier: NSToolbarItem.Identifier,
                               label: String, image: String,
                               action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label   = label
        item.toolTip = label
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        item.image  = NSImage(systemSymbolName: image, accessibilityDescription: label)?
            .withSymbolConfiguration(cfg)
        item.target = self
        item.action = action
        return item
    }

    private func makeSortItem(_ identifier: NSToolbarItem.Identifier) -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label   = "Sort"
        item.toolTip = "Sort order"
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        item.image = NSImage(systemSymbolName: "arrow.up.arrow.down",
                             accessibilityDescription: "Sort")?.withSymbolConfiguration(cfg)
        item.showsIndicator = true

        let menu = NSMenu()
        for field in SortField.allCases {
            let mi = NSMenuItem(title: field.label,
                                action: #selector(sortMenuItemSelected(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.representedObject = field
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let asc  = NSMenuItem(title: "Ascending",  action: #selector(setSortAscending),  keyEquivalent: "")
        let desc = NSMenuItem(title: "Descending", action: #selector(setSortDescending), keyEquivalent: "")
        asc.target  = self
        desc.target = self
        menu.addItem(asc)
        menu.addItem(desc)
        item.menu = menu
        sortMenuToolbarItem = item
        return item
    }

    private func makeViewModeItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let seg = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "list.bullet",  accessibilityDescription: "List")!,
                NSImage(systemSymbolName: "envelope",     accessibilityDescription: "Email")!,
                NSImage(systemSymbolName: "list.number",  accessibilityDescription: "Ranking")!,
            ],
            trackingMode: .selectOne,
            target: self,
            action: #selector(viewModeSegmentChanged(_:))
        )
        seg.selectedSegment = 0
        viewModeControl = seg
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "View"
        item.view  = seg
        return item
    }

    private func makeTitleItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let ficLabel = NSTextField(labelWithString: "")
        ficLabel.font      = NSFont.systemFont(ofSize: 12, weight: .semibold)
        ficLabel.textColor = .labelColor
        ficLabel.alignment = .left
        ficLabel.setContentHuggingPriority(.required, for: .vertical)
        ficLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let stack = NSStackView(views: [ficLabel])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 1
        stack.setHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.frame = NSRect(x: 0, y: 0, width: 140, height: 28)

        ficCountLabel = ficLabel
        updateCountLabel()

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Library"
        item.view  = stack
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        stack.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive    = true
        return item
    }

    private func updateCountLabel() {
        guard let ts = toolbarState, let sess = session else { return }
        if let status = sess.extractionProgress.statusText {
            ficCountLabel?.stringValue = status
            return
        }
        let count = ts.activeFilterResult?.totalCount ?? sess.totalCount
        let fmt   = NumberFormatter()
        fmt.numberStyle = .decimal
        ficCountLabel?.stringValue = "\(fmt.string(from: NSNumber(value: count)) ?? "\(count)") fics"
    }

    private func startObservingCounts() { scheduleCounting() }

    private func scheduleCounting() {
        withObservationTracking {
            _ = toolbarState?.activeFilterResult?.totalCount
            _ = session?.totalCount
            _ = session?.extractionProgress.completed
            _ = session?.extractionProgress.total
            _ = session?.extractionProgress.isRunning
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.updateCountLabel(); self?.scheduleCounting() }
        }
    }

    // MARK: - NSSearchFieldDelegate

    /// Called on every keypress via the field's action (target/action set above).
    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        let text = sender.stringValue
        // Update searchText immediately for display, but page load is debounced
        // inside BookGridItem / EmailLibraryViewController (0.4 s).
        toolbarState?.searchText = text

        if text.isEmpty {
            closeSuggestionPanel()
        } else {
            suggestionDebouncer.schedule { [weak self] in
                self?.refreshSuggestions(for: text)
            }
        }
    }

    /// Called when the user presses Return in the search field.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitCurrentSearchText()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closeSuggestionPanel()
            return false  // let NSSearchToolbarItem handle the Cancel button normally
        }
        return false
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        // Delay so a panel row click fires before we close.
        // mouseUp on the NSPanel row arrives ~50 ms after endSearching.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.closeSuggestionPanel()
        }
    }

    // MARK: - Commit: search text → filter rule or plain FTS

    /// Called when the user presses Return. If the text is a recognised scoped
    /// prefix (tag:, author:, series:, title:) the whole value is committed as a
    /// FilterRule and the field is cleared. Otherwise the text is kept for FTS.
    private func commitCurrentSearchText() {
        guard let field = searchToolbarItem?.searchField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { closeSuggestionPanel(); return }

        let query = SearchQueryParser.parse(text)

        if let rule = query.asSingleFilterRule {
            // Scoped token: add as filter rule and clear the search field
            commitFilterRule(rule)
            clearSearchField()
        }
        // Plain text: leave in field — BookGridItem will FTS within any active filter

        closeSuggestionPanel()
    }

    /// Commits a suggestion row tap: always produces a filter rule and clears the field.
    private func commitSuggestion(_ suggestion: SearchSuggestion) {
        commitFilterRule(suggestion.asFilterRule)
        clearSearchField()
        closeSuggestionPanel()
    }

    /// Delivers a FilterRule to the active content view via the registered handler.
    private func commitFilterRule(_ rule: FilterRule) {
        toolbarState?.filterCommitHandler?(rule)
    }

    private func clearSearchField() {
        searchToolbarItem?.searchField.stringValue = ""
        toolbarState?.searchText = ""
    }

    // MARK: - Suggestion panel

    private func refreshSuggestions(for text: String) {
        guard let library = session?.library else { closeSuggestionPanel(); return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sections = computeSectionedSuggestions(for: text, library: library)
            DispatchQueue.main.async {
                guard let self else { return }
                if sections.allSatisfy({ $0.suggestions.isEmpty }) {
                    self.closeSuggestionPanel()
                } else {
                    self.showSuggestionPanel(sections: sections)
                }
            }
        }
    }

    private func showSuggestionPanel(sections: [SuggestionSection]) {
        guard let searchField = searchToolbarItem?.searchField,
              let parentWindow = window else { return }

        let view = SearchSuggestionsView(sections: sections) { [weak self] suggestion in
            self?.commitSuggestion(suggestion)
        }

        // Update content in-place if already visible — avoids flicker on each keystroke.
        if let panel = suggestionPanel, panel.isVisible, let vc = suggestionHostingVC {
            vc.rootView = view
            repositionPanel(panel, relativeTo: searchField)
            return
        }

        // Build hosting controller
        let vc = NSHostingController(rootView: view)
        vc.view.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        vc.view.layoutSubtreeIfNeeded()
        let fittingSize = vc.sizeThatFits(in: NSSize(width: 360, height: 600))

        // NSPanel with .nonactivatingPanel never steals key focus.
        // The search field stays first responder throughout the suggestion lifecycle.
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
        panel.contentViewController = vc
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu

        // No layer clipping needed — the SwiftUI content draws its own
        // rounded-rectangle background with material and border.
        vc.view.wantsLayer = true
        vc.view.layer?.backgroundColor = CGColor.clear

        suggestionHostingVC = vc
        suggestionPanel = panel

        repositionPanel(panel, relativeTo: searchField)

        // Attach as child so it follows the parent window and hides on miniaturise.
        parentWindow.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)

        // Restore first responder. orderFront can shift the key window on first show.
        // After makeFirstResponder, NSSearchField selects-all by default — move the
        // insertion point to end of string so the next keystroke appends rather than
        // replacing the whole query.
        parentWindow.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            let end = (searchField.stringValue as NSString).length
            editor.selectedRange = NSRange(location: end, length: 0)
        }
    }

    /// Positions the panel flush below the search field, right-aligned.
    private func repositionPanel(_ panel: NSPanel, relativeTo searchField: NSSearchField) {
        guard let fieldWindow = searchField.window else { return }
        let fieldFrameInWindow = searchField.convert(searchField.bounds, to: nil)
        let fieldFrameOnScreen = fieldWindow.convertToScreen(fieldFrameInWindow)
        let size: NSSize
        if let vc = suggestionHostingVC {
            size = vc.sizeThatFits(in: NSSize(width: 360, height: 600))
        } else {
            size = panel.frame.size
        }
        let origin = NSPoint(
            x: fieldFrameOnScreen.maxX - size.width,
            y: fieldFrameOnScreen.minY - size.height - 4
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func closeSuggestionPanel() {
        if let panel = suggestionPanel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        suggestionPanel = nil
        suggestionHostingVC = nil
    }

    // MARK: - Other toolbar actions

    @objc private func toggleFilter()        { toolbarState?.showFilterDrawer   = true }
    @objc private func triggerSidebarToggle(){ toolbarState?.toggleEmailSidebar = true }
    @objc private func showCollections()     { toolbarState?.showCollections    = true }
    @objc private func showReadingGoal()     { toolbarState?.showReadingGoal    = true }
    @objc private func triggerExport()       { toolbarState?.triggerExport      = true }

    @objc private func sortMenuItemSelected(_ sender: NSMenuItem) {
        guard let field = sender.representedObject as? SortField else { return }
        toolbarState?.sortField = field
    }
    @objc private func setSortAscending()  { toolbarState?.ascending = true  }
    @objc private func setSortDescending() { toolbarState?.ascending = false }

    @objc private func viewModeSegmentChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 1:  toolbarState?.viewMode = .email
        case 2:  toolbarState?.viewMode = .ranking
        default: toolbarState?.viewMode = .list
        }
    }
}
