import XCTest
@testable import Ambrosia

final class TagAutocompleteTests: XCTestCase {

    private var metaDB: AmbrosiaMetaDB?
    private var tempDir: URL?

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagAutocompleteTests-\(UUID().uuidString)")
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

    func testSearchTagsFindsFandomAndAppliesContext() async throws {
        guard let db = metaDB else {
            XCTFail("metaDB was not initialized")
            return
        }

        let rec1 = AO3MetadataRecord(
            storyURL: nil,
            workID: nil,
            authors: [AO3AuthorEntry(username: "Alice", pseud: nil, profileURL: nil, source: .byline)],
            kudosCount: nil,
            wordCount: nil,
            chapterCurrent: 1,
            chapterTotal: 1,
            isComplete: true,
            language: "English",
            publishedDate: nil,
            updatedDate: nil,
            fandoms: ["Harry Potter - J. K. Rowling"],
            relationships: ["Harry/Draco"],
            characters: ["Harry Potter", "Draco Malfoy"],
            additionalTags: ["Slow Burn", "Angst"],
            categories: ["M/M"],
            ao3Collections: [],
            series: [],
            rating: "Explicit",
            warnings: ["No Archive Warnings Apply"],
            extractedAt: "2024-01-01T00:00:00Z"
        )
        let rec2 = AO3MetadataRecord(
            storyURL: nil,
            workID: nil,
            authors: [AO3AuthorEntry(username: "Bob", pseud: nil, profileURL: nil, source: .byline)],
            kudosCount: nil,
            wordCount: nil,
            chapterCurrent: 1,
            chapterTotal: 1,
            isComplete: true,
            language: "English",
            publishedDate: nil,
            updatedDate: nil,
            fandoms: ["Marvel Cinematic Universe"],
            relationships: ["Steve/Tony"],
            characters: ["Steve Rogers", "Tony Stark"],
            additionalTags: ["Fluff", "Coffee Shop AU"],
            categories: ["M/M"],
            ao3Collections: [],
            series: [],
            rating: "Teen And Up Audiences",
            warnings: ["No Archive Warnings Apply"],
            extractedAt: "2024-01-01T00:00:00Z"
        )

        try await db.insertBatch([(rec1, 101), (rec2, 102)], diagnostics: [])

        // 1. Search tags for characters without fandom context
        let allChars = await db.searchTags(query: "", field: .character, fandomContext: [], limit: 10)
        XCTAssertEqual(allChars.count, 4)

        // 2. Search characters with query "Harry"
        let harryMatch = await db.searchTags(query: "Harry", field: .character, fandomContext: [], limit: 10)
        XCTAssertEqual(harryMatch.count, 1)
        XCTAssertEqual(harryMatch.first?.name, "Harry Potter")

        // 3. Search characters with fandomContext scoped to Harry Potter
        let scopedChars = await db.searchTags(
            query: "",
            field: .character,
            fandomContext: ["Harry Potter - J. K. Rowling"],
            limit: 10
        )
        XCTAssertEqual(scopedChars.count, 2)
        let names = scopedChars.map(\.name)
        XCTAssertTrue(names.contains("Harry Potter"))
        XCTAssertTrue(names.contains("Draco Malfoy"))
        XCTAssertFalse(names.contains("Steve Rogers"))

        // 4. Search author
        let authors = await db.searchTags(query: "Ali", field: .author, fandomContext: [], limit: 10)
        XCTAssertEqual(authors.count, 1)
        XCTAssertEqual(authors.first?.name, "Alice")
    }
}
