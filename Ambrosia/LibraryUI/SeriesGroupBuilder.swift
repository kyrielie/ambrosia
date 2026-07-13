import Foundation

// MARK: - Shared series-group construction
//
// Extracted from the near-identical loops formerly duplicated inline in
// `LibraryRootView.rebuildItems()` and `EmailLibraryViewController.rebuildSidebarItems()`.
// `LocalFeedServer` is a third consumer (feed grouping), which is the direct
// reason this was pulled out instead of letting a third divergent copy appear.
//
// Pure function — no UI framework dependency — so it can run from a SwiftUI
// view's Task, an AppKit view controller's Task, or an actor (`LocalFeedServer`)
// with no MainActor hop required.

/// Builds `SeriesGroup` values from a page's series-membership rows plus the
/// AO3/Calibre metadata needed to aggregate them.
///
/// `allEntries` must already be the "keys" fetch (`metaDB.seriesEntries(keys:)`
/// over every series key touched by the page), not just the page's own
/// `seriesEntries(for:)` rows — the group needs every member, not just the ones
/// on the current page. `byID` must resolve every calibreID present in
/// `allEntries` to its `CalibreBook` (typically `library.booksForIDs(allIDs)`
/// where `allIDs = Array(Set(allEntries.map(\.calibreID)))`).
///
/// `seriesDiagnostics` and `placeholders` are UI-display-only inputs (`#if DEBUG`
/// logging and `SeriesGroup.placeholders` respectively) — callers that don't need
/// them (e.g. `LocalFeedServer`, which serializes neither into a feed item) may
/// omit them and rely on the empty defaults below.
func buildSeriesGroups(
    allEntries: [SeriesCacheEntry],
    byID: [Int: CalibreBook],
    seriesMetadata: [Int: AO3MetadataRecord],
    seriesDiagnostics: [Int: AO3ExtractionDiagnostic] = [:],
    anthologyIDs: Set<Int> = [],
    placeholders: [String: [SeriesPlaceholder]] = [:]
) -> [String: SeriesGroup] {
    let entriesBySeries = Dictionary(
        grouping: allEntries.filter { !anthologyIDs.contains($0.calibreID) },
        by: \.seriesKey
    )
    var seriesByKey: [String: SeriesGroup] = [:]

    for (seriesKey, entries) in entriesBySeries {
        let sortedEntries = sortedSeriesEntries(entries)
        // Anthology/merged-epub rows (e.g. a Calibre epubmerge compilation that
        // shares this series' ao3_series_id) must not count toward the group nor
        // be exposed in it — but their presence must not disqualify the rest of
        // the series from being grouped. Filter them out of `works` rather than
        // bailing on the whole group when any single member is anthology-flagged.
        let works = sortedEntries.compactMap { byID[$0.calibreID] }
            .filter { !$0.isDescriptionAnthology }
        guard works.count > 1 else { continue }
        let workIDs = Set(works.map(\.id))
        // Mirror the same anthology exclusion onto the entries used for
        // index/placeholder bookkeeping, so the anthology's own series_index
        // doesn't leak into workIndices/missingIndices or get passed to
        // sortedSeriesWorks alongside a `works` array that no longer includes it.
        let filteredSortedEntries = sortedEntries.filter { workIDs.contains($0.calibreID) }
        let metadata = works.compactMap { seriesMetadata[$0.id] }
        let metadataByID = seriesMetadata
        let indices = filteredSortedEntries.map(\.seriesIndex)
        let missing = missingIndices(in: indices)
        let ratings = Array(Set(works.flatMap(\.tags).filter { if case .rating = AO3TagKind.classify($0) { return true }; return false })).sorted()
        let warnings = Array(Set(works.flatMap(\.tags).filter { if case .warning = AO3TagKind.classify($0) { return true }; return false })).sorted()
        let categories = Array(Set(metadata.flatMap(\.categories) + works.flatMap(\.tags).filter { if case .category = AO3TagKind.classify($0) { return true }; return false })).sorted()
        let fandoms = Array(Set(metadata.flatMap(\.fandoms))).sorted()
        let relationships = Array(Set(metadata.flatMap(\.relationships))).sorted()
        let characters = Array(Set(metadata.flatMap(\.characters))).sorted()
        let additionalTags = Array(Set(metadata.flatMap(\.additionalTags))).sorted()
        let tags = Array(Set(works.flatMap(\.tags) + additionalTags)).sorted()
        let authors = Array(Set(works.flatMap(\.authors))).sorted()
        let descriptions = works.compactMap(\.displayComment)
        let chapterRecords = works.compactMap { metadataByID[$0.id] }.filter { $0.chapterCurrent != nil }
        let knownChapterCurrentTotal = chapterRecords.reduce(0) { $0 + ($1.chapterCurrent ?? 0) }
        let chapterTotalKnownForAll = !chapterRecords.isEmpty
            && chapterRecords.count == works.count
            && chapterRecords.allSatisfy { $0.chapterTotal != nil }
        #if DEBUG
        works.forEach { logMissingVisibleWorkMetadata(book: $0, ao3Metadata: metadataByID[$0.id], diagnostic: seriesDiagnostics[$0.id]) }
        #endif
        seriesByKey[seriesKey] = SeriesGroup(
            id: seriesKey,
            seriesKey: seriesKey,
            seriesName: filteredSortedEntries.first?.seriesName ?? seriesKey,
            works: sortedSeriesWorks(works, using: filteredSortedEntries),
            allFandoms: fandoms,
            allRelationships: relationships,
            allCharacters: characters,
            allCategories: categories,
            allWarnings: warnings,
            allRatings: ratings,
            allAdditionalTags: additionalTags,
            allTags: tags,
            allAuthors: authors,
            allDescriptions: descriptions,
            totalWordCount: works.reduce(0) { total, work in
                total + (seriesMetadata[work.id]?.wordCount ?? work.wordCount ?? 0)
            },
            chapterCurrentTotal: chapterRecords.isEmpty ? nil : knownChapterCurrentTotal,
            chapterTotalTotal: chapterTotalKnownForAll
                ? chapterRecords.reduce(0) { $0 + ($1.chapterTotal ?? 0) } : nil,
            hasUnknownChapterTotal: !chapterRecords.isEmpty && !chapterTotalKnownForAll,
            earliestPublished: metadata.compactMap { parseISODate($0.publishedDate) }.min(),
            latestUpdated: metadata.compactMap { parseISODate($0.updatedDate) }.max(),
            workIndices: indices,
            missingIndices: missing,
            placeholders: placeholders[seriesKey] ?? [],
            isComplete: !metadata.isEmpty && metadata.allSatisfy(\.isComplete)
        )
    }
    return seriesByKey
}
