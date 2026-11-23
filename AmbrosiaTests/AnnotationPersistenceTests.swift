import XCTest
@testable import Ambrosia

@MainActor
final class AnnotationPersistenceTests: XCTestCase {

    struct TestError: Error, LocalizedError {
        var errorDescription: String? { "Database locked" }
    }

    func testSaveAnnotationSuccessDoesNotTriggerRollback() async {
        var inserted = false
        var rollbackCalled = false

        let persistence = AnnotationPersistence(
            metaDB: nil,
            insertHandler: { _, _ in
                inserted = true
            },
            deleteHandler: { _, _ in }
        )

        let annotation = Annotation(spineIndex: 0, startChar: 10, endChar: 20, selectedText: "test", colorHex: "#FFD60A")
        persistence.saveAnnotation(annotation, calibreID: 42) {
            rollbackCalled = true
        }

        // Allow unstructured Task to execute
        for _ in 0..<10 {
            if inserted { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(inserted)
        XCTAssertFalse(rollbackCalled)
    }

    func testSaveAnnotationFailureTriggersRollback() async {
        var rollbackCalled = false

        let persistence = AnnotationPersistence(
            metaDB: nil,
            insertHandler: { _, _ in
                throw TestError()
            },
            deleteHandler: { _, _ in }
        )

        let annotation = Annotation(spineIndex: 0, startChar: 10, endChar: 20, selectedText: "test", colorHex: "#FFD60A")
        persistence.saveAnnotation(annotation, calibreID: 42) {
            rollbackCalled = true
        }

        // Allow unstructured Task to execute
        for _ in 0..<10 {
            if rollbackCalled { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(rollbackCalled)
    }

    func testDeleteAnnotationFailureTriggersRollback() async {
        var rollbackCalled = false

        let persistence = AnnotationPersistence(
            metaDB: nil,
            insertHandler: { _, _ in },
            deleteHandler: { _, _ in
                throw TestError()
            }
        )

        persistence.removeAnnotation(id: UUID(), calibreID: 42) {
            rollbackCalled = true
        }

        // Allow unstructured Task to execute
        for _ in 0..<10 {
            if rollbackCalled { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(rollbackCalled)
    }
}
