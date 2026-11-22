import XCTest
@testable import Ambrosia

final class TagPillDisplayTests: XCTestCase {

    func testTagPillDisplayFirstListedRelationshipAndCharacter() {
        let record = AO3MetadataRecord(
            storyURL: nil,
            workID: nil,
            authors: [],
            kudosCount: nil,
            wordCount: nil,
            chapterCurrent: 1,
            chapterTotal: 1,
            isComplete: true,
            language: "English",
            publishedDate: nil,
            updatedDate: nil,
            fandoms: ["Harry Potter - J. K. Rowling"],
            relationships: ["Harry Potter/Draco Malfoy", "Ron Weasley/Hermione Granger"],
            characters: ["Harry Potter", "Draco Malfoy", "Hermione Granger"],
            additionalTags: ["Slow Burn", "Fluff"],
            categories: ["M/M"],
            ao3Collections: [],
            series: [],
            rating: "Mature",
            warnings: [],
            extractedAt: "2024-01-01T00:00:00Z"
        )

        let pills = TagPillDisplay.make(
            calibreTags: [],
            ao3Metadata: record,
            hideFanworks: false
        )

        let rel1 = pills.first { $0.role == TagPillDisplay.Role.relationship && $0.label == "Harry Potter/Draco Malfoy" }
        let rel2 = pills.first { $0.role == TagPillDisplay.Role.relationship && $0.label == "Ron Weasley/Hermione Granger" }
        let char1 = pills.first { $0.role == TagPillDisplay.Role.character && $0.label == "Harry Potter" }
        let char2 = pills.first { $0.role == TagPillDisplay.Role.character && $0.label == "Draco Malfoy" }
        let fandom = pills.first { $0.role == TagPillDisplay.Role.fandom }

        XCTAssertEqual(rel1?.isFirstListed, true)
        XCTAssertEqual(rel2?.isFirstListed, false)
        XCTAssertEqual(char1?.isFirstListed, true)
        XCTAssertEqual(char2?.isFirstListed, false)
        XCTAssertEqual(fandom?.isFirstListed, false)
    }

    func testTagPillDisplayFirstCharacterDedupedByEarlierRoleDoesNotMisattribute() {
        let record = AO3MetadataRecord(
            storyURL: nil,
            workID: nil,
            authors: [],
            kudosCount: nil,
            wordCount: nil,
            chapterCurrent: 1,
            chapterTotal: 1,
            isComplete: true,
            language: "English",
            publishedDate: nil,
            updatedDate: nil,
            fandoms: ["Harry Potter"],
            relationships: ["Harry Potter/Draco Malfoy"],
            characters: ["Harry Potter", "Draco Malfoy"],
            additionalTags: [],
            categories: [],
            ao3Collections: [],
            series: [],
            rating: "General",
            warnings: [],
            extractedAt: "2024-01-01T00:00:00Z"
        )

        let pills = TagPillDisplay.make(
            calibreTags: [],
            ao3Metadata: record,
            hideFanworks: false
        )

        // "Harry Potter" was captured by fandom, so "Draco Malfoy" is the first character pill rendered.
        // It must NOT be marked as isFirstListed because it is not the record's first character.
        let draco = pills.first { $0.role == .character && $0.label == "Draco Malfoy" }
        XCTAssertEqual(draco?.isFirstListed, false)
    }

    func testTagPillDisplaySeriesRowsHaveNoFirstListedMarkers() {
        let facets = TagPillDisplay.SeriesTagFacets(
            fandoms: ["Harry Potter"],
            relationships: ["Harry Potter/Draco Malfoy", "Ron Weasley/Hermione Granger"],
            characters: ["Harry Potter", "Draco Malfoy"],
            categories: ["M/M"],
            warnings: [],
            ratings: ["Explicit"],
            additionalTags: ["Slow Burn"],
            tags: []
        )

        let pills = TagPillDisplay.makeForSeries(facets, hideFanworks: false)
        for pill in pills {
            XCTAssertFalse(pill.isFirstListed, "Series pill \(pill.label) should not be marked as first-listed")
        }
    }
}
