import XCTest
@testable import Ambrosia

/// `LibrarySession.narrowingBase` (plan PR I): subset lookup in `filterResultCache`.
@MainActor
final class NarrowingBaseTests: XCTestCase {

    private func tag(_ value: String) -> FilterRule { FilterRule(field: .tag, op: .contains, value: value) }

    private func expression(_ rules: [FilterRule]) -> FilterExpression {
        var expr = FilterExpression()
        expr.groups = [FilterGroup(rules: rules, conjunction: .and)]
        expr.groupConjunction = .and
        return expr
    }

    func testReturnsPreviousStepOfAChain() {
        let session = LibrarySession()
        let first = tag("A"), second = tag("B")
        session.rememberFilterResult(FilterResult(calibreIDs: [1, 2, 3], totalCount: 3),
                                     for: expression([first]), visibilitySignature: "v")
        let hit = session.narrowingBase(for: expression([first, second]), visibilitySignature: "v")
        XCTAssertEqual(hit?.base.calibreIDs, [1, 2, 3])
        XCTAssertEqual(hit?.delta.value, "B")
    }

    func testReturnsSmallestCachedBase() {
        let session = LibrarySession()
        let first = tag("A"), second = tag("B"), third = tag("C")
        session.rememberFilterResult(FilterResult(calibreIDs: [1, 2, 3, 4, 5], totalCount: 5),
                                     for: expression([first, second]), visibilitySignature: "v")
        session.rememberFilterResult(FilterResult(calibreIDs: [1, 2], totalCount: 2),
                                     for: expression([first, third]), visibilitySignature: "v")
        let hit = session.narrowingBase(for: expression([first, second, third]), visibilitySignature: "v")
        XCTAssertEqual(hit?.base.calibreIDs, [1, 2])
        XCTAssertEqual(hit?.delta.value, "B")
    }

    func testNilWhenNothingCachedForAnySplit() {
        let session = LibrarySession()
        XCTAssertNil(session.narrowingBase(for: expression([tag("A"), tag("B")]), visibilitySignature: "v"))
    }

    func testNilAfterMembershipVersionChanges() {
        let session = LibrarySession()
        let first = tag("A"), second = tag("B")
        session.rememberFilterResult(FilterResult(calibreIDs: [1], totalCount: 1),
                                     for: expression([first]), visibilitySignature: "v")
        session.bumpMembershipVersion()
        XCTAssertNil(session.narrowingBase(for: expression([first, second]), visibilitySignature: "v"))
    }

    func testIgnoresBaseKeyedWithDifferentVisibilitySignature() {
        let session = LibrarySession()
        let first = tag("A"), second = tag("B")
        session.rememberFilterResult(FilterResult(calibreIDs: [1], totalCount: 1),
                                     for: expression([first]), visibilitySignature: "old")
        XCTAssertNil(session.narrowingBase(for: expression([first, second]), visibilitySignature: "new"))
    }

    func testIgnoresSQLBackedBase() {
        let session = LibrarySession()
        let first = tag("A"), second = tag("B")
        session.rememberFilterResult(FilterResult(calibreIDs: [], isSQLBacked: true),
                                     for: expression([first]), visibilitySignature: "v")
        XCTAssertNil(session.narrowingBase(for: expression([first, second]), visibilitySignature: "v"))
    }

    func testOrExpressionNeverNarrows() {
        let session = LibrarySession()
        let first = tag("A"), second = tag("B")
        session.rememberFilterResult(FilterResult(calibreIDs: [1], totalCount: 1),
                                     for: expression([first]), visibilitySignature: "v")
        var orExpression = expression([first, second])
        orExpression.groups[0].conjunction = .or
        XCTAssertNil(session.narrowingBase(for: orExpression, visibilitySignature: "v"))
    }
}
