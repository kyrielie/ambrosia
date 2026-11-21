// SPDX-License-Identifier: GPL-3.0-only
import Accelerate
import SQLite3
import XCTest
@testable import Ambrosia

final class PassageDatabaseTests: XCTestCase {

    private var tempDBURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassageDBTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempDBURL = tempDir.appendingPathComponent("ambrosia_semantic_passages.db")
    }

    override func tearDownWithError() throws {
        if let tempDBURL {
            try? FileManager.default.removeItem(at: tempDBURL.deletingLastPathComponent())
        }
        try super.tearDownWithError()
    }

    private func createTestDatabase(dimension: Int = 4) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        XCTAssertEqual(sqlite3_open_v2(tempDBURL.path, &db, flags, nil), SQLITE_OK)
        defer { sqlite3_close_v2(db) }

        let schema = """
        CREATE TABLE index_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE indexed_books (book_id INTEGER PRIMARY KEY, file_size INTEGER, mtime INTEGER, chunk_count INTEGER, indexed_at INTEGER);
        CREATE TABLE passage_chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id INTEGER NOT NULL,
            spine_index INTEGER NOT NULL,
            chunk_index INTEGER NOT NULL,
            start_offset INTEGER NOT NULL,
            end_offset INTEGER NOT NULL,
            anchor_phrase TEXT NOT NULL
        );
        CREATE TABLE passage_vectors (
            chunk_id INTEGER PRIMARY KEY,
            vector BLOB NOT NULL
        );
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)

        // Metadata
        let metaSQL = """
        INSERT INTO index_metadata VALUES ('schema_version', '1.0');
        INSERT INTO index_metadata VALUES ('model_id', 'Qwen/Qwen3-Embedding-0.6B');
        INSERT INTO index_metadata VALUES ('dimension', '\(dimension)');
        INSERT INTO index_metadata VALUES ('precision', 'FP16');
        INSERT INTO index_metadata VALUES ('chunk_count', '3');
        """
        XCTAssertEqual(sqlite3_exec(db, metaSQL, nil, nil, nil), SQLITE_OK)

        // Books
        let booksSQL = """
        INSERT INTO indexed_books VALUES (101, 5000, 1600000000, 2, 1600000000);
        INSERT INTO indexed_books VALUES (102, 8000, 1600000000, 1, 1600000000);
        """
        XCTAssertEqual(sqlite3_exec(db, booksSQL, nil, nil, nil), SQLITE_OK)

        // Chunks
        let chunksSQL = """
        INSERT INTO passage_chunks VALUES (1, 101, 0, 0, 0, 150, 'The rain beat against the carriage windows');
        INSERT INTO passage_chunks VALUES (2, 101, 1, 0, 20, 220, 'Swords clashed in the courtyard as thunder rolled');
        INSERT INTO passage_chunks VALUES (3, 102, 0, 0, 50, 180, 'She brewed the tea in silence by the hearth');
        """
        XCTAssertEqual(sqlite3_exec(db, chunksSQL, nil, nil, nil), SQLITE_OK)

        // Vectors: 4 dimensions, normalized
        // Vector 1: [1, 0, 0, 0]
        // Vector 2: [0, 1, 0, 0]
        // Vector 3: [0, 0, 1, 0]
        let rawVecs: [[Float]] = [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0]
        ]

        var insertVecStmt: OpaquePointer?
        let insertVecSQL = "INSERT INTO passage_vectors (chunk_id, vector) VALUES (?, ?);"
        XCTAssertEqual(sqlite3_prepare_v2(db, insertVecSQL, -1, &insertVecStmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(insertVecStmt) }

        for (idx, vec) in rawVecs.enumerated() {
            let chunkID = idx + 1
            sqlite3_reset(insertVecStmt)
            sqlite3_bind_int(insertVecStmt, 1, Int32(chunkID))

            let f16Data = vec.map { Float16($0) }
            f16Data.withUnsafeBytes { raw in
                sqlite3_bind_blob(insertVecStmt, 2, raw.baseAddress, Int32(raw.count), nil)
            }
            XCTAssertEqual(sqlite3_step(insertVecStmt), SQLITE_DONE)
        }
    }

    func testPassageDatabaseMetadataAndStatus() async throws {
        try createTestDatabase(dimension: 4)

        guard let passageDB = PassageDatabase(databaseURL: tempDBURL) else {
            XCTFail("Failed to open PassageDatabase")
            return
        }

        let metadata = await passageDB.metadata
        XCTAssertEqual(metadata.dimension, 4)
        XCTAssertEqual(metadata.modelID, "Qwen/Qwen3-Embedding-0.6B")
        XCTAssertEqual(metadata.chunkCount, 3)

        let status = await passageDB.status()
        XCTAssertTrue(status.isLoaded)
        XCTAssertEqual(status.bookCount, 2)
        XCTAssertEqual(status.chunkCount, 3)
        XCTAssertGreaterThan(status.storageBytes, 0)
    }

    func testPassageDatabaseVectorSearchRanking() async throws {
        try createTestDatabase(dimension: 4)

        guard let passageDB = PassageDatabase(databaseURL: tempDBURL) else {
            XCTFail("Failed to open PassageDatabase")
            return
        }

        // Query Vector exactly aligned with Chunk 2: [0, 1, 0, 0]
        let queryVector: [Float] = [0.0, 1.0, 0.0, 0.0]
        let results = try await passageDB.search(queryVector: queryVector, topK: 10, minSimilarity: 0.1)

        XCTAssertEqual(results.count, 1)
        guard let top = results.first else {
            XCTFail("Missing top result")
            return
        }

        XCTAssertEqual(top.id, 2)
        XCTAssertEqual(top.calibreID, 101)
        XCTAssertEqual(top.spineIndex, 1)
        XCTAssertEqual(top.anchorPhrase, "Swords clashed in the courtyard as thunder rolled")
        XCTAssertEqual(top.similarity, 1.0, accuracy: 0.001)
    }

    func testPassageDatabaseScopedSearch() async throws {
        try createTestDatabase(dimension: 4)

        guard let passageDB = PassageDatabase(databaseURL: tempDBURL) else {
            XCTFail("Failed to open PassageDatabase")
            return
        }

        // Query Vector with components in dim 0 and dim 2: [0.7071, 0, 0.7071, 0]
        let queryVector: [Float] = [0.7071, 0.0, 0.7071, 0.0]

        // Unscoped search returns both Chunk 1 (calibreID 101) and Chunk 3 (calibreID 102)
        let unscoped = try await passageDB.search(queryVector: queryVector, topK: 10, minSimilarity: 0.1)
        XCTAssertEqual(unscoped.count, 2)

        // Scoped to book 102 only: should return only Chunk 3
        let scopedTo102 = try await passageDB.search(
            queryVector: queryVector,
            topK: 10,
            minSimilarity: 0.1,
            restrictBookIDs: [102]
        )
        XCTAssertEqual(scopedTo102.count, 1)
        XCTAssertEqual(scopedTo102.first?.id, 3)
        XCTAssertEqual(scopedTo102.first?.calibreID, 102)
        XCTAssertEqual(scopedTo102.first?.anchorPhrase, "She brewed the tea in silence by the hearth")

        // Scoped to empty set or non-existent book returns 0
        let scopedEmpty = try await passageDB.search(
            queryVector: queryVector,
            topK: 10,
            minSimilarity: 0.1,
            restrictBookIDs: [999]
        )
        XCTAssertEqual(scopedEmpty.count, 0)
    }

    func testPassageQueryEmbedderNormalization() {
        let rawVec: [Float] = [3.0, 4.0]
        let normalized = PassageQueryEmbedder.normalize(rawVec)
        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(normalized[1], 0.8, accuracy: 0.0001)

        // Empty vector
        XCTAssertEqual(PassageQueryEmbedder.normalize([]), [])

        // Zero vector
        XCTAssertEqual(PassageQueryEmbedder.normalize([0.0, 0.0]), [0.0, 0.0])
    }

    func testPassageSnippetExtractorMissingFileReturnsNil() {
        let fakeURL = URL(fileURLWithPath: "/tmp/non_existent_\(UUID().uuidString).epub")
        let result = PassageSnippetExtractor.extractPassage(
            epubURL: fakeURL,
            spineIndex: 0,
            startOffset: 0,
            endOffset: 100
        )
        XCTAssertNil(result)
    }

    func testPassageQueryEmbedderModelAvailability() async {
        let isAvailable = await PassageQueryEmbedder.shared.isModelAvailable
        XCTAssertTrue(isAvailable)
    }

    func testPassageDatabaseCompactAndVacuum() throws {
        try createTestDatabase(dimension: 4)
        let libraryDir = tempDBURL.deletingLastPathComponent()

        let result = try PassageDatabase.compactAndVacuum(libraryURL: libraryDir)
        XCTAssertGreaterThan(result.passagesAfter, 0)
        XCTAssertGreaterThanOrEqual(result.bytesReclaimed, 0)
    }

    func testPassageDatabaseCompactAndVacuumMissingFile() throws {
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmptyDir_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let result = try PassageDatabase.compactAndVacuum(libraryURL: emptyDir)
        XCTAssertEqual(result.bytesReclaimed, 0)
        XCTAssertEqual(result.passagesAfter, 0)
    }
}
