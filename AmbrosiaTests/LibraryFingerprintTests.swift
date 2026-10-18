import XCTest
@testable import Ambrosia

final class LibraryFingerprintTests: XCTestCase {

    private func make(modified: Int = 100, size: Int = 5_000, count: Int = 50, maxID: Int = 60,
                      lastModified: String = "2026-01-01 00:00:00+00:00") -> LibraryFingerprint {
        LibraryFingerprint(fileModified: modified, fileSize: size, bookCount: count,
                           maxBookID: maxID, maxLastModified: lastModified)
    }

    func testEqualFingerprintsAreUnchanged() {
        XCTAssertTrue(LibraryFingerprint.isUnchanged(stored: make(), current: make()))
    }

    func testEachComponentChangeIsDetected() {
        let stored = make()
        let changed = [
            make(modified: 101), make(size: 5_001), make(count: 51), make(maxID: 61),
            make(lastModified: "2026-01-02 00:00:00+00:00")
        ]
        for current in changed {
            XCTAssertFalse(LibraryFingerprint.isUnchanged(stored: stored, current: current))
        }
    }

    func testMissingStoredValueMeansChanged() {
        XCTAssertFalse(LibraryFingerprint.isUnchanged(stored: nil, current: make()))
    }

    func testEncodeDecodeRoundTrip() {
        let original = make()
        XCTAssertEqual(LibraryFingerprint.decode(original.encoded()), original)
    }

    func testEqualFingerprintsEncodeIdentically() {
        XCTAssertEqual(make().encoded(), make().encoded())
    }

    func testDecodeFailureAndNilFallBackToNil() {
        XCTAssertNil(LibraryFingerprint.decode(nil))
        XCTAssertNil(LibraryFingerprint.decode(""))
        XCTAssertNil(LibraryFingerprint.decode("not json"))
    }

    func testVersionMismatchIsIgnored() {
        var old = make()
        old.version = LibraryFingerprint.currentVersion + 1
        XCTAssertNil(LibraryFingerprint.decode(old.encoded()))
    }

    // MARK: - LibraryChange

    func testNoKnownFingerprintIsNoChange() {
        XCTAssertEqual(LibraryChange.classify(known: nil, current: make()), .none)
    }

    func testEqualFingerprintIsNoChange() {
        XCTAssertEqual(LibraryChange.classify(known: make(), current: make()), .none)
    }

    func testFileOnlyChangeIsNotContent() {
        XCTAssertEqual(LibraryChange.classify(known: make(), current: make(modified: 200)), .fileOnly)
        XCTAssertEqual(LibraryChange.classify(known: make(), current: make(size: 9_999)), .fileOnly)
    }

    func testBookSetComponentsAreContentChanges() {
        let known = make()
        XCTAssertEqual(LibraryChange.classify(known: known, current: make(count: 51)), .content)
        XCTAssertEqual(LibraryChange.classify(known: known, current: make(maxID: 61)), .content)
        XCTAssertEqual(LibraryChange.classify(known: known, current: make(lastModified: "2026-02-01 00:00:00+00:00")), .content)
    }

    func testContentWinsOverFileChange() {
        XCTAssertEqual(LibraryChange.classify(known: make(), current: make(modified: 200, count: 51)), .content)
    }
}
