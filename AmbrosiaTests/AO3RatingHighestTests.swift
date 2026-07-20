import XCTest
@testable import Ambrosia

// NOTE: this file needs a Unit Testing Bundle target added in Xcode
// (see the matching note in LibraryVisibilityPolicyTests.swift) before
// `xcodebuild test` will pick it up.
//
// Covers `AO3Rating.highest(among:)`, the hierarchy-collapse helper used by
// LocalFeedServer's buildJSONFeedItem/buildGroupedJSONFeedItem/transferRow
// to turn a raw tag union into the single rating tag those wire formats
// publish. Pure function, no DB dependency.
final class AO3RatingHighestTests: XCTestCase {

    func test_singleRecognizedTag_returnsIt() {
        XCTAssertEqual(AO3Rating.highest(among: ["General Audiences"]), .generalAudiences)
    }

    func test_mixedRatings_returnsHighestOnHierarchy() {
        XCTAssertEqual(
            AO3Rating.highest(among: ["General Audiences", "Explicit", "Teen And Up Audiences"]),
            .explicit
        )
    }

    func test_orderInInputDoesNotMatter() {
        XCTAssertEqual(AO3Rating.highest(among: ["Explicit", "General Audiences"]), .explicit)
        XCTAssertEqual(AO3Rating.highest(among: ["General Audiences", "Explicit"]), .explicit)
    }

    func test_notRated_onlyWinsWhenNothingElseIsRanked() {
        XCTAssertEqual(AO3Rating.highest(among: ["Not Rated"]), .notRated)
        XCTAssertEqual(
            AO3Rating.highest(among: ["Not Rated", "General Audiences"]),
            .generalAudiences,
            "any ranked rating beats Not Rated, regardless of position in the array"
        )
    }

    func test_unrecognizedTagsAreIgnored() {
        XCTAssertEqual(
            AO3Rating.highest(among: ["Fluff", "Angst", "Mature"]),
            .mature,
            "non-rating freeform/warning/category tags mixed into the same array must not affect the result"
        )
    }

    func test_noRecognizedRatingTag_returnsNil() {
        XCTAssertNil(AO3Rating.highest(among: ["Fluff", "Angst"]))
        XCTAssertNil(AO3Rating.highest(among: []))
    }
}
