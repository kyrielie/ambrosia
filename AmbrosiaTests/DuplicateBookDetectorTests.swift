import XCTest
@testable import Ambrosia

// NOTE: this file needs a Unit Testing Bundle target added in Xcode
// (see the matching note in LibraryVisibilityPolicyTests.swift) before
// `xcodebuild test` will pick it up.

final class DuplicateBookDetectorTests: XCTestCase {

    private func dates(published: String? = nil, updated: String? = nil) -> (published: String?, updated: String?) {
        (published: published, updated: updated)
    }

    func test_noWorkIDs_returnsEmpty() {
        let losers = DuplicateBookDetector.loserIDs(workIDs: [:], dates: [:])
        XCTAssertTrue(losers.isEmpty)
    }

    func test_distinctWorkIDs_neverGroup() {
        let workIDs: [Int: String] = [1: "work-a", 2: "work-b", 3: "work-c"]
        let losers = DuplicateBookDetector.loserIDs(workIDs: workIDs, dates: [:])
        XCTAssertTrue(losers.isEmpty, "no two calibre IDs share a work id, so nothing should be flagged")
    }

    func test_nilWorkID_neverParticipates() {
        // Only entries present in `workIDs` are eligible; a book with no
        // extracted AO3 metadata simply isn't in the dictionary at all.
        let workIDs: [Int: String] = [1: "work-a"]
        let losers = DuplicateBookDetector.loserIDs(workIDs: workIDs, dates: [:])
        XCTAssertTrue(losers.isEmpty, "a single member of a work-id group is never a loser")
    }

    func test_sameWorkID_newerUpdatedWins() {
        let workIDs: [Int: String] = [1: "work-a", 2: "work-a"]
        let dates: [Int: (published: String?, updated: String?)] = [
            1: dates(updated: "2023-01-01"),
            2: dates(updated: "2024-06-15")
        ]
        let losers = DuplicateBookDetector.loserIDs(workIDs: workIDs, dates: dates)
        XCTAssertEqual(losers, [1], "the older-updated copy should be the loser")
    }

    func test_sameWorkID_missingUpdatedFallsBackToPublished() {
        let workIDs: [Int: String] = [1: "work-a", 2: "work-a"]
        let dates: [Int: (published: String?, updated: String?)] = [
            1: dates(published: "2020-01-01"),
            2: dates(published: "2022-01-01")
        ]
        let losers = DuplicateBookDetector.loserIDs(workIDs: workIDs, dates: dates)
        XCTAssertEqual(losers, [1], "with no updated date on either side, published date should decide")
    }

    func test_sameWorkID_updatedPreferredOverPublishedEvenWhenOlder() {
        // ID 1 has a newer updated date but an older published date than ID 2.
        // updated should take priority.
        let workIDs: [Int: String] = [1: "work-a", 2: "work-a"]
        let dates: [Int: (published: String?, updated: String?)] = [
            1: dates(published: "2019-01-01", updated: "2024-01-01"),
            2: dates(published: "2023-01-01", updated: "2020-01-01")
        ]
        let losers = DuplicateBookDetector.loserIDs(workIDs: workIDs, dates: dates)
        XCTAssertEqual(losers, [2], "newer `updated` should win even against a newer `published` on the other side")
    }

    func test_sameWorkID_noDatesAtAll_stableArbitraryTiebreak() {
        let workIDs: [Int: String] = [7: "work-a", 3: "work-a"]
        let losers1 = DuplicateBookDetector.loserIDs(workIDs: workIDs, dates: [:])
        let losers2 = DuplicateBookDetector.loserIDs(workIDs: workIDs, dates: [:])
        XCTAssertEqual(losers1, [7], "lower calibre_id should win the arbitrary tiebreak")
        XCTAssertEqual(losers1, losers2, "the tiebreak must be stable across repeated calls")
    }

    func test_sameWorkID_exactlyEqualDates_stableArbitraryTiebreak() {
        let workIDs: [Int: String] = [10: "work-a", 4: "work-a"]
        let dates: [Int: (published: String?, updated: String?)] = [
            10: dates(updated: "2024-01-01"),
            4: dates(updated: "2024-01-01")
        ]
        let losers = DuplicateBookDetector.loserIDs(workIDs: workIDs, dates: dates)
        XCTAssertEqual(losers, [10], "on an exact tie, the lower calibre_id should win")
    }

    func test_threeWayDuplicateGroup_keepsOnlyTheNewest() {
        let workIDs: [Int: String] = [1: "work-a", 2: "work-a", 3: "work-a"]
        let dates: [Int: (published: String?, updated: String?)] = [
            1: dates(updated: "2021-01-01"),
            2: dates(updated: "2024-01-01"),
            3: dates(updated: "2022-01-01")
        ]
        let losers = DuplicateBookDetector.loserIDs(workIDs: workIDs, dates: dates)
        XCTAssertEqual(losers, [1, 3], "every member except the newest-updated should be a loser")
    }

    func test_multipleIndependentDuplicateGroups() {
        let workIDs: [Int: String] = [1: "work-a", 2: "work-a", 3: "work-b", 4: "work-b"]
        let dates: [Int: (published: String?, updated: String?)] = [
            1: dates(updated: "2020-01-01"),
            2: dates(updated: "2024-01-01"),
            3: dates(updated: "2024-01-01"),
            4: dates(updated: "2020-01-01")
        ]
        let losers = DuplicateBookDetector.loserIDs(workIDs: workIDs, dates: dates)
        XCTAssertEqual(losers, [1, 4], "each group should resolve independently")
    }
}
