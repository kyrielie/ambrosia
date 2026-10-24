import AppKit

// MARK: - BookSearchResult

struct BookSearchResult: Equatable, Identifiable {
    var id: String { "\(spineIndex)-\(characterOffset)" }
    let spineIndex: Int
    let characterOffset: Int
    let excerpt: String
}

// MARK: - SearchBarDelegate

protocol SearchBarDelegate: AnyObject {
    func searchBar(_ bar: SearchBarViewController, didSearch term: String)
    func searchBar(_ bar: SearchBarViewController, didSelect result: BookSearchResult)
    func searchBarDidRequestNext(_ bar: SearchBarViewController)
    func searchBarDidRequestPrevious(_ bar: SearchBarViewController)
    func searchBarDidDismiss(_ bar: SearchBarViewController)
}

// MARK: - SearchBarViewController

final class SearchBarViewController: NSViewController {

    weak var delegate: SearchBarDelegate?
    var onExpandedChange: ((Bool) -> Void)?

    private var searchField: NSSearchField?
    private var resultLabel: NSTextField?
    private var prevButton: NSButton?
    private var nextButton: NSButton?
    private var closeButton: NSButton?
    private var resultsTable: NSTableView?
    private var resultsScroll: NSScrollView?

    private var results: [BookSearchResult] = []
    private var chapterTitles: [Int: String] = [:]
    private var selectedResultIndex = -1
    private var expanded = false

    private var rootHeightConstraint: NSLayoutConstraint?
    private var resultsPanelConstraints: [NSLayoutConstraint] = []

    var searchFieldValue: String {
        searchField?.stringValue ?? ""
    }

    var resultCount: Int {
        results.count
    }

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 410, height: 48))
        root.material = .hudWindow
        root.blendingMode = .withinWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        root.layer?.borderColor = NSColor.separatorColor.cgColor
        root.layer?.borderWidth = 0.5
        root.translatesAutoresizingMaskIntoConstraints = false

        let field = NSSearchField()
        field.placeholderString = "Search in book…"
        field.focusRingType = .none
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(field)
        self.searchField = field

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(label)
        self.resultLabel = label

        let prev = makeIconButton(symbol: "chevron.up", tip: "Previous result", action: #selector(prevTapped))
        let next = makeIconButton(symbol: "chevron.down", tip: "Next result", action: #selector(nextTapped))
        let close = makeIconButton(symbol: "xmark", tip: "Close search", action: #selector(closeTapped))

        prev.isEnabled = false
        next.isEnabled = false

        [prev, next, close].forEach { root.addSubview($0) }
        self.prevButton = prev
        self.nextButton = next
        self.closeButton = close

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("excerpt"))
        col.title = "Results"
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 44
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        self.resultsTable = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.isHidden = true
        root.addSubview(scroll)
        self.resultsScroll = scroll

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),

            label.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 68),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),

            prev.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            prev.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            prev.widthAnchor.constraint(equalToConstant: 26),
            prev.heightAnchor.constraint(equalToConstant: 26),

            next.leadingAnchor.constraint(equalTo: prev.trailingAnchor, constant: 2),
            next.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            next.widthAnchor.constraint(equalToConstant: 26),
            next.heightAnchor.constraint(equalToConstant: 26),

            close.leadingAnchor.constraint(equalTo: next.trailingAnchor, constant: 4),
            close.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            close.widthAnchor.constraint(equalToConstant: 24),
            close.heightAnchor.constraint(equalToConstant: 24)
        ])

        resultsPanelConstraints = [
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ]

        let heightConstraint = root.heightAnchor.constraint(equalToConstant: 48)
        heightConstraint.isActive = true
        self.rootHeightConstraint = heightConstraint

        self.view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusSearchField(selectAll: false)
    }

    func focusSearchField(selectAll: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let field = self.searchField, let window = self.view.window else { return }
            window.makeFirstResponder(field)
            if selectAll, let editor = window.firstResponder as? NSTextView {
                editor.selectAll(nil)
            }
        }
    }

    func beginSearch(with text: String?) {
        _ = view
        searchField?.stringValue = text ?? ""
        setExpanded(!(text ?? "").isEmpty)
        if let text, !text.isEmpty {
            delegate?.searchBar(self, didSearch: text)
        }
        focusSearchField(selectAll: text?.isEmpty == false)
    }

    func showResults(_ results: [BookSearchResult], chapterTitles: [Int: String]) {
        self.results = results
        self.chapterTitles = chapterTitles
        self.selectedResultIndex = -1

        let count = results.count
        let text: String
        if count == 0 {
            text = "No results"
        } else if count >= 250 {
            text = "250+ found"
        } else {
            text = "\(count) found"
        }
        resultLabel?.stringValue = text
        resultLabel?.textColor = count == 0 ? .systemRed : .secondaryLabelColor

        prevButton?.isEnabled = count > 0
        nextButton?.isEnabled = count > 0

        resultsTable?.reloadData()
        setExpanded(!searchFieldValue.isEmpty)
    }

    func selectResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        selectedResultIndex = index
        resultsTable?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        resultsTable?.scrollRowToVisible(index)
        delegate?.searchBar(self, didSelect: results[index])
    }

    func stepResult(by delta: Int) {
        guard !results.isEmpty else { return }
        let base = selectedResultIndex < 0 ? (delta > 0 ? -1 : 0) : selectedResultIndex
        selectResult(at: (base + delta + results.count) % results.count)
    }

    func clear() {
        searchField?.stringValue = ""
        results = []
        chapterTitles = [:]
        selectedResultIndex = -1
        resultsTable?.reloadData()
        resultLabel?.stringValue = ""
        prevButton?.isEnabled = false
        nextButton?.isEnabled = false
        setExpanded(false)
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        resultsScroll?.isHidden = !value
        rootHeightConstraint?.constant = value ? 340 : 48
        if value {
            NSLayoutConstraint.activate(resultsPanelConstraints)
        } else {
            NSLayoutConstraint.deactivate(resultsPanelConstraints)
        }
        onExpandedChange?(value)
    }

    // MARK: - Actions

    @objc private func prevTapped() {
        delegate?.searchBarDidRequestPrevious(self)
    }

    @objc private func nextTapped() {
        delegate?.searchBarDidRequestNext(self)
    }

    @objc private func closeTapped() {
        delegate?.searchBarDidDismiss(self)
    }

    // MARK: - Helpers

    private func makeIconButton(symbol: String, tip: String, action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let btn = NSButton(image: img, target: self, action: action)
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.toolTip = tip
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }
}

// MARK: - NSSearchFieldDelegate

extension SearchBarViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        setExpanded(!field.stringValue.isEmpty)
        delegate?.searchBar(self, didSearch: field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            delegate?.searchBarDidRequestNext(self)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            delegate?.searchBarDidDismiss(self)
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            stepResult(by: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            stepResult(by: -1)
            return true
        }
        return false
    }
}

// MARK: - NSTableViewDataSource & Delegate

extension SearchBarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let cellID = NSUserInterfaceItemIdentifier("SearchExcerptCell")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView)
            ?? {
                let view = NSTableCellView()
                view.identifier = cellID
                let label = NSTextField(wrappingLabelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.maximumNumberOfLines = 2
                view.addSubview(label)
                view.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
                    label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
                    label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
                ])
                return view
            }()
        let result = results[row]
        let chapter = chapterTitles[result.spineIndex] ?? "Chapter \(result.spineIndex + 1)"
        cell.textField?.stringValue = "\(chapter)  ·  \(result.excerpt)"
        cell.textField?.font = NSFont.systemFont(ofSize: 11)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = resultsTable else { return }
        let row = table.selectedRow
        guard results.indices.contains(row), selectedResultIndex != row else { return }
        selectedResultIndex = row
        delegate?.searchBar(self, didSelect: results[row])
    }
}
