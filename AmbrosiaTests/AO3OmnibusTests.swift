import XCTest
import ZIPFoundation
@testable import Ambrosia

final class AO3OmnibusTests: XCTestCase {

    func testOmnibusPoliciesOnIncompleteSeries() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let books = [
            CalibreBook(id: 1, title: "Part 1 Story", relativePath: "b1", authors: ["Author One"]),
            CalibreBook(id: 3, title: "Part 3 Story", relativePath: "b3", authors: ["Author One"])
        ]

        let series = SeriesGroup(
            id: "series:part_gap",
            seriesKey: "series:part_gap",
            seriesName: "Trilogy",
            works: books,
            allFandoms: ["Fandom A"],
            allRelationships: [],
            allCharacters: [],
            allCategories: [],
            allWarnings: [],
            allRatings: [],
            allAdditionalTags: [],
            allTags: [],
            allAuthors: ["Author One"],
            allDescriptions: [],
            totalWordCount: 30000,
            chapterCurrentTotal: 6,
            chapterTotalTotal: 6,
            hasUnknownChapterTotal: false,
            earliestPublished: nil,
            latestUpdated: nil,
            workIndices: [1, 3],
            missingIndices: [2],
            isComplete: false
        )

        let targetEPUB = tempDir.appendingPathComponent("omnibus.epub")

        // Policy: .skip -> throws seriesIncomplete
        XCTAssertThrowsError(
            try AO3OmnibusBuilder.buildOmnibus(
                series: series,
                libraryRoot: tempDir,
                metadataByID: [:],
                incompletePolicy: .skip,
                destinationEPUB: targetEPUB
            )
        ) { error in
            guard case AO3OmnibusBuilder.OmnibusError.seriesIncomplete(let indices) = error else {
                XCTFail("Expected seriesIncomplete, got \(error)")
                return
            }
            XCTAssertEqual(indices, [2])
        }

        // Policy: .warnWithManifest -> throws manifestRequired
        XCTAssertThrowsError(
            try AO3OmnibusBuilder.buildOmnibus(
                series: series,
                libraryRoot: tempDir,
                metadataByID: [:],
                incompletePolicy: .warnWithManifest,
                destinationEPUB: targetEPUB
            )
        ) { error in
            guard case AO3OmnibusBuilder.OmnibusError.manifestRequired(let manifest) = error else {
                XCTFail("Expected manifestRequired, got \(error)")
                return
            }
            XCTAssertTrue(manifest.contains("# Series: Trilogy"))
        }

        // Policy: .requireComplete on unfinished series -> throws seriesUnfinished
        XCTAssertThrowsError(
            try AO3OmnibusBuilder.buildOmnibus(
                series: series,
                libraryRoot: tempDir,
                metadataByID: [:],
                incompletePolicy: .includeWithPlaceholders,
                unfinishedPolicy: .requireComplete,
                destinationEPUB: targetEPUB
            )
        ) { error in
            guard case AO3OmnibusBuilder.OmnibusError.seriesUnfinished = error else {
                XCTFail("Expected seriesUnfinished, got \(error)")
                return
            }
        }
    }
}
