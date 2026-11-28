// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import ZIPFoundation
@testable import Ambrosia

final class DuplicateVerificationServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateVerificationTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeEPUB(named name: String, entries: [String: String]) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let archive = try Archive(url: url, accessMode: .create)
        for (path, content) in entries {
            let data = Data(content.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    let start = Int(position)
                    let end = min(start + size, data.count)
                    return data.subdata(in: start..<end)
                }
            )
        }
        return url
    }

    func test_verifyCluster_exactByteMatch_returnsExactFileMatch() throws {
        let epub1 = try makeEPUB(named: "a.epub", entries: ["chapter1.xhtml": "<p>Hello world</p>"])
        let epub2 = tempDir.appendingPathComponent("b.epub")
        try FileManager.default.copyItem(at: epub1, to: epub2)

        let result = DuplicateVerificationService.verifyCluster(
            winnerURL: epub1,
            loserURLs: [2: epub2]
        )
        XCTAssertEqual(result[2], .exactFileMatch)
    }

    func test_verifyCluster_contentIdenticalWithWrapperDiff_returnsContentMatch() throws {
        let epub1 = try makeEPUB(named: "a.epub", entries: [
            "mimetype": "application/epub+zip",
            "content.opf": "<package>v1</package>",
            "chapter1.xhtml": "<p>Same story text</p>"
        ])
        let epub2 = try makeEPUB(named: "b.epub", entries: [
            "mimetype": "application/epub+zip",
            "content.opf": "<package>v2-calibre-timestamp</package>",
            "META-INF/calibre_bookmarks.txt": "bookmark-data",
            "chapter1.xhtml": "<p>Same story text</p>"
        ])

        let result = DuplicateVerificationService.verifyCluster(
            winnerURL: epub1,
            loserURLs: [2: epub2]
        )
        XCTAssertEqual(result[2], .contentMatch)
    }

    func test_verifyCluster_differentChapterText_returnsDifferentEdition() throws {
        let epub1 = try makeEPUB(named: "a.epub", entries: ["chapter1.xhtml": "<p>Chapter 1</p>"])
        let epub2 = try makeEPUB(named: "b.epub", entries: ["chapter1.xhtml": "<p>Chapter 1 edited</p>"])

        let result = DuplicateVerificationService.verifyCluster(
            winnerURL: epub1,
            loserURLs: [2: epub2]
        )
        XCTAssertEqual(result[2], .differentEdition)
    }

    func test_verifyCluster_sameInodeHardlink_returnsSameInode() throws {
        let epub1 = try makeEPUB(named: "a.epub", entries: ["chapter1.xhtml": "<p>Shared</p>"])
        let epub2 = tempDir.appendingPathComponent("hardlink.epub")
        try FileManager.default.linkItem(at: epub1, to: epub2)

        let result = DuplicateVerificationService.verifyCluster(
            winnerURL: epub1,
            loserURLs: [2: epub2]
        )
        XCTAssertEqual(result[2], .sameInode)
    }

    func test_isAnthologyArchive_detectsMergedSeriesStructure() throws {
        let single = try makeEPUB(named: "single.epub", entries: ["Story_split_000.xhtml": "<p>One</p>"])
        let anthology = try makeEPUB(named: "omni.epub", entries: [
            "1/Part1_split_000.xhtml": "<p>One</p>",
            "2/Part2_split_000.xhtml": "<p>Two</p>"
        ])

        XCTAssertFalse(DuplicateVerificationService.isAnthologyArchive(at: single))
        XCTAssertTrue(DuplicateVerificationService.isAnthologyArchive(at: anthology))
    }

    func test_duplicateBookDetector_excludesAnthologiesAndPrefersHigherCountsAndNewerDateAdded() {
        let workIDs: [Int: String] = [1: "w1", 2: "w1", 3: "w1"]
        let dates: [Int: (published: String?, updated: String?)] = [
            1: (published: "2024-01-01", updated: "2024-06-01"),
            2: (published: "2024-01-01", updated: "2024-06-01"),
            3: (published: "2024-01-01", updated: "2024-06-01")
        ]

        // Book 3 is an anthology — excluded; between 1 and 2, 2 has more chapters & newer dateAdded
        let losers = DuplicateBookDetector.loserIDs(
            workIDs: workIDs,
            dates: dates,
            anthologyIDs: [3],
            wordCounts: [1: 1000, 2: 2000],
            chapterCurrents: [1: 2, 2: 3],
            datesAdded: [1: Date(timeIntervalSince1970: 100), 2: Date(timeIntervalSince1970: 200)]
        )
        XCTAssertEqual(losers, [1])
    }

    func test_maintenanceDismissals_roundTrip() async throws {
        let libDir = tempDir.appendingPathComponent("CalibreLib")
        try FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)
        let metaDB = try AmbrosiaMetaDB(libraryURL: libDir)

        try await metaDB.dismissMaintenanceItem(kind: "stale_wip", targetKey: "42")
        let dismissed = await metaDB.dismissedMaintenanceKeys(kind: "stale_wip")
        XCTAssertEqual(dismissed, ["42"])

        try await metaDB.undismissMaintenanceItem(kind: "stale_wip", targetKey: "42")
        let after = await metaDB.dismissedMaintenanceKeys(kind: "stale_wip")
        XCTAssertTrue(after.isEmpty)
    }
}
