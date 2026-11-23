import XCTest
@testable import Ambrosia

final class AnnotationMetaDBCRUDTests: XCTestCase {

    private var tempDir: URL!
    private var metaDB: AmbrosiaMetaDB!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationMetaDBCRUDTests-\(UUID().uuidString)")
        metaDB = try AmbrosiaMetaDB(libraryURL: tempDir)
    }

    override func tearDown() async throws {
        metaDB = nil
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    func testInsertAndFetchAnnotations() async throws {
        let annotation = Annotation(
            spineIndex: 2,
            startChar: 100,
            endChar: 150,
            selectedText: "Sample text",
            note: "A thoughtful note",
            colorHex: "#FFD60A"
        )

        try await metaDB.insertAnnotation(annotation, calibreID: 42)

        let fetched = try await metaDB.annotations(for: 42)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.id, annotation.id)
        XCTAssertEqual(fetched.first?.selectedText, "Sample text")
        XCTAssertEqual(fetched.first?.note, "A thoughtful note")
        XCTAssertEqual(fetched.first?.spineIndex, 2)
    }

    func testDeleteAnnotationRemovesRecord() async throws {
        let a1 = Annotation(spineIndex: 1, startChar: 10, endChar: 20, selectedText: "First", colorHex: "#FFD60A")
        let a2 = Annotation(spineIndex: 1, startChar: 30, endChar: 40, selectedText: "Second", colorHex: "#FFD60A")

        try await metaDB.insertAnnotation(a1, calibreID: 55)
        try await metaDB.insertAnnotation(a2, calibreID: 55)

        var current = try await metaDB.annotations(for: 55)
        XCTAssertEqual(current.count, 2)

        try await metaDB.deleteAnnotation(id: a1.id, calibreID: 55)

        current = try await metaDB.annotations(for: 55)
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current.first?.id, a2.id)
    }

    func testDeleteMissingAnnotationDoesNotThrow() async throws {
        let missingID = UUID()
        try await metaDB.deleteAnnotation(id: missingID, calibreID: 99)
    }

    func testPerBookAnnotationIsolation() async throws {
        let a1 = Annotation(spineIndex: 0, startChar: 5, endChar: 10, selectedText: "Book 10 note", colorHex: "#FFD60A")
        let a2 = Annotation(spineIndex: 0, startChar: 5, endChar: 10, selectedText: "Book 20 note", colorHex: "#FFD60A")

        try await metaDB.insertAnnotation(a1, calibreID: 10)
        try await metaDB.insertAnnotation(a2, calibreID: 20)

        let forBook10 = try await metaDB.annotations(for: 10)
        let forBook20 = try await metaDB.annotations(for: 20)

        XCTAssertEqual(forBook10.count, 1)
        XCTAssertEqual(forBook10.first?.id, a1.id)

        XCTAssertEqual(forBook20.count, 1)
        XCTAssertEqual(forBook20.first?.id, a2.id)
    }
}
