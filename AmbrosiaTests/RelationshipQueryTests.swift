import XCTest
@testable import Ambrosia

final class RelationshipQueryTests: XCTestCase {

    func testExplicitEntityParsing() {
        let q1 = RelationshipQuery.parse("steve/tony")
        XCTAssertEqual(q1, .explicitEntities([["steve"], ["tony"]]))

        let q2 = RelationshipQuery.parse("steve rogers & tony stark")
        XCTAssertEqual(q2, .explicitEntities([["steve", "rogers"], ["tony", "stark"]]))

        let q3 = RelationshipQuery.parse("steve x tony")
        XCTAssertEqual(q3, .explicitEntities([["steve"], ["tony"]]))

        let q4 = RelationshipQuery.parse("tony, steve")
        XCTAssertEqual(q4, .explicitEntities([["tony"], ["steve"]]))
    }

    func testTokenSetParsing() {
        let q1 = RelationshipQuery.parse("tony steve")
        XCTAssertEqual(q1, .tokenSet(["tony", "steve"]))

        let q2 = RelationshipQuery.parse("alex/tony")
        // 'alex' is not split on 'x'
        XCTAssertEqual(q2, .explicitEntities([["alex"], ["tony"]]))
    }

    func testRelationshipInvertedOrderMatches() {
        let query = RelationshipQuery.parse("tony/loki")
        let (matches, dist) = query.matches(candidateName: "Loki/Tony Stark")
        XCTAssertTrue(matches)
        XCTAssertEqual(dist, 0)
    }

    func testRelationshipAmpersandMatches() {
        let query = RelationshipQuery.parse("zuko & toph")
        let (matches, dist) = query.matches(candidateName: "Toph Beifong & Zuko")
        XCTAssertTrue(matches)
        XCTAssertEqual(dist, 0)
    }

    func testRelationshipDiacriticFoldMatches() {
        let query = RelationshipQuery.parse("padme/anakin")
        let (matches, dist) = query.matches(candidateName: "Padmé Amidala/Anakin Skywalker")
        XCTAssertTrue(matches)
        XCTAssertEqual(dist, 0)
    }

    func testRelationshipTokenSetReversedNameMatches() {
        let query = RelationshipQuery.parse("stark tony")
        let (matches, dist) = query.matches(candidateName: "Tony Stark")
        XCTAssertTrue(matches)
        XCTAssertEqual(dist, 0)
    }

    func testLetterXIsNotASeparatorInsideWord() {
        let query = RelationshipQuery.parse("alex/tony")
        let (matches, _) = query.matches(candidateName: "Loki/Tony Stark")
        // "alex" does not match "Loki"
        XCTAssertFalse(matches)
    }

    func testRelationshipWithTypoMatches() {
        let query = RelationshipQuery.parse("hurt/comfrt")
        let (matches, dist) = query.matches(candidateName: "Hurt/Comfort")
        XCTAssertTrue(matches)
        XCTAssertEqual(dist, 1)
    }

    func testRelationshipWithQualifierMatches() {
        let query = RelationshipQuery.parse("aziraphale/crowley")
        let (matches, dist) = query.matches(candidateName: "Aziraphale/Crowley (Good Omens)")
        XCTAssertTrue(matches)
        XCTAssertEqual(dist, 0)
    }
}
