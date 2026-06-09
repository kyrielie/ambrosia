import AppKit
import SwiftData

// MARK: - EmailSidebarViewController
//
// Left pane of the email split view.
//
// Layout (top to bottom):
//   ┌──────────────────────┐
//   │  FilterHeaderView    │  fixed 52pt — shows active filter chips or "All fics"
//   ├──────────────────────┤
//   │  NSScrollView        │  fills remaining space
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

    // MARK: - Dependencies

    var toolbarState: LibraryToolbarState?

    // MARK: - Data (set externally; didSet triggers reload)

    var books:      [CalibreBook]    = [] { didSet { tableView?.reloadData() } }
    var bookStates: [Int: BookState] = [:] { didSet { tableView?.reloadData() } }

    // MARK: - Private

    private var tableView:    NSTableView!
    private var scrollView:   NSScrollView!
    private var filterHeader: FilterHeaderView!
    private var hasTriggeredLoadMore = false

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView()

        // --- Filter header ---
        filterHeader = FilterHeaderView()
        filterHeader.translatesAutoresizingMaskIntoConstraints = false
        filterHeader.onEdit  = { [weak self] in self?.onEditFilter?() }
        filterHeader.onClear = { [weak self] in self?.onClearFilter?() }
        container.addSubview(filterHeader)

        // --- Table ---
        tableView = NSTableView()
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
        scrollView.documentView     = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers  = true
        scrollView.borderType          = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollDidChange),
            name: NSScrollView.didLiveScrollNotification, object: scrollView
        )

        // Layout: header pinned to top, scroll fills the rest
        NSLayoutConstraint.activate([
            filterHeader.topAnchor.constraint(equalTo: container.topAnchor),
            filterHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            filterHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            filterHeader.heightAnchor.constraint(equalToConstant: 52),

            scrollView.topAnchor.constraint(equalTo: filterHeader.bottomAnchor),
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
        if let ts = toolbarState { filterHeader.configure(with: ts) }
        startObservingFilter()
    }

    // MARK: - Filter header observation

    private func startObservingFilter() { scheduleFilterObservation() }

    private func scheduleFilterObservation() {
        guard let ts = toolbarState else { return }
        withObservationTracking {
            _ = ts.activeFilterResult
            _ = ts.filterExpression.groups
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, let ts = self.toolbarState else { return }
                self.filterHeader.configure(with: ts)
                self.scheduleFilterObservation()
            }
        }
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

    // MARK: - Double-click

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < books.count else { return }
        onOpen?(books[row])
    }

    // MARK: - Scroll pagination

    @objc private func scrollDidChange(_ notification: Notification) {
        guard let clip = scrollView.contentView as? NSClipView,
              let doc  = scrollView.documentView else { return }
        let visBottom = clip.documentVisibleRect.maxY
        let docHeight = doc.frame.height
        guard docHeight > 0, visBottom >= docHeight - 150 else { return }
        guard !hasTriggeredLoadMore else { return }
        hasTriggeredLoadMore = true
        onLoadMore?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.hasTriggeredLoadMore = false
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

// MARK: - FilterHeaderView
//
// Fixed 52pt bar above the book list showing what filter is active.
//
//  No filter:  [ All fics            ] [Edit]
//  Filtered:   [ 47 matched          ] [Edit] [✕]
//
// "Edit" opens the filter drawer. "✕" clears the filter.

final class FilterHeaderView: NSView {

    var onEdit:  (() -> Void)?
    var onClear: (() -> Void)?

    private let summaryLabel = NSTextField(labelWithString: "All fics")
    private let editButton   = NSButton(title: "Filter", target: nil, action: nil)
    private let clearButton  = NSButton(title: "", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor

        // Bottom separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sep)

        summaryLabel.font      = NSFont.systemFont(ofSize: 11, weight: .medium)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(summaryLabel)

        editButton.bezelStyle = .inline
        editButton.isBordered = true
        editButton.font       = NSFont.systemFont(ofSize: 10)
        editButton.target     = self
        editButton.action     = #selector(editTapped)
        editButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(editButton)

        // Clear button — SF Symbol ✕
        let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        clearButton.image        = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Clear filter")?
            .withSymbolConfiguration(cfg)
        clearButton.bezelStyle   = .regularSquare
        clearButton.isBordered   = false
        clearButton.target       = self
        clearButton.action       = #selector(clearTapped)
        clearButton.isHidden     = true
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),

            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            summaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            editButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            editButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            clearButton.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -4),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 18),
            clearButton.heightAnchor.constraint(equalToConstant: 18),

            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -4),
        ])
    }

    func configure(with ts: LibraryToolbarState) {
        if let result = ts.activeFilterResult, ts.filterExpression.hasCompleteRules {
            let fmt = NumberFormatter()
            fmt.numberStyle = .decimal
            let n = fmt.string(from: NSNumber(value: result.totalCount)) ?? "\(result.totalCount)"
            summaryLabel.stringValue = "\(n) matched"
            summaryLabel.textColor   = .controlAccentColor
            clearButton.isHidden     = false
        } else {
            summaryLabel.stringValue = "All fics"
            summaryLabel.textColor   = .secondaryLabelColor
            clearButton.isHidden     = true
        }
    }

    @objc private func editTapped()  { onEdit?()  }
    @objc private func clearTapped() { onClear?() }
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
