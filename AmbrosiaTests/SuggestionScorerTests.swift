import XCTest
@testable import Ambrosia

final class SuggestionScorerTests: XCTestCase {

    func testClassBeatsFrequency() {
        // Rare exact prefix vs very frequent fuzzy match
        let exactMatch = SuggestionMatch(value: "RareTag", matchClass: .exact, frequency: 1)
        let fuzzyMatch = SuggestionMatch(value: "PopularTag", matchClass: .fuzzyDistance1, frequency: 50_000)

        XCTAssertTrue(SuggestionMatch.isBetter(exactMatch, than: fuzzyMatch))
        XCTAssertFalse(SuggestionMatch.isBetter(fuzzyMatch, than: exactMatch))
    }

    func testFrequencyTieBreakWithinSameClass() {
        let popular = SuggestionMatch(value: "PopularTag", matchClass: .substring, frequency: 1_200)
        let rare = SuggestionMatch(value: "RareTag", matchClass: .substring, frequency: 5)

        XCTAssertTrue(SuggestionMatch.isBetter(popular, than: rare))
    }

    func testAlphabeticalTieBreakWhenClassAndFrequencyEqual() {
        let tagA = SuggestionMatch(value: "Alpha", matchClass: .prefix, frequency: 10)
        let tagB = SuggestionMatch(value: "Beta", matchClass: .prefix, frequency: 10)

        XCTAssertTrue(SuggestionMatch.isBetter(tagA, than: tagB))
    }

    func testCollectorLimitsAndDeduplicates() {
        var collector = SuggestionCollector(limit: 2)
        collector.insert(SuggestionMatch(value: "Tag1", matchClass: .fuzzyDistance1, frequency: 10))
        collector.insert(SuggestionMatch(value: "Tag1", matchClass: .exact, frequency: 100)) // Duplicate value
        collector.insert(SuggestionMatch(value: "Tag2", matchClass: .prefix, frequency: 5))
        collector.insert(SuggestionMatch(value: "Tag3", matchClass: .exact, frequency: 2))

        let results = collector.finalized()
        XCTAssertEqual(results.count, 2)
        // Tag3 is .exact, Tag2 is .prefix -> Tag3 first, Tag2 second
        XCTAssertEqual(results.map(\.value), ["Tag3", "Tag2"])
    }
}
