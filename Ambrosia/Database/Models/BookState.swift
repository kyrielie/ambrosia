import Foundation

/// App-owned state for a single book, keyed by Calibre's book ID.
/// Stored in each library's scoped ambrosia_meta.db (book_state table).
///
/// STORAGE INVARIANTS:
/// - characterOffset fields use UTF-16 code units, text nodes only.
///   Must match EPUBParser, PaginationJS, HighlightBridge exactly.
public struct BookState: Identifiable, Sendable, Equatable, Hashable {
    public var id: Int { calibreID }

    /// Foreign key into Calibre's books table. Unique per library.
    public var calibreID: Int

    // MARK: - Reading progress
    public var lastOpenedDate: Date
    public var totalReadPercent: Double
    public var totalReadingTimeSeconds: TimeInterval

    // MARK: - Reading position
    public var lastSpineIndex: Int
    public var lastCharacterOffset: Int        // UTF-16 code units, text nodes only
    public var lastScrollOffset: Double

    // MARK: - ELO ranking
    public var eloScore: Double
    public var eloMatchCount: Int

    public init(
        calibreID: Int,
        lastOpenedDate: Date = Date(timeIntervalSince1970: 0),
        totalReadPercent: Double = 0.0,
        totalReadingTimeSeconds: TimeInterval = 0.0,
        lastSpineIndex: Int = 0,
        lastCharacterOffset: Int = 0,
        lastScrollOffset: Double = 0.0,
        eloScore: Double = 1000.0,
        eloMatchCount: Int = 0
    ) {
        self.calibreID = calibreID
        self.lastOpenedDate = lastOpenedDate
        self.totalReadPercent = totalReadPercent
        self.totalReadingTimeSeconds = totalReadingTimeSeconds
        self.lastSpineIndex = lastSpineIndex
        self.lastCharacterOffset = lastCharacterOffset
        self.lastScrollOffset = lastScrollOffset
        self.eloScore = eloScore
        self.eloMatchCount = eloMatchCount
    }

    public var isRead: Bool {
        totalReadPercent >= 0.98
    }

    public var hasBeenOpened: Bool {
        lastOpenedDate > Date(timeIntervalSince1970: 0)
    }

    public mutating func markRead() {
        totalReadPercent = 1.0
    }

    public mutating func resetReadingProgress() {
        totalReadPercent = 0.0
        lastSpineIndex = 0
        lastCharacterOffset = 0
        lastScrollOffset = 0.0
        lastOpenedDate = Date(timeIntervalSince1970: 0)
        totalReadingTimeSeconds = 0.0
    }
}

// MARK: - Annotation (unified bookmark + highlight)

struct Annotation: Codable, Identifiable {
    var id: UUID               = UUID()
    var spineIndex: Int                 // which spine item
    var startChar: Int                  // UTF-16 code units, text nodes only
    var endChar: Int                    // == startChar for point annotations (old bookmarks)
    var selectedText: String            // "" for point annotations
    var note: String?                   // user-written note, optional
    var colorKey: AnnotationColor       // semantic key ("yellow", "red", etc.)
    var colorHex: String                // legacy hex retained for backward compatibility
    var isPointAnnotation: Bool { startChar == endChar }
    var createdDate: Date      = Date()

    init(
        id: UUID = UUID(),
        spineIndex: Int,
        startChar: Int,
        endChar: Int,
        selectedText: String,
        note: String? = nil,
        colorKey: AnnotationColor? = nil,
        colorHex: String = "#FFD60A",
        createdDate: Date = Date()
    ) {
        self.id = id
        self.spineIndex = spineIndex
        self.startChar = startChar
        self.endChar = endChar
        self.selectedText = selectedText
        self.note = note
        let resolvedKey = colorKey ?? AnnotationColor(legacyHex: colorHex)
        self.colorKey = resolvedKey
        self.colorHex = colorHex
        self.createdDate = createdDate
    }

    enum CodingKeys: String, CodingKey {
        case id, spineIndex, startChar, endChar, selectedText, note, colorKey, colorHex, createdDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        spineIndex = try container.decode(Int.self, forKey: .spineIndex)
        startChar = try container.decode(Int.self, forKey: .startChar)
        endChar = try container.decode(Int.self, forKey: .endChar)
        selectedText = try container.decode(String.self, forKey: .selectedText)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        let decodedHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FFD60A"
        colorHex = decodedHex
        colorKey = try container.decodeIfPresent(AnnotationColor.self, forKey: .colorKey)
            ?? AnnotationColor(legacyHex: decodedHex)
        createdDate = try container.decodeIfPresent(Date.self, forKey: .createdDate) ?? Date()
    }
}

// MARK: - ReadingMode (used by ReaderPreferences — kept here for compatibility)

enum ReadingMode: String, Codable, CaseIterable, Identifiable {
    case scroll
    case paginated
    var id: String { rawValue }
    var label: String {
        switch self {
        case .scroll:    return "Scroll"
        case .paginated: return "Paginated"
        }
    }
}
