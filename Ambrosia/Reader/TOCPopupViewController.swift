import AppKit

// MARK: - TOCPopupOutline / Table

final class TOCPopupTableView: NSTableView {
    var onActivate: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, Keypad Enter
            if let onActivate {
                onActivate()
                return
            }
        case 53: // Escape
            if let onCancel {
                onCancel()
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }
}

// MARK: - TOCPopupCellView

final class TOCPopupCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let markerDot = NSImageView()
    private var leadingConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        markerDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Current Chapter")
        markerDot.contentTintColor = .controlAccentColor
        markerDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(markerDot)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        let leading = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18)
        self.leadingConstraint = leading

        NSLayoutConstraint.activate([
            markerDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            markerDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            markerDot.widthAnchor.constraint(equalToConstant: 8),
            markerDot.heightAnchor.constraint(equalToConstant: 8),

            leading,
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(with entry: TOCPanelEntry, isCurrent: Bool) {
        titleLabel.stringValue = entry.title
        toolTip = entry.title

        let indent = CGFloat(min(entry.depth, 4) * 14) + 18
        leadingConstraint?.constant = indent

        markerDot.isHidden = !isCurrent

        if isCurrent {
            titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            titleLabel.textColor = .controlAccentColor
        } else {
            let weight: NSFont.Weight = entry.depth == 0 ? .medium : .regular
            titleLabel.font = NSFont.systemFont(ofSize: 13, weight: weight)
            titleLabel.textColor = .labelColor
        }
    }
}

// MARK: - TOCPopupViewController

final class TOCPopupViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    var onSelect: ((TOCPanelEntry) -> Void)?
    var onDismiss: (() -> Void)?

    private var allEntries: [TOCPanelEntry] = []
    private var filteredEntries: [TOCPanelEntry] = []
    private var currentSpineIndex: Int = 0

    private var searchField: NSSearchField?
    private var tableView: TOCPopupTableView?
    private var emptyLabel: NSTextField?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 440))
        root.translatesAutoresizingMaskIntoConstraints = false

        let field = NSSearchField()
        field.placeholderString = "Filter contents"
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(field)
        self.searchField = field

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sep)

        let table = TOCPopupTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .regular
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked)
        table.onActivate = { [weak self] in self?.activateSelectedEntry() }
        table.onCancel = { [weak self] in self?.handleCancel() }

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tocCol"))
        col.isEditable = false
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        self.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        let empty = NSTextField(labelWithString: "No matches")
        empty.font = NSFont.systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(empty)
        self.emptyLabel = empty

        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            field.heightAnchor.constraint(equalToConstant: 28),

            sep.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),

            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])

        self.view = root
    }

    func configure(entries: [TOCPanelEntry], currentSpineIndex: Int) {
        _ = view
        self.allEntries = entries
        self.currentSpineIndex = currentSpineIndex
        self.filteredEntries = entries
        self.searchField?.stringValue = ""

        tableView?.reloadData()
        updateEmptyState()
        selectAndScrollToCurrent()

        DispatchQueue.main.async { [weak self] in
            guard let self, let field = self.searchField else { return }
            self.view.window?.makeFirstResponder(field)
        }
    }

    private func updateEmptyState() {
        let empty = filteredEntries.isEmpty
        emptyLabel?.isHidden = !empty
        if empty {
            emptyLabel?.stringValue = allEntries.isEmpty ? "No table of contents" : "No matches"
        }
    }

    private func selectAndScrollToCurrent() {
        guard let table = tableView else { return }
        if let idx = filteredEntries.firstIndex(where: { $0.spineIndex == currentSpineIndex }) {
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            table.scrollRowToVisible(idx)
        } else if !filteredEntries.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        } else {
            table.deselectAll(nil)
        }
    }

    private func activateSelectedEntry() {
        guard let table = tableView else { return }
        let row = table.selectedRow
        guard filteredEntries.indices.contains(row) else { return }
        let entry = filteredEntries[row]
        onSelect?(entry)
    }

    @objc private func tableDoubleClicked() {
        activateSelectedEntry()
    }

    private func handleCancel() {
        if let field = searchField, !field.stringValue.isEmpty {
            field.stringValue = ""
            applyFilter("")
        } else {
            onDismiss?()
        }
    }

    private func applyFilter(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            filteredEntries = allEntries
        } else {
            filteredEntries = allEntries.filter {
                $0.title.lowercased().contains(trimmed) || ($0.workTitle?.lowercased().contains(trimmed) == true)
            }
        }
        tableView?.reloadData()
        updateEmptyState()
        selectAndScrollToCurrent()
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        applyFilter(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let table = tableView else { return false }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            let nextRow = min(table.numberOfRows - 1, table.selectedRow + 1)
            if nextRow >= 0 {
                table.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
                table.scrollRowToVisible(nextRow)
            }
            return true
        } else if commandSelector == #selector(NSResponder.moveUp(_:)) {
            let prevRow = max(0, table.selectedRow - 1)
            if prevRow >= 0 {
                table.selectRowIndexes(IndexSet(integer: prevRow), byExtendingSelection: false)
                table.scrollRowToVisible(prevRow)
            }
            return true
        } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            activateSelectedEntry()
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            handleCancel()
            return true
        }
        return false
    }

    // MARK: - NSTableViewDataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredEntries.indices.contains(row) else { return nil }
        let entry = filteredEntries[row]
        let cellID = NSUserInterfaceItemIdentifier("TOCPopupCellView")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: self) as? TOCPopupCellView)
            ?? TOCPopupCellView()
        cell.identifier = cellID
        let isCurrent = (entry.spineIndex == currentSpineIndex)
        cell.configure(with: entry, isCurrent: isCurrent)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Selection is maintained for keyboard navigation; click/double-click activates.
    }
}
