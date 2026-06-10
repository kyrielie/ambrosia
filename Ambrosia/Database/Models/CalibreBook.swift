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
    let relativePath: String    // books.path — relative to library root

    // Populated by bulk JOIN queries after the page is fetched
    var authors: [String] = []
    var tags: [String] = []
    var comment: String?        // HTML, stripped for display by HTMLStripper

    // MARK: - Display accessors

    var displayTitle: String {
        title.isEmpty ? "Untitled" : title
    }

    var displayAuthors: String {
        authors.isEmpty ? "Unknown Author" : authors.joined(separator: ", ")
    }

    var displaySeries: String? {
        guard let s = series, !s.isEmpty else { return nil }
        if let idx = seriesIndex {
            let idxStr = idx.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(idx)) : String(idx)
            return "\(s) #\(idxStr)"
        }
        return s
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
        guard let k = kudos, k > 0 else { return "" }
        return k >= 1_000 ? String(format: "%.1fk kudos", Double(k) / 1_000) : "\(k) kudos"
    }

    var displayComment: String? {
        guard let raw = comment, !raw.isEmpty else { return nil }
        return HTMLStripper.strip(raw)
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

struct SeriesCacheEntry: Hashable, Sendable {
    let calibreID: Int
    let seriesName: String
    let seriesIndex: Int
    let ao3SeriesID: String?
    let isAnthology: Bool
}

struct SeriesPlaceholder: Hashable, Sendable {
    let seriesName: String
    let partIndex: Int
    let note: String?
}

struct SeriesGroup: Identifiable, Hashable {
    let id: String
    let seriesName: String
    let works: [CalibreBook]
    let allFandoms: [String]
    let allTags: [String]
    let allAuthors: [String]
    let allDescriptions: [String]
    let totalWordCount: Int
    let earliestPublished: Date?
    let latestUpdated: Date?
    let missingIndices: [Int]
    let placeholders: [SeriesPlaceholder]
    let isComplete: Bool

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

    var dateRangeText: String {
        let calendar = Calendar.current
        let years = [earliestPublished, latestUpdated].compactMap { $0 }.map {
            calendar.component(.year, from: $0)
        }
        guard let first = years.min(), let last = years.max() else { return "" }
        return first == last ? "\(first)" : "\(first)-\(last)"
    }

    var coverBook: CalibreBook? { works.first }
}

enum LibraryItem: Identifiable, Hashable {
    case book(CalibreBook)
    case series(SeriesGroup)

    var id: String {
        switch self {
        case .book(let book): return "book-\(book.id)"
        case .series(let series): return "series-\(series.id)"
        }
    }
}

enum ReadingTarget: Hashable {
    case singleBook(CalibreBook)
    case series(SeriesGroup)

    var primaryBook: CalibreBook {
        switch self {
        case .singleBook(let book): return book
        case .series(let series): return series.works.first!
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
