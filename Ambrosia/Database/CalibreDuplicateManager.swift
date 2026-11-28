import Foundation

/// A single duplicate entry representing a Calibre row of an AO3 work.
struct AO3DuplicateEntry: Identifiable, Sendable, Equatable {
    var id: Int { calibreID }
    let calibreID: Int
    let isWinner: Bool
    let title: String
    let authors: [String]
    let wordCount: Int?
    let chapterCurrent: Int?
    let chapterTotal: Int?
    let publishedDate: String?
    let updatedDate: String?
    let readPercent: Double
    let readingTimeSeconds: TimeInterval
    let annotationCount: Int
    let epubPath: String?
    let dateAdded: Date?
    var fileSizeBytes: Int64?
    var matchTier: DuplicateMatchTier?
}

/// A cluster of two or more Calibre rows sharing the same canonical `ao3_work_id`.
struct AO3DuplicateCluster: Identifiable, Sendable, Equatable {
    var id: String { workID }
    let workID: String
    let title: String
    let winnerID: Int
    let loserIDs: [Int]
    let entries: [AO3DuplicateEntry]

    var winnerEntry: AO3DuplicateEntry? {
        entries.first { $0.calibreID == winnerID }
    }

    var loserEntries: [AO3DuplicateEntry] {
        entries.filter { $0.calibreID != winnerID }
    }

    /// Returns a new cluster designating `newWinnerID` as the canonical winner
    /// and recalculating loser IDs and entry badges.
    func withWinner(_ newWinnerID: Int) -> AO3DuplicateCluster {
        let updatedLosers = entries.map(\.calibreID).filter { $0 != newWinnerID }.sorted()
        let updatedEntries = entries.map { entry in
            AO3DuplicateEntry(
                calibreID: entry.calibreID,
                isWinner: entry.calibreID == newWinnerID,
                title: entry.title,
                authors: entry.authors,
                wordCount: entry.wordCount,
                chapterCurrent: entry.chapterCurrent,
                chapterTotal: entry.chapterTotal,
                publishedDate: entry.publishedDate,
                updatedDate: entry.updatedDate,
                readPercent: entry.readPercent,
                readingTimeSeconds: entry.readingTimeSeconds,
                annotationCount: entry.annotationCount,
                epubPath: entry.epubPath,
                dateAdded: entry.dateAdded,
                fileSizeBytes: entry.fileSizeBytes,
                matchTier: entry.matchTier
            )
        }.sorted { e1, e2 in
            if e1.calibreID == newWinnerID { return true }
            if e2.calibreID == newWinnerID { return false }
            return e1.calibreID < e2.calibreID
        }
        return AO3DuplicateCluster(
            workID: workID,
            title: title,
            winnerID: newWinnerID,
            loserIDs: updatedLosers,
            entries: updatedEntries
        )
    }
}

/// Identifies, clusters, and formats duplicate AO3 works in a Calibre library.
///
/// Pure value type: no actor isolation, no disk access, safe to run from any
/// thread or task.
enum CalibreDuplicateManager {

    /// Constructs clusters of duplicate AO3 works from pre-fetched caches.
    /// Excludes merged anthologies (`anthologyIDs`) from competing as single-work duplicates.
    static func buildClusters(
        workIDs: [Int: String],
        dates: [Int: (published: String?, updated: String?)],
        booksByID: [Int: CalibreBook],
        metadataByID: [Int: AO3MetadataRecord] = [:],
        bookStatesByID: [Int: BookState] = [:],
        annotationCountsByID: [Int: Int] = [:],
        anthologyIDs: Set<Int> = [],
        datesAdded: [Int: Date] = [:]
    ) -> [AO3DuplicateCluster] {
        guard !workIDs.isEmpty else { return [] }

        let groups = Dictionary(grouping: workIDs.keys, by: { workIDs[$0] ?? "" })
            .filter { !$0.key.isEmpty && $0.value.count > 1 }

        var wordCounts: [Int: Int] = [:]
        var chapterCurrents: [Int: Int] = [:]
        for (id, meta) in metadataByID {
            if let wc = meta.wordCount { wordCounts[id] = wc }
            if let cc = meta.chapterCurrent { chapterCurrents[id] = cc }
        }
        for (id, book) in booksByID where wordCounts[id] == nil {
            if let wc = book.wordCount { wordCounts[id] = wc }
        }

        var clusters: [AO3DuplicateCluster] = []

        for (workID, rawCalibreIDs) in groups.sorted(by: { $0.key < $1.key }) {
            let calibreIDs = anthologyIDs.isEmpty
                ? rawCalibreIDs
                : rawCalibreIDs.filter { !anthologyIDs.contains($0) }
            guard calibreIDs.count > 1,
                  let winnerID = DuplicateBookDetector.preferredWinner(
                    in: calibreIDs,
                    dates: dates,
                    wordCounts: wordCounts,
                    chapterCurrents: chapterCurrents,
                    datesAdded: datesAdded
                  ) else {
                continue
            }

            let loserIDs = calibreIDs.filter { $0 != winnerID }.sorted()

            let entries: [AO3DuplicateEntry] = calibreIDs.sorted { id1, id2 in
                if id1 == winnerID { return true }
                if id2 == winnerID { return false }
                return id1 < id2
            }.map { id in
                let book = booksByID[id]
                let meta = metadataByID[id]
                let state = bookStatesByID[id]
                let annCount = annotationCountsByID[id] ?? 0

                let words = meta?.wordCount ?? book?.wordCount
                let chapCurr = meta?.chapterCurrent
                let chapTot = meta?.chapterTotal
                let pub = meta?.publishedDate ?? dates[id]?.published
                let upd = meta?.updatedDate ?? dates[id]?.updated

                return AO3DuplicateEntry(
                    calibreID: id,
                    isWinner: id == winnerID,
                    title: book?.displayTitle ?? "Book #\(id)",
                    authors: book?.authors ?? [],
                    wordCount: words,
                    chapterCurrent: chapCurr,
                    chapterTotal: chapTot,
                    publishedDate: pub,
                    updatedDate: upd,
                    readPercent: state?.totalReadPercent ?? 0.0,
                    readingTimeSeconds: state?.totalReadingTimeSeconds ?? 0.0,
                    annotationCount: annCount,
                    epubPath: book?.relativePath,
                    dateAdded: datesAdded[id],
                    fileSizeBytes: nil,
                    matchTier: nil
                )
            }

            let clusterTitle = entries.first(where: { $0.calibreID == winnerID })?.title
                ?? entries.first?.title
                ?? "AO3 Work #\(workID)"

            clusters.append(AO3DuplicateCluster(
                workID: workID,
                title: clusterTitle,
                winnerID: winnerID,
                loserIDs: loserIDs,
                entries: entries
            ))
        }

        return clusters
    }

    /// Formats a safe Calibre command to remove the superseded duplicate IDs.
    ///
    /// Example:
    /// `"/Applications/calibre.app/Contents/MacOS/calibredb" remove 1042 1089`
    static func calibrePruneCLICommand(
        loserIDs: [Int],
        calibreBinaryPath: String = "/Applications/calibre.app/Contents/MacOS/calibredb",
        libraryPath: String? = nil
    ) -> String {
        guard !loserIDs.isEmpty else { return "" }
        let idArgs = loserIDs.sorted().map(String.init).joined(separator: " ")
        var command = "\"\(calibreBinaryPath)\""
        if let libraryPath, !libraryPath.isEmpty {
            command += " --with-library \"\(libraryPath)\""
        }
        command += " remove \(idArgs)"
        return command
    }

    /// Formats a search query string to paste directly into Calibre's search bar.
    ///
    /// Example: `id:1042 or id:1089`
    static func calibreSearchQuery(calibreIDs: [Int]) -> String {
        guard !calibreIDs.isEmpty else { return "" }
        return calibreIDs.sorted().map { "id:\($0)" }.joined(separator: " or ")
    }
}
