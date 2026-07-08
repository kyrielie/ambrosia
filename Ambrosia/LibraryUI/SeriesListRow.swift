import SwiftUI
import AppKit

struct SeriesListRow: View, Equatable {
    let series: SeriesGroup
    let hideFanworksTagPill: Bool
    let isLiked: Bool
    let onTagTap: (String, FilterField) -> Void
    let onLikeToggle: () -> Void
    let onOpen: () -> Void
    let isInReadLater: Bool
    let onReadLaterToggle: () -> Void
    let onSkip: () -> Void
    let onMarkRead: () -> Void
    let onResetProgress: () -> Void
    let onCollectionChanged: () -> Void

    @State private var showIndex = false
    @State private var showCollectionPicker = false

    // Closures are excluded (functions aren't Equatable); everything that
    // actually varies the rendered content is included. Mirrors BookListRow's
    // `==`, and — unlike the version that shipped without this — must be kept
    // in sync with every stored property added above.
    static func == (lhs: SeriesListRow, rhs: SeriesListRow) -> Bool {
        lhs.series               == rhs.series
            && lhs.hideFanworksTagPill == rhs.hideFanworksTagPill
            && lhs.isLiked             == rhs.isLiked
            && lhs.isInReadLater       == rhs.isInReadLater
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(series.seriesName)
                    .font(.headline.weight(.semibold))
                    .lineLimit(2)
                Text("\(series.works.count) works")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !series.indexRangeText.isEmpty {
                    Text(series.indexRangeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(series.missingIndices.isEmpty ? Color.secondary : Color.orange)
                }
                Spacer()
                Button {
                    showIndex.toggle()
                } label: {
                    Image(systemName: series.missingIndices.isEmpty ? "list.number" : "exclamationmark.triangle.fill")
                }
                .buttonStyle(.borderless)
                .help(series.missingIndices.isEmpty ? "Show series index" : "Missing works")
                .popover(isPresented: $showIndex) { indexPopover }
                Button(action: onLikeToggle) {
                    Image(systemName: isLiked ? "star.fill" : "star")
                        .foregroundStyle(isLiked ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(isLiked ? "Unlike Series" : "Like Series")
                Button(action: onReadLaterToggle) {
                    Image(systemName: isInReadLater ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(isInReadLater ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(isInReadLater ? "Remove from Read Later" : "Add to Read Later")
            }
            Text(series.displayAuthors)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            LibraryStatsRow(stats: libraryStats)
            tagsRow
            if !series.allDescriptions.isEmpty {
                Text(series.allDescriptions.joined(separator: "\n\n"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .contextMenu {
            Button("Open Series", action: onOpen)
            Button("Show Individual Works") { showIndex = true }
            Divider()
            Button(isLiked ? "Unlike Series" : "Like Series", action: onLikeToggle)
            Button(isInReadLater ? "Remove Series from Read Later" : "Add Series to Read Later",
                   action: onReadLaterToggle)
            Button("Mark Series as Read", action: onMarkRead)
            Button("Reset Series Reading Progress", action: onResetProgress)
            Button("Skip Series", action: onSkip)
            Divider()
            Button("Add to Collection...") { showCollectionPicker = true }
        }
        .popover(isPresented: $showCollectionPicker, arrowEdge: .trailing) {
            CollectionSearchPickerView(
                calibreIDs: series.works.map(\.id),
                onChange: { onCollectionChanged() },
                onComplete: { showCollectionPicker = false }
            )
        }
    }

    @ViewBuilder
    private var tagsRow: some View {
        let pills = TagPillDisplay.makeForSeries(
            fandoms: series.allFandoms,
            relationships: series.allRelationships,
            characters: series.allCharacters,
            categories: series.allCategories,
            warnings: series.allWarnings,
            ratings: series.allRatings,
            additionalTags: series.allAdditionalTags,
            tags: series.allTags,
            hideFanworks: hideFanworksTagPill
        )
        if !pills.isEmpty {
            FlowLayout(spacing: 4) {
                ForEach(pills) { pill in
                    Button {
                        onTagTap(pill.label, pill.field)
                    } label: {
                        tagPill(pill.label, color: pill.color)
                    }
                    .buttonStyle(.plain)
                    .help("Filter by \(pill.label)")
                }
            }
        }
    }

    private var libraryStats: LibraryStats {
        LibraryStats(
            chapterText: series.displayChapterCount.nilIfEmptyForLibraryRow,
            isComplete: series.isComplete,
            wordText: series.displayWordCount.nilIfEmptyForLibraryRow,
            publishedText: series.earliestPublished.map(Self.formatDate),
            updatedText: series.latestUpdated.map(Self.formatDate)
        )
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func tagPill(_ label: String, color: Color?) -> some View {
        Text(label)
            .font(.caption2)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                color.map { $0.opacity(0.18) }
                    ?? Color(NSColor.controlBackgroundColor)
            )
            .foregroundStyle(color ?? .secondary)
            .clipShape(Capsule())
    }

    private var indexPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(series.seriesName).font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(series.works, id: \.id) { work in
                        HStack {
                            Text("\(series.displayIndex(for: work) ?? 0).")
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            Text(work.displayTitle).lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxHeight: 360)

            if !series.missingIndices.isEmpty {
                Divider()
                Text("Missing: \(series.missingIndices.map(String.init).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(width: 340)
        .frame(maxHeight: 460)
    }
}

private extension String {
    var nilIfEmptyForLibraryRow: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct SingletonSeriesWarningButton: View {
    let warnings: [SingletonSeriesWarning]
    @State private var showIndex = false
    @State private var showCollectionPicker = false

    private var helpText: String {
        warnings.count == 1
            ? warnings[0].displayText
            : "\(warnings.count) orphaned series memberships"
    }

    var body: some View {
        Button {
            showIndex.toggle()
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .buttonStyle(.borderless)
        .help(helpText)
        .popover(isPresented: $showIndex) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(warnings.enumerated()), id: \.offset) { offset, warning in
                    if offset > 0 { Divider() }
                    Text(warning.seriesName).font(.headline)
                    Text("Local index: #\(warning.seriesIndex)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("\(warning.seriesIndex).")
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        Text(warning.title).lineLimit(1)
                    }
                    Text(warning.displayText)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(14)
            .frame(width: 340)
        }
    }
}
