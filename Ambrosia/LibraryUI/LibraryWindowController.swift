import AppKit
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

    // The search toolbar item — kept strongly so we can anchor the popover.
    private var searchToolbarItem: NSSearchToolbarItem?

    // MARK: - Suggestion popover
    //
    // NSPopover is used instead of a child NSWindow because:
    // - It correctly resolves the coordinate space for NSSearchToolbarItem, which
    //   lives inside a private NSToolbarItemViewer and cannot be reliably converted
    //   via convert(_:to:nil) + convertToScreen.
    // - It does not steal first responder from the search field.
    // - It sizes itself from SwiftUI content naturally.
    // - .semitransient behaviour closes on content-area clicks but not on field edits.

    private var suggestionPopover: NSPopover?
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
        startObservingCounts()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
            item.toolTip = "Search — or type tag:, author:, series:, title: to add a filter"
            item.resignsFirstResponderWithCancel = true
            item.searchField.delegate = self
            item.searchField.placeholderString = "Search, or tag: / author: / series:"
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
            closeSuggestionPopover()
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
            closeSuggestionPopover()
            return false  // let NSSearchToolbarItem handle the Cancel button normally
        }
        return false
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        // Small delay so a popover row click can fire before we close.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.closeSuggestionPopover()
        }
    }

    // MARK: - Commit: search text → filter rule or plain FTS

    /// Called when the user presses Return. If the text is a recognised scoped
    /// prefix (tag:, author:, series:, title:) the whole value is committed as a
    /// FilterRule and the field is cleared. Otherwise the text is kept for FTS.
    private func commitCurrentSearchText() {
        guard let field = searchToolbarItem?.searchField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { closeSuggestionPopover(); return }

        let query = SearchQueryParser.parse(text)

        if let rule = query.asSingleFilterRule {
            // Scoped token: add as filter rule and clear the search field
            commitFilterRule(rule)
            clearSearchField()
        }
        // Plain text: leave in field — BookGridItem will FTS within any active filter

        closeSuggestionPopover()
    }

    /// Commits a suggestion row tap: always produces a filter rule and clears the field.
    private func commitSuggestion(_ suggestion: SearchSuggestion) {
        commitFilterRule(suggestion.asFilterRule)
        clearSearchField()
        closeSuggestionPopover()
    }

    /// Delivers a FilterRule to the active content view via the registered handler.
    private func commitFilterRule(_ rule: FilterRule) {
        toolbarState?.filterCommitHandler?(rule)
    }

    private func clearSearchField() {
        searchToolbarItem?.searchField.stringValue = ""
        toolbarState?.searchText = ""
    }

    // MARK: - Suggestion popover

    private func refreshSuggestions(for text: String) {
        guard let library = session?.library else { closeSuggestionPopover(); return }

        // Run on a background thread — SQLite is fast but avoid blocking the main thread
        // on large libraries. Results are dispatched back to main before presenting.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sections = computeSectionedSuggestions(for: text, library: library)
            DispatchQueue.main.async {
                guard let self else { return }
                if sections.allSatisfy({ $0.suggestions.isEmpty }) {
                    self.closeSuggestionPopover()
                } else {
                    self.showSuggestionPopover(sections: sections)
                }
            }
        }
    }

    private func showSuggestionPopover(sections: [SuggestionSection]) {
        guard let item = searchToolbarItem else { return }

        let view = SearchSuggestionsView(sections: sections) { [weak self] suggestion in
            self?.commitSuggestion(suggestion)
        }

        if let existing = suggestionPopover, existing.isShown,
           let vc = suggestionHostingVC {
            // Update content in place — avoids flicker on each keystroke
            vc.rootView = view
            return
        }

        // Create fresh popover
        let vc      = NSHostingController(rootView: view)
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior              = .semitransient
        popover.animates              = false   // instant feel, like Finder
        // Size will be updated by SwiftUI — set a reasonable initial value
        popover.contentSize           = CGSize(width: 320, height: 200)

        suggestionHostingVC = vc
        suggestionPopover   = popover

        // Anchor to the search field view inside the toolbar item.
        // NSSearchToolbarItem.searchField is the NSSearchField itself — a valid
        // NSView that AppKit can use as a popover anchor regardless of its position
        // in the toolbar's private view hierarchy.
        popover.show(relativeTo: item.searchField.bounds,
                     of: item.searchField,
                     preferredEdge: .maxY)
    }

    private func closeSuggestionPopover() {
        suggestionPopover?.close()
        suggestionPopover   = nil
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
