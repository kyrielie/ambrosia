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

struct Annotation: Codable, Identifiable, Sendable {
    var id: UUID               = UUID()
    var spineIndex: Int                 // which spine item
    var spineHref: String      = ""     // OPF href for surviving spine reordering
    var startChar: Int                  // UTF-16 code units, text nodes only
    var endChar: Int                    // == startChar for point annotations (old bookmarks)
    var selectedText: String            // "" or sentence preview for point annotations
    var quotePrefix: String    = ""     // up to 200 UTF-16 code units before anchor
    var quoteSuffix: String    = ""     // up to 200 UTF-16 code units after anchor
    var chapterTitle: String?           // nearest preceding heading in spine
    var note: String?                   // user-written note, optional
    var colorKey: AnnotationColor       // semantic key ("yellow", "red", etc.)
    var colorHex: String                // legacy hex retained for backward compatibility
    var hasHighlight: Bool     = true   // independent of text edit
    var originalText: String?           // non-nil when carrying a non-destructive text edit
    var replacementText: String?        // replacement text rendered in-place
    var needsReanchor: Bool    = false  // flagged after EPUB update/replace
    var lastReanchoredAt: Date?
    var orphanedAt: Date?
    var createdDate: Date      = Date()
    var updatedAt: Date        = Date()

    var isPointAnnotation: Bool { startChar == endChar }
    var isTextEdit: Bool { originalText != nil }
    var isOrphaned: Bool { orphanedAt != nil }
    var displayText: String { replacementText ?? selectedText }

    init(
        id: UUID = UUID(),
        spineIndex: Int,
        spineHref: String = "",
        startChar: Int,
        endChar: Int,
        selectedText: String,
        quotePrefix: String = "",
        quoteSuffix: String = "",
        chapterTitle: String? = nil,
        note: String? = nil,
        colorKey: AnnotationColor? = nil,
        colorHex: String = "#FFD60A",
        hasHighlight: Bool = true,
        originalText: String? = nil,
        replacementText: String? = nil,
        needsReanchor: Bool = false,
        lastReanchoredAt: Date? = nil,
        orphanedAt: Date? = nil,
        createdDate: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.spineIndex = spineIndex
        self.spineHref = spineHref
        self.startChar = startChar
        self.endChar = endChar
        self.selectedText = selectedText
        self.quotePrefix = quotePrefix
        self.quoteSuffix = quoteSuffix
        self.chapterTitle = chapterTitle
        self.note = note
        let resolvedKey = colorKey ?? AnnotationColor(legacyHex: colorHex)
        self.colorKey = resolvedKey
        self.colorHex = colorHex
        self.hasHighlight = hasHighlight || originalText == nil
        self.originalText = originalText
        self.replacementText = replacementText
        self.needsReanchor = needsReanchor
        self.lastReanchoredAt = lastReanchoredAt
        self.orphanedAt = orphanedAt
        self.createdDate = createdDate
        self.updatedAt = updatedAt ?? createdDate
    }

    enum CodingKeys: String, CodingKey {
        case id, spineIndex, spineHref, startChar, endChar, selectedText
        case quotePrefix, quoteSuffix, chapterTitle, note, colorKey, colorHex
        case hasHighlight, originalText, replacementText
        case needsReanchor, lastReanchoredAt, orphanedAt, createdDate, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        spineIndex = try container.decode(Int.self, forKey: .spineIndex)
        spineHref = try container.decodeIfPresent(String.self, forKey: .spineHref) ?? ""
        startChar = try container.decode(Int.self, forKey: .startChar)
        endChar = try container.decode(Int.self, forKey: .endChar)
        selectedText = try container.decode(String.self, forKey: .selectedText)
        quotePrefix = try container.decodeIfPresent(String.self, forKey: .quotePrefix) ?? ""
        quoteSuffix = try container.decodeIfPresent(String.self, forKey: .quoteSuffix) ?? ""
        chapterTitle = try container.decodeIfPresent(String.self, forKey: .chapterTitle)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        let decodedHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FFD60A"
        colorHex = decodedHex
        colorKey = try container.decodeIfPresent(AnnotationColor.self, forKey: .colorKey)
            ?? AnnotationColor(legacyHex: decodedHex)
        originalText = try container.decodeIfPresent(String.self, forKey: .originalText)
        replacementText = try container.decodeIfPresent(String.self, forKey: .replacementText)
        let decodedHasHighlight = try container.decodeIfPresent(Bool.self, forKey: .hasHighlight) ?? true
        hasHighlight = decodedHasHighlight || originalText == nil
        needsReanchor = try container.decodeIfPresent(Bool.self, forKey: .needsReanchor) ?? false
        lastReanchoredAt = try container.decodeIfPresent(Date.self, forKey: .lastReanchoredAt)
        orphanedAt = try container.decodeIfPresent(Date.self, forKey: .orphanedAt)
        let decodedCreated = try container.decodeIfPresent(Date.self, forKey: .createdDate) ?? Date()
        createdDate = decodedCreated
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? decodedCreated
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
