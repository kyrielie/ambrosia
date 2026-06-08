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
/// - Collections stored as JSON Data — never [String] or [T] directly.
@Model
final class BookState {
    /// Foreign key into Calibre's books table. Unique per library.
    var calibreID: Int

    // MARK: - User state
    var isLiked: Bool = false
    var isHidden: Bool = false

    // MARK: - Reading progress
    var lastOpenedDate: Date = Date(timeIntervalSince1970: 0)
    var totalReadPercent: Double = 0
    var totalReadingTimeSeconds: TimeInterval = 0

    // MARK: - Reading position
    var readingModeRaw: String = "scroll"   // Legacy — superseded by ReaderPreferences.shared.defaultReadingMode (global override).
                                             // Not removed to avoid SwiftData migration. Never read or written.
    var lastSpineIndex: Int = 0
    var lastCharacterOffset: Int = 0        // UTF-16 code units, text nodes only
    var lastScrollOffset: Double = 0
    var lastSavedDate: Date = Date()

    // MARK: - Legacy annotation fields (orphaned — never read or written)
    // bookmarksData and highlightsData are retained to avoid SwiftData migration.
    // All annotation code now uses annotationsData / annotations below.
    var bookmarksData: Data?
    var highlightsData: Data?

    // MARK: - Annotation (unified bookmark + highlight)

    var annotationsData: Data?   // JSON-encoded [Annotation]. Never [Annotation] directly.

    var annotations: [Annotation] {
        get {
            guard let d = annotationsData else { return [] }
            return (try? JSONDecoder().decode([Annotation].self, from: d)) ?? []
        }
        set {
            annotationsData = try? JSONEncoder().encode(newValue)
        }
    }

    init(calibreID: Int) {
        self.calibreID = calibreID
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

// MARK: - Legacy types (retained for decode compatibility — not used in new code)

struct Bookmark: Codable, Identifiable {
    var id: UUID = UUID()
    let spineIndex: Int
    let characterOffset: Int
    let note: String?
    let createdDate: Date
    let previewText: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = (try? c.decode(UUID.self,   forKey: .id))              ?? UUID()
        spineIndex      = (try? c.decode(Int.self,    forKey: .spineIndex))      ?? 0
        characterOffset = (try? c.decode(Int.self,    forKey: .characterOffset)) ?? 0
        note            =  try? c.decodeIfPresent(String.self, forKey: .note)
        createdDate     = (try? c.decode(Date.self,   forKey: .createdDate))     ?? Date()
        previewText     = (try? c.decode(String.self, forKey: .previewText))     ?? ""
    }

    init(spineIndex: Int, characterOffset: Int,
         note: String? = nil, createdDate: Date = Date(), previewText: String = "") {
        self.spineIndex      = spineIndex
        self.characterOffset = characterOffset
        self.note            = note
        self.createdDate     = createdDate
        self.previewText     = previewText
    }
}

struct Highlight: Codable, Identifiable {
    var id: UUID = UUID()
    let spineIndex: Int
    let startChar: Int
    let endChar: Int
    let selectedText: String
    let note: String?
    let createdDate: Date
    let colorHex: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = (try? c.decode(UUID.self,   forKey: .id))           ?? UUID()
        spineIndex   = (try? c.decode(Int.self,    forKey: .spineIndex))   ?? 0
        startChar    = (try? c.decode(Int.self,    forKey: .startChar))    ?? 0
        endChar      = (try? c.decode(Int.self,    forKey: .endChar))      ?? 0
        selectedText = (try? c.decode(String.self, forKey: .selectedText)) ?? ""
        note         =  try? c.decodeIfPresent(String.self, forKey: .note)
        createdDate  = (try? c.decode(Date.self,   forKey: .createdDate))  ?? Date()
        colorHex     = (try? c.decode(String.self, forKey: .colorHex))     ?? "#FFD60A"
    }

    init(spineIndex: Int, startChar: Int, endChar: Int,
         selectedText: String, note: String? = nil,
         createdDate: Date = Date(), colorHex: String = "#FFD60A") {
        self.spineIndex   = spineIndex
        self.startChar    = startChar
        self.endChar      = endChar
        self.selectedText = selectedText
        self.note         = note
        self.createdDate  = createdDate
        self.colorHex     = colorHex
    }
}
