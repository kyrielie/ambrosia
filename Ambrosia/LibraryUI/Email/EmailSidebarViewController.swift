import AppKit
import SwiftUI
import SwiftData

// MARK: - EmailSidebarViewController
//
// Left pane of the email split view.
//
// Layout (top to bottom):
//   ┌──────────────────────┐
//   │  NSScrollView        │  fills all space
//   │  └─ NSTableView      │  64pt rows: title / author / progress text + bar
//   └──────────────────────┘
//
// No per-row SwiftData access — bookStates dict is populated by the parent.

final class EmailSidebarViewController: NSViewController,
                                        NSTableViewDataSource,
                                        NSTableViewDelegate {

    // MARK: - Callbacks (set by parent before viewDidLoad)

    var onSelect:      ((CalibreBook?) -> Void)?
    var onOpen:        ((CalibreBook) -> Void)?
    var onLoadMore:    (() -> Void)?
    var onEditFilter:  (() -> Void)?
    var onClearFilter: (() -> Void)?
    var onContextMenuLike:             ((CalibreBook) -> Void)?
    var onContextMenuSkip:             ((CalibreBook) -> Void)?
    var onContextMenuMarkRead:         ((CalibreBook) -> Void)?
    var onContextMenuOpen:             ((CalibreBook) -> Void)?
    var onContextMenuToggleCollection: ((CalibreBook, String) -> Void)?
    var onContextMenuNewCollection:    ((CalibreBook) -> Void)?

    // MARK: - Dependencies

    var toolbarState: LibraryToolbarState?

    // MARK: - Data (set externally; didSet triggers reload)

    var books:      [CalibreBook]    = [] { didSet { tableView?.reloadData() } }
    var bookStates: [Int: BookState] = [:] { didSet { tableView?.reloadData() } }
    var likedIDs: Set<Int> = [] { didSet { tableView?.reloadData() } }
    /// Collection snapshot for building context menu submenus. Key = name, value = member calibreIDs.
    var collectionMembership: [String: Set<Int>] = [:]

    // MARK: - Private

    private var tableView:  NSTableView!
    private var scrollView: NSScrollView!
    private var hasTriggeredLoadMore = false

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView()

        let tv = SidebarTableView()
        tableView = tv
        tv.sidebarVC = self
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.headerView = nil
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight  = 64
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAutomaticRowHeights = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("BookColumn"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.target       = self
        tableView.doubleAction = #selector(handleDoubleClick)

        scrollView = NSScrollView()
        scrollView.documentView        = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers  = true
        scrollView.borderType          = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollDidChange),
            name: NSScrollView.didLiveScrollNotification, object: scrollView
        )



        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.tableColumns.first?.width = tableView.bounds.width
    }

    func reloadAppearance() {
        view.needsDisplay = true
        scrollView?.needsDisplay = true
        tableView?.reloadData()
        tableView?.needsDisplay = true
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { books.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("EmailBookCell")
        let cell: EmailBookCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? EmailBookCellView {
            cell = reused
        } else {
            cell = EmailBookCellView()
            cell.identifier = id
        }
        let book = books[row]
        cell.configure(book: book, readPercent: bookStates[book.id]?.totalReadPercent ?? 0)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 64 }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        onSelect?(row >= 0 ? books[row] : nil)
    }

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < books.count else { return }
        onOpen?(books[row])
    }

    // MARK: - Scroll pagination

    @objc private func scrollDidChange(_ notification: Notification) {
        let clip = scrollView.contentView
        guard let doc = scrollView.documentView else { return }
        let visBottom = clip.documentVisibleRect.maxY
        let docHeight = doc.frame.height
        guard docHeight > 0, visBottom >= docHeight - 150, !hasTriggeredLoadMore else { return }
        hasTriggeredLoadMore = true
        onLoadMore?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.hasTriggeredLoadMore = false
        }
    }

    // MARK: - Context menu (called by SidebarTableView on right-click)

    func contextMenu(for row: Int) -> NSMenu? {
        guard row >= 0, row < books.count else { return nil }
        let book = books[row]

        let menu = NSMenu()

        // Open
        let openItem = NSMenuItem(title: "Open", action: #selector(contextOpen(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = book
        menu.addItem(openItem)

        menu.addItem(.separator())

        // Like / Unlike
        let likeTitle = likedIDs.contains(book.id) ? "Unlike" : "Like"
        let likeItem  = NSMenuItem(title: likeTitle, action: #selector(contextLike(_:)), keyEquivalent: "")
        likeItem.target = self
        likeItem.representedObject = book
        menu.addItem(likeItem)

        let markReadItem = NSMenuItem(title: "Mark as Read", action: #selector(contextMarkRead(_:)), keyEquivalent: "")
        markReadItem.target = self
        markReadItem.representedObject = book
        menu.addItem(markReadItem)

        let skipItem = NSMenuItem(title: "Skip", action: #selector(contextSkip(_:)), keyEquivalent: "")
        skipItem.target = self
        skipItem.representedObject = book
        menu.addItem(skipItem)

        menu.addItem(.separator())

        // Add to Collection submenu
        let collectionSubmenu = NSMenu(title: "Add to Collection")
        let sortedNames = collectionMembership.keys
            .filter { $0 != "Skipped" || ReaderPreferences.shared.showSkippedCollection }
            .sorted()
        for name in sortedNames {
            let isMember = collectionMembership[name]?.contains(book.id) == true
            let item = NSMenuItem(
                title: isMember ? "✓ \(name)" : name,
                action: #selector(contextToggleCollection(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = ["book": book, "collection": name] as [String: Any]
            collectionSubmenu.addItem(item)
        }
        if !sortedNames.isEmpty {
            collectionSubmenu.addItem(.separator())
        }
        let newItem = NSMenuItem(title: "New Collection…", action: #selector(contextNewCollection(_:)), keyEquivalent: "")
        newItem.target = self
        newItem.representedObject = book
        collectionSubmenu.addItem(newItem)

        let collectionMenuItem = NSMenuItem(title: "Add to Collection", action: nil, keyEquivalent: "")
        collectionMenuItem.submenu = collectionSubmenu
        menu.addItem(collectionMenuItem)

        return menu
    }

    @objc private func contextOpen(_ sender: NSMenuItem) {
        guard let book = sender.representedObject as? CalibreBook else { return }
        onContextMenuOpen?(book)
    }

    @objc private func contextLike(_ sender: NSMenuItem) {
        guard let book = sender.representedObject as? CalibreBook else { return }
        onContextMenuLike?(book)
    }

    @objc private func contextSkip(_ sender: NSMenuItem) {
        guard let book = sender.representedObject as? CalibreBook else { return }
        onContextMenuSkip?(book)
    }

    @objc private func contextMarkRead(_ sender: NSMenuItem) {
        guard let book = sender.representedObject as? CalibreBook else { return }
        onContextMenuMarkRead?(book)
    }

    @objc private func contextToggleCollection(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: Any],
              let book = dict["book"] as? CalibreBook,
              let name = dict["collection"] as? String else { return }
        onContextMenuToggleCollection?(book, name)
    }

    @objc private func contextNewCollection(_ sender: NSMenuItem) {
        guard let book = sender.representedObject as? CalibreBook else { return }
        onContextMenuNewCollection?(book)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

// MARK: - EmailBookCellView

/// Fixed 64pt table cell: title / author / progress text + 2px progress bar.
final class EmailBookCellView: NSTableCellView {

    private let titleLabel    = NSTextField(labelWithString: "")
    private let authorLabel   = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let progressBar   = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupSubviews() {
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        authorLabel.font = NSFont.systemFont(ofSize: 11)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.maximumNumberOfLines = 1
        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(authorLabel)

        progressLabel.font      = NSFont.systemFont(ofSize: 10)
        progressLabel.textColor = .tertiaryLabelColor
        progressLabel.lineBreakMode = .byClipping
        progressLabel.maximumNumberOfLines = 1
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressLabel)

        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressBar)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),

            authorLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            authorLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            authorLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            progressLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            progressLabel.topAnchor.constraint(equalTo: authorLabel.bottomAnchor, constant: 3),

            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    private var progressWidthConstraint: NSLayoutConstraint?

    func configure(book: CalibreBook, readPercent: Double) {
        titleLabel.stringValue  = book.displayTitle
        authorLabel.stringValue = book.displayAuthors

        if readPercent > 0.01 {
            let pct = Int((readPercent * 100).rounded())
            progressLabel.stringValue = "\(pct)% read"
            progressLabel.textColor   = .controlAccentColor
        } else {
            progressLabel.stringValue = "Unread"
            progressLabel.textColor   = .tertiaryLabelColor
        }

        progressWidthConstraint?.isActive = false
        if readPercent > 0.01 {
            progressBar.isHidden = false
            let prop = NSLayoutConstraint(
                item: progressBar, attribute: .width,
                relatedBy: .equal,
                toItem: self, attribute: .width,
                multiplier: CGFloat(min(readPercent, 1.0)), constant: 0
            )
            prop.isActive = true
            progressWidthConstraint = prop
        } else {
            progressBar.isHidden = true
        }
    }
}
// MARK: - SidebarTableView
//
// NSTableView subclass that forwards right-clicks to the sidebar VC so it can
// build a context menu from the clicked row — matching the list-view context menu.

final class SidebarTableView: NSTableView {
    weak var sidebarVC: EmailSidebarViewController?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row   = self.row(at: point)
        return sidebarVC?.contextMenu(for: row) ?? super.menu(for: event)
    }
}
