// BookInfoViewController.swift
// Modal sheet presenting rich AO3 preface metadata, reading statistics, and EPUB sharing.

import AppKit

final class BookInfoViewController: NSViewController {

    private let book: CalibreBook
    private let ao3: AO3MetadataRecord?
    private let epubURL: URL?

    private static let sheetWidth: CGFloat = 520
    private static let baseHeight: CGFloat = 460
    private static let ao3Height: CGFloat = 620
    private static let labelColumnWidth: CGFloat = 110

    init(book: CalibreBook, ao3: AO3MetadataRecord?, epubURL: URL?) {
        self.book = book
        self.ao3 = ao3
        self.epubURL = epubURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let height = ao3 == nil ? Self.baseHeight : Self.ao3Height
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.sheetWidth, height: height))
        root.wantsLayer = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content

        let (stack, fullWidthViews) = buildContentStack()
        content.addSubview(stack)

        let footerSeparator = createSeparator()
        let buttonBox = createBottomBar()
        root.addSubview(footerSeparator)
        root.addSubview(buttonBox)

        var constraints: [NSLayoutConstraint] = [
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor, constant: -8),

            footerSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footerSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footerSeparator.bottomAnchor.constraint(equalTo: buttonBox.topAnchor, constant: -12),

            buttonBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            buttonBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttonBox.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),

            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ]
        constraints += fullWidthViews.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) }
        NSLayoutConstraint.activate(constraints)

        self.view = root
    }

    private func buildContentStack() -> (stack: NSStackView, fullWidth: [NSView]) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let headerBox = createHeaderView()
        let separator = createSeparator()
        let prefaceView = createPrefaceView()

        let fullWidthViews: [NSView] = [headerBox, separator, prefaceView]
        stack.addArrangedSubview(headerBox)
        stack.addArrangedSubview(separator)
        stack.addArrangedSubview(prefaceView)

        return (stack, fullWidthViews)
    }

    private func createHeaderView() -> NSView {
        let headerBox = NSView()
        headerBox.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: book.displayTitle.isEmpty ? "Untitled Document" : book.displayTitle)
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.isSelectable = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerBox.addSubview(titleLabel)

        let authorLabel = NSTextView()
        authorLabel.isEditable = false
        authorLabel.isSelectable = true
        authorLabel.drawsBackground = false
        authorLabel.textContainer?.lineFragmentPadding = 0
        authorLabel.translatesAutoresizingMaskIntoConstraints = false

        let authorAttr = NSMutableAttributedString()
        authorAttr.append(NSAttributedString(string: "By ", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))

        if let authors = ao3?.authors, !authors.isEmpty {
            for (idx, author) in authors.enumerated() {
                let name = author.pseud ?? author.username
                let urlString = author.profileURL ?? "https://archiveofourown.org/users/\(author.username)/pseuds/\(name)"
                if let url = URL(string: urlString) {
                    authorAttr.append(NSAttributedString(string: name, attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                        .link: url,
                        .foregroundColor: NSColor.controlAccentColor
                    ]))
                } else {
                    authorAttr.append(NSAttributedString(string: name, attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]))
                }
                if idx < authors.count - 1 {
                    authorAttr.append(NSAttributedString(string: ", ", attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]))
                }
            }
        } else {
            let authorText = book.displayAuthors.isEmpty ? "Unknown Author" : book.displayAuthors
            authorAttr.append(NSAttributedString(string: authorText, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        authorLabel.textStorage?.setAttributedString(authorAttr)
        headerBox.addSubview(authorLabel)

        let realCoverImage: NSImage? = {
            guard let libraryRoot = AppDelegate.shared?.session.activePath.map(URL.init(fileURLWithPath:)),
                  let coverURL = book.coverURL(libraryRoot: libraryRoot),
                  FileManager.default.fileExists(atPath: coverURL.path) else { return nil }
            return NSImage(contentsOf: coverURL)
        }()

        var constraints: [NSLayoutConstraint] = []

        if let coverImage = realCoverImage {
            let coverView = NSImageView()
            coverView.imageScaling = .scaleProportionallyUpOrDown
            coverView.wantsLayer = true
            coverView.layer?.cornerRadius = 6
            coverView.layer?.masksToBounds = true
            coverView.layer?.borderColor = NSColor.separatorColor.cgColor
            coverView.layer?.borderWidth = 0.5
            coverView.image = coverImage
            coverView.translatesAutoresizingMaskIntoConstraints = false
            headerBox.addSubview(coverView)

            constraints += [
                coverView.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor),
                coverView.topAnchor.constraint(equalTo: headerBox.topAnchor),
                coverView.bottomAnchor.constraint(lessThanOrEqualTo: headerBox.bottomAnchor),
                coverView.widthAnchor.constraint(equalToConstant: 64),
                coverView.heightAnchor.constraint(equalToConstant: 90),

                titleLabel.leadingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: 14),
                titleLabel.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor),
                titleLabel.topAnchor.constraint(equalTo: headerBox.topAnchor, constant: 2),

                authorLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                authorLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
                authorLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4)
            ]
        } else {
            constraints += [
                titleLabel.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor),
                titleLabel.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor),
                titleLabel.topAnchor.constraint(equalTo: headerBox.topAnchor, constant: 2),

                authorLabel.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor),
                authorLabel.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor),
                authorLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4)
            ]
        }

        if let storyURL = ao3?.storyURL, URL(string: storyURL) != nil {
            let linkButton = NSButton(title: "View Work on Archive of Our Own ↗", target: self, action: #selector(openStoryURL))
            linkButton.bezelStyle = .inline
            linkButton.isBordered = false
            linkButton.contentTintColor = .controlAccentColor
            linkButton.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            linkButton.translatesAutoresizingMaskIntoConstraints = false
            headerBox.addSubview(linkButton)

            constraints += [
                linkButton.leadingAnchor.constraint(equalTo: authorLabel.leadingAnchor),
                linkButton.topAnchor.constraint(equalTo: authorLabel.bottomAnchor, constant: 6),
                linkButton.bottomAnchor.constraint(lessThanOrEqualTo: headerBox.bottomAnchor, constant: -2)
            ]
        } else {
            constraints += [
                authorLabel.bottomAnchor.constraint(lessThanOrEqualTo: headerBox.bottomAnchor, constant: -2)
            ]
        }

        NSLayoutConstraint.activate(constraints)
        return headerBox
    }

    private func createPrefaceView() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        if let ao3 {
            appendPrefaceRow(label: "Rating:", tags: ao3.rating.map { [$0] } ?? [], to: container)
            appendPrefaceRow(label: "Archive Warning:", tags: ao3.warnings, to: container)
            appendPrefaceRow(label: "Category:", tags: ao3.categories, to: container)
            appendPrefaceRow(label: "Fandom:", tags: ao3.fandoms, to: container)
            appendPrefaceRow(label: "Relationships:", tags: ao3.relationships, to: container)
            appendPrefaceRow(label: "Characters:", tags: ao3.characters, to: container)
            appendPrefaceRow(label: "Additional Tags:", tags: ao3.additionalTags, to: container)

            if !ao3.series.isEmpty {
                appendSeriesRow(series: ao3.series, to: container)
            }

            if let lang = ao3.language {
                appendPlainRow(label: "Language:", value: lang, to: container)
            }

            if !ao3.ao3Collections.isEmpty {
                appendPrefaceRow(label: "Collections:", tags: ao3.ao3Collections, isCollection: true, to: container)
            }

            var statsParts: [String] = []
            if let pub = ao3.publishedDate { statsParts.append("Published: \(pub)") }
            if let upd = ao3.updatedDate, upd != ao3.publishedDate { statsParts.append("Updated: \(upd)") }
            if let words = ao3.wordCount { statsParts.append("Words: \(formatNumber(words))") }
            if let ch = ao3.chapterCurrent {
                statsParts.append("Chapters: \(ch)/\(ao3.chapterTotal.map(String.init) ?? "?")")
            }
            if let kudos = ao3.kudosCount { statsParts.append("Kudos: \(formatNumber(kudos))") }
            statsParts.append("Status: \(ao3.isComplete ? "Complete" : "In Progress")")
            appendPlainRow(label: "Stats:", value: statsParts.joined(separator: "  •  "), to: container)

            if let comment = book.displayComment, !comment.isEmpty {
                appendSummary(comment, to: container)
            }
        } else {
            // Non-AO3 book fallback
            appendPlainRow(label: "Authors:", value: book.displayAuthors, to: container)
            if let series = book.displaySeries { appendPlainRow(label: "Series:", value: series, to: container) }
            if let words = book.wordCount { appendPlainRow(label: "Words:", value: formatNumber(words), to: container) }
            appendPrefaceRow(label: "Tags:", tags: book.tags, to: container)
            if let comment = book.displayComment, !comment.isEmpty {
                appendSummary(comment, to: container)
            }
        }

        return container
    }

    private func appendSeriesRow(series: [AO3MetadataRecord.SeriesEntry], to container: NSStackView) {
        guard !series.isEmpty else { return }

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let labelField = createRowLabel("Series:")
        labelField.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true
        row.addArrangedSubview(labelField)

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.translatesAutoresizingMaskIntoConstraints = false

        let attrString = NSMutableAttributedString()
        for (idx, entry) in series.enumerated() {
            let partText = "Part \(entry.index) of "
            attrString.append(NSAttributedString(string: partText, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor
            ]))

            if let ao3ID = entry.ao3ID, let url = URL(string: "https://archiveofourown.org/series/\(ao3ID)") {
                attrString.append(NSAttributedString(string: entry.name, attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .link: url,
                    .foregroundColor: NSColor.controlAccentColor
                ]))
            } else {
                attrString.append(NSAttributedString(string: entry.name, attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.labelColor
                ]))
            }

            if idx < series.count - 1 {
                attrString.append(NSAttributedString(string: "; ", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]))
            }
        }
        textView.textStorage?.setAttributedString(attrString)
        row.addArrangedSubview(textView)

        container.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
    }

    private func appendPlainRow(label: String, value: String, to container: NSStackView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let labelField = createRowLabel(label)
        labelField.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true
        row.addArrangedSubview(labelField)

        let valField = NSTextField(wrappingLabelWithString: value)
        valField.font = NSFont.systemFont(ofSize: 12)
        valField.isSelectable = true
        row.addArrangedSubview(valField)

        container.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
    }

    private func appendPrefaceRow(label: String, tags: [String], isCollection: Bool = false, to container: NSStackView) {
        guard !tags.isEmpty else { return }

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let labelField = createRowLabel(label)
        labelField.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true
        row.addArrangedSubview(labelField)

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.translatesAutoresizingMaskIntoConstraints = false

        let attrString = NSMutableAttributedString()
        for (idx, tag) in tags.enumerated() {
            let encodedTag = ao3TagURL(tag, isCollection: isCollection)
            let tagAttr = NSAttributedString(string: tag, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .link: encodedTag,
                .foregroundColor: NSColor.controlAccentColor
            ])
            attrString.append(tagAttr)
            if idx < tags.count - 1 {
                attrString.append(NSAttributedString(string: ", ", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]))
            }
        }
        textView.textStorage?.setAttributedString(attrString)
        row.addArrangedSubview(textView)

        container.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
    }

    private func appendSummary(_ summary: String, to container: NSStackView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let labelField = createRowLabel("Summary:")
        labelField.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true
        row.addArrangedSubview(labelField)

        let cleanText = summary
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let valField = NSTextField(wrappingLabelWithString: cleanText)
        valField.font = NSFont.systemFont(ofSize: 12)
        valField.textColor = .labelColor
        valField.isSelectable = true
        row.addArrangedSubview(valField)

        container.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
    }

    private func createBottomBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        let finderButton = NSButton(title: "Show in Finder", target: self, action: #selector(revealInFinder))
        finderButton.bezelStyle = .rounded
        finderButton.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Finder")
        finderButton.translatesAutoresizingMaskIntoConstraints = false
        finderButton.isEnabled = epubURL != nil
        bar.addSubview(finderButton)

        let shareButton = NSButton(title: "Share", target: self, action: #selector(shareEPUB(_:)))
        shareButton.bezelStyle = .rounded
        shareButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
        shareButton.translatesAutoresizingMaskIntoConstraints = false
        shareButton.isEnabled = epubURL != nil
        bar.addSubview(shareButton)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(dismissSheet))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(doneButton)

        NSLayoutConstraint.activate([
            finderButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            finderButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            shareButton.leadingAnchor.constraint(equalTo: finderButton.trailingAnchor, constant: 8),
            shareButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            doneButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            doneButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            bar.heightAnchor.constraint(equalToConstant: 32)
        ])

        return bar
    }

    private func createRowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private func createSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func formatNumber(_ num: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: num)) ?? String(num)
    }

    private func ao3TagURL(_ tag: String, isCollection: Bool) -> URL {
        if isCollection {
            let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
            return URL(string: "https://archiveofourown.org/collections/\(encoded)") ?? URL(string: "https://archiveofourown.org")!
        }
        var encoded = tag.replacingOccurrences(of: "/", with: "*s*")
        encoded = encoded.replacingOccurrences(of: "&", with: "*a*")
        encoded = encoded.replacingOccurrences(of: ".", with: "*d*")
        let urlEncoded = encoded.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? encoded
        return URL(string: "https://archiveofourown.org/tags/\(urlEncoded)") ?? URL(string: "https://archiveofourown.org")!
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Prevent AppKit from auto-selecting the first text field / control on sheet presentation
        view.window?.makeFirstResponder(nil)
    }

    @objc private func openStoryURL() {
        guard let storyURL = ao3?.storyURL, let url = URL(string: storyURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealInFinder() {
        guard let url = epubURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func shareEPUB(_ sender: NSButton) {
        guard let url = epubURL else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func dismissSheet() {
        dismiss(nil)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
