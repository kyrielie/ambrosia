import SwiftUI
import AppKit

/// Click-count policy for controls inside a row (title, tag pills, authors).
///
/// A control acts on the first click of a multi-click only. After that first
/// click the list may reload and re-lay out, so a second click can land on a
/// different element; ignoring repeat clicks makes a double-click on a pill
/// apply its filter exactly once and a double-click on the title open once.
enum RowClickPolicy {
    /// Pure rule, unit tested: only a first click is handled.
    static func shouldHandle(clickCount: Int) -> Bool { clickCount <= 1 }

    /// True when the click being delivered is a first click (or no event is
    /// available, for example when invoked from a context menu or VoiceOver).
    @MainActor
    static var shouldHandleCurrentClick: Bool {
        shouldHandle(clickCount: NSApp.currentEvent?.clickCount ?? 1)
    }
}

/// Row title as a link-style button: single click opens the work. Shows a
/// pointing-hand cursor and an underline on hover so it reads as clickable.
struct RowTitleButton: View {
    let text: String
    let font: Font
    let lineLimit: Int
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            guard RowClickPolicy.shouldHandleCurrentClick else { return }
            action()
        } label: {
            Text(text)
                .font(font)
                .lineLimit(lineLimit)
                .underline(isHovering)
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerStyle(.link)
        .help(help)
    }
}

// MARK: - Book list row

struct BookListRow: View, Equatable {
    let book: CalibreBook
    let bookState: BookState?
    let ao3Metadata: AO3MetadataRecord?
    let ao3ExtractionDiagnostic: AO3ExtractionDiagnostic?
    let singletonSeriesWarnings: [SingletonSeriesWarning]
    let isLiked: Bool
    let isInReadLater: Bool
    let onReadLaterToggle: () -> Void
    let hideFanworksTagPill: Bool
    let correctCalibreAmpEntities: Bool
    let searchBadge: SearchMatchBadge?
    let onTagTap: (String, FilterField) -> Void
    let onAuthorTap: (String) -> Void
    let onOpen: () -> Void
    let onLikeToggle: () -> Void
    let onReadLater: () -> Void
    let onSkip: () -> Void
    let onMarkRead: () -> Void
    let onResetProgress: () -> Void
    let onCollectionChanged: () -> Void
    let activeCollectionID: String?
    let onRemoveFromCollection: (String) -> Void
    @State private var optimisticLiked: Bool?
    @State private var optimisticReadLater: Bool?
    @State private var showCollectionPicker = false

    private var effectiveLiked: Bool { optimisticLiked ?? isLiked }
    private var effectiveReadLater: Bool { optimisticReadLater ?? isInReadLater }

    static func == (lhs: BookListRow, rhs: BookListRow) -> Bool {
        lhs.book.id                       == rhs.book.id
            && lhs.book.title             == rhs.book.title
            && lhs.book.series            == rhs.book.series
            && lhs.book.seriesIndex       == rhs.book.seriesIndex
            && lhs.book.wordCount         == rhs.book.wordCount
            && lhs.book.kudos             == rhs.book.kudos
            && lhs.book.authors           == rhs.book.authors
            && lhs.book.tags              == rhs.book.tags
            && lhs.book.comment           == rhs.book.comment
            && lhs.ao3Metadata            == rhs.ao3Metadata
            && lhs.ao3ExtractionDiagnostic == rhs.ao3ExtractionDiagnostic
            && lhs.singletonSeriesWarnings == rhs.singletonSeriesWarnings
            && lhs.bookState?.calibreID        == rhs.bookState?.calibreID
            && lhs.isLiked                     == rhs.isLiked
            && lhs.isInReadLater                == rhs.isInReadLater
            && lhs.hideFanworksTagPill         == rhs.hideFanworksTagPill
            && lhs.correctCalibreAmpEntities   == rhs.correctCalibreAmpEntities
            && lhs.searchBadge                 == rhs.searchBadge
            && lhs.bookState?.totalReadPercent == rhs.bookState?.totalReadPercent
            && lhs.activeCollectionID          == rhs.activeCollectionID
    }

    init(book: CalibreBook,
         bookState: BookState?,
         ao3Metadata: AO3MetadataRecord?,
         ao3ExtractionDiagnostic: AO3ExtractionDiagnostic?,
         singletonSeriesWarnings: [SingletonSeriesWarning],
         isLiked: Bool,
         hideFanworksTagPill: Bool,
         correctCalibreAmpEntities: Bool,
         searchBadge: SearchMatchBadge? = nil,
         onTagTap: @escaping (String, FilterField) -> Void,
         onAuthorTap: @escaping (String) -> Void,
         onOpen: @escaping () -> Void,
         isInReadLater: Bool,
         onReadLaterToggle: @escaping () -> Void,
         onLikeToggle: @escaping () -> Void,
         onReadLater: @escaping () -> Void,
         onSkip: @escaping () -> Void,
         onMarkRead: @escaping () -> Void,
         onResetProgress: @escaping () -> Void,
         onCollectionChanged: @escaping () -> Void,
         activeCollectionID: String?,
         onRemoveFromCollection: @escaping (String) -> Void) {
        self.book         = book
        self.bookState    = bookState
        self.ao3Metadata  = ao3Metadata
        self.ao3ExtractionDiagnostic = ao3ExtractionDiagnostic
        self.singletonSeriesWarnings = singletonSeriesWarnings
        self.isLiked      = isLiked
        self.isInReadLater = isInReadLater
        self.onReadLaterToggle = onReadLaterToggle
        self.hideFanworksTagPill = hideFanworksTagPill
        self.correctCalibreAmpEntities = correctCalibreAmpEntities
        self.searchBadge = searchBadge
        self.onTagTap     = onTagTap
        self.onAuthorTap  = onAuthorTap
        self.onOpen = onOpen
        self.onLikeToggle = onLikeToggle
        self.onReadLater = onReadLater
        self.onSkip       = onSkip
        self.onMarkRead   = onMarkRead
        self.onResetProgress = onResetProgress
        self.onCollectionChanged = onCollectionChanged
        self.activeCollectionID = activeCollectionID
        self.onRemoveFromCollection = onRemoveFromCollection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleRow
            authorsRow
            LibraryStatsRow(stats: libraryStats, readPercent: bookState?.totalReadPercent)
            tagsRow
            statsRow
            descriptionRow
        }
        .onChange(of: isLiked) { _, newLiked in
            optimisticLiked = newLiked
        }
        .onChange(of: isInReadLater) { _, newReadLater in
            optimisticReadLater = newReadLater
        }
        // Outside a List the row no longer stretches to the row width, so
        // extend the frame to keep the double-click hit area full width.
        .frame(maxWidth: .infinity, alignment: .leading)
        // Row-open double-click lives on a layer behind the content, so
        // buttons, pills and popover triggers never see it.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onOpen)
        }
        .contextMenu {
            Button("Open") {
                onOpen()
            }
            Button("Reveal in Finder") {
                AppDelegate.shared?.revealInFinder(book: book)
            }
            Divider()
            Button(effectiveLiked ? "Unlike" : "Like") { onLikeToggle() }
            Button(effectiveReadLater ? "Remove from Read Later" : "Add to Read Later") { onReadLaterToggle() }
            Button("Mark as Read") { onMarkRead() }
            Button("Reset Reading Progress") { onResetProgress() }
            Button("Skip") { onSkip() }
            Divider()
            Button("Add to Collection…") { showCollectionPicker = true }
            if let activeCollectionID {
                Button("Remove from Collection") { onRemoveFromCollection(activeCollectionID) }
            }
        }
        .popover(isPresented: $showCollectionPicker, arrowEdge: .trailing) {
            CollectionSearchPickerView(
                calibreIDs: [book.id],
                onChange: {
                    onCollectionChanged()
                },
                onComplete: {
                    showCollectionPicker = false
                }
            )
        }
        .onAppear {
            logMissingDisplayedMetadataIfNeeded()
        }
    }

    // MARK: - Row sections

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            RowTitleButton(text: book.displayTitle, font: .headline, lineLimit: 1,
                           help: "Open", action: onOpen)
            if let searchBadge {
                searchBadgePill(searchBadge)
            }
            if let series = book.displaySeries {
                Text("·").foregroundStyle(.tertiary)
                Text(series).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            singletonSeriesWarningButton
            Button(action: {
                let next = !effectiveReadLater
                optimisticReadLater = next
                onReadLaterToggle()
            }, label: {
                Image(systemName: effectiveReadLater ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 14))
                    .foregroundStyle(effectiveReadLater ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            })
            .buttonStyle(.borderless)
            .help(effectiveReadLater ? "Remove from Read Later" : "Add to Read Later")
            .accessibilityLabel(effectiveReadLater ? "Remove from Read Later" : "Add to Read Later")
            Button(action: {
                let next = !effectiveLiked
                optimisticLiked = next
                onLikeToggle()
            }, label: {
                Image(systemName: effectiveLiked ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundStyle(effectiveLiked ? Color.yellow : Color.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            })
            .buttonStyle(.borderless)
            .help(effectiveLiked ? "Unlike" : "Like")
            .accessibilityLabel(effectiveLiked ? "Unlike" : "Like")
        }
    }

    private func searchBadgePill(_ badge: SearchMatchBadge) -> some View {
        HStack(spacing: 3) {
            Image(systemName: badge.systemImage)
                .font(.caption2)
            Text(badge.label)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(badge.tintColor.opacity(0.12))
        )
        .foregroundColor(badge.tintColor)
    }

    @ViewBuilder
    private var singletonSeriesWarningButton: some View {
        if !singletonSeriesWarnings.isEmpty {
            SingletonSeriesWarningButton(warnings: singletonSeriesWarnings)
        }
    }

    @ViewBuilder
    private var authorsRow: some View {
        if !book.authors.isEmpty {
            HStack(spacing: 4) {
                ForEach(book.authors, id: \.self) { author in
                    Button {
                        guard RowClickPolicy.shouldHandleCurrentClick else { return }
                        onAuthorTap(author)
                    } label: {
                        Text(author)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Filter by \(author)")
                    if author != book.authors.last {
                        Text("·").foregroundStyle(.tertiary).font(.subheadline)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var tagsRow: some View {
        let pills = visibleTagPills
        if !pills.isEmpty {
            let capped = TagPillDisplay.capped(pills)
            FlowLayout(spacing: 4) {
                ForEach(capped.shown) { pill in
                    Button {
                        guard RowClickPolicy.shouldHandleCurrentClick else { return }
                        onTagTap(pill.label, pill.field)
                    } label: {
                        tagPill(pill, isSelected: false)
                    }
                    .buttonStyle(.plain)
                    .help("Filter by \(pill.label)")
                }
                if capped.hiddenCount > 0 {
                    tagPill("+\(capped.hiddenCount)", color: nil, isSelected: false)
                        .help(pills.dropFirst(capped.shown.count).map(\.label).joined(separator: ", "))
                }
            }
        }
    }

    @ViewBuilder
    private var statsRow: some View {
        let kudosText  = book.displayKudos
        let ao3Kudos = book.kudos == nil ? ao3Metadata?.kudosCount : nil
        if !kudosText.isEmpty || ao3Kudos != nil {
            HStack(spacing: 14) {
                if !kudosText.isEmpty { statChip(kudosText, icon: "heart") }
                if let ao3Kudos { statChip(Self.formatKudos(ao3Kudos), icon: "heart") }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var descriptionRow: some View {
        if let comment = book.displayComment, !comment.isEmpty {
            RowDescriptionPreview(content: .single(comment))
        }
    }

    // MARK: - Helpers

    private var libraryStats: LibraryStats {
        LibraryStats(
            chapterText: ao3Metadata.flatMap(Self.chapterText),
            isComplete: ao3Metadata?.isComplete == true,
            wordText: (ao3Metadata?.wordCount ?? book.wordCount).map(WordCountFormatting.label),
            publishedText: Self.nonEmpty(ao3Metadata?.publishedDate),
            updatedText: Self.nonEmpty(ao3Metadata?.updatedDate)
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func chapterText(_ metadata: AO3MetadataRecord) -> String? {
        guard let current = metadata.chapterCurrent else { return nil }
        if let total = metadata.chapterTotal {
            return "\(current)/\(total) ch"
        }
        return "\(current)/? ch"
    }

    private static func formatKudos(_ count: Int) -> String {
        count >= 1_000 ? String(format: "%.1fk kudos", Double(count) / 1_000) : "\(count) kudos"
    }

    private func tagPill(_ pill: TagPillDisplay, isSelected: Bool) -> some View {
        HStack(spacing: 3) {
            if pill.isFirstListed {
                if pill.role == .relationship {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 7))
                } else if pill.role == .character {
                    Image(systemName: "person.fill")
                        .font(.system(size: 7))
                }
            }
            Text(pill.label)
        }
        .font(pill.isFirstListed ? .caption2.weight(.semibold) : .caption2)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            isSelected
                ? (pill.color ?? .secondary).opacity(0.35)
                : (pill.color.map { $0.opacity(0.18) } ?? Color(NSColor.controlBackgroundColor))
        )
        .foregroundStyle(isSelected ? Color.primary : (pill.color ?? .secondary))
        .clipShape(Capsule())
        .accessibilityLabel(
            pill.isFirstListed
                ? (pill.role == .relationship ? "First-listed relationship: \(pill.label)" : "First-listed character: \(pill.label)")
                : pill.label
        )
    }

    private func tagPill(_ label: String, color: Color?, isSelected: Bool) -> some View {
        Text(label)
            .font(.caption2)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                isSelected
                    ? (color ?? .secondary).opacity(0.35)
                    : (color.map { $0.opacity(0.18) } ?? Color(NSColor.controlBackgroundColor))
            )
            .foregroundStyle(isSelected ? Color.primary : (color ?? .secondary))
            .clipShape(Capsule())
    }

    private var visibleTagPills: [TagPillDisplay] {
        TagPillDisplay.make(
            calibreTags: book.tags,
            ao3Metadata: ao3Metadata,
            hideFanworks: hideFanworksTagPill
        )
    }

    private func statChip(_ label: String, icon: String) -> some View {
        Label(label, systemImage: icon).font(.caption2).foregroundStyle(.tertiary)
    }

    private func logMissingDisplayedMetadataIfNeeded() {
        #if DEBUG
        logMissingVisibleWorkMetadata(book: book, ao3Metadata: ao3Metadata, diagnostic: ao3ExtractionDiagnostic)
        #endif
    }
}

struct LibraryStats: Equatable {
    let chapterText: String?
    let isComplete: Bool
    let wordText: String?
    let publishedText: String?
    let updatedText: String?

    var isEmpty: Bool {
        chapterText == nil && wordText == nil && publishedText == nil && normalizedUpdatedText == nil
    }

    var normalizedUpdatedText: String? {
        guard let updatedText, !updatedText.isEmpty, updatedText != publishedText else { return nil }
        return updatedText
    }
}

struct LibraryStatsRow: View {
    let stats: LibraryStats
    var readPercent: Double?

    var body: some View {
        let hasPercent = readPercent != nil
        if !stats.isEmpty || hasPercent {
            HStack(spacing: 14) {
                if let chapterText = stats.chapterText {
                    statChip(chapterText, icon: stats.isComplete ? "checkmark.circle" : "clock")
                }
                if let wordText = stats.wordText {
                    statChip(wordText, icon: "text.word.spacing")
                }
                if let publishedText = stats.publishedText {
                    statChip("Pub \(publishedText)", icon: "calendar")
                }
                if let updatedText = stats.normalizedUpdatedText {
                    statChip("Upd \(updatedText)", icon: "arrow.triangle.2.circlepath")
                }
                if let pct = readPercent {
                    statChip(String(format: "%.0f%% read", min(pct, 1.0) * 100), icon: "book.pages")
                }
                Spacer()
            }
            .frame(height: 16)
        }
    }

    private func statChip(_ label: String, icon: String) -> some View {
        Label(label, systemImage: icon)
            .font(.caption2)
            .imageScale(.small)
            .lineLimit(1)
            .foregroundStyle(.tertiary)
    }
}

struct TagPillDisplay: Identifiable, Equatable {
    enum Role: Equatable, Sendable {
        case rating
        case fandom
        case relationship
        case character
        case category
        case warning
        case regular
    }

    let label: String
    let field: FilterField
    let role: Role
    var isFirstListed: Bool = false

    var id: String { "\(role)-\(label)" }

    var color: Color? {
        switch role {
        case .rating:       return .orange
        case .fandom:       return .purple
        case .relationship: return .pink
        case .character:    return .teal
        case .category:     return .blue
        case .warning:      return .red
        case .regular:      return nil
        }
    }

    static func make(
        calibreTags: [String],
        ao3Metadata: AO3MetadataRecord?,
        hideFanworks: Bool
    ) -> [TagPillDisplay] {
        var seen = Set<String>()
        var pills: [TagPillDisplay] = []
        let firstRelationship = ao3Metadata?.relationships.first
        let firstCharacter = ao3Metadata?.characters.first

        func append(_ tags: [String], role: Role, field: FilterField = .tag) {
            for tag in tags where shouldShow(tag, hideFanworks: hideFanworks) {
                guard seen.insert(tag).inserted else { continue }
                let isFirst = (role == .relationship && tag == firstRelationship)
                    || (role == .character && tag == firstCharacter)
                pills.append(TagPillDisplay(label: tag, field: field, role: role, isFirstListed: isFirst))
            }
        }

        let buckets = AO3TagBuckets.from(tags: calibreTags)
        append(buckets.ratings, role: .rating, field: .rating)

        if let ao3Metadata {
            append(ao3Metadata.fandoms, role: .fandom)
            append(ao3Metadata.relationships, role: .relationship)
            append(ao3Metadata.characters, role: .character)
            append(ao3Metadata.categories, role: .category, field: .category)
            append(buckets.categories, role: .category, field: .category)
            append(buckets.warnings, role: .warning, field: .warning)
            append(ao3Metadata.additionalTags, role: .regular)
        } else {
            append(buckets.categories, role: .category, field: .category)
            append(buckets.warnings, role: .warning, field: .warning)
        }

        append(buckets.regular, role: .regular)
        return pills
    }

    /// The AO3 tag-facet arrays needed by `makeForSeries`, grouped together
    /// since they're always looked up and passed together at the one call
    /// site (all sourced from the same `SeriesGroup`'s `all*` accessors).
    struct SeriesTagFacets {
        var fandoms: [String]
        var relationships: [String]
        var characters: [String]
        var categories: [String]
        var warnings: [String]
        var ratings: [String]
        var additionalTags: [String]
        var tags: [String]
    }

    static func makeForSeries(
        _ facets: SeriesTagFacets,
        hideFanworks: Bool
    ) -> [TagPillDisplay] {
        let fandoms = facets.fandoms
        let relationships = facets.relationships
        let characters = facets.characters
        let categories = facets.categories
        let warnings = facets.warnings
        let ratings = facets.ratings
        let additionalTags = facets.additionalTags
        let tags = facets.tags
        let buckets = AO3TagBuckets.from(tags: tags)
        let regularTags = buckets.regular.filter { tag in
            !additionalTags.contains(tag) &&
                !fandoms.contains(tag) &&
                !relationships.contains(tag) &&
                !characters.contains(tag)
        }
        var seen = Set<String>()
        var pills: [TagPillDisplay] = []

        func append(_ values: [String], role: Role, field: FilterField = .tag) {
            for value in values where shouldShow(value, hideFanworks: hideFanworks) {
                guard seen.insert(value).inserted else { continue }
                pills.append(TagPillDisplay(label: value, field: field, role: role))
            }
        }

        append(ratings + buckets.ratings, role: .rating, field: .rating)
        append(fandoms, role: .fandom)
        append(relationships, role: .relationship)
        append(characters, role: .character)
        append(categories + buckets.categories, role: .category, field: .category)
        append(warnings + buckets.warnings, role: .warning, field: .warning)
        append(additionalTags, role: .regular)
        append(regularTags, role: .regular)
        return pills
    }

    private static func shouldShow(_ tag: String, hideFanworks: Bool) -> Bool {
        !(hideFanworks && tag == "Fanworks")
    }
}

/// Row description bounds. See docs/library-ui.md "Row height bounds".
enum RowDescriptionLimit {
    static let characters = 1_500
    static let lines = 10

    /// O(limit), not O(n): never counts the whole string.
    static func capped(_ text: String, limit: Int = characters) -> String {
        guard limit > 0 else { return "" }
        let head = text.prefix(limit + 1)
        guard head.count > limit else { return text }
        return String(head.prefix(limit - 1))
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
    }
}

struct RowDescriptionContent: Equatable {
    struct Section: Equatable {
        let title: String?
        let text: String
    }

    static let perWorkCharacterLimit = 400

    let sections: [Section]
    let fullText: String
    let previewText: String
    let isCharacterTruncated: Bool

    init(sections: [Section], perSectionCharacterLimit: Int? = nil) {
        let visibleSections = sections.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        self.sections = visibleSections
        self.fullText = Self.render(visibleSections, characterLimit: nil)
        self.previewText = RowDescriptionLimit.capped(
            Self.render(visibleSections, characterLimit: perSectionCharacterLimit)
        )
        self.isCharacterTruncated = self.previewText != self.fullText
    }

    static func single(_ text: String) -> RowDescriptionContent {
        RowDescriptionContent(sections: [Section(title: nil, text: text)])
    }

    static func series(works: [CalibreBook]) -> RowDescriptionContent {
        RowDescriptionContent(
            sections: works.compactMap { work in
                guard let text = work.displayComment else { return nil }
                return Section(title: work.displayTitle, text: text)
            },
            perSectionCharacterLimit: perWorkCharacterLimit
        )
    }

    private static func render(_ sections: [Section], characterLimit: Int?) -> String {
        sections.map { section in
            let text: String
            if let characterLimit {
                text = RowDescriptionLimit.capped(section.text, limit: characterLimit)
            } else {
                text = section.text
            }
            if let title = section.title {
                return "\(title)\n\(text)"
            }
            return text
        }
        .joined(separator: "\n\n")
    }
}

private enum RowDescriptionMeasurement: Hashable {
    case preview
    case full
}

private struct RowDescriptionHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [RowDescriptionMeasurement: CGFloat] = [:]

    static func reduce(
        value: inout [RowDescriptionMeasurement: CGFloat],
        nextValue: () -> [RowDescriptionMeasurement: CGFloat]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct RowDescriptionPreview: View {
    let content: RowDescriptionContent

    @State private var isLineTruncated = false
    @State private var showFullDescription = false

    private var needsMeasurement: Bool {
        guard !content.isCharacterTruncated else { return false }
        return content.previewText.count >= 120 || content.previewText.contains("\n")
    }

    private var showsMore: Bool {
        content.isCharacterTruncated || isLineTruncated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(content.previewText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(RowDescriptionLimit.lines)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: RowDescriptionHeightPreferenceKey.self,
                            value: [.preview: geometry.size.height]
                        )
                    }
                }

            if showsMore {
                HStack {
                    Spacer(minLength: 0)
                    Button("More…") { showFullDescription = true }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                        .help("Show full description")
                        .accessibilityLabel("Show full description")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if needsMeasurement {
                VStack(alignment: .leading, spacing: 0) {
                    measuredText(content.previewText, key: .preview, lineLimit: RowDescriptionLimit.lines)
                    measuredText(content.fullText, key: .full)
                }
                .hidden()
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
        }
        .onPreferenceChange(RowDescriptionHeightPreferenceKey.self) { heights in
            guard needsMeasurement,
                  let previewHeight = heights[.preview],
                  let fullHeight = heights[.full] else { return }
            isLineTruncated = fullHeight > previewHeight + 0.5
        }
        .onChange(of: content) { _, _ in
            isLineTruncated = false
        }
        .popover(isPresented: $showFullDescription, arrowEdge: .trailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(content.sections.enumerated()), id: \.offset) { entry in
                        let section = entry.element
                        VStack(alignment: .leading, spacing: 4) {
                            if let title = section.title {
                                Text(title).font(.headline)
                            }
                            Text(section.text)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .frame(width: 480, height: 420)
        }
    }

    private func measuredText(
        _ text: String,
        key: RowDescriptionMeasurement,
        lineLimit: Int? = nil
    ) -> some View {
        Text(text)
            .font(.caption)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: RowDescriptionHeightPreferenceKey.self,
                        value: [key: geometry.size.height]
                    )
                }
            }
    }
}

extension TagPillDisplay {
    /// Pills rendered per book row before collapsing the rest into a "+N" pill.
    /// AO3 allows 75 fandom/character/relationship/additional tags per work
    /// (mean 17, mode 11, under 0.5% above 75), plus rating/category/warning
    /// pills, so 30 trims only the long tail. Set to `Int.max` to disable.
    static let maxVisible = 30

    /// Same, for series rows. A series row shows the union of tags across all
    /// its works, so it reaches far higher pill counts than a single book and
    /// is the main layout cost. Tune separately from `maxVisible`.
    static let maxVisibleSeries = 30

    /// Returns the pills to render and how many were dropped. Order is
    /// preserved, so the first `max` (rating, fandom, relationship, ...) win.
    static func capped(_ pills: [TagPillDisplay], max: Int = maxVisible)
        -> (shown: [TagPillDisplay], hiddenCount: Int) {
        guard pills.count > max else { return (pills, 0) }
        return (Array(pills.prefix(max)), pills.count - max)
    }
}
