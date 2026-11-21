// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// MARK: - Passage Index Metadata

/// Stored metadata from `index_metadata` in `ambrosia_semantic_passages.db`.
public struct PassageIndexMetadata: Sendable, Equatable {
    public let schemaVersion: String
    public let modelID: String
    public let dimension: Int
    public let precision: String
    public let generatedAt: String
    public let generatorTool: String
    public let chunkCount: Int

    public init(
        schemaVersion: String = "1.0",
        modelID: String = "",
        dimension: Int = 1024,
        precision: String = "FP16",
        generatedAt: String = "",
        generatorTool: String = "",
        chunkCount: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.dimension = dimension
        self.precision = precision
        self.generatedAt = generatedAt
        self.generatorTool = generatorTool
        self.chunkCount = chunkCount
    }
}

// MARK: - Passage Database Diagnostic Status

/// Diagnostic status for Preferences ▸ Data and search summary bar.
public struct PassageDatabaseStatus: Sendable, Equatable {
    public let chunkCount: Int
    public let bookCount: Int
    public let storageBytes: Int64
    public let isLoaded: Bool
    public let modelID: String
    public let dimension: Int

    public init(
        chunkCount: Int = 0,
        bookCount: Int = 0,
        storageBytes: Int64 = 0,
        isLoaded: Bool = false,
        modelID: String = "",
        dimension: Int = 0
    ) {
        self.chunkCount = chunkCount
        self.bookCount = bookCount
        self.storageBytes = storageBytes
        self.isLoaded = isLoaded
        self.modelID = modelID
        self.dimension = dimension
    }
}

// MARK: - Passage Chunk Record

/// Raw SQLite row representation from `passage_chunks`.
public struct PassageChunkRecord: Sendable, Equatable {
    public let id: Int
    public let bookID: Int
    public let spineIndex: Int
    public let chunkIndex: Int
    public let startOffset: Int
    public let endOffset: Int
    public let anchorPhrase: String

    public init(
        id: Int,
        bookID: Int,
        spineIndex: Int,
        chunkIndex: Int,
        startOffset: Int,
        endOffset: Int,
        anchorPhrase: String
    ) {
        self.id = id
        self.bookID = bookID
        self.spineIndex = spineIndex
        self.chunkIndex = chunkIndex
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.anchorPhrase = anchorPhrase
    }
}

// MARK: - Semantic Passage Match Result

/// A scored search result representing a passage match in the library.
public struct SemanticPassageMatch: Identifiable, Sendable, Equatable {
    public let id: Int                    // passage_chunks.id
    public let calibreID: Int             // passage_chunks.book_id
    public let spineIndex: Int            // EPUB spine item index
    public let startOffset: Int           // UTF-16 code units from spine start
    public let endOffset: Int             // UTF-16 code units
    public let anchorPhrase: String       // First 8-12 words
    public let similarity: Float          // Cosine similarity score (0.0 ... 1.0)
    public var extractedText: String?     // Full ~400-word excerpt (lazily populated from EPUB)
    public var isLoadingText: Bool        // Async streaming indicator
    public var chapterTitle: String?      // Chapter name if resolved from TOC
    public var approximatePercent: Double // Rough position in book (0.0 ... 1.0)

    public var charLength: Int {
        max(0, endOffset - startOffset)
    }

    public var similarityPercentage: Int {
        Int((min(max(similarity, 0.0), 1.0) * 100.0).rounded())
    }

    public init(
        id: Int,
        calibreID: Int,
        spineIndex: Int,
        startOffset: Int,
        endOffset: Int,
        anchorPhrase: String,
        similarity: Float,
        extractedText: String? = nil,
        isLoadingText: Bool = false,
        chapterTitle: String? = nil,
        approximatePercent: Double = 0.0
    ) {
        self.id = id
        self.calibreID = calibreID
        self.spineIndex = spineIndex
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.anchorPhrase = anchorPhrase
        self.similarity = similarity
        self.extractedText = extractedText
        self.isLoadingText = isLoadingText
        self.chapterTitle = chapterTitle
        self.approximatePercent = approximatePercent
    }
}
