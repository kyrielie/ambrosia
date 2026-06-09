import AppKit
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

class LibraryWindowController: NSWindowController, NSToolbarDelegate {

    private weak var toolbarState: LibraryToolbarState?
    private weak var session: LibrarySession?
    private var viewModeControl: NSSegmentedControl?
    private var sortMenuToolbarItem: NSMenuToolbarItem?
    /// Two-line count label in the toolbar centre.
    private var ficCountLabel: NSTextField?
    private var readCountLabel: NSTextField?

    init(modelContainer: ModelContainer, session: LibrarySession) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ambrosia"
        window.titleVisibility = .hidden   // suppress "Ambrosia" — count label replaces it
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
        let toolbar = NSToolbar(identifier: "LibraryToolbar2")
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
            item.toolTip = "Search titles and authors"
            item.resignsFirstResponderWithCancel = true
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldChanged(_:))
            return item

        case .librarySidebarToggle:
            return makeIconItem(
                identifier, label: "Sidebar",
                image: "sidebar.left",
                action: #selector(triggerSidebarToggle)
            )

        case .libraryTitle:
            return makeTitleItem(identifier)

        case .libraryFilter:
            return makeIconItem(
                identifier, label: "Filter",
                image: "line.3.horizontal.decrease.circle",
                action: #selector(toggleFilter)
            )

        case .librarySort:
            return makeSortItem(identifier)

        case .libraryCollections:
            return makeIconItem(
                identifier, label: "Collections",
                image: "tray.2",
                action: #selector(showCollections)
            )

        case .libraryReadingGoal:
            return makeIconItem(
                identifier, label: "Goal",
                image: "target",
                action: #selector(showReadingGoal)
            )

        case .libraryExport:
            return makeIconItem(
                identifier, label: "Export",
                image: "arrow.up.doc",
                action: #selector(triggerExport)
            )

        case .libraryViewMode:
            return makeViewModeItem(identifier)

        default:
            return nil
        }
    }

    // MARK: - Item builders

    private func makeIconItem(_ identifier: NSToolbarItem.Identifier,
                               label: String,
                               image: String,
                               action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label   = label
        item.toolTip = label
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        item.image   = NSImage(systemSymbolName: image, accessibilityDescription: label)?
            .withSymbolConfiguration(cfg)
        item.target  = self
        item.action  = action
        return item
    }

    private func makeSortItem(_ identifier: NSToolbarItem.Identifier) -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label   = "Sort"
        item.toolTip = "Sort order"
        let sortCfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        item.image   = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")?
            .withSymbolConfiguration(sortCfg)
        item.showsIndicator = true

        let menu = NSMenu()
        for field in SortField.allCases {
            let mi = NSMenuItem(title: field.label, action: #selector(sortMenuItemSelected(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = field
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let ascItem = NSMenuItem(title: "Ascending",  action: #selector(setSortAscending),  keyEquivalent: "")
        let descItem = NSMenuItem(title: "Descending", action: #selector(setSortDescending), keyEquivalent: "")
        ascItem.target  = self
        descItem.target = self
        menu.addItem(ascItem)
        menu.addItem(descItem)

        item.menu = menu
        sortMenuToolbarItem = item
        return item
    }

    private func makeViewModeItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let seg = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "list.bullet",   accessibilityDescription: "List")!,
                NSImage(systemSymbolName: "envelope",       accessibilityDescription: "Email")!,
                NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Grid")!,
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
        // Two-line block: "1,234 fics" (semibold) + "— read" scaffold (small, tertiary).
        // Left-aligned so it sits naturally after the sidebar toggle button.
        let ficLabel = NSTextField(labelWithString: "")
        ficLabel.font      = NSFont.systemFont(ofSize: 12, weight: .semibold)
        ficLabel.textColor = .labelColor
        ficLabel.alignment = .left
        ficLabel.setContentHuggingPriority(.required, for: .vertical)
        ficLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let readLabel = NSTextField(labelWithString: "— read")
        readLabel.font      = NSFont.systemFont(ofSize: 10)
        readLabel.textColor = .tertiaryLabelColor
        readLabel.alignment = .left
        readLabel.setContentHuggingPriority(.required, for: .vertical)
        readLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let stack = NSStackView(views: [ficLabel, readLabel])
        stack.orientation  = .vertical
        stack.alignment    = .leading
        stack.spacing      = 1
        stack.setHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        // Give the stack a concrete frame so the toolbar item doesn't clip it
        stack.frame = NSRect(x: 0, y: 0, width: 140, height: 38)

        ficCountLabel  = ficLabel
        readCountLabel = readLabel
        updateCountLabel()

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label   = "Library"
        item.view    = stack
        item.minSize = NSSize(width: 100, height: 38)
        item.maxSize = NSSize(width: 220, height: 38)
        return item
    }

    private func updateCountLabel() {
        guard let ts = toolbarState, let sess = session else { return }
        let count = ts.activeFilterResult?.totalCount ?? sess.totalCount
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        let str = fmt.string(from: NSNumber(value: count)) ?? "\(count)"
        ficCountLabel?.stringValue = "\(str) fics"
    }

    /// Observation loop: re-fires whenever filter result or total count changes.
    private func startObservingCounts() {
        scheduleCounting()
    }

    private func scheduleCounting() {
        withObservationTracking {
            _ = toolbarState?.activeFilterResult?.totalCount
            _ = session?.totalCount
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateCountLabel()
                self?.scheduleCounting()
            }
        }
    }

    // MARK: - Actions

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        toolbarState?.searchText = sender.stringValue
    }

    @objc private func toggleFilter() {
        toolbarState?.showFilterDrawer = true
    }

    @objc private func triggerSidebarToggle() {
        toolbarState?.toggleEmailSidebar = true
    }

    @objc private func sortMenuItemSelected(_ sender: NSMenuItem) {
        guard let field = sender.representedObject as? SortField else { return }
        toolbarState?.sortField = field
    }

    @objc private func setSortAscending()  { toolbarState?.ascending = true  }
    @objc private func setSortDescending() { toolbarState?.ascending = false }

    @objc private func showCollections()  { toolbarState?.showCollections  = true }
    @objc private func showReadingGoal()  { toolbarState?.showReadingGoal  = true }
    @objc private func triggerExport()    { toolbarState?.triggerExport    = true }

    @objc private func viewModeSegmentChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 1:  toolbarState?.viewMode = .email
        case 2:  toolbarState?.viewMode = .grid
        default: toolbarState?.viewMode = .list
        }
    }
}
