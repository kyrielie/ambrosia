import AppKit
import SwiftData

// MARK: - EmailSidebarViewController

/// AppKit sidebar for the email split view.
/// NSTableView with 52pt fixed-height rows showing title + author + optional progress bar.
/// No per-row SwiftData access — bookStates dict is populated by the parent.
final class EmailSidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - Callbacks (set by parent before use)

    /// Called on single-click selection change.
    var onSelect: ((CalibreBook?) -> Void)?
    /// Called on double-click — opens the reader.
    var onOpen:   ((CalibreBook) -> Void)?
    /// Called when the user scrolls near the bottom — parent should append next page.
    var onLoadMore: (() -> Void)?

    // MARK: - Data (set externally; call reloadData() after changes)

    var books:      [CalibreBook]     = [] { didSet { tableView?.reloadData() } }
    var bookStates: [Int: BookState]  = [:] { didSet { tableView?.reloadData() } }

    // MARK: - Private

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var hasTriggeredLoadMore = false

    // MARK: - Lifecycle

    override func loadView() {
        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.headerView = nil
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 52
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAutomaticRowHeights = false

        // Single column spanning full width
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("BookColumn"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)

        // Double-click
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // Observe scroll position for pagination
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollDidChange),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )

        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Stretch table column to full width
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.tableColumns.first?.width = tableView.bounds.width
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { books.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("EmailBookCell")
        let cell: EmailBookCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? EmailBookCellView {
            cell = reused
        } else {
            cell = EmailBookCellView()
            cell.identifier = id
        }
        let book  = books[row]
        let state = bookStates[book.id]
        cell.configure(book: book, readPercent: state?.totalReadPercent ?? 0)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 52 }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        onSelect?(row >= 0 ? books[row] : nil)
    }

    // MARK: - Double-click

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < books.count else { return }
        onOpen?(books[row])
    }

    // MARK: - Scroll-to-bottom pagination

    @objc private func scrollDidChange(_ notification: Notification) {
        guard let clipView = scrollView.contentView as? NSClipView,
              let docView  = scrollView.documentView else { return }
        let visibleBottom = clipView.documentVisibleRect.maxY
        let docHeight     = docView.frame.height
        // Trigger when within 150pt of the bottom
        if docHeight > 0, visibleBottom >= docHeight - 150 {
            if !hasTriggeredLoadMore {
                hasTriggeredLoadMore = true
                onLoadMore?()
                // Reset after a brief delay so rapid scrolling doesn't multi-fire
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.hasTriggeredLoadMore = false
                }
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - EmailBookCellView

/// Fixed 52pt table cell with title, author, and optional progress bar.
final class EmailBookCellView: NSTableCellView {

    private let titleLabel  = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let progressBar = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupSubviews() {
        // Title
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Author
        authorLabel.font = NSFont.systemFont(ofSize: 11)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.maximumNumberOfLines = 1
        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(authorLabel)

        // Progress bar — thin accent-coloured strip at the bottom
        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressBar)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            authorLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            authorLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            authorLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),

            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    // Progress bar width constraint — updated in configure()
    private var progressWidthConstraint: NSLayoutConstraint?

    func configure(book: CalibreBook, readPercent: Double) {
        titleLabel.stringValue  = book.displayTitle
        authorLabel.stringValue = book.displayAuthors

        // Update progress bar
        progressWidthConstraint?.isActive = false
        if readPercent > 0 {
            progressBar.isHidden = false
            // Width is set relative to cell width in layout; use a multiplier constraint
            let w = progressWidthConstraint ?? progressBar.widthAnchor.constraint(equalToConstant: 0)
            w.isActive = false
            // Re-create as a proportional constraint anchored to the cell's full width
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
