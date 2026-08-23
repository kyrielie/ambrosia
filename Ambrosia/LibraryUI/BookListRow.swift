import SwiftUI
import SwiftData
import AppKit

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
    let modelContext: ModelContext
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
    @State private var showCollectionPicker = false

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
         modelContext: ModelContext,
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
        self.modelContext = modelContext
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
            LibraryStatsRow(stats: libraryStats)
            tagsRow
            statsRow
            descriptionRow
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2).onEnded(onOpen)
        )
        .contextMenu {
            Button("Open") {
                onOpen()
            }
            Divider()
            Button(isLiked ? "Unlike" : "Like") { onLikeToggle() }
            Button("Read Later") { onReadLater() }
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
        HStack(alignment: .firstTextBaseline) {
            Text(book.displayTitle).font(.headline).lineLimit(1)
            if let series = book.displaySeries {
                Text("·").foregroundStyle(.tertiary)
                Text(series).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            singletonSeriesWarningButton
            Button(action: onReadLaterToggle) {
                Image(systemName: isInReadLater ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(isInReadLater ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(isInReadLater ? "Remove from Read Later" : "Add to Read Later")
            Button(action: onLikeToggle) {
                Image(systemName: isLiked ? "star.fill" : "star")
                    .foregroundStyle(isLiked ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(isLiked ? "Unlike" : "Like")
        }
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
            FlowLayout(spacing: 4) {
                ForEach(pills) { pill in
                    Button {
                        onTagTap(pill.label, pill.field)
                    } label: {
                        tagPill(pill.label, color: pill.color, isSelected: false)
                    }
                    .buttonStyle(.plain)
                    .help("Filter by \(pill.label)")
                }
            }
        }
    }

    @ViewBuilder
    private var statsRow: some View {
        let kudosText  = book.displayKudos
        let ao3Kudos = book.kudos == nil ? ao3Metadata?.kudosCount : nil
        let pct = bookState.map { $0.totalReadPercent }
        if !kudosText.isEmpty || ao3Kudos != nil || (pct ?? 0) > 0 {
            HStack(spacing: 14) {
                if !kudosText.isEmpty { statChip(kudosText, icon: "heart") }
                if let ao3Kudos { statChip(Self.formatKudos(ao3Kudos), icon: "heart") }
                if let readPercent = pct, readPercent > 0 {
                    statChip(String(format: "%.0f%% read", min(readPercent, 1.0) * 100), icon: "book.pages")
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var descriptionRow: some View {
        if let comment = book.displayComment, !comment.isEmpty {
            Text(comment)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private var libraryStats: LibraryStats {
        LibraryStats(
            chapterText: ao3Metadata.flatMap(Self.chapterText),
            isComplete: ao3Metadata?.isComplete == true,
            wordText: (ao3Metadata?.wordCount ?? book.wordCount).map(Self.formatWordCount),
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

    private static func formatWordCount(_ count: Int) -> String {
        switch count {
        case 0..<1_000: return "\(count) words"
        case 0..<1_000_000: return String(format: "%.1fk words", Double(count) / 1_000)
        default: return String(format: "%.2fM words", Double(count) / 1_000_000)
        }
    }

    private static func formatKudos(_ count: Int) -> String {
        count >= 1_000 ? String(format: "%.1fk kudos", Double(count) / 1_000) : "\(count) kudos"
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

    var body: some View {
        if !stats.isEmpty {
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
                Spacer()
            }
        }
    }

    private func statChip(_ label: String, icon: String) -> some View {
        Label(label, systemImage: icon).font(.caption2).foregroundStyle(.tertiary)
    }
}

struct TagPillDisplay: Identifiable, Equatable {
    enum Role {
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

        func append(_ tags: [String], role: Role, field: FilterField = .tag) {
            for tag in tags where shouldShow(tag, hideFanworks: hideFanworks) {
                guard seen.insert(tag).inserted else { continue }
                pills.append(TagPillDisplay(label: tag, field: field, role: role))
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
