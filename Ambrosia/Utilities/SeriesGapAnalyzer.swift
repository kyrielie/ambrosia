import Foundation

/// Item in a series gap report representing either a present or missing part.
struct SeriesGapItem: Identifiable, Sendable, Equatable {
    var id: Int { partIndex }
    let partIndex: Int
    let isPresent: Bool
    let title: String
    let wordCount: Int?
    let workID: String?
    let url: URL?
}

/// Comprehensive report on missing sequential works or gaps in a fanfiction series.
struct SeriesGapReport: Sendable, Equatable {
    let seriesKey: String
    let seriesName: String
    let ao3SeriesID: String?
    let authors: [String]
    let presentIndices: [Int]
    let missingIndices: [Int]
    let totalKnownParts: Int
    let items: [SeriesGapItem]

    /// Direct URLs for missing works or the canonical series page on AO3.
    var targetDownloadURLs: [URL] {
        var urls: [URL] = []
        for item in items where !item.isPresent {
            if let url = item.url {
                urls.append(url)
            }
        }
        if urls.isEmpty, let ao3SeriesID, let seriesURL = URL(string: "https://archiveofourown.org/series/\(ao3SeriesID)") {
            urls.append(seriesURL)
        }
        return urls
    }

    /// Progress fraction of local library coverage (0.0 to 1.0).
    var coverageFraction: Double {
        guard totalKnownParts > 0 else { return 0.0 }
        return Double(presentIndices.count) / Double(totalKnownParts)
    }

    /// Percentage string of library coverage (e.g. "40%").
    var coveragePercentageString: String {
        "\(Int(coverageFraction * 100))%"
    }
}

/// Analyzes series structures and detects missing prefix, infix, and known parts.
enum SeriesGapAnalyzer {

    /// Generates a gap report from a `SeriesGroup`.
    static func analyze(
        series: SeriesGroup,
        metadataByID: [Int: AO3MetadataRecord] = [:]
    ) -> SeriesGapReport {
        // Collect present works
        let presentIndices = Array(Set(series.workIndices)).sorted()
        let maxIndex = max(presentIndices.last ?? 0, 1)

        // Missing indices calculation: includes prefix gaps (e.g. if min > 1) and infix gaps
        var missing = Set<Int>()
        for idx in 1...maxIndex where !presentIndices.contains(idx) {
            missing.insert(idx)
        }
        for placeholder in series.placeholders where !presentIndices.contains(placeholder.partIndex) {
            missing.insert(placeholder.partIndex)
        }
        let missingIndices = Array(missing).sorted()
        let totalParts = max(maxIndex, (missingIndices.last ?? 0))

        // Determine canonical AO3 Series ID from metadata
        var ao3SeriesID: String?
        for work in series.works {
            if let meta = metadataByID[work.id] {
                for seriesEntry in meta.series where seriesEntry.name.caseInsensitiveCompare(series.seriesName) == .orderedSame {
                    if let id = seriesEntry.ao3ID, !id.isEmpty {
                        ao3SeriesID = id
                        break
                    }
                }
            }
            if ao3SeriesID != nil { break }
        }

        // Build item rows for every part from 1 to totalParts
        var items: [SeriesGapItem] = []
        let placeholdersByPart = Dictionary(series.placeholders.map { ($0.partIndex, $0) }, uniquingKeysWith: { first, _ in first })

        // Map books by their series index
        var booksByPart: [Int: CalibreBook] = [:]
        for work in series.works {
            if let meta = metadataByID[work.id] {
                for seriesEntry in meta.series where seriesEntry.name.caseInsensitiveCompare(series.seriesName) == .orderedSame {
                    booksByPart[seriesEntry.index] = work
                }
            }
        }

        for part in 1...totalParts {
            if presentIndices.contains(part) {
                let book = booksByPart[part]
                let meta = book.flatMap { metadataByID[$0.id] }
                let title = book?.displayTitle ?? "Part \(part)"
                let words = meta?.wordCount ?? book?.wordCount
                let workID = meta?.workID
                let url = workID.flatMap { URL(string: "https://archiveofourown.org/works/\($0)") }
                items.append(SeriesGapItem(
                    partIndex: part,
                    isPresent: true,
                    title: title,
                    wordCount: words,
                    workID: workID,
                    url: url
                ))
            } else {
                let placeholder = placeholdersByPart[part]
                let title = placeholder?.note ?? "Part \(part) (Missing)"
                let url: URL? = {
                    if let ao3SeriesID {
                        return URL(string: "https://archiveofourown.org/series/\(ao3SeriesID)")
                    }
                    return nil
                }()
                items.append(SeriesGapItem(
                    partIndex: part,
                    isPresent: false,
                    title: title,
                    wordCount: nil,
                    workID: nil,
                    url: url
                ))
            }
        }

        return SeriesGapReport(
            seriesKey: series.seriesKey,
            seriesName: series.seriesName,
            ao3SeriesID: ao3SeriesID,
            authors: series.allAuthors,
            presentIndices: presentIndices,
            missingIndices: missingIndices,
            totalKnownParts: totalParts,
            items: items
        )
    }
}
