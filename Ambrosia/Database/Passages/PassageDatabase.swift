// SPDX-License-Identifier: GPL-3.0-only
import Accelerate
import Foundation
import SQLite
import SQLite3

// MARK: - Passage Database Actor

/// Manages high-performance read-only access to `ambrosia_semantic_passages.db`.
///
/// Performance architecture:
/// - Opened with `readonly: true`, `mmap_size = 2GB`, and `query_only = 1`.
/// - Scored directly on raw SQLite column BLOB pointers (zero heap allocation per row).
/// - Fast conversion from packed Little-Endian Float16 to Float32.
/// - Apple Accelerate SIMD dot product (`vDSP_dotpr`).
/// - Bounded Top-K candidate collection using insertion sort (avoids sorting all rows).
public actor PassageDatabase {

    public let databaseURL: URL
    public private(set) var metadata: PassageIndexMetadata
    public private(set) var isLoaded: Bool = false

    private var dbHandle: OpaquePointer?

    // MARK: - Initialization

    public init?(databaseURL: URL) {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return nil
        }
        self.databaseURL = databaseURL

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            return nil
        }

        self.dbHandle = handle

        // Optimize SQLite for memory-mapped read-only scanning
        Self.executePragma(handle, "PRAGMA query_only = 1;")
        Self.executePragma(handle, "PRAGMA mmap_size = 2147483648;") // 2 GB
        Self.executePragma(handle, "PRAGMA page_size = 16384;")
        Self.executePragma(handle, "PRAGMA cache_size = -65536;")    // 64 MB cache
        Self.executePragma(handle, "PRAGMA temp_store = MEMORY;")

        self.metadata = Self.readMetadata(handle)
        self.isLoaded = true
    }

    deinit {
        if let dbHandle {
            sqlite3_close_v2(dbHandle)
        }
    }

    // MARK: - Diagnostic Status

    public func status() -> PassageDatabaseStatus {
        guard let dbHandle, isLoaded else {
            return PassageDatabaseStatus(isLoaded: false)
        }

        var bookCount = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(dbHandle, "SELECT COUNT(*) FROM indexed_books;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                bookCount = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }

        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: databaseURL.path)[.size] as? Int64) ?? 0

        return PassageDatabaseStatus(
            chunkCount: metadata.chunkCount,
            bookCount: bookCount,
            storageBytes: fileBytes,
            isLoaded: true,
            modelID: metadata.modelID,
            dimension: metadata.dimension
        )
    }

    // MARK: - Vector Similarity Search

    /// Searches the passage database for top matching passages against a unit-normalized query vector.
    ///
    /// - Parameters:
    ///   - queryVector: Unit-normalized Float32 vector (must match `metadata.dimension`).
    ///   - topK: Number of top candidate passages to return (default 50).
    ///   - minSimilarity: Minimum cosine similarity threshold (default 0.25).
    ///   - restrictBookIDs: Optional set of Calibre book IDs to restrict the search to.
    /// - Returns: Ranked array of `SemanticPassageMatch` sorted by similarity descending.
    public func search(
        queryVector: [Float],
        topK: Int = 50,
        minSimilarity: Float = 0.25,
        restrictBookIDs: Set<Int>? = nil
    ) throws -> [SemanticPassageMatch] {
        guard let dbHandle, isLoaded else { return [] }
        let dimension = metadata.dimension
        guard queryVector.count == dimension else {
            return []
        }

        let expectedByteCount = dimension * MemoryLayout<Float16>.size

        // Build SQL query
        var sql = """
        SELECT c.id, c.book_id, c.spine_index, c.start_offset, c.end_offset, c.anchor_phrase, v.vector
        FROM passage_chunks c
        JOIN passage_vectors v ON c.id = v.chunk_id
        """

        let hasRestriction = restrictBookIDs != nil && !(restrictBookIDs?.isEmpty ?? true)
        if hasRestriction {
            sql += " WHERE " + SQLIDList.clause(column: "c.book_id")
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(dbHandle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        if hasRestriction, let ids = restrictBookIDs {
            let jsonBinding = SQLIDList.binding(Array(ids))
            if let stringBinding = jsonBinding as? String {
                sqlite3_bind_text(stmt, 1, (stringBinding as NSString).utf8String, -1, nil)
            }
        }

        // Reusable float buffer to avoid per-row allocations
        var floatBuffer = [Float](repeating: 0, count: dimension)
        var topMatches: [SemanticPassageMatch] = []
        topMatches.reserveCapacity(topK + 1)

        var minScoreInTop: Float = minSimilarity

        while sqlite3_step(stmt) == SQLITE_ROW {
            if Task.isCancelled { break }

            guard let rawBlob = sqlite3_column_blob(stmt, 6) else { continue }
            let blobBytes = Int(sqlite3_column_bytes(stmt, 6))
            guard blobBytes == expectedByteCount else { continue }

            // Zero-copy pointer read of Float16 elements
            let f16Ptr = rawBlob.assumingMemoryBound(to: Float16.self)
            for dimIndex in 0..<dimension {
                floatBuffer[dimIndex] = Float(f16Ptr[dimIndex])
            }

            // SIMD Dot Product (since vectors are L2-normalized, dot product is cosine similarity)
            var score: Float = 0
            vDSP_dotpr(queryVector, 1, floatBuffer, 1, &score, vDSP_Length(dimension))

            if score >= minScoreInTop {
                let chunkID = Int(sqlite3_column_int64(stmt, 0))
                let bookID = Int(sqlite3_column_int64(stmt, 1))
                let spineIndex = Int(sqlite3_column_int(stmt, 2))
                let startOffset = Int(sqlite3_column_int(stmt, 3))
                let endOffset = Int(sqlite3_column_int(stmt, 4))
                let anchorText: String
                if let textPtr = sqlite3_column_text(stmt, 5) {
                    anchorText = String(cString: textPtr)
                } else {
                    anchorText = ""
                }

                let match = SemanticPassageMatch(
                    id: chunkID,
                    calibreID: bookID,
                    spineIndex: spineIndex,
                    startOffset: startOffset,
                    endOffset: endOffset,
                    anchorPhrase: anchorText,
                    similarity: score,
                    extractedText: nil,
                    isLoadingText: false,
                    approximatePercent: 0.0
                )

                // Insert in sorted order (descending)
                let insertIdx = topMatches.partitioningIndex { $0.similarity <= score }
                topMatches.insert(match, at: insertIdx)

                if topMatches.count > topK {
                    topMatches.removeLast()
                }

                if topMatches.count >= topK {
                    minScoreInTop = max(minSimilarity, topMatches.last?.similarity ?? minSimilarity)
                }
            }
        }

        return topMatches
    }

    // MARK: - Internal Helpers

    private static func executePragma(_ handle: OpaquePointer, _ pragma: String) {
        sqlite3_exec(handle, pragma, nil, nil, nil)
    }

    private static func readMetadata(_ handle: OpaquePointer) -> PassageIndexMetadata {
        var metaDict: [String: String] = [:]
        var stmt: OpaquePointer?
        let sql = "SELECT key, value FROM index_metadata;"
        if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let keyPtr = sqlite3_column_text(stmt, 0),
                   let valPtr = sqlite3_column_text(stmt, 1) {
                    let key = String(cString: keyPtr)
                    let val = String(cString: valPtr)
                    metaDict[key] = val
                }
            }
            sqlite3_finalize(stmt)
        }

        // If chunk_count is not in metadata, query COUNT(*)
        var chunkCount = Int(metaDict["chunk_count"] ?? "") ?? 0
        if chunkCount == 0 {
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM passage_chunks;", -1, &countStmt, nil) == SQLITE_OK {
                if sqlite3_step(countStmt) == SQLITE_ROW {
                    chunkCount = Int(sqlite3_column_int(countStmt, 0))
                }
                sqlite3_finalize(countStmt)
            }
        }

        return PassageIndexMetadata(
            schemaVersion: metaDict["schema_version"] ?? "1.0",
            modelID: metaDict["model_id"] ?? "Qwen/Qwen3-Embedding-0.6B",
            dimension: Int(metaDict["dimension"] ?? "") ?? 1024,
            precision: metaDict["precision"] ?? "FP16",
            generatedAt: metaDict["generated_at"] ?? "",
            generatorTool: metaDict["generator_tool"] ?? "",
            chunkCount: chunkCount
        )
    }

    // MARK: - Maintenance & Compaction

    /// Checkpoints the WAL and vacuums `ambrosia_semantic_passages.db` if it exists.
    @discardableResult
    public static func compactAndVacuum(libraryURL: URL) throws -> (bytesReclaimed: Int64, passagesAfter: Int64) {
        let dbURL = libraryURL.appendingPathComponent("ambrosia_semantic_passages.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return (0, 0)
        }
        let beforeSize = databaseFilesSize(baseFileURL: dbURL)
        let conn = try Connection(dbURL.path)
        conn.busyTimeout = 5.0
        _ = try? conn.run("PRAGMA wal_checkpoint(TRUNCATE);")
        _ = try? conn.run("VACUUM;")
        _ = try? conn.run("PRAGMA wal_checkpoint(TRUNCATE);")

        let afterSize = databaseFilesSize(baseFileURL: dbURL)
        let reclaimed = max(0, beforeSize - afterSize)
        return (bytesReclaimed: reclaimed, passagesAfter: afterSize)
    }

    private static func databaseFilesSize(baseFileURL: URL) -> Int64 {
        var total: Int64 = 0
        let paths = [
            baseFileURL,
            baseFileURL.deletingPathExtension().appendingPathExtension("db-wal"),
            baseFileURL.deletingPathExtension().appendingPathExtension("db-shm")
        ]
        let fm = FileManager.default
        for path in paths {
            if let attrs = try? fm.attributesOfItem(atPath: path.path),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }
}

// MARK: - Array Partitioning Extension

private extension Array {
    /// Returns the first index where `predicate` is true, using binary search on a partitioned collection.
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = low + (high - low) / 2
            if predicate(self[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
}
