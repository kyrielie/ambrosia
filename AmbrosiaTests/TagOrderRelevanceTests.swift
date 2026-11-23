import XCTest
@testable import Ambrosia

final class TagOrderRelevanceTests: XCTestCase {

    private var metaDB: AmbrosiaMetaDB?
    private var tempDir: URL?

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagOrderRelevanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        metaDB = try AmbrosiaMetaDB(libraryURL: dir)
    }

    override func tearDownWithError() throws {
        metaDB = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testFirstListedPositionsRelationshipIndex() async throws {
        guard let db = metaDB else {
            XCTFail("metaDB was not initialized")
            return
        }

        let rec1 = AO3MetadataRecord(
            storyURL: nil,
            workID: nil,
            authors: [],
            kudosCount: nil,
            wordCount: nil,
            chapterCurrent: 1,
            chapterTotal: 1,
            isComplete: true,
            language: "English",
            publishedDate: nil,
            updatedDate: nil,
            fandoms: ["Marvel"],
            relationships: ["Thor/Loki", "Tony Stark/Steve Rogers"],
            characters: ["Thor", "Loki", "Tony Stark", "Steve Rogers"],
            additionalTags: ["Fluff"],
            categories: ["M/M"],
            ao3Collections: [],
            series: [],
            rating: "Mature",
            warnings: [],
            extractedAt: "2024-01-01T00:00:00Z"
        )

        let rec2 = AO3MetadataRecord(
            storyURL: nil,
            workID: nil,
            authors: [],
            kudosCount: nil,
            wordCount: nil,
            chapterCurrent: 1,
            chapterTotal: 1,
            isComplete: true,
            language: "English",
            publishedDate: nil,
            updatedDate: nil,
            fandoms: ["Marvel"],
            relationships: ["Tony Stark/Steve Rogers"],
            characters: ["Tony Stark", "Steve Rogers"],
            additionalTags: ["Angst"],
            categories: ["M/M"],
            ao3Collections: [],
            series: [],
            rating: "Explicit",
            warnings: [],
            extractedAt: "2024-01-01T00:00:00Z"
        )

        try await db.insertBatch([(rec1, 101), (rec2, 102)], diagnostics: [])

        let posMap = await db.firstListedPositions(
            targets: ["Tony Stark/Steve Rogers"],
            bookIDs: [101, 102]
        )

        XCTAssertEqual(posMap[101]?.roleRank, 0)
        XCTAssertEqual(posMap[101]?.index, 1)

        XCTAssertEqual(posMap[102]?.roleRank, 0)
        XCTAssertEqual(posMap[102]?.index, 0)

        // When sorted without candidateRanked, Book 102 (index 0) must precede Book 101 (index 1)
        let sorted = [101, 102].sorted { idA, idB in
            RelevanceOrdering.areInIncreasingOrder(
                idA: idA,
                idB: idB,
                rankMap: nil,
                posMap: posMap,
                ascending: false
            )
        }
        XCTAssertEqual(sorted, [102, 101])
    }

    func testFirstListedPositionsRoleRankBeatsIndex() async throws {
        guard let db = metaDB else {
            XCTFail("metaDB was not initialized")
            return
        }

        // Book 201 has relationship at index 3
        let rec1 = AO3MetadataRecord(
            storyURL: nil,
            workID: nil,
            authors: [],
            kudosCount: nil,
            wordCount: nil,
            chapterCurrent: 1,
            chapterTotal: 1,
            isComplete: true,
            language: "English",
            publishedDate: nil,
            updatedDate: nil,
            fandoms: ["MCU"],
            relationships: ["Ship A", "Ship B", "Ship C", "Target Ship"],
            characters: ["Target Char"],
            additionalTags: [],
            categories: [],
            ao3Collections: [],
            series: [],
            rating: "General",
            warnings: [],
            extractedAt: "2024-01-01T00:00:00Z"
        )

        // Book 202 has character at index 0 (no relationship match)
        let rec2 = AO3MetadataRecord(
            storyURL: nil,
            workID: nil,
            authors: [],
            kudosCount: nil,
            wordCount: nil,
            chapterCurrent: 1,
            chapterTotal: 1,
            isComplete: true,
            language: "English",
            publishedDate: nil,
            updatedDate: nil,
            fandoms: ["MCU"],
            relationships: ["Other Ship"],
            characters: ["Target Char"],
            additionalTags: [],
            categories: [],
            ao3Collections: [],
            series: [],
            rating: "General",
            warnings: [],
            extractedAt: "2024-01-01T00:00:00Z"
        )

        try await db.insertBatch([(rec1, 201), (rec2, 202)], diagnostics: [])

        let posMap = await db.firstListedPositions(
            targets: ["Target Ship", "Target Char"],
            bookIDs: [201, 202]
        )

        XCTAssertEqual(posMap[201]?.roleRank, 0)
        XCTAssertEqual(posMap[201]?.index, 3)

        XCTAssertEqual(posMap[202]?.roleRank, 1)
        XCTAssertEqual(posMap[202]?.index, 0)

        // Relationship (roleRank 0) beats character (roleRank 1) despite index 3 vs 0
        let sorted = [202, 201].sorted { idA, idB in
            RelevanceOrdering.areInIncreasingOrder(
                idA: idA,
                idB: idB,
                rankMap: nil,
                posMap: posMap,
                ascending: false
            )
        }
        XCTAssertEqual(sorted, [201, 202])
    }

    func testContainsTargetMatching() async throws {
        guard let db = metaDB else {
            XCTFail("metaDB was not initialized")
            return
        }

        let rec = AO3MetadataRecord(
            storyURL: nil,
            workID: nil,
            authors: [],
            kudosCount: nil,
            wordCount: nil,
            chapterCurrent: 1,
            chapterTotal: 1,
            isComplete: true,
            language: "English",
            publishedDate: nil,
            updatedDate: nil,
            fandoms: ["MCU"],
            relationships: [],
            characters: [],
            additionalTags: ["Eventual Slow Burn AU"],
            categories: [],
            ao3Collections: [],
            series: [],
            rating: "General",
            warnings: [],
            extractedAt: "2024-01-01T00:00:00Z"
        )

        try await db.insertBatch([(rec, 301)], diagnostics: [])

        let posMap = await db.firstListedPositions(
            exactTargets: [],
            containsTargets: ["Slow Burn"],
            bookIDs: [301]
        )

        XCTAssertEqual(posMap[301]?.roleRank, 3)
        XCTAssertEqual(posMap[301]?.index, 0)
    }

    func testMalformedAndEmptyJSONRowsDoNotAbortPositions() async throws {
        guard let db = metaDB else { return }

        // Insert malformed/empty rows directly
        try await db.run("""
            INSERT INTO ao3_metadata (calibre_id, relationships_json, characters_json, fandoms_json, additional_tags_json, extracted_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """, [401, "", "not json", nil, "[]", "2024-01-01T00:00:00Z"])

        let validRec = AO3MetadataRecord(
            storyURL: nil, workID: nil, authors: [], kudosCount: nil, wordCount: nil,
            chapterCurrent: 1, chapterTotal: 1, isComplete: true, language: "English",
            publishedDate: nil, updatedDate: nil, fandoms: [],
            relationships: ["Target Ship"], characters: [], additionalTags: [],
            categories: [], ao3Collections: [], series: [], rating: "General", warnings: [],
            extractedAt: "2024-01-01T00:00:00Z"
        )
        try await db.insertBatch([(validRec, 402)], diagnostics: [])

        let posMap = await db.firstListedPositions(
            exactTargets: ["Target Ship"],
            bookIDs: [401, 402]
        )

        XCTAssertNil(posMap[401])
        XCTAssertEqual(posMap[402]?.roleRank, 0)
        XCTAssertEqual(posMap[402]?.index, 0)
    }

    func testSQLErrorIsLoggedToErrorLog() async throws {
        guard let db = metaDB else { return }

        // Drop ao3_metadata to trigger a SQL error in firstListedPositions
        try await db.run("DROP TABLE ao3_metadata")

        let posMap = await db.firstListedPositions(
            exactTargets: ["Target Ship"],
            bookIDs: [501]
        )
        XCTAssertTrue(posMap.isEmpty)

        let errors = try await db.recentErrors()
        XCTAssertTrue(errors.contains { $0.subsystem == "relevance" && $0.operation == "firstListedPositions" })
    }

    func testBookWithDuplicateTargetTagsUsesMinimumIndex() async throws {
        guard let db = metaDB else { return }

        let rec = AO3MetadataRecord(
            storyURL: nil, workID: nil, authors: [], kudosCount: nil, wordCount: nil,
            chapterCurrent: 1, chapterTotal: 1, isComplete: true, language: "English",
            publishedDate: nil, updatedDate: nil, fandoms: [],
            relationships: ["Other Ship", "Target Ship", "Target Ship"],
            characters: [], additionalTags: [], categories: [], ao3Collections: [],
            series: [], rating: "General", warnings: [], extractedAt: "2024-01-01T00:00:00Z"
        )
        try await db.insertBatch([(rec, 601)], diagnostics: [])

        let posMap = await db.firstListedPositions(
            exactTargets: ["Target Ship"],
            bookIDs: [601]
        )

        XCTAssertEqual(posMap[601]?.roleRank, 0)
        XCTAssertEqual(posMap[601]?.index, 1)
    }

    func testNonASCIICaseVariantsDocumentedBehavior() async throws {
        guard let db = metaDB else { return }

        let rec = AO3MetadataRecord(
            storyURL: nil, workID: nil, authors: [], kudosCount: nil, wordCount: nil,
            chapterCurrent: 1, chapterTotal: 1, isComplete: true, language: "English",
            publishedDate: nil, updatedDate: nil, fandoms: [],
            relationships: [], characters: [], additionalTags: ["Mädchen"],
            categories: [], ao3Collections: [], series: [], rating: "General", warnings: [],
            extractedAt: "2024-01-01T00:00:00Z"
        )
        try await db.insertBatch([(rec, 701)], diagnostics: [])

        let posMapExact = await db.firstListedPositions(
            exactTargets: ["Mädchen"],
            bookIDs: [701]
        )
        XCTAssertEqual(posMapExact[701]?.roleRank, 3)

        let posMapUpper = await db.firstListedPositions(
            exactTargets: ["MÄDCHEN"],
            bookIDs: [701]
        )
        XCTAssertNil(posMapUpper[701], "Documents SQLite's ASCII-only lower() limitation without ICU")
    }

    func testBenchmark20kMatchedBooksPositions() async throws {
        guard let db = metaDB else { return }

        let count = 20_000
        let bookIDs = Array(1...count)

        let chunkSize = 500
        for chunk in stride(from: 1, through: count, by: chunkSize) {
            let end = min(chunk + chunkSize - 1, count)
            let ids = Array(chunk...end)
            let placeholders = ids.map {
                "(\($0), '[\"Target Ship\", \"Other Ship\"]', '[\"Hero\"]', '[\"Fandom\"]', '[\"Tag\"]', '2024-01-01T00:00:00Z')"
            }.joined(separator: ", ")
            try await db.run("""
                INSERT INTO ao3_metadata (calibre_id, relationships_json, characters_json, fandoms_json, additional_tags_json, extracted_at)
                VALUES \(placeholders)
            """)
        }

        _ = await db.firstListedPositions(exactTargets: ["Target Ship"], bookIDs: bookIDs)

        var timings: [Double] = []
        for _ in 1...5 {
            let start = DispatchTime.now()
            let positions = await db.firstListedPositions(exactTargets: ["Target Ship"], bookIDs: bookIDs)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
            timings.append(elapsedMs)
            XCTAssertEqual(positions.count, count)
        }

        timings.sort()
        let p95 = timings[Int(Double(timings.count) * 0.95)]
        print("==> Benchmark 20k books firstListedPositions p95: \(String(format: "%.2f", p95)) ms (timings: \(timings.map { String(format: "%.2f", $0) }))")
        XCTAssertLessThanOrEqual(p95, 100.0, "p95 <= 100ms in Debug Swift (measured ~71-76ms; raw SQLite ~49ms)")
    }

    // MARK: - Pass 1 Tests: Wildcard Escaping & Folding Characterization

    func testTagContainsEscapesUnderscore() async throws {
        guard let db = metaDB else {
            XCTFail("metaDB was not initialized")
            return
        }

        try await db.run("INSERT INTO book_tags (calibre_id, tag_name, tag_type) VALUES (?, ?, ?)", [201, "foo_bar", "relationship"])
        try await db.run("INSERT INTO book_tags (calibre_id, tag_name, tag_type) VALUES (?, ?, ?)", [202, "fooxbar", "relationship"])

        let matches = try await db.bookTagMatchIDs(op: .contains, terms: ["foo_bar"], tagType: nil)
        XCTAssertTrue(matches.contains(201), "Should match literal foo_bar")
        XCTAssertFalse(matches.contains(202), "Should NOT match fooxbar (underscore must be escaped)")
    }

    func testTagStartsWithEscapesPercent() async throws {
        guard let db = metaDB else {
            XCTFail("metaDB was not initialized")
            return
        }

        try await db.run("INSERT INTO book_tags (calibre_id, tag_name, tag_type) VALUES (?, ?, ?)", [301, "%percent", "freeform"])
        try await db.run("INSERT INTO book_tags (calibre_id, tag_name, tag_type) VALUES (?, ?, ?)", [302, "other_percent", "freeform"])

        let matches = try await db.bookTagMatchIDs(op: .startsWith, terms: ["%per"], tagType: nil)
        XCTAssertTrue(matches.contains(301), "Should match literal %percent")
        XCTAssertFalse(matches.contains(302), "Should NOT match other_percent (percent must be escaped)")
    }

    func testFirstListedPositionsNonASCIICaseCharacterization() async throws {
        guard let db = metaDB else {
            XCTFail("metaDB was not initialized")
            return
        }

        try await db.run("""
            INSERT INTO ao3_metadata (calibre_id, relationships_json, characters_json, fandoms_json, additional_tags_json, extracted_at)
            VALUES (401, '["Éowyn/Faramir"]', '[]', '[]', '[]', '2024-01-01T00:00:00Z')
        """)

        let positionsLowerTarget = await db.firstListedPositions(exactTargets: ["éowyn/faramir"], bookIDs: [401])
        let positionsUpperTarget = await db.firstListedPositions(exactTargets: ["ÉOWYN/FARAMIR"], bookIDs: [401])
        let positionsExactTarget = await db.firstListedPositions(exactTargets: ["Éowyn/Faramir"], bookIDs: [401])

        let upperCount = positionsUpperTarget.count
        let exactCount = positionsExactTarget.count
        print("==> Characterization: lower count: \(positionsLowerTarget.count), upper: \(upperCount), exact: \(exactCount)")
        XCTAssertEqual(positionsExactTarget.count, 1, "Exact case always matches")
    }
}
