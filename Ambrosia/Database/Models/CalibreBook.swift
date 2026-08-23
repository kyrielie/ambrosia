import Foundation

/// A single book row as read from Calibre's metadata.db.
/// Plain Swift struct — no SwiftData, no faulting, no relationships.
/// Authors, tags, and comments are fetched per page in bulk and merged in.
struct CalibreBook: Identifiable, Hashable {
    let id: Int                 // Calibre books.id — used as calibreID throughout
    let title: String
    let series: String?
    let seriesIndex: Double?
    let wordCount: Int?
    let kudos: Int?
    let publishedDate: Date?
    let publisher: String?
    let relativePath: String    // books.path — relative to library root

    // Populated by bulk JOIN queries after the page is fetched
    var authors: [String] = []
    var tags: [String] = []
    var comment: String?        // HTML, stripped for display by HTMLStripper

    // MARK: - Display accessors

    var displayTitle: String {
        let value = title.isEmpty ? "Untitled" : title
        return ReaderPreferences.shared.correctCalibreAmpEntities ? value.correctedCalibreAmpEntity : value
    }

    var displayAuthors: String {
        authors.isEmpty ? "Unknown Author" : authors.joined(separator: ", ")
    }

    var displaySeries: String? {
        guard let seriesName = series, !seriesName.isEmpty else { return nil }
        if let idx = seriesIndex {
            let idxStr = idx.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(idx)) : String(idx)
            return "\(seriesName) #\(idxStr)"
        }
        return seriesName
    }

    var displayWordCount: String {
        guard let wc = wordCount, wc > 0 else { return "" }
        switch wc {
        case 0..<1_000:     return "\(wc) words"
        case 0..<1_000_000: return String(format: "%.1fk words", Double(wc) / 1_000)
        default:            return String(format: "%.2fM words", Double(wc) / 1_000_000)
        }
    }

    var displayKudos: String {
        guard let kudosCount = kudos, kudosCount > 0 else { return "" }
        return kudosCount >= 1_000 ? String(format: "%.1fk kudos", Double(kudosCount) / 1_000) : "\(kudosCount) kudos"
    }

    var displayComment: String? {
        guard let raw = comment, !raw.isEmpty else { return nil }
        let stripped = HTMLStripper.strip(raw)
        return ReaderPreferences.shared.correctCalibreAmpEntities ? stripped.correctedCalibreAmpEntity : stripped
    }

    /// True for books whose description was written by Calibre's EPUB-merge plugin,
    /// which prefixes merged/anthology comments with this exact literal string.
    /// Deliberately an exact prefix match (not a loose "contains 'anthology'" check)
    /// to avoid misfiring on real works whose own description happens to mention
    /// the word "anthology".
    var isDescriptionAnthology: Bool {
        guard let comment = displayComment else { return false }
        return AnthologyDetector.isAnthology(strippedComment: comment)
    }

    var isAO3PublisherBook: Bool {
        publisher?.trimmingCharacters(in: .whitespacesAndNewlines) == "Archive of Our Own"
    }

    /// Absolute EPUB URL — requires the library root URL from LibrarySession.
    func epubURL(libraryRoot: URL) -> URL? {
        let folder = libraryRoot.appendingPathComponent(relativePath)
        let contents = (try? FileManager.default.contentsOfDirectory(
                            at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents.first { $0.pathExtension.lowercased() == "epub" }
    }

    /// Absolute cover URL if Calibre has generated a cover.jpg beside the book files.
    func coverURL(libraryRoot: URL) -> URL? {
        let url = libraryRoot
            .appendingPathComponent(relativePath)
            .appendingPathComponent("cover.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Hashable
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: CalibreBook, rhs: CalibreBook) -> Bool { lhs.id == rhs.id }
}

private extension String {
    var correctedCalibreAmpEntity: String {
        replacingOccurrences(of: "&amp;", with: "&")
    }
}

struct SeriesCacheEntry: Hashable, Sendable {
    let calibreID: Int
    let seriesName: String
    let seriesIndex: Int
    let ao3SeriesID: String?
    let isAnthology: Bool
    /// Calibre's own `series.id` for this membership, when known. `NULL` for
    /// AO3-derived rows (see Bug 3 decision log: AO3 series are already
    /// uniquely identified per-row by `ao3SeriesID`, no Calibre cross-
    /// reference needed) and for rows backfilled before this column existed.
    let calibreSeriesID: Int?

    /// Precedence: an AO3-derived series id, then a persisted Calibre
    /// series id, then bare series name as a last-resort fallback (the only
    /// option before `calibre_series_id` existed, and still needed for
    /// libraries/rows that haven't been backfilled). Two distinct Calibre
    /// series sharing a name previously collided under the name-only key;
    /// this fixes that as soon as `calibreSeriesID` is populated. See Bug 3.
    var seriesKey: String {
        if let ao3SeriesID, !ao3SeriesID.isEmpty {
            return "ao3:\(ao3SeriesID)"
        }
        if let calibreSeriesID {
            return "calibre:\(calibreSeriesID)"
        }
        return "calibre-name:\(seriesName)"
    }
}

struct SeriesPlaceholder: Hashable, Sendable {
    let seriesKey: String
    let seriesName: String
    let partIndex: Int
    let note: String?
}

struct SingletonSeriesWarning: Hashable, Sendable {
    let seriesKey: String
    let seriesName: String
    let seriesIndex: Int
    let title: String

    var displayText: String {
        "Only local work in series; starts at #\(seriesIndex)"
    }
}

struct SeriesGroup: Identifiable, Hashable {
    let id: String
    let seriesKey: String
    let seriesName: String
    let works: [CalibreBook]
    let allFandoms: [String]
    let allRelationships: [String]
    let allCharacters: [String]
    let allCategories: [String]
    let allWarnings: [String]
    let allRatings: [String]
    let allAdditionalTags: [String]
    let allTags: [String]
    let allAuthors: [String]
    let allDescriptions: [String]
    let totalWordCount: Int
    let chapterCurrentTotal: Int?
    let chapterTotalTotal: Int?
    let hasUnknownChapterTotal: Bool
    let earliestPublished: Date?
    let latestUpdated: Date?
    let workIndices: [Int]
    let missingIndices: [Int]
    let placeholders: [SeriesPlaceholder]
    let isComplete: Bool

    init(
        id: String,
        seriesKey: String,
        seriesName: String,
        works: [CalibreBook],
        allFandoms: [String],
        allRelationships: [String],
        allCharacters: [String],
        allCategories: [String],
        allWarnings: [String],
        allRatings: [String],
        allAdditionalTags: [String],
        allTags: [String],
        allAuthors: [String],
        allDescriptions: [String],
        totalWordCount: Int,
        chapterCurrentTotal: Int?,
        chapterTotalTotal: Int?,
        hasUnknownChapterTotal: Bool,
        earliestPublished: Date?,
        latestUpdated: Date?,
        workIndices: [Int],
        missingIndices: [Int],
        placeholders: [SeriesPlaceholder],
        isComplete: Bool
    ) {
        precondition(!works.isEmpty, "SeriesGroup must be constructed with at least one work")
        self.id = id
        self.seriesKey = seriesKey
        self.seriesName = seriesName
        self.works = works
        self.allFandoms = allFandoms
        self.allRelationships = allRelationships
        self.allCharacters = allCharacters
        self.allCategories = allCategories
        self.allWarnings = allWarnings
        self.allRatings = allRatings
        self.allAdditionalTags = allAdditionalTags
        self.allTags = allTags
        self.allAuthors = allAuthors
        self.allDescriptions = allDescriptions
        self.totalWordCount = totalWordCount
        self.chapterCurrentTotal = chapterCurrentTotal
        self.chapterTotalTotal = chapterTotalTotal
        self.hasUnknownChapterTotal = hasUnknownChapterTotal
        self.earliestPublished = earliestPublished
        self.latestUpdated = latestUpdated
        self.workIndices = workIndices
        self.missingIndices = missingIndices
        self.placeholders = placeholders
        self.isComplete = isComplete
    }

    var displayAuthors: String {
        allAuthors.isEmpty ? "Unknown Author" : allAuthors.joined(separator: ", ")
    }

    var displayWordCount: String {
        guard totalWordCount > 0 else { return "" }
        switch totalWordCount {
        case 0..<1_000: return "\(totalWordCount) words"
        case 0..<1_000_000: return String(format: "%.1fk words", Double(totalWordCount) / 1_000)
        default: return String(format: "%.2fM words", Double(totalWordCount) / 1_000_000)
        }
    }

    var displayChapterCount: String {
        guard let chapterCurrentTotal else { return "" }
        guard !hasUnknownChapterTotal, let chapterTotalTotal else {
            return "\(chapterCurrentTotal)/? ch"
        }
        return "\(chapterCurrentTotal)/\(chapterTotalTotal) ch"
    }

    var dateRangeText: String {
        let calendar = Calendar.current
        let years = [earliestPublished, latestUpdated].compactMap { $0 }.map {
            calendar.component(.year, from: $0)
        }
        guard let first = years.min(), let last = years.max() else { return "" }
        return first == last ? "\(first)" : "\(first)-\(last)"
    }

    var coverBook: CalibreBook? { works.first }

    func displayIndex(for work: CalibreBook) -> Int? {
        guard let offset = works.firstIndex(where: { $0.id == work.id }),
              offset < workIndices.count else { return nil }
        return workIndices[offset]
    }

    var indexRangeText: String {
        let unique = Array(Set(workIndices)).sorted()
        guard !unique.isEmpty else { return "" }
        var ranges: [String] = []
        var start = unique[0]
        var previous = unique[0]
        for value in unique.dropFirst() {
            if value == previous + 1 {
                previous = value
            } else {
                ranges.append(Self.formatRange(start: start, end: previous))
                start = value
                previous = value
            }
        }
        ranges.append(Self.formatRange(start: start, end: previous))
        return ranges.joined(separator: ", ")
    }

    private static func formatRange(start: Int, end: Int) -> String {
        start == end ? "#\(start)" : "#\(start)-#\(end)"
    }
}

enum LibraryItem: Identifiable, Hashable {
    case book(CalibreBook)
    case series(SeriesGroup)
    /// A book that is a solo, non-leading member of a series with no other visible
    /// members (so no `SeriesGroup` was built for it) — e.g. orphaned #5 of a series
    /// where nobody else's #1-#4 or #6+ are in this library. Rendered as its own row
    /// so a book that leads series A, is grouped in series B, and is orphaned-alone in
    /// series C still surfaces all three memberships distinctly. The id is namespaced by
    /// seriesKey (not just book id) because the same book can appear this way more than
    /// once, once per orphaned series.
    case orphanedSeriesEntry(book: CalibreBook, warning: SingletonSeriesWarning)

    var id: String {
        switch self {
        case .book(let book): return "book-\(book.id)"
        case .series(let series): return "series-\(series.id)"
        case .orphanedSeriesEntry(let book, let warning): return "orphan-\(book.id)-\(warning.seriesKey)"
        }
    }
}

enum ReadingTarget: Hashable {
    case singleBook(CalibreBook)
    case series(SeriesGroup)

    var primaryBook: CalibreBook {
        switch self {
        case .singleBook(let book): return book
        case .series(let series):
            precondition(!series.works.isEmpty, "SeriesGroup invariant violated: works must be non-empty")
            return series.works[0]
        }
    }

    var windowKey: String {
        switch self {
        case .singleBook(let book): return "book-\(book.id)"
        case .series(let series): return "series-\(series.id)"
        }
    }

    var displayTitle: String {
        switch self {
        case .singleBook(let book): return book.displayTitle
        case .series(let series): return series.seriesName
        }
    }
}
