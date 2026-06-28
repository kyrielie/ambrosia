import SwiftData
import Foundation

/// App-owned state for a single book, keyed by Calibre's book ID.
/// This is the ONLY @Model in the new architecture.
/// All display metadata (title, authors, tags, description) is read
/// directly from Calibre's metadata.db via CalibreLibrary.
///
/// STORAGE INVARIANTS:
/// - characterOffset fields use UTF-16 code units, text nodes only.
///   Must match EPUBParser, PaginationJS, HighlightBridge exactly.
@Model
final class BookState {
    /// Foreign key into Calibre's books table. Unique per library.
    var calibreID: Int

    // MARK: - Reading progress
    var lastOpenedDate: Date = Date(timeIntervalSince1970: 0)
    var totalReadPercent: Double = 0
    var totalReadingTimeSeconds: TimeInterval = 0

    // MARK: - Reading position
    var lastSpineIndex: Int = 0
    var lastCharacterOffset: Int = 0        // UTF-16 code units, text nodes only
    var lastScrollOffset: Double = 0

    // MARK: - ELO ranking
    var eloScore: Double = 1000.0
    var eloMatchCount: Int = 0

    init(calibreID: Int) {
        self.calibreID = calibreID
    }

    func markRead() {
        totalReadPercent = 1.0
    }

    func resetReadingProgress() {
        totalReadPercent = 0
        lastSpineIndex = 0
        lastCharacterOffset = 0
        lastScrollOffset = 0
        lastOpenedDate = Date(timeIntervalSince1970: 0)
        totalReadingTimeSeconds = 0
    }
}

// MARK: - Annotation (unified bookmark + highlight)

struct Annotation: Codable, Identifiable {
    var id: UUID          = UUID()
    var spineIndex: Int                 // which spine item
    var startChar: Int                  // UTF-16 code units, text nodes only
    var endChar: Int                    // == startChar for point annotations (old bookmarks)
    var selectedText: String            // "" for point annotations
    var note: String?                   // user-written note, optional
    var colorHex: String                // "#FFD60A" yellow default
    var isPointAnnotation: Bool { startChar == endChar }
    var createdDate: Date               = Date()
}

// MARK: - ReadingMode (used by ReaderPreferences — kept here for compatibility)

enum ReadingMode: String, Codable, CaseIterable, Identifiable {
    case scroll    = "scroll"
    case paginated = "paginated"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .scroll:    return "Scroll"
        case .paginated: return "Paginated"
        }
    }
}
