import XCTest
@testable import Ambrosia

final class DuplicateManagerTests: XCTestCase {

    func testDuplicateClusteringAndWinnerSelection() {
        let workIDs: [Int: String] = [
            101: "12345",
            102: "12345",
            201: "67890" // singleton, should not be clustered
        ]
        let dates: [Int: (published: String?, updated: String?)] = [
            101: (published: "2023-01-01", updated: "2023-05-01"),
            102: (published: "2023-01-01", updated: "2023-06-01") // newer updated date -> winner
        ]
        let booksByID: [Int: CalibreBook] = [
            101: CalibreBook(id: 101, title: "Test Fic (Old)", relativePath: "a/old", authors: ["Author A"]),
            102: CalibreBook(id: 102, title: "Test Fic (New)", relativePath: "a/new", authors: ["Author A"])
        ]

        let clusters = CalibreDuplicateManager.buildClusters(
            workIDs: workIDs,
            dates: dates,
            booksByID: booksByID
        )

        XCTAssertEqual(clusters.count, 1)
        guard let cluster = clusters.first else { return }
        XCTAssertEqual(cluster.workID, "12345")
        XCTAssertEqual(cluster.winnerID, 102)
        XCTAssertEqual(cluster.loserIDs, [101])
        XCTAssertEqual(cluster.entries.count, 2)
        XCTAssertEqual(cluster.winnerEntry?.calibreID, 102)
        XCTAssertEqual(cluster.winnerEntry?.isWinner, true)
        XCTAssertEqual(cluster.loserEntries.first?.calibreID, 101)
        XCTAssertEqual(cluster.loserEntries.first?.isWinner, false)
    }

    func testCalibrePruneCLICommandFormatting() {
        let command = CalibreDuplicateManager.calibrePruneCLICommand(
            loserIDs: [1042, 1089, 1015],
            libraryPath: "/Users/test/Calibre Library"
        )

        XCTAssertTrue(command.contains("calibredb"))
        XCTAssertTrue(command.contains("--with-library \"/Users/test/Calibre Library\""))
        XCTAssertTrue(command.contains("remove 1015 1042 1089"))
    }

    func testCalibreSearchQueryFormatting() {
        let query = CalibreDuplicateManager.calibreSearchQuery(calibreIDs: [1042, 1089])
        XCTAssertEqual(query, "id:1042 or id:1089")

        let empty = CalibreDuplicateManager.calibreSearchQuery(calibreIDs: [])
        XCTAssertEqual(empty, "")
    }

    func testTransferBookStateInMetaDB() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let metaDB = try AmbrosiaMetaDB(libraryURL: tempDir)

        let loserID = 1001
        let winnerID = 1002

        // Set up loser state: 85% read, 1200 seconds, position spine 4, char 120
        try await metaDB.updateReadingPosition(
            calibreID: loserID,
            spineIndex: 4,
            characterOffset: 120,
            scrollOffset: 0.5,
            readPercent: 0.85
        )
        try await metaDB.addReadingTime(calibreID: loserID, seconds: 1200)

        // Set up winner state: 10% read, 300 seconds
        try await metaDB.updateReadingPosition(
            calibreID: winnerID,
            spineIndex: 1,
            characterOffset: 0,
            scrollOffset: 0.0,
            readPercent: 0.10
        )
        try await metaDB.addReadingTime(calibreID: winnerID, seconds: 300)

        // Add annotation to loser
        let annotation = Annotation(
            id: UUID(),
            spineIndex: 4,
            startChar: 10,
            endChar: 50,
            selectedText: "Important quote",
            note: "A great line",
            colorHex: "#FFCC00",
            createdDate: Date()
        )
        try await metaDB.insertAnnotation(annotation, calibreID: loserID)

        // Verify pre-conditions
        let loserAnnsPre = try await metaDB.annotations(for: loserID)
        XCTAssertEqual(loserAnnsPre.count, 1)
        let winnerAnnsPre = try await metaDB.annotations(for: winnerID)
        XCTAssertEqual(winnerAnnsPre.count, 0)

        // Execute transfer
        try await metaDB.transferBookState(fromLoserID: loserID, toWinnerID: winnerID)

        // Verify post-conditions
        let winnerState = await metaDB.bookState(for: winnerID)
        XCTAssertEqual(winnerState.totalReadPercent, 0.85, accuracy: 0.001)
        XCTAssertEqual(winnerState.lastSpineIndex, 4)
        XCTAssertEqual(winnerState.lastCharacterOffset, 120)
        XCTAssertEqual(winnerState.totalReadingTimeSeconds, 1500, accuracy: 1.0)

        // Loser annotations migrated to winner
        let loserAnnsPost = try await metaDB.annotations(for: loserID)
        XCTAssertEqual(loserAnnsPost.count, 0)
        let winnerAnnsPost = try await metaDB.annotations(for: winnerID)
        XCTAssertEqual(winnerAnnsPost.count, 1)
        XCTAssertEqual(winnerAnnsPost.first?.selectedText, "Important quote")
    }

    func testWithWinnerDesignation() {
        let workIDs: [Int: String] = [101: "12345", 102: "12345", 103: "12345"]
        let dates: [Int: (published: String?, updated: String?)] = [
            101: (published: "2023-01-01", updated: "2023-05-01"),
            102: (published: "2023-01-01", updated: "2023-06-01"),
            103: (published: "2023-01-01", updated: "2023-04-01")
        ]
        let booksByID: [Int: CalibreBook] = [
            101: CalibreBook(id: 101, title: "Test Fic A", relativePath: "a", authors: ["Author"]),
            102: CalibreBook(id: 102, title: "Test Fic B", relativePath: "b", authors: ["Author"]),
            103: CalibreBook(id: 103, title: "Test Fic C", relativePath: "c", authors: ["Author"])
        ]

        let clusters = CalibreDuplicateManager.buildClusters(
            workIDs: workIDs,
            dates: dates,
            booksByID: booksByID
        )

        XCTAssertEqual(clusters.count, 1)
        let initial = clusters[0]
        XCTAssertEqual(initial.winnerID, 102)
        XCTAssertEqual(initial.loserIDs, [101, 103])

        // User overrides winner to 101
        let updated = initial.withWinner(101)
        XCTAssertEqual(updated.winnerID, 101)
        XCTAssertEqual(updated.loserIDs, [102, 103])
        XCTAssertEqual(updated.entries.count, 3)
        XCTAssertEqual(updated.entries[0].calibreID, 101)
        XCTAssertTrue(updated.entries[0].isWinner)
        XCTAssertEqual(updated.entries[1].calibreID, 102)
        XCTAssertFalse(updated.entries[1].isWinner)
        XCTAssertEqual(updated.entries[2].calibreID, 103)
        XCTAssertFalse(updated.entries[2].isWinner)
    }
}
