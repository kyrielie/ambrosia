// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Accelerate
@testable import Ambrosia

final class SemanticVectorEngineTests: XCTestCase {

    func testWorkEmbeddingSynthesizer() {
        let book = CalibreBook(
            id: 1,
            title: "The Disappearances of Draco Malfoy",
            series: "Disappearances AU",
            seriesIndex: 1.0,
            wordCount: 296_000,
            kudos: 50_000,
            publishedDate: Date(timeIntervalSince1970: 1600000000),
            publisher: "Calibre",
            relativePath: "speechwriter/The Disappearances of Draco Malfoy",
            authors: ["speechwriter"],
            tags: ["Fanfiction"]
        )

        let ao3 = AO3MetadataRecord(
            storyURL: "https://archiveofourown.org/works/23296162",
            workID: "23296162",
            authors: [AO3AuthorEntry(username: "speechwriter", pseud: nil, profileURL: nil, source: .byline)],
            kudosCount: 50_000,
            wordCount: 296_000,
            chapterCurrent: 33,
            chapterTotal: 33,
            isComplete: true,
            language: "English",
            publishedDate: "2020-03-24",
            updatedDate: "2021-06-18",
            fandoms: ["Harry Potter - J. K. Rowling"],
            relationships: ["Hermione Granger/Draco Malfoy"],
            characters: ["Draco Malfoy", "Hermione Granger", "Harry Potter", "Ron Weasley"],
            additionalTags: ["Canon Divergence", "Horcrux Hunt", "Redemption", "Slow Burn"],
            categories: ["F/M"],
            ao3Collections: [],
            series: [],
            rating: "Mature",
            warnings: ["Major Character Death"],
            extractedAt: "2024-01-01T00:00:00Z"
        )

        let doc = WorkEmbeddingSynthesizer.synthesize(
            book: book,
            ao3: ao3,
            summary: "<p>The night on the Astronomy Tower goes differently... Draco takes the offer of protection.</p>"
        )

        XCTAssertTrue(doc.contains("Title: The Disappearances of Draco Malfoy"))
        XCTAssertTrue(doc.contains("Author: speechwriter"))
        XCTAssertTrue(doc.contains("Series: Disappearances AU"))
        XCTAssertTrue(doc.contains("Fandom: Harry Potter - J. K. Rowling"))
        XCTAssertTrue(doc.contains("Relationships: Hermione Granger/Draco Malfoy"))
        XCTAssertTrue(doc.contains("Characters: Draco Malfoy, Hermione Granger, Harry Potter, Ron Weasley"))
        XCTAssertTrue(doc.contains("Tags: Canon Divergence, Horcrux Hunt, Redemption, Slow Burn"))
        XCTAssertTrue(doc.contains("Rating: Mature"))
        XCTAssertTrue(doc.contains("Status: Complete"))
        XCTAssertTrue(doc.contains("Summary: The night on the Astronomy Tower goes differently... Draco takes the offer of protection."))
        XCTAssertFalse(doc.contains("<p>"))
    }

    func testVectorStoreBinaryReadWrite() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("test_vectors.bin")

        let values: [Float] = [
            1.0, 0.0, 0.0,
            0.0, 1.0, 0.0,
            0.0, 0.0, 1.0,
            0.577, 0.577, 0.577
        ]
        let matrix = EmbeddingMatrix(rows: 4, dimension: 3, values: values)

        try VectorStore.write(matrix, to: fileURL)

        guard let loaded = VectorStore.read(from: fileURL) else {
            XCTFail("Failed to read matrix from binary file")
            return
        }

        XCTAssertEqual(loaded.rows, 4)
        XCTAssertEqual(loaded.dimension, 3)
        XCTAssertEqual(loaded.values.count, 12)
        XCTAssertEqual(loaded.values[0], 1.0, accuracy: 0.0001)
        XCTAssertEqual(loaded.values[4], 1.0, accuracy: 0.0001)
        XCTAssertEqual(loaded.values[8], 1.0, accuracy: 0.0001)
        XCTAssertEqual(loaded.values[9], 0.577, accuracy: 0.0001)
    }

    func testVectorStoreCosineSimilarities() {
        let values: [Float] = [
            1.0, 0.0, 0.0,   // Identical to query -> sim 1.0
            0.0, 1.0, 0.0,   // Orthogonal -> sim 0.0
            -1.0, 0.0, 0.0,  // Opposite -> sim -1.0
            0.7071, 0.7071, 0.0 // 45 deg -> sim ~0.7071
        ]
        let matrix = EmbeddingMatrix(rows: 4, dimension: 3, values: values)
        let query: [Float] = [1.0, 0.0, 0.0]

        let scores = VectorStore.cosineSimilarities(matrix: matrix, query: query)

        XCTAssertEqual(scores.count, 4)
        XCTAssertEqual(scores[0], 1.0, accuracy: 0.0001)
        XCTAssertEqual(scores[1], 0.0, accuracy: 0.0001)
        XCTAssertEqual(scores[2], -1.0, accuracy: 0.0001)
        XCTAssertEqual(scores[3], 0.7071, accuracy: 0.001)
    }

    func testHybridSearchReciprocalRankFusion() {
        // Book 1: Rank 1 in lexical, Rank 2 in semantic
        // Book 2: Rank 2 in lexical, not in top semantic
        // Book 3: Not in lexical, Rank 1 in semantic
        // Book 4: Rank 3 in lexical, Rank 3 in semantic

        let lexicalIDs = [1, 2, 4]
        let semanticHits = [(id: 3, score: 0.95), (id: 1, score: 0.90), (id: 4, score: 0.80)]

        let results = HybridSearchCoordinator.fuse(lexicalIDs: lexicalIDs, semanticHits: semanticHits, kConstant: 60.0)

        XCTAssertFalse(results.isEmpty)
        // Book 1 appears near top of both -> highest score
        XCTAssertEqual(results[0].bookID, 1)

        let book1Score = (1.0 / 61.0) + (1.0 / 62.0)
        XCTAssertEqual(results[0].rrfScore, book1Score, accuracy: 0.0001)
        XCTAssertEqual(results[0].lexicalRank, 1)
        XCTAssertEqual(results[0].semanticRank, 2)
    }

    func testSemanticSearchEngineIncrementalIndexingAndProgress() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = SemanticSearchEngine(storageURL: tempDir)

        var reportedProgress: [(completed: Int, total: Int)] = []
        let initialDocs = [
            (id: 101, text: "Title: Space Adventures. Fandom: Sci-Fi. Tags: Spaceship, Exploration."),
            (id: 102, text: "Title: Medieval Quest. Fandom: Fantasy. Tags: Magic, Dragons.")
        ]

        await engine.index(documents: initialDocs, incremental: false) { completed, total in
            reportedProgress.append((completed, total))
        }

        let initialCount = await engine.count
        XCTAssertEqual(initialCount, 2)
        let initialIDs = await engine.indexedIDSet()
        XCTAssertTrue(initialIDs.contains(101))
        XCTAssertTrue(initialIDs.contains(102))

        let status1 = await engine.status(in: tempDir)
        XCTAssertEqual(status1.indexedCount, 2)
        XCTAssertTrue(status1.storageBytes > 0)
        XCTAssertTrue(status1.isLoaded)

        // Incremental pass with 1 existing and 1 new document
        let nextDocs = [
            (id: 101, text: "Title: Space Adventures. Fandom: Sci-Fi. Tags: Spaceship, Exploration."),
            (id: 103, text: "Title: Cyberpunk City. Fandom: Noir. Tags: Androids, Neon.")
        ]

        await engine.index(documents: nextDocs, incremental: true)

        let updatedCount = await engine.count
        XCTAssertEqual(updatedCount, 3)
        let updatedIDs = await engine.indexedIDSet()
        XCTAssertTrue(updatedIDs.contains(101))
        XCTAssertTrue(updatedIDs.contains(102))
        XCTAssertTrue(updatedIDs.contains(103))

        let status2 = await engine.status(in: tempDir)
        XCTAssertEqual(status2.indexedCount, 3)
        XCTAssertTrue(status2.storageBytes >= status1.storageBytes)
    }

    func testSearchMatchBadgeProperties() {
        let tagBadge = SearchMatchBadge.exactTag("Slow Burn")
        XCTAssertEqual(tagBadge.label, "Exact Tag: Slow Burn")
        XCTAssertEqual(tagBadge.systemImage, "tag.fill")
        XCTAssertEqual(tagBadge.nsColor, .systemTeal)

        let titleBadge = SearchMatchBadge.exactTitle
        XCTAssertEqual(titleBadge.label, "Exact Title")
        XCTAssertEqual(titleBadge.systemImage, "text.quote")
        XCTAssertEqual(titleBadge.nsColor, .systemBlue)

        let authorBadge = SearchMatchBadge.exactAuthor
        XCTAssertEqual(authorBadge.label, "Exact Author")
        XCTAssertEqual(authorBadge.systemImage, "person.fill")

        let seriesBadge = SearchMatchBadge.exactSeries
        XCTAssertEqual(seriesBadge.label, "Exact Series")
        XCTAssertEqual(seriesBadge.systemImage, "books.vertical.fill")

        let semBadge = SearchMatchBadge.semantic(percent: 94)
        XCTAssertEqual(semBadge.label, "94% Semantic")
        XCTAssertEqual(semBadge.systemImage, "sparkles")
        XCTAssertEqual(semBadge.nsColor, .systemIndigo)

        let hybridBadge = SearchMatchBadge.hybrid(semanticPercent: 88)
        XCTAssertEqual(hybridBadge.label, "Top Match (88% Semantic)")
        XCTAssertEqual(hybridBadge.systemImage, "sparkle.magnifyingglass")
        XCTAssertEqual(hybridBadge.nsColor, .systemPurple)

        let bodyBadge = SearchMatchBadge.bodyText(count: 5)
        XCTAssertEqual(bodyBadge.label, "5 Body Text Matches")
        XCTAssertEqual(bodyBadge.systemImage, "doc.text.magnifyingglass")
        XCTAssertEqual(bodyBadge.nsColor, .systemOrange)

        let singleBodyBadge = SearchMatchBadge.bodyText(count: 1)
        XCTAssertEqual(singleBodyBadge.label, "Body Text Match")
    }

    func testLibraryStorageBreakdownWithSemanticVectors() {
        let breakdown = LibraryStorageBreakdown(
            epubsSizeBytes: 1000,
            calibreDBSizeBytes: 200,
            ftsDBSizeBytes: 300,
            ambrosiaMetaDBSizeBytes: 100,
            semanticVectorsSizeBytes: 50
        )

        XCTAssertEqual(breakdown.totalSizeBytes, 1650)
        XCTAssertEqual(breakdown.semanticVectorsSizeBytes, 50)
        XCTAssertFalse(breakdown.formattedSemanticVectorsSize.isEmpty)

        let b2 = LibraryStorageBreakdown(
            epubsSizeBytes: 500,
            calibreDBSizeBytes: 100,
            ftsDBSizeBytes: 100,
            ambrosiaMetaDBSizeBytes: 50,
            semanticVectorsSizeBytes: 25
        )

        let combined = LibraryStorageBreakdown.combining([breakdown, b2])
        XCTAssertEqual(combined.semanticVectorsSizeBytes, 75)
        XCTAssertEqual(combined.totalSizeBytes, 2425)
    }
}
