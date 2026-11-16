// SPDX-License-Identifier: GPL-3.0-only
import Accelerate
import Foundation
import NaturalLanguage

/// Semantic indexing status diagnostics.
public struct SemanticIndexStatus: Sendable, Equatable {
    public let indexedCount: Int
    public let storageBytes: Int64
    public let isLoaded: Bool

    public init(indexedCount: Int, storageBytes: Int64, isLoaded: Bool) {
        self.indexedCount = indexedCount
        self.storageBytes = storageBytes
        self.isLoaded = isLoaded
    }
}

/// On-device semantic search engine using Apple NaturalLanguage embeddings and Accelerate BLAS SIMD.
public actor SemanticSearchEngine {
    private var embedding: NLEmbedding?
    private var matrix: EmbeddingMatrix?
    private var indexedIDs: [Int] = []
    private var idToIndex: [Int: Int] = [:]
    private let storageURL: URL?

    public init(storageURL: URL? = nil) {
        self.storageURL = storageURL
        self.embedding = NLEmbedding.sentenceEmbedding(for: .english)
    }

    /// Unit normalizes a vector.
    public static func normalize(_ vector: [Float]) -> [Float] {
        var sumSquares: Float = 0
        vDSP_svesq(vector, 1, &sumSquares, vDSP_Length(vector.count))
        let norm = sqrt(sumSquares)
        guard norm > 0 else { return vector }
        var result = [Float](repeating: 0, count: vector.count)
        var scale = 1.0 / norm
        vDSP_vsmul(vector, 1, &scale, &result, 1, vDSP_Length(vector.count))
        return result
    }

    /// Embeds a single string into a unit-normalized Float vector.
    public func embed(text: String) -> [Float]? {
        guard let embedding = embedding ?? NLEmbedding.sentenceEmbedding(for: .english) else {
            return nil
        }
        self.embedding = embedding
        guard let raw = embedding.vector(for: text) else {
            return nil
        }
        let floats = raw.map(Float.init)
        return Self.normalize(floats)
    }

    /// Indexes multiple documents, each associated with a Calibre book ID.
    /// If `incremental` is true, preserves existing embeddings and only generates embeddings for unindexed IDs.
    public func index(
        documents: [(id: Int, text: String)],
        incremental: Bool = false,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) {
        guard let embedding = embedding ?? NLEmbedding.sentenceEmbedding(for: .english) else {
            return
        }
        self.embedding = embedding
        let dimension = embedding.dimension

        let existingIDs = (incremental && matrix != nil) ? self.indexedIDs : []
        let existingValues = (incremental && matrix != nil) ? (self.matrix?.values ?? []) : []
        var existingSet = Set(existingIDs)

        var newIDs: [Int] = []
        var newValues: [Float] = []
        let total = documents.count

        for (index, doc) in documents.enumerated() {
            if incremental && existingSet.contains(doc.id) {
                progress?(index + 1, total)
                continue
            }
            guard let raw = embedding.vector(for: doc.text), raw.count == dimension else {
                progress?(index + 1, total)
                continue
            }
            let normalized = Self.normalize(raw.map(Float.init))
            newIDs.append(doc.id)
            newValues.append(contentsOf: normalized)
            existingSet.insert(doc.id)
            progress?(index + 1, total)
        }

        let combinedIDs = existingIDs + newIDs
        let combinedValues = existingValues + newValues

        let matrix = EmbeddingMatrix(rows: combinedIDs.count, dimension: dimension, values: combinedValues)
        self.matrix = matrix
        self.indexedIDs = combinedIDs
        self.idToIndex = Dictionary(uniqueKeysWithValues: combinedIDs.enumerated().map { ($1, $0) })

        if let storageURL {
            try? save(to: storageURL)
        }
    }

    /// Returns the set of currently indexed book IDs.
    public func indexedIDSet() -> Set<Int> {
        Set(indexedIDs)
    }

    /// Returns the live index diagnostics and disk footprint.
    public func status(in directory: URL? = nil) -> SemanticIndexStatus {
        let dir = directory ?? storageURL
        var bytes: Int64 = 0
        if let dir {
            let binURL = dir.appendingPathComponent("semantic_vectors.bin")
            let idsURL = dir.appendingPathComponent("semantic_ids.json")
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: binURL.path),
               let size = attrs[.size] as? Int64 {
                bytes += size
            }
            if let attrs = try? fm.attributesOfItem(atPath: idsURL.path),
               let size = attrs[.size] as? Int64 {
                bytes += size
            }
        }
        return SemanticIndexStatus(
            indexedCount: indexedIDs.count,
            storageBytes: bytes,
            isLoaded: matrix != nil
        )
    }

    /// Searches for works semantically relevant to the query string.
    public func search(query: String, minSimilarity: Double = 0.2, topK: Int = 100) -> [(id: Int, score: Double)] {
        guard ReaderPreferences.shared.enableSemanticSearch else { return [] }
        guard let matrix, !indexedIDs.isEmpty,
              let queryVec = embed(text: query), queryVec.count == matrix.dimension else {
            return []
        }

        let scores = VectorStore.cosineSimilarities(matrix: matrix, query: queryVec)
        var ranked: [(id: Int, score: Double)] = []
        ranked.reserveCapacity(scores.count)

        for (index, score) in scores.enumerated() {
            let scoreDouble = Double(score)
            if scoreDouble >= minSimilarity {
                ranked.append((id: indexedIDs[index], score: scoreDouble))
            }
        }

        ranked.sort { $0.score > $1.score }
        if ranked.count > topK {
            return Array(ranked.prefix(topK))
        }
        return ranked
    }

    /// Saves binary vectors and ID mapping to disk.
    public func save(to directory: URL) throws {
        guard let matrix else { return }
        let binURL = directory.appendingPathComponent("semantic_vectors.bin")
        let idsURL = directory.appendingPathComponent("semantic_ids.json")
        try VectorStore.write(matrix, to: binURL)
        let idsData = try JSONEncoder().encode(indexedIDs)
        try idsData.write(to: idsURL, options: .atomic)
    }

    /// Loads binary vectors and ID mapping from disk.
    public func load(from directory: URL) -> Bool {
        let binURL = directory.appendingPathComponent("semantic_vectors.bin")
        let idsURL = directory.appendingPathComponent("semantic_ids.json")
        guard let matrix = VectorStore.read(from: binURL),
              let idsData = try? Data(contentsOf: idsURL),
              let ids = try? JSONDecoder().decode([Int].self, from: idsData),
              ids.count == matrix.rows else {
            return false
        }
        self.matrix = matrix
        self.indexedIDs = ids
        self.idToIndex = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return true
    }

    public var count: Int {
        indexedIDs.count
    }

    /// Clears memory and cached vector files from disk.
    public func clear(in directory: URL? = nil) {
        indexedIDs.removeAll()
        idToIndex.removeAll()
        matrix = nil
        if let dir = directory ?? storageURL {
            let binURL = dir.appendingPathComponent("semantic_vectors.bin")
            let idsURL = dir.appendingPathComponent("semantic_ids.json")
            try? FileManager.default.removeItem(at: binURL)
            try? FileManager.default.removeItem(at: idsURL)
        }
    }
}
