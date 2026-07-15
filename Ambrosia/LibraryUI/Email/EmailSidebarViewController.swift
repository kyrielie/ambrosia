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
//   │  └─ NSTableView      │  90pt rows: title / author+stats / AO3 pills / progress
//   └──────────────────────┘
//
// No per-row SwiftData access — bookStates dict is populated by the parent.

final class EmailSidebarViewController: NSViewController,
                                        NSTableViewDataSource,
                                        NSTableViewDelegate {

    // MARK: - Callbacks (set by parent before viewDidLoad)

    var onSelect:      ((CalibreBook?) -> Void)?
    var onOpen:        ((ReadingTarget) -> Void)?
    var onLoadMore:    (() -> Void)?
    var onEditFilter:  (() -> Void)?
    var onClearFilter: (() -> Void)?
    var onContextMenuSetLiked:         (([CalibreBook], Bool) -> Void)?
    var onContextMenuSkip:             (([CalibreBook]) -> Void)?
    var onContextMenuMarkRead:         (([CalibreBook]) -> Void)?
    var onContextMenuResetProgress:    (([CalibreBook]) -> Void)?
    var onContextMenuOpen:             (([CalibreBook]) -> Void)?
    var onContextMenuReadLater:        (([CalibreBook]) -> Void)?
    var onContextMenuCollectionPicker: (([CalibreBook], NSView, NSRect) -> Void)?
    var onToggleLiked:                 (([CalibreBook]) -> Void)?
    var onToggleReadLater:             (([CalibreBook]) -> Void)?

    // MARK: - Dependencies

    var toolbarState: LibraryToolbarState?

    // MARK: - Data (set externally; didSet triggers reload)

    var books:      [CalibreBook]    = [] { didSet { items = books.map { .book($0) } } }
    var items:      [LibraryItem]    = [] { didSet { reloadItemsPreservingSingleSelection(from: oldValue) } }
    var bookStates: [Int: BookState] = [:] { didSet { reloadVisibleRows() } }
    var ao3Metadata: [Int: AO3MetadataRecord] = [:] { didSet { reloadVisibleRows() } }
    var likedIDs: Set<Int> = [] { didSet { reloadVisibleRows() } }
    var readLaterIDs: Set<Int> = [] { didSet { reloadVisibleRows() } }
    /// Collection snapshot for building context menu submenus. Key = name, value = member calibreIDs.
    var collectionMembership: [String: Set<Int>] = [:] { didSet { reloadVisibleRows() } }

    // MARK: - Private

    private var tableView:  NSTableView!
    private var scrollView: NSScrollView!
    private var hasTriggeredLoadMore = false
    private var isRestoringSelection = false

    // MARK: - Degraded-data banner (Finding 12 follow-up)
    //
    // rebuildSidebarItems in EmailLibraryViewController has the identical
    // silent-catch pattern LibraryRootView's rebuildItems had before plan2
    // Finding 12 — five `try? await metaDB....` calls falling back to empty
    // data with no signal at all (not even a #if DEBUG print). This mirrors
    // LibraryRootView's fix on the AppKit side: a thin dismissible banner
    // above the sidebar list, toggled by the parent view controller.
    var onRetryTapped: (() -> Void)?
    var rebuildDegraded: Bool = false {
        didSet {
            guard isViewLoaded else { return }
            degradedBannerHeightConstraint?.constant = rebuildDegraded ? 28 : 0
            degradedBanner?.isHidden = !rebuildDegraded
        }
    }
    private var degradedBanner: NSView!
    private var degradedBannerHeightConstraint: NSLayoutConstraint!

    @objc private func retryButtonClicked() {
        onRetryTapped?()
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView()

        let tv = SidebarTableView()
        tableView = tv
        tv.sidebarVC = self
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.headerView = nil
        tableView.allowsMultipleSelection = true
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight  = 90
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

        let banner = NSView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.15).cgColor
        banner.isHidden = true
        degradedBanner = banner

        let label = NSTextField(labelWithString: "Some library data couldn't load")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let retryButton = NSButton(title: "Retry", target: self, action: #selector(retryButtonClicked))
        retryButton.bezelStyle = .inline
        retryButton.controlSize = .small
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        banner.addSubview(label)
        banner.addSubview(retryButton)
        container.addSubview(banner)

        let heightConstraint = banner.heightAnchor.constraint(equalToConstant: 0)
        degradedBannerHeightConstraint = heightConstraint

        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollDidChange),
            name: NSScrollView.didLiveScrollNotification, object: scrollView
        )



        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: container.topAnchor),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            heightConstraint,
            label.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            retryButton.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -8),
            retryButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: banner.bottomAnchor),
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

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

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
        cell.configure(
            item: items[row],
            readPercent: bookStates[items[row].primaryBook.id]?.totalReadPercent ?? 0,
            ao3Metadata: ao3Metadata[items[row].primaryBook.id],
            isLiked: likedIDs.contains(items[row].primaryBook.id),
            isInReadLater: readLaterIDs.contains(items[row].primaryBook.id),
            collectionPills: manualCollectionPills(for: items[row]),
            showCollectionPills: ReaderPreferences.shared.emailPillsShowCollections,
            onToggleLiked: { [weak self] books in
                self?.onToggleLiked?(books)
            },
            onToggleReadLater: { [weak self] books in
                self?.onToggleReadLater?(books)
            }
        )
        return cell
    }

    private func manualCollectionPills(for item: LibraryItem) -> [String] {
        let ids = Set(item.contextBooks.map(\.id))
        return collectionMembership.compactMap { name, members in
            guard !Self.systemCollectionNames.contains(name),
                  !ids.isDisjoint(with: members) else { return nil }
            return name
        }.sorted()
    }

    private static let systemCollectionNames: Set<String> = [
        "Liked", "Read Later", "Skipped", "Finished", "In Progress", "Has Annotations",
        SystemCollectionID.seriesOrMergedName
    ]

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 90 }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringSelection else { return }
        onSelect?(singleSelectedBook())
    }

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        onOpen?(items[row].readingTarget)
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
        guard row >= 0, row < items.count else { return nil }
        let book = items[row].primaryBook
        let selectedBooks = contextBooks(fallbackRow: row)
        let isBulk = selectedBooks.count > 1

        let menu = NSMenu()

        // Open
        let openItem = NSMenuItem(title: isBulk ? "Open Selected" : "Open", action: #selector(contextOpen(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = selectedBooks
        menu.addItem(openItem)

        menu.addItem(.separator())

        // Like / Unlike
        if isBulk {
            let likeItem = NSMenuItem(title: "Like Selected", action: #selector(contextLike(_:)), keyEquivalent: "")
            likeItem.target = self
            likeItem.representedObject = ["books": selectedBooks, "liked": true] as [String: Any]
            menu.addItem(likeItem)
            let unlikeItem = NSMenuItem(title: "Unlike Selected", action: #selector(contextLike(_:)), keyEquivalent: "")
            unlikeItem.target = self
            unlikeItem.representedObject = ["books": selectedBooks, "liked": false] as [String: Any]
            menu.addItem(unlikeItem)
        } else {
            let likeTitle = likedIDs.contains(book.id) ? "Unlike" : "Like"
            let likeItem  = NSMenuItem(title: likeTitle, action: #selector(contextLike(_:)), keyEquivalent: "")
            likeItem.target = self
            likeItem.representedObject = ["books": selectedBooks, "liked": !likedIDs.contains(book.id)] as [String: Any]
            menu.addItem(likeItem)
        }

        let readLaterItem = NSMenuItem(title: isBulk ? "Add Selected to Read Later" : "Read Later", action: #selector(contextReadLater(_:)), keyEquivalent: "")
        readLaterItem.target = self
        readLaterItem.representedObject = selectedBooks
        menu.addItem(readLaterItem)

        let markReadItem = NSMenuItem(title: isBulk ? "Mark Selected as Read" : "Mark as Read", action: #selector(contextMarkRead(_:)), keyEquivalent: "")
        markReadItem.target = self
        markReadItem.representedObject = selectedBooks
        menu.addItem(markReadItem)

        let resetItem = NSMenuItem(title: "Reset Reading Progress", action: #selector(contextResetProgress(_:)), keyEquivalent: "")
        resetItem.target = self
        resetItem.representedObject = selectedBooks
        menu.addItem(resetItem)

        let skipItem = NSMenuItem(title: isBulk ? "Skip Selected" : "Skip", action: #selector(contextSkip(_:)), keyEquivalent: "")
        skipItem.target = self
        skipItem.representedObject = selectedBooks
        menu.addItem(skipItem)

        menu.addItem(.separator())

        let collectionItem = NSMenuItem(title: "Add to Collection…", action: #selector(contextShowCollectionPicker(_:)), keyEquivalent: "")
        collectionItem.target = self
        collectionItem.representedObject = ["books": selectedBooks, "row": row] as [String: Any]
        menu.addItem(collectionItem)

        return menu
    }

    @objc private func contextOpen(_ sender: NSMenuItem) {
        guard let books = sender.representedObject as? [CalibreBook] else { return }
        onContextMenuOpen?(books)
    }

    @objc private func contextLike(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: Any],
              let books = dict["books"] as? [CalibreBook],
              let liked = dict["liked"] as? Bool else { return }
        onContextMenuSetLiked?(books, liked)
    }

    @objc private func contextSkip(_ sender: NSMenuItem) {
        guard let books = sender.representedObject as? [CalibreBook] else { return }
        onContextMenuSkip?(books)
    }

    @objc private func contextMarkRead(_ sender: NSMenuItem) {
        guard let books = sender.representedObject as? [CalibreBook] else { return }
        onContextMenuMarkRead?(books)
    }

    @objc private func contextResetProgress(_ sender: NSMenuItem) {
        guard let books = sender.representedObject as? [CalibreBook] else { return }
        onContextMenuResetProgress?(books)
    }

    @objc private func contextReadLater(_ sender: NSMenuItem) {
        guard let books = sender.representedObject as? [CalibreBook] else { return }
        onContextMenuReadLater?(books)
    }

    @objc private func contextShowCollectionPicker(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: Any],
              let books = dict["books"] as? [CalibreBook],
              let row = dict["row"] as? Int,
              row >= 0,
              row < tableView.numberOfRows else { return }
        onContextMenuCollectionPicker?(books, tableView, tableView.rect(ofRow: row))
    }

    func updateSelectionForContextClick(row: Int, event: NSEvent) {
        guard row >= 0, row < items.count else { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            if tableView.selectedRowIndexes.contains(row) {
                tableView.deselectRow(row)
            } else {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
            }
        } else if modifiers.contains(.shift), tableView.selectedRow >= 0 {
            let lower = min(tableView.selectedRow, row)
            let upper = max(tableView.selectedRow, row)
            tableView.selectRowIndexes(IndexSet(integersIn: lower...upper), byExtendingSelection: false)
        } else if !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func contextBooks(fallbackRow row: Int) -> [CalibreBook] {
        let selected = tableView.selectedRowIndexes.compactMap { idx in
            idx >= 0 && idx < items.count ? items[idx].contextBooks : nil
        }.flatMap { $0 }
        return selected.isEmpty ? items[row].contextBooks : selected
    }

    private func reloadItemsPreservingSingleSelection(from oldItems: [LibraryItem]) {
        guard let tableView else { return }
        let selectedIndexes = tableView.selectedRowIndexes
        let selectedID = selectedIndexes.count == 1
            ? selectedIndexes.compactMap { idx in idx >= 0 && idx < oldItems.count ? oldItems[idx].primaryBook.id : nil }.first
            : nil

        isRestoringSelection = true
        tableView.reloadData()
        tableView.deselectAll(nil)

        if let selectedID, let restoredIndex = items.firstIndex(where: { $0.primaryBook.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: restoredIndex), byExtendingSelection: false)
        }
        isRestoringSelection = false

        onSelect?(singleSelectedBook())
    }

    private func reloadBooksPreservingSingleSelection(from oldBooks: [CalibreBook]) {
        reloadItemsPreservingSingleSelection(from: oldBooks.map { .book($0) })
    }

    private func singleSelectedBook() -> CalibreBook? {
        let indexes = tableView.selectedRowIndexes
        guard indexes.count == 1, let row = indexes.first, row >= 0, row < items.count else {
            return nil
        }
        return items[row].primaryBook
    }

    private func reloadVisibleRows() {
        guard let tableView else { return }
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound,
              visibleRows.length > 0,
              visibleRows.location >= 0,
              visibleRows.location < tableView.numberOfRows,
              tableView.numberOfColumns > 0 else { return }
        let upperBound = min(visibleRows.location + visibleRows.length, tableView.numberOfRows)
        guard upperBound > visibleRows.location else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: visibleRows.location..<upperBound),
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

private extension LibraryItem {
    var primaryBook: CalibreBook {
        readingTarget.primaryBook
    }

    var contextBooks: [CalibreBook] {
        switch self {
        case .book(let book): return [book]
        case .series(let series): return series.works
        case .orphanedSeriesEntry(let book, _): return [book]
        }
    }

    var readingTarget: ReadingTarget {
        switch self {
        case .book(let book): return .singleBook(book)
        case .series(let series): return .series(series)
        case .orphanedSeriesEntry(let book, _): return .singleBook(book)
        }
    }
}

// MARK: - EmailBookCellView

/// Fixed 90pt table cell: title / author+metadata / AO3 pills / inline progress row.
/// `likeButton`/`readLaterButton` are 34×34pt and centered on the cell's own
/// `centerYAnchor` (not `titleLabel`'s) so they sit in the middle of the full
/// row height rather than clustering near the top edge next to the title.
final class EmailBookCellView: NSTableCellView {

    private let titleLabel    = NSTextField(labelWithString: "")
    private let authorLabel   = NSTextField(labelWithString: "")
    private let metadataClip  = NSView()
    private let metadataStack = NSStackView()
    private let progressLabel = NSTextField(labelWithString: "")
    private let progressTrack = NSView()
    private let progressFill  = NSView()
    private let likeButton = NSButton()
    private let readLaterButton = NSButton()
    private var representedContextBooks: [CalibreBook] = []
    private var onToggleLiked: (([CalibreBook]) -> Void)?
    private var onToggleReadLater: (([CalibreBook]) -> Void)?

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

        likeButton.isBordered = false
        likeButton.bezelStyle = .regularSquare
        likeButton.imagePosition = .imageOnly
        likeButton.target = self
        likeButton.action = #selector(toggleLiked)
        likeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(likeButton)

        readLaterButton.isBordered = false
        readLaterButton.bezelStyle = .regularSquare
        readLaterButton.imagePosition = .imageOnly
        readLaterButton.target = self
        readLaterButton.action = #selector(toggleReadLaterAction)
        readLaterButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(readLaterButton)

        authorLabel.font = NSFont.systemFont(ofSize: 11)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.maximumNumberOfLines = 1
        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(authorLabel)

        metadataClip.wantsLayer = true
        metadataClip.layer?.masksToBounds = true
        metadataClip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metadataClip)

        metadataStack.orientation = .horizontal
        metadataStack.alignment = .centerY
        metadataStack.spacing = 4
        metadataStack.distribution = .gravityAreas
        metadataStack.translatesAutoresizingMaskIntoConstraints = false
        metadataClip.addSubview(metadataStack)

        progressLabel.font      = NSFont.systemFont(ofSize: 10)
        progressLabel.textColor = .tertiaryLabelColor
        progressLabel.lineBreakMode = .byClipping
        progressLabel.maximumNumberOfLines = 1
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressLabel)

        progressTrack.wantsLayer = true
        progressTrack.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        progressTrack.layer?.cornerRadius = 2
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressTrack)

        progressFill.wantsLayer = true
        progressFill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progressFill.layer?.cornerRadius = 2
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: readLaterButton.leadingAnchor, constant: -9),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),

            readLaterButton.trailingAnchor.constraint(equalTo: likeButton.leadingAnchor, constant: -7),
            readLaterButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            readLaterButton.widthAnchor.constraint(equalToConstant: 34),
            readLaterButton.heightAnchor.constraint(equalToConstant: 34),

            likeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            likeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            likeButton.widthAnchor.constraint(equalToConstant: 34),
            likeButton.heightAnchor.constraint(equalToConstant: 34),

            authorLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            authorLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            authorLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            metadataClip.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metadataClip.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            metadataClip.topAnchor.constraint(equalTo: authorLabel.bottomAnchor, constant: 5),
            metadataClip.heightAnchor.constraint(equalToConstant: 18),

            metadataStack.leadingAnchor.constraint(equalTo: metadataClip.leadingAnchor),
            metadataStack.centerYAnchor.constraint(equalTo: metadataClip.centerYAnchor),
            metadataStack.heightAnchor.constraint(lessThanOrEqualTo: metadataClip.heightAnchor),

            progressLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressLabel.topAnchor.constraint(equalTo: metadataClip.bottomAnchor, constant: 5),
            progressLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),

            progressTrack.leadingAnchor.constraint(equalTo: progressLabel.trailingAnchor, constant: 8),
            // Not tied to titleLabel.trailing: that anchor is squeezed by the
            // like/read-later icon row above (title row only), which has no
            // bearing on this row's own layout. Tying progressTrack's ≥56pt
            // minimum width to that already-constrained anchor produced an
            // unsatisfiable pair of constraints at the cell's fixed 168pt
            // width (progressLabel ≥42 + 8pt gap + progressTrack ≥56 needs
            // more horizontal room than titleLabel.trailing left available),
            // which AppKit could only resolve by breaking the ≥56 constraint
            // at runtime. Pinning to the cell's own trailing edge (matching
            // likeButton's -10 inset) gives this row the same margin as every
            // other row without inheriting a constraint that belongs to a
            // different row.
            progressTrack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            progressTrack.centerYAnchor.constraint(equalTo: progressLabel.centerYAnchor),
            progressTrack.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
            progressTrack.heightAnchor.constraint(equalToConstant: 4),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
        ])
    }

    private var progressWidthConstraint: NSLayoutConstraint?

    func configure(
        item: LibraryItem,
        readPercent: Double,
        ao3Metadata: AO3MetadataRecord?,
        isLiked: Bool,
        isInReadLater: Bool,
        collectionPills: [String],
        showCollectionPills: Bool,
        onToggleLiked: @escaping ([CalibreBook]) -> Void,
        onToggleReadLater: @escaping ([CalibreBook]) -> Void
    ) {
        representedContextBooks = item.contextBooks
        self.onToggleLiked = onToggleLiked
        self.onToggleReadLater = onToggleReadLater
        likeButton.image = NSImage(systemSymbolName: isLiked ? "star.fill" : "star", accessibilityDescription: isLiked ? "Unlike" : "Like")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        likeButton.contentTintColor = isLiked ? .systemYellow : .secondaryLabelColor
        readLaterButton.image = NSImage(systemSymbolName: isInReadLater ? "bookmark.fill" : "bookmark", accessibilityDescription: isInReadLater ? "Remove from Read Later" : "Add to Read Later")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        readLaterButton.contentTintColor = isInReadLater ? .controlAccentColor : .secondaryLabelColor
        switch item {
        case .book(let book):
            titleLabel.stringValue = book.displayTitle
            authorLabel.attributedStringValue = Self.authorLine(for: book, ao3Metadata: ao3Metadata)
            showCollectionPills ? configureCollectionPills(collectionPills) : configureMetadataPills(ao3Metadata)
        case .series(let series):
            titleLabel.stringValue = series.seriesName
            authorLabel.attributedStringValue = Self.seriesLine(for: series)
            showCollectionPills ? configureCollectionPills(collectionPills) : configureSeriesPills(series)
        case .orphanedSeriesEntry(let book, let warning):
            titleLabel.stringValue = "\(book.displayTitle) (\(warning.seriesName) #\(warning.seriesIndex))"
            authorLabel.attributedStringValue = Self.authorLine(for: book, ao3Metadata: ao3Metadata)
            showCollectionPills ? configureCollectionPills(collectionPills) : configureMetadataPills(ao3Metadata)
        }

        if readPercent > 0.01 {
            let pct = Int((min(readPercent, 1.0) * 100).rounded())
            progressLabel.stringValue = "\(pct)% read"
            progressLabel.textColor   = .controlAccentColor
        } else {
            progressLabel.stringValue = "Unread"
            progressLabel.textColor   = .tertiaryLabelColor
        }

        progressWidthConstraint?.isActive = false
        if readPercent > 0.01 {
            progressFill.isHidden = false
            let prop = NSLayoutConstraint(
                item: progressFill, attribute: .width,
                relatedBy: .equal,
                toItem: progressTrack, attribute: .width,
                multiplier: CGFloat(min(readPercent, 1.0)), constant: 0
            )
            prop.isActive = true
            progressWidthConstraint = prop
        } else {
            progressFill.isHidden = true
        }
    }

    @objc private func toggleLiked() {
        guard !representedContextBooks.isEmpty else { return }
        onToggleLiked?(representedContextBooks)
    }

    @objc private func toggleReadLaterAction() {
        guard !representedContextBooks.isEmpty else { return }
        onToggleReadLater?(representedContextBooks)
    }

    private func configureCollectionPills(_ names: [String]) {
        metadataStack.arrangedSubviews.forEach { view in
            metadataStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        metadataClip.isHidden = names.isEmpty
        for name in names {
            metadataStack.addArrangedSubview(Self.metadataPill(label: name, color: .controlAccentColor))
        }
    }

    private func configureSeriesPills(_ series: SeriesGroup) {
        metadataStack.arrangedSubviews.forEach { view in
            metadataStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        var seen = Set<String>()
        let pills = [
            (series.allRatings, NSColor.systemOrange),
            (series.allFandoms, NSColor.systemPurple),
            (series.allRelationships, NSColor.systemPink),
            (series.allCharacters, NSColor.systemTeal),
            (series.allCategories, NSColor.systemBlue),
            (series.allWarnings, NSColor.systemRed),
            (series.allAdditionalTags, NSColor.secondaryLabelColor),
            (series.allTags, NSColor.secondaryLabelColor),
        ].flatMap { values, color in
            values.compactMap { value -> (String, NSColor)? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
                return (trimmed, color)
            }
        }
        metadataClip.isHidden = pills.isEmpty
        for (label, color) in pills {
            metadataStack.addArrangedSubview(Self.metadataPill(label: label, color: color))
        }
    }

    private func configureMetadataPills(_ metadata: AO3MetadataRecord?) {
        metadataStack.arrangedSubviews.forEach { view in
            metadataStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard let metadata else {
            metadataClip.isHidden = true
            return
        }

        var seen = Set<String>()
        let pills = [
            (metadata.fandoms, NSColor.systemPurple),
            (metadata.relationships, NSColor.systemPink),
            (metadata.characters, NSColor.systemTeal),
        ].flatMap { values, color in
            values.compactMap { value -> (String, NSColor)? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
                return (trimmed, color)
            }
        }

        metadataClip.isHidden = pills.isEmpty
        for (label, color) in pills {
            metadataStack.addArrangedSubview(Self.metadataPill(label: label, color: color))
        }
    }

    private static func authorLine(for book: CalibreBook, ao3Metadata: AO3MetadataRecord?) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: book.displayAuthors,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )

        let details = [
            (ao3Metadata?.wordCount ?? book.wordCount).map(formatWordCount),
            completionStatus(for: ao3Metadata),
        ].compactMap { $0 }

        guard !details.isEmpty else { return result }
        result.append(NSAttributedString(
            string: "  \(details.joined(separator: "  "))",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        ))
        return result
    }

    private static func seriesLine(for series: SeriesGroup) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: series.displayAuthors,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        let details = [
            "\(series.works.count) works",
            series.displayWordCount.isEmpty ? nil : series.displayWordCount,
            series.displayChapterCount.isEmpty ? nil : series.displayChapterCount,
        ].compactMap { $0 }
        if !details.isEmpty {
            result.append(NSAttributedString(
                string: "  \(details.joined(separator: "  "))",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            ))
        }
        return result
    }

    private static func completionStatus(for metadata: AO3MetadataRecord?) -> String? {
        guard let current = metadata?.chapterCurrent else { return nil }
        guard let total = metadata?.chapterTotal else { return AO3CompletionStatus.workInProgress.rawValue }
        return current == total
            ? AO3CompletionStatus.complete.rawValue         // §5
            : AO3CompletionStatus.workInProgress.rawValue   // §5
    }

    private static func formatWordCount(_ count: Int) -> String {
        switch count {
        case 0..<1_000: return "\(count) words"
        case 0..<1_000_000: return String(format: "%.1fk words", Double(count) / 1_000)
        default: return String(format: "%.2fM words", Double(count) / 1_000_000)
        }
    }

    private static func metadataPill(label: String, color: NSColor) -> NSTextField {
        let pill = NSTextField(labelWithString: label)
        pill.font = NSFont.systemFont(ofSize: 10)
        pill.textColor = color
        pill.lineBreakMode = .byTruncatingTail
        pill.maximumNumberOfLines = 1
        pill.drawsBackground = false
        pill.isBezeled = false
        pill.wantsLayer = true
        pill.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        pill.layer?.cornerRadius = 7
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        pill.setContentHuggingPriority(.required, for: .horizontal)
        return pill
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
        sidebarVC?.updateSelectionForContextClick(row: row, event: event)
        return sidebarVC?.contextMenu(for: row) ?? super.menu(for: event)
    }
}
