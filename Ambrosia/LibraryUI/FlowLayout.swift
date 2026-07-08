import SwiftUI

// MARK: - FlowLayout
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    struct Cache {
        var subviewSizes: [CGSize] = []
        var lastWidth: CGFloat = -1
        var rows: [(startIndex: Int, y: CGFloat, height: CGFloat)] = []
        var totalHeight: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache {
        var c = Cache()
        c.subviewSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return c
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.subviewSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.lastWidth = -1
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? 800
        refreshSubviewSizes(in: &cache, subviews: subviews)
        rebuildRows(in: &cache, maxWidth: maxWidth)
        return CGSize(width: maxWidth, height: cache.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        refreshSubviewSizes(in: &cache, subviews: subviews)
        rebuildRows(in: &cache, maxWidth: bounds.width)
        var rowIdx = 0
        var x = bounds.minX

        for (i, sub) in subviews.enumerated() {
            let size = cache.subviewSizes[i]
            if rowIdx + 1 < cache.rows.count && i >= cache.rows[rowIdx + 1].startIndex {
                rowIdx += 1
                x = bounds.minX
            }
            let currentRowY = bounds.minY + cache.rows[rowIdx].y
            let currentRowH = cache.rows[rowIdx].height
            let yOffset = (currentRowH - size.height) / 2
            sub.place(at: CGPoint(x: x, y: currentRowY + yOffset), proposal: .unspecified)
            x += size.width + spacing
        }
    }

    private func refreshSubviewSizes(in cache: inout Cache, subviews: Subviews) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        if sizes != cache.subviewSizes {
            cache.subviewSizes = sizes
            cache.lastWidth = -1
        }
    }

    private func rebuildRows(in cache: inout Cache, maxWidth: CGFloat) {
        guard abs(cache.lastWidth - maxWidth) > 0.5 else { return }
        cache.lastWidth = maxWidth

        var rows: [(startIndex: Int, y: CGFloat, height: CGFloat)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var rowStart = 0

        for (i, size) in cache.subviewSizes.enumerated() {
            if x + size.width > maxWidth && x > 0 {
                rows.append((startIndex: rowStart, y: y, height: rowH))
                y += rowH + spacing
                x = 0; rowH = 0; rowStart = i
            }
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
        rows.append((startIndex: rowStart, y: y, height: rowH))
        cache.rows = rows
        cache.totalHeight = y + rowH
    }
}

func missingIndices(in indices: [Int]) -> [Int] {
    let unique = Array(Set(indices)).sorted()
    guard let last = unique.last, last > 1 else { return [] }
    let present = Set(unique)
    return (1...last).filter { !present.contains($0) }
}

func parseISODate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    if let date = iso.date(from: value) { return date }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value)
}

// MARK: - Series leadership helpers
//
// Shared between LibraryRootView.rebuildItems and
// EmailLibraryViewController.rebuildSidebarItems. Both surfaces must agree on
// which work anchors a multi-work series row, and that notion must also match
// AmbrosiaMetaDB.seriesLeadershipCTE's SQL-side ranking (series_index ASC,
// calibre_id ASC) — otherwise a book could be treated as the database-side
// leader (kept visible, not stripped into "Series or Merged") while a
// different book is treated as the UI-side leader (the one that actually
// anchors the rendered row), silently dropping the true leader from view.

/// Sorts series_cache entries by `series_index ASC, calibreID ASC`. This tie-break
/// must stay identical to the `ORDER BY` in `AmbrosiaMetaDB.seriesLeadershipCTE`.
func sortedSeriesEntries(_ entries: [SeriesCacheEntry]) -> [SeriesCacheEntry] {
    entries.sorted {
        $0.seriesIndex != $1.seriesIndex ? $0.seriesIndex < $1.seriesIndex : $0.calibreID < $1.calibreID
    }
}

/// Sorts a series' works into display/leadership order using the same
/// `series_index ASC, calibreID ASC` tie-break as `sortedSeriesEntries`, keyed by
/// the corresponding series_cache entries since `CalibreBook` itself carries no
/// series_index. `works.first` after this sort is, by construction, the same book
/// `AmbrosiaMetaDB.seriesLeadershipCTE` would compute as `rn = 1` for this series.
func sortedSeriesWorks(_ works: [CalibreBook], using sortedEntries: [SeriesCacheEntry]) -> [CalibreBook] {
    works.sorted { left, right in
        let leftIndex = sortedEntries.first { $0.calibreID == left.id }?.seriesIndex ?? 0
        let rightIndex = sortedEntries.first { $0.calibreID == right.id }?.seriesIndex ?? 0
        if leftIndex != rightIndex { return leftIndex < rightIndex }
        return left.id < right.id
    }
}

/// Assigns each page-resident book to the grouped series row(s) it leads, to
/// standalone `.orphanedSeriesEntry` row(s) for series it's a solo, non-leading
/// member of (no `SeriesGroup` exists because it has no other visible members),
/// or to a plain `.book` row if it's in no series at all and isn't subsumed into
/// someone else's group as a non-leading member.
///
/// A book that leads more than one of its series (e.g. an AO3 work that opens both
/// a tight subseries and a larger umbrella series) legitimately anchors more than
/// one row here — this intentionally does not collapse a book down to a single
/// "canonical" series. A book that is a grouped (non-orphaned) member of a series
/// but does not lead it is never emitted directly; it only surfaces inside the
/// `works` array of whichever group(s) it belongs to. A book that is an *orphaned*
/// (ungrouped) member of a series always gets its own `.orphanedSeriesEntry` row,
/// since there's no group for it to be subsumed into.
///
/// Leadership is read off `group.works.first?.id == book.id`, so `seriesByKey` must
/// have been built with `SeriesGroup.works` populated via `sortedSeriesWorks`, or
/// this will not agree with the database's notion of leadership.
///
/// `singletonWarningsByCalibreID` is one-to-many (see
/// `AmbrosiaMetaDB.singletonNonLeadingSeriesEntries`): a book can be orphaned in more
/// than one series simultaneously, and each such membership gets its own row here.
func assignSeriesItems(
    pageBooks: [CalibreBook],
    entries: [SeriesCacheEntry],
    seriesByKey: [String: SeriesGroup],
    collapsedIDs: Set<Int>,
    singletonWarningsByCalibreID: [Int: [SingletonSeriesWarning]] = [:],
    anthologyIDs: Set<Int> = []
) -> [LibraryItem] {
    var nextItems: [LibraryItem] = []
    var emittedSeries = Set<String>()
    for book in pageBooks {
        let bookEntries = entries
            .filter { $0.calibreID == book.id && !anthologyIDs.contains($0.calibreID) }
            .sorted { $0.seriesKey < $1.seriesKey }
        let warningsBySeriesKey = Dictionary(
            uniqueKeysWithValues: (singletonWarningsByCalibreID[book.id] ?? []).map { ($0.seriesKey, $0) }
        )
        var emittedAny = false
        for entry in bookEntries {
            if let group = seriesByKey[entry.seriesKey] {
                guard !emittedSeries.contains(entry.seriesKey),
                      group.works.first?.id == book.id
                else { continue }
                nextItems.append(.series(group))
                emittedSeries.insert(entry.seriesKey)
                emittedAny = true
            } else if let warning = warningsBySeriesKey[entry.seriesKey],
                      !emittedSeries.contains(entry.seriesKey) {
                // No SeriesGroup exists for this series (it has no other visible
                // members), but it's a flagged orphaned membership (solo, index > 1).
                // Give it its own row rather than silently dropping the membership.
                nextItems.append(.orphanedSeriesEntry(book: book, warning: warning))
                emittedSeries.insert(entry.seriesKey)
                emittedAny = true
            }
        }
        if !emittedAny && !collapsedIDs.contains(book.id) {
            nextItems.append(.book(book))
        }
    }
    return nextItems
}

func logMissingVisibleWorkMetadata(
    book: CalibreBook,
    ao3Metadata: AO3MetadataRecord?,
    diagnostic: AO3ExtractionDiagnostic?
) {
    #if DEBUG
    let missingWords = (ao3Metadata?.wordCount ?? book.wordCount) == nil
    let missingChapters = ao3Metadata?.chapterCurrent == nil
    guard missingWords || missingChapters else { return }

    var reasons: [String] = []
    if ao3Metadata == nil {
        if let diagnostic {
            reasons.append("no AO3 metadata row; extractionStatus=\(diagnostic.status); extractionReason=\(diagnostic.reason)")
        } else {
            reasons.append("no AO3 metadata row; extraction has not recorded a status yet (pending, not attempted under diagnostics schema, or pre-diagnostics DB)")
        }
    } else {
        if ao3Metadata?.wordCount == nil {
            reasons.append("AO3 metadata has nil word count")
        }
        if ao3Metadata?.chapterCurrent == nil {
            reasons.append("AO3 metadata has nil chapter current")
        }
    }
    if missingWords, book.wordCount == nil {
        reasons.append("Calibre fallback missing")
    }

    print("[LibraryMetadata] visible work missing displayed metadata reason=\(reasons.joined(separator: "; ")) calibreID=\(book.id) title=\"\(book.displayTitle)\" hasAO3Metadata=\(ao3Metadata != nil) ao3WorkID=\(ao3Metadata?.workID ?? "nil") ao3Words=\(ao3Metadata?.wordCount.map(String.init) ?? "nil") ao3ChapterCurrent=\(ao3Metadata?.chapterCurrent.map(String.init) ?? "nil") ao3ChapterTotal=\(ao3Metadata?.chapterTotal.map(String.init) ?? "nil") calibreWords=\(book.wordCount.map(String.init) ?? "nil") extractedAt=\(ao3Metadata?.extractedAt ?? "nil") extractionStatus=\(diagnostic?.status ?? "nil") extractionReason=\"\(diagnostic?.reason ?? "nil")\" attemptedAt=\(diagnostic?.attemptedAt ?? "nil") epubFilename=\"\(diagnostic?.epubFilename ?? "nil")\" epubPath=\"\(diagnostic?.epubPath ?? "nil")\" spineItemsChecked=\(diagnostic?.spineItemsChecked.map(String.init) ?? "nil")")
    #endif
}

