import XCTest
@testable import Ambrosia

// `GroupAwareSorter` replaced an inline comparator that did two dictionary
// lookups per comparison. The reference below is that comparator verbatim;
// the new sort must match it exactly, including ties and direction.
final class GroupAwareSortOrderTests: XCTestCase {

    private func reference(ids: [Int], seriesNames: [Int: String], titles: [Int: String],
                           ascending: Bool) -> [Int] {
        func sortKey(_ id: Int) -> String { seriesNames[id] ?? titles[id] ?? "" }
        return ids.sorted { idA, idB in
            let ka = sortKey(idA), kb = sortKey(idB)
            if ka == kb { return ascending ? idA < idB : idA > idB }
            return ascending ? ka < kb : ka > kb
        }
    }

    // Mixed: series members share a name (tie broken by id), standalone books
    // use their title, id 9 has no title or series (empty key), and "apple"
    // vs "Apple" exercises plain String ordering rather than a collation.
    private let ids = [5, 3, 8, 1, 9, 2, 7, 4, 6]
    private let seriesNames = [1: "Saga", 2: "Saga", 3: "Saga", 4: "Alpha Series"]
    private let titles = [1: "Z book", 2: "A book", 3: "M book", 4: "Q book",
                          5: "apple", 6: "Apple", 7: "apple", 8: "Banana"]

    func testMatchesReferenceAscending() {
        XCTAssertEqual(
            GroupAwareSorter.sort(ids: ids, seriesNames: seriesNames, titles: titles, ascending: true),
            reference(ids: ids, seriesNames: seriesNames, titles: titles, ascending: true))
    }

    func testMatchesReferenceDescending() {
        XCTAssertEqual(
            GroupAwareSorter.sort(ids: ids, seriesNames: seriesNames, titles: titles, ascending: false),
            reference(ids: ids, seriesNames: seriesNames, titles: titles, ascending: false))
    }

    func testSeriesMembersStayTogetherAndTieBreakByIDInDirection() {
        let asc = GroupAwareSorter.sort(ids: ids, seriesNames: seriesNames, titles: titles, ascending: true)
        let saga = asc.filter { seriesNames[$0] == "Saga" }
        XCTAssertEqual(saga, [1, 2, 3])
        let desc = GroupAwareSorter.sort(ids: ids, seriesNames: seriesNames, titles: titles, ascending: false)
        XCTAssertEqual(desc.filter { seriesNames[$0] == "Saga" }, [3, 2, 1])
    }

    func testEqualTitlesTieBreakByID() {
        let asc = GroupAwareSorter.sort(ids: ids, seriesNames: seriesNames, titles: titles, ascending: true)
        let apples = asc.filter { titles[$0] == "apple" }
        XCTAssertEqual(apples, [5, 7])
    }

    func testMissingKeySortsAsEmptyString() {
        let asc = GroupAwareSorter.sort(ids: ids, seriesNames: seriesNames, titles: titles, ascending: true)
        XCTAssertEqual(asc.first, 9)
    }

    func testEmptyInput() {
        XCTAssertEqual(GroupAwareSorter.sort(ids: [], seriesNames: [:], titles: [:], ascending: true), [])
    }
}
