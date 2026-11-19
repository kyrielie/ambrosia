import XCTest
@testable import Ambrosia

final class SeriesIdentityTests: XCTestCase {
    func testStoredKeysSurviveNameUpdatesAndSameNameAO3RowsRemainDistinct() async throws {
        let libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeriesIdentityTests-\(UUID().uuidString)")
        let db = try AmbrosiaMetaDB(libraryURL: libraryURL)

        try await db.insert(metadata(series: [
            .init(name: "Shared Series", index: 1, ao3ID: "101"),
            .init(name: "Shared Series", index: 2, ao3ID: "202")
        ]), calibreID: 1)
        let distinct = try await db.seriesEntries(for: [1])
        XCTAssertEqual(Set(distinct.map(\.seriesKey)), ["ao3:101", "ao3:202"])
        XCTAssertEqual(distinct.compactMap(\.seriesID).count, 2)

        try await db.insert(metadata(series: [.init(name: "  Name   Only ", index: 1, ao3ID: "")]), calibreID: 2)
        let firstNameOnlyKey = try await db.seriesEntries(for: [2]).first?.seriesKey
        try await db.insert(metadata(series: [.init(name: "name only", index: 1, ao3ID: nil)]), calibreID: 2)
        let updated = try await db.seriesEntries(for: [2]).first
        XCTAssertEqual(updated?.seriesKey, firstNameOnlyKey)
        XCTAssertEqual(updated?.seriesKey, "calibre-name:Name   Only")
        XCTAssertEqual(updated?.seriesName, "name only")
        try? FileManager.default.removeItem(at: libraryURL)
    }

    func testGarbageCollectionKeepsFlaggedSeriesAndClearExtractionKeepsIdentityRows() async throws {
        let libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeriesIdentityGC-\(UUID().uuidString)")
        let db = try AmbrosiaMetaDB(libraryURL: libraryURL)
        try await db.insert(metadata(series: [.init(name: "Keep Identity", index: 1, ao3ID: "303")]), calibreID: 3)
        try await db.run("INSERT INTO series (series_key, name, calibre_series_id, created_at) VALUES ('calibre:404', 'Flagged', 404, '2026-01-01T00:00:00Z')")
        try await db.run("""
            INSERT INTO series_collection_members (collection_id, series_id, added_at)
            SELECT ?, series_id, '2026-01-01T00:00:00Z' FROM series WHERE series_key='calibre:404'
            """, [SystemCollectionID.liked])
        try await db.run("INSERT INTO series (series_key, name, calibre_series_id, created_at) VALUES ('calibre:405', 'Orphan', 405, '2026-01-01T00:00:00Z')")

        try await db.clearAO3Metadata()
        let identityCount = try await db.scalar("SELECT COUNT(*) FROM series WHERE series_key = 'ao3:303'") as? Int64
        XCTAssertEqual(identityCount, 1)
        try await db.collectUnreferencedSeries()
        let flaggedCount = try await db.scalar("SELECT COUNT(*) FROM series WHERE series_key = 'calibre:404'") as? Int64
        let orphanCount = try await db.scalar("SELECT COUNT(*) FROM series WHERE series_key = 'calibre:405'") as? Int64
        XCTAssertEqual(flaggedCount, 1)
        XCTAssertEqual(orphanCount, 0)
    }

    private func metadata(series: [AO3MetadataRecord.SeriesEntry]) -> AO3MetadataRecord {
        AO3MetadataRecord(
            storyURL: nil, workID: nil, authors: [], kudosCount: nil, wordCount: nil,
            chapterCurrent: nil, chapterTotal: nil, isComplete: false, language: nil,
            publishedDate: nil, updatedDate: nil, fandoms: [], relationships: [],
            characters: [], additionalTags: [], categories: [], ao3Collections: [],
            series: series, rating: nil, warnings: [], extractedAt: "2026-01-01T00:00:00Z"
        )
    }
}
