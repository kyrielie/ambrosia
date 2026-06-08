import AppKit
import SwiftData

// MARK: - Toolbar item identifiers

extension NSToolbarItem.Identifier {
    static let librarySearch     = NSToolbarItem.Identifier("ambrosia.library.search")
    static let libraryFilter     = NSToolbarItem.Identifier("ambrosia.library.filter")
    static let librarySort       = NSToolbarItem.Identifier("ambrosia.library.sort")
    static let libraryCollections = NSToolbarItem.Identifier("ambrosia.library.collections")
    static let libraryReadingGoal = NSToolbarItem.Identifier("ambrosia.library.readinggoal")
    static let libraryExport     = NSToolbarItem.Identifier("ambrosia.library.export")
    static let libraryViewMode   = NSToolbarItem.Identifier("ambrosia.library.viewmode")
}

// MARK: - LibraryWindowController

class LibraryWindowController: NSWindowController, NSToolbarDelegate {

    private weak var toolbarState: LibraryToolbarState?
    private var viewModeControl: NSSegmentedControl?
    private var sortMenuToolbarItem: NSMenuToolbarItem?

    init(modelContainer: ModelContainer, session: LibrarySession) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ambrosia"
        window.minSize = NSSize(width: 700, height: 500)
        window.isReleasedWhenClosed = false   // keep alive so Dock click can re-show it
        window.center()
        super.init(window: window)

        let libraryVC = LibraryViewController(
            modelContainer: modelContainer,
            session: session
        )
        window.contentViewController = libraryVC

        // Grab the toolbarState before configuring the toolbar
        toolbarState = libraryVC.toolbarState
        configureToolbar(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Toolbar setup

    private func configureToolbar(window: NSWindow) {
        let toolbar = NSToolbar(identifier: "LibraryToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration  = true
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.librarySearch, .libraryFilter, .librarySort,
         .flexibleSpace,
         .libraryCollections, .libraryReadingGoal, .libraryExport,
         .space,
         .libraryViewMode]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.librarySearch, .libraryFilter, .librarySort,
         .libraryCollections, .libraryReadingGoal, .libraryExport,
         .libraryViewMode,
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
            // Wire search field via target-action (KVO binding to @Observable requires a helper)
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldChanged(_:))
            return item

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

    // MARK: - Actions

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        toolbarState?.searchText = sender.stringValue
    }

    @objc private func toggleFilter() {
        toolbarState?.showFilterDrawer = true
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
