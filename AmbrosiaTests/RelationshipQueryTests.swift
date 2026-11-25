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
        let (matches, dist, _) = query.matches(candidateName: "Loki/Tony Stark")
        XCTAssertTrue(matches)
        XCTAssertEqual(dist, 0)
    }

    func testRelationshipAmpersandMatches() {
        let query = RelationshipQuery.parse("zuko & toph")
        let (matches, dist, _) = query.matches(candidateName: "Toph Beifong & Zuko")
        XCTAssertTrue(matches)
        XCTAssertEqual(dist, 0)
    }

    func testRelationshipDiacriticFoldMatches() {
        let query = RelationshipQuery.parse("padme/anakin")
        let (matches, dist, _) = query.matches(candidateName: "Padmé Amidala/Anakin Skywalker")
        XCTAssertTrue(matches)
        XCTAssertEqual(dist, 0)
    }

    func testRelationshipTokenSetReversedNameMatches() {
        let query = RelationshipQuery.parse("stark tony")
        let (matches, dist, _) = query.matches(candidateName: "Tony Stark")
        XCTAssertTrue(matches)
        XCTAssertEqual(dist, 0)
    }

    func testLetterXIsNotASeparatorInsideWord() {
        let query = RelationshipQuery.parse("alex/tony")
        let (matches, _, _) = query.matches(candidateName: "Loki/Tony Stark")
        // "alex" does not match "Loki"
        XCTAssertFalse(matches)
    }

    func testRelationshipWithTypoMatches() {
        let query = RelationshipQuery.parse("hurt/comfrt")
        let (matches, dist, _) = query.matches(candidateName: "Hurt/Comfort")
        XCTAssertTrue(matches)
        XCTAssertEqual(dist, 1)
    }

    func testRelationshipWithQualifierMatches() {
        let query = RelationshipQuery.parse("aziraphale/crowley")
        let (matches, dist, _) = query.matches(candidateName: "Aziraphale/Crowley (Good Omens)")
        XCTAssertTrue(matches)
        XCTAssertEqual(dist, 0)
    }

    func testRelationshipWithPerEntityParentheticalsMatches() {
        let query = RelationshipQuery.parse("loki/tony")
        let (matches, dist, _) = query.matches(candidateName: "Loki (Marvel)/Tony Stark")
        XCTAssertTrue(matches)
        XCTAssertEqual(dist, 0)

        let queryWithFandom = RelationshipQuery.parse("loki (marvel)/tony")
        let (matches2, dist2, _) = queryWithFandom.matches(candidateName: "Loki/Tony Stark")
        XCTAssertTrue(matches2)
        XCTAssertEqual(dist2, 0)
    }

    func testReaderAndYNUnification() {
        let query1 = RelationshipQuery.parse("bucky/y/n")
        let (matches1, dist1, _) = query1.matches(candidateName: "James \"Bucky\" Barnes/Reader")
        XCTAssertTrue(matches1)
        XCTAssertEqual(dist1, 0)

        let query2 = RelationshipQuery.parse("bucky/reader")
        let (matches2, dist2, _) = query2.matches(candidateName: "James \"Bucky\" Barnes/Y/N")
        XCTAssertTrue(matches2)
        XCTAssertEqual(dist2, 0)
    }

    func testInitialsMatchingInEntities() {
        let query1 = RelationshipQuery.parse("sr/ts")
        let (matches1, dist1, _) = query1.matches(candidateName: "Steve Rogers/Tony Stark")
        XCTAssertTrue(matches1)
        XCTAssertEqual(dist1, 0)

        let query2 = RelationshipQuery.parse("jb/sr")
        let (matches2, dist2, _) = query2.matches(candidateName: "James \"Bucky\" Barnes/Steve Rogers")
        XCTAssertTrue(matches2)
        XCTAssertEqual(dist2, 0)

        let query3 = RelationshipQuery.parse("jbb/sr")
        let (matches3, dist3, _) = query3.matches(candidateName: "James \"Bucky\" Barnes/Steve Rogers")
        XCTAssertTrue(matches3)
        XCTAssertEqual(dist3, 0)
    }

    func testNicknameAndPrefixSearchInSnapshot() {
        let originals = [
            "Adam \"Holster\" Birkholtz/Justin \"Ransom\" Oluransi",
            "James \"Bucky\" Barnes/Steve Rogers",
            "Steve McGarrett/Danny \"Danno\" Williams",
            "Tyrannus Basilton \"Baz\" Pitch/Simon Snow",
            "Steve Rogers/Tony Stark",
            "Leon S. Kennedy/Reader",
            "Loki (Marvel)/Tony Stark"
        ]
        let frequencies = [50, 60, 40, 30, 100, 20, 45]
        let types = Array(repeating: SuggestionTagType.relationship, count: originals.count)

        let snapshot = SuggestionSnapshot(originals: originals, frequencies: frequencies, types: types)

        // 1. Nicknames across slashes
        let r1 = snapshot.search(query: "holster/ransom", limit: 5)
        XCTAssertEqual(r1.first?.value, "Adam \"Holster\" Birkholtz/Justin \"Ransom\" Oluransi")

        // 2. Prefix abbreviations across slashes
        let r2 = snapshot.search(query: "holst/rans", limit: 5)
        XCTAssertEqual(r2.first?.value, "Adam \"Holster\" Birkholtz/Justin \"Ransom\" Oluransi")

        let r3 = snapshot.search(query: "buck/steve", limit: 5)
        XCTAssertEqual(r3.first?.value, "James \"Bucky\" Barnes/Steve Rogers")

        // 3. Initials across slashes
        let r4 = snapshot.search(query: "jb/sr", limit: 5)
        XCTAssertEqual(r4.first?.value, "James \"Bucky\" Barnes/Steve Rogers")

        let r5 = snapshot.search(query: "sr/ts", limit: 5)
        XCTAssertEqual(r5.first?.value, "Steve Rogers/Tony Stark")

        let r6 = snapshot.search(query: "h/r", limit: 5)
        XCTAssertEqual(r6.first?.value, "Adam \"Holster\" Birkholtz/Justin \"Ransom\" Oluransi")

        // 4. Reader / Y/N searches
        let r7 = snapshot.search(query: "leon/y/n", limit: 5)
        XCTAssertEqual(r7.first?.value, "Leon S. Kennedy/Reader")

        // 5. Per-entity parenthetical disambiguation
        let r8 = snapshot.search(query: "loki/tony", limit: 5)
        XCTAssertTrue(r8.contains { $0.value == "Loki (Marvel)/Tony Stark" })
    }

    func testNonRelationshipTagsWithDelimiters() {
        let originals = [
            "Hurt/Comfort",
            "Drama & Romance",
            "Dungeons & Dragons",
            "Hunter x Hunter",
            "Spy x Family",
            "Alpha/Beta/Omega Dynamics",
            "M/M",
            "Steve Rogers/Tony Stark"
        ]
        let frequencies = [500, 300, 400, 200, 250, 150, 1000, 800]
        let types: [SuggestionTagType] = [
            .freeform,
            .freeform,
            .fandom,
            .fandom,
            .fandom,
            .freeform,
            .category,
            .relationship
        ]

        let snapshot = SuggestionSnapshot(originals: originals, frequencies: frequencies, types: types)

        // 1. Direct search for freeform tags with slashes
        let r1 = snapshot.search(query: "hurt/comfort", limit: 5)
        XCTAssertEqual(r1.first?.value, "Hurt/Comfort")
        XCTAssertEqual(r1.first?.tagType, .freeform)
        XCTAssertEqual(r1.first?.matchClass, .exact)

        // 2. Short / abbreviated search for Hurt/Comfort
        let r2 = snapshot.search(query: "hurt/comf", limit: 5)
        XCTAssertEqual(r2.first?.value, "Hurt/Comfort")

        // 3. Category search
        let r3 = snapshot.search(query: "m/m", limit: 5)
        XCTAssertEqual(r3.first?.value, "M/M")
        XCTAssertEqual(r3.first?.tagType, .category)

        // 4. Fandom with '&'
        let r4 = snapshot.search(query: "dungeons & dragons", limit: 5)
        XCTAssertEqual(r4.first?.value, "Dungeons & Dragons")
        XCTAssertEqual(r4.first?.tagType, .fandom)

        // 5. Fandom with ' x '
        let r5 = snapshot.search(query: "hunter x hunter", limit: 5)
        XCTAssertEqual(r5.first?.value, "Hunter x Hunter")

        let r6 = snapshot.search(query: "spy x family", limit: 5)
        XCTAssertEqual(r6.first?.value, "Spy x Family")

        // 6. Freeform with multi-slash
        let r7 = snapshot.search(query: "alpha/beta", limit: 5)
        XCTAssertEqual(r7.first?.value, "Alpha/Beta/Omega Dynamics")

        // 7. Relationship search does not get polluted by non-relationship tags
        let r8 = snapshot.search(query: "steve/tony", limit: 5)
        XCTAssertEqual(r8.first?.value, "Steve Rogers/Tony Stark")
        XCTAssertEqual(r8.first?.tagType, .relationship)
    }
}
