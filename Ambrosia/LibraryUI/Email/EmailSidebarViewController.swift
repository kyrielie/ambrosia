import AppKit
import SwiftUI
import SwiftData

// MARK: - EmailSidebarViewController
//
// Left pane of the email split view.
//
// Layout (top to bottom):
//   ┌──────────────────────┐
//   │  SidebarFilterPillsView │  SwiftUI, variable height, hidden when no filter active
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

    private var tableView:  NSTableView!
    private var scrollView: NSScrollView!
    private var pillsHost:  NSHostingView<SidebarFilterPillsView>?
    private var hasTriggeredLoadMore = false

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView()

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

        // Scroll view fills the whole container initially;
        // installPillsHost() will re-pin its top edge after the pills view is added.
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
        if let ts = toolbarState { installPillsHost(ts: ts) }
    }

    // MARK: - Pills header

    private func installPillsHost(ts: LibraryToolbarState) {
        let pillsView = SidebarFilterPillsView(
            toolbarState: ts,
            onEdit:  { [weak self] in self?.onEditFilter?()  },
            onClear: { [weak self] in self?.onClearFilter?() }
        )
        let hv = NSHostingView(rootView: pillsView)
        hv.sizingOptions = .preferredContentSize  // lets SwiftUI height drive the constraint
        hv.translatesAutoresizingMaskIntoConstraints = false

        let container = view
        container.addSubview(hv, positioned: .above, relativeTo: scrollView)

        // Remove the scroll view's top-to-container constraint, re-pin below pills
        if let topC = scrollView.constraints.first(where: {
            $0.firstAttribute == .top && $0.secondItem === container
        }) { topC.isActive = false }

        NSLayoutConstraint.activate([
            hv.topAnchor.constraint(equalTo: container.topAnchor),
            hv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: hv.bottomAnchor),
        ])
        pillsHost = hv
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

    deinit { NotificationCenter.default.removeObserver(self) }
}

// MARK: - SidebarFilterPillsView
//
// SwiftUI view that renders filter pills matching the list-view chip style.
// Returns zero height (empty) when no filter is active, so no space is wasted.

struct SidebarFilterPillsView: View {
    let toolbarState: LibraryToolbarState
    let onEdit:  () -> Void
    let onClear: () -> Void

    var body: some View {
        let rules   = toolbarState.filterExpression.groups.flatMap(\.rules).filter(\.isComplete)
        let hasFilter = toolbarState.activeFilterResult != nil && !rules.isEmpty

        if hasFilter {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption)
                    let count = toolbarState.activeFilterResult?.totalCount ?? 0
                    Text("\(count) result\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit") { onEdit() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    Button { onClear() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }

                FlowLayout(spacing: 4) {
                    ForEach(rules) { rule in
                        let negated = rule.op == .notContains || rule.op == .notEquals
                        HStack(spacing: 3) {
                            if negated {
                                Text("NOT")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.red.opacity(0.85))
                                    .clipShape(Capsule())
                            }
                            Text(rule.field.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if !rule.value.isEmpty {
                                Text(rule.value).font(.caption2.bold())
                            }
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(negated ? Color.red.opacity(0.08) : Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(
                            negated ? Color.red.opacity(0.3) : Color.accentColor.opacity(0.3),
                            lineWidth: 0.5))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
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
