import XCTest
@testable import Ambrosia

final class ListedPositionFilterTests: XCTestCase {

    private static var libraryRoot: URL?
    private static var library: CalibreLibrary!
    private var metaDB: AmbrosiaMetaDB!
    private var tempDir: URL!

    // swiftlint:disable:next static_over_final_class
    override class func setUp() {
        super.setUp()
        do {
            libraryRoot = try CalibreTestFixture.makeTempLibraryRoot()
            if let root = libraryRoot {
                library = try CalibreLibrary(root: root)
            }
        } catch {
            XCTFail("Failed to build shared fixture: \(error)")
        }
    }

    // swiftlint:disable:next static_over_final_class
    override class func tearDown() {
        library = nil
        if let libraryRoot { try? FileManager.default.removeItem(at: libraryRoot) }
        libraryRoot = nil
        super.tearDown()
    }

    private var builder: FilterBuilder {
        FilterBuilder(library: Self.library, metaDB: metaDB)
    }

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ListedPositionFilterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        metaDB = try AmbrosiaMetaDB(libraryURL: dir)
    }

    override func tearDownWithError() throws {
        metaDB = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeRecord(
        relationships: [String] = [],
        characters: [String] = [],
        fandoms: [String] = ["General"]
    ) -> AO3MetadataRecord {
        AO3MetadataRecord(
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
            fandoms: fandoms,
            relationships: relationships,
            characters: characters,
            additionalTags: [],
            categories: ["M/M"],
            ao3Collections: [],
            series: [],
            rating: "Mature",
            warnings: [],
            extractedAt: "2024-01-01T00:00:00Z"
        )
    }

    func testFirstRelationshipIndexZeroOnly() async throws {
        // Book 101 has A/B at index 0
        // Book 102 has C/D at index 0, A/B at index 1
        let rec1 = makeRecord(relationships: ["Thor/Loki", "Tony Stark/Steve Rogers"])
        let rec2 = makeRecord(relationships: ["Tony Stark/Steve Rogers", "Thor/Loki"])
        try await metaDB.insertBatch([(rec1, 101), (rec2, 102)], diagnostics: [])

        let membersLimit1 = await metaDB.listedPositionMembers(
            role: .relationship,
            terms: ["Thor/Loki"],
            limit: 1
        )
        XCTAssertEqual(membersLimit1, [101], "Index 0 only matches book 101")
    }

    func testFirstRelationshipWithinFirstThree() async throws {
        let rec1 = makeRecord(relationships: ["A/B", "C/D", "E/F", "G/H"])
        let rec2 = makeRecord(relationships: ["X/Y", "A/B", "C/D"])
        let rec3 = makeRecord(relationships: ["W/Z", "X/Y", "C/D", "A/B"]) // A/B at index 3
        try await metaDB.insertBatch([(rec1, 1), (rec2, 2), (rec3, 3)], diagnostics: [])

        let members = await metaDB.listedPositionMembers(
            role: .relationship,
            terms: ["A/B"],
            limit: 3
        )
        XCTAssertTrue(members.contains(1), "Index 0 is within first 3")
        XCTAssertTrue(members.contains(2), "Index 1 is within first 3")
        XCTAssertFalse(members.contains(3), "Index 3 is NOT within first 3")
    }

    func testFirstCharacterRoleIsolated() async throws {
        // Book 1 has "Loki" as character, book 2 has "Loki" as relationship
        let rec1 = makeRecord(relationships: [], characters: ["Loki", "Thor"])
        let rec2 = makeRecord(relationships: ["Loki/Thor"], characters: [])
        try await metaDB.insertBatch([(rec1, 1), (rec2, 2)], diagnostics: [])

        let charMembers = await metaDB.listedPositionMembers(
            role: .character,
            terms: ["Loki"],
            limit: 1
        )
        XCTAssertEqual(charMembers, [1])

        let relMembers = await metaDB.listedPositionMembers(
            role: .relationship,
            terms: ["Loki"],
            limit: 1
        )
        XCTAssertTrue(relMembers.isEmpty, "Character role does not cross into relationship role")
    }

    func testIsNotExcludesBooksWithoutAO3Metadata() async throws {
        // Book 1 has AO3 metadata with relationship "A/B"
        // Book 2 has AO3 metadata with relationship "C/D"
        // Book 3 has NO ao3_metadata row at all
        let rec1 = makeRecord(relationships: ["A/B"])
        let rec2 = makeRecord(relationships: ["C/D"])
        try await metaDB.insertBatch([(rec1, 1), (rec2, 2)], diagnostics: [])

        let coverage = await metaDB.listedRoleCoverage(role: .relationship)
        let members = await metaDB.listedPositionMembers(role: .relationship, terms: ["A/B"], limit: 1)

        // All candidate books: [1, 2, 3]
        let allCandidates: Set<Int> = [1, 2, 3]
        // Negated match per Decision 4: candidates ∩ coverage − members
        let negated = allCandidates.intersection(coverage).subtracting(members)

        XCTAssertTrue(negated.contains(2), "Book 2 with other relationship passes negated rule")
        XCTAssertFalse(negated.contains(1), "Book 1 with matching relationship is excluded")
        XCTAssertFalse(negated.contains(3), "Book 3 with no AO3 metadata MUST be excluded from 'is not'")
    }

    func testIsNotExcludesEmptyRoleArray() async throws {
        // Book 1 has relationships ["A/B"]
        // Book 2 has relationships ["C/D"]
        // Book 3 has relationships [] (empty role array)
        let rec1 = makeRecord(relationships: ["A/B"])
        let rec2 = makeRecord(relationships: ["C/D"])
        let rec3 = makeRecord(relationships: [])
        try await metaDB.insertBatch([(rec1, 1), (rec2, 2), (rec3, 3)], diagnostics: [])

        let coverage = await metaDB.listedRoleCoverage(role: .relationship)
        XCTAssertFalse(coverage.contains(3), "Empty array has 0 length and is not covered")

        let members = await metaDB.listedPositionMembers(role: .relationship, terms: ["A/B"], limit: 1)
        let allCandidates: Set<Int> = [1, 2, 3]
        let negated = allCandidates.intersection(coverage).subtracting(members)

        XCTAssertTrue(negated.contains(2))
        XCTAssertFalse(negated.contains(1))
        XCTAssertFalse(negated.contains(3), "Empty array MUST be excluded from 'is not'")
    }

    func testFicLabStyleRecordExcludedFromCharacterIsAndIsNot() async throws {
        // FicLab-extracted book: empty characters array
        let rec = makeRecord(relationships: ["A/B"], characters: [])
        try await metaDB.insertBatch([(rec, 99)], diagnostics: [])

        let charCoverage = await metaDB.listedRoleCoverage(role: .character)
        XCTAssertFalse(charCoverage.contains(99), "FicLab record with empty characters is not in character coverage")

        let isMembers = await metaDB.listedPositionMembers(role: .character, terms: ["Hero"], limit: 3)
        XCTAssertFalse(isMembers.contains(99), "FicLab record excluded from 'is'")

        let isNotMembers = Set([99]).intersection(charCoverage).subtracting(isMembers)
        XCTAssertFalse(isNotMembers.contains(99), "FicLab record excluded from 'is not'")
    }

    func testCaseInsensitiveExactMatch() async throws {
        let rec = makeRecord(relationships: ["Thor/Loki"])
        try await metaDB.insertBatch([(rec, 1)], diagnostics: [])

        let members = await metaDB.listedPositionMembers(
            role: .relationship,
            terms: ["thor/loki"],
            limit: 1
        )
        XCTAssertEqual(members, [1], "Terms in lower case match stored title-case via name index")
    }

    func testSeedSynonymExpansionApplies() async throws {
        let rec = makeRecord(relationships: ["Tony Stark/Steve Rogers"])
        try await metaDB.insertBatch([(rec, 1)], diagnostics: [])

        // Simulated seed expansions handed in as `terms`
        let terms = ["Iron Man/Captain America", "Tony Stark/Steve Rogers", "Steve/Tony"]
        let members = await metaDB.listedPositionMembers(
            role: .relationship,
            terms: terms,
            limit: 1
        )
        XCTAssertEqual(members, [1], "Synonym terms match the work")
    }

    func testRepeatedNameUsesMinimumIndex() async throws {
        // A corrupted or duplicate record has A/B at index 0 and 2
        let rec = makeRecord(relationships: ["A/B", "C/D", "A/B"])
        try await metaDB.insertBatch([(rec, 1)], diagnostics: [])

        let members = await metaDB.listedPositionMembers(role: .relationship, terms: ["A/B"], limit: 1)
        XCTAssertEqual(members, [1])
    }

    func testMalformedJSONRowDoesNotAbortQuery() async throws {
        let rec = makeRecord(relationships: ["A/B"])
        try await metaDB.insertBatch([(rec, 1)], diagnostics: [])

        // Insert malformed JSON row directly
        try await metaDB.run("""
            INSERT INTO ao3_metadata (calibre_id, relationships_json, characters_json, fandoms_json, additional_tags_json, extracted_at)
            VALUES (2, '{invalid json', '[]', '[]', '[]', '2024-01-01T00:00:00Z')
        """)

        let members = await metaDB.listedPositionMembers(role: .relationship, terms: ["A/B"], limit: 1)
        XCTAssertEqual(members, [1], "Query continues and returns valid rows")
    }

    func testBookTagsNamesEqualJSONEntries() async throws {
        // Guard F9: verify that writeBookTags inserts tag_name matching JSON array entries exactly
        let rec = makeRecord(
            relationships: ["Ship A/Ship B", "Ship C & Ship D"],
            characters: ["Char One", "Char Two"]
        )
        try await metaDB.insertBatch([(rec, 501)], diagnostics: [])

        let relMatches = try await metaDB.bookTagMatchIDs(op: .equals, terms: ["Ship A/Ship B"], tagType: "relationship")
        let charMatches = try await metaDB.bookTagMatchIDs(op: .equals, terms: ["Char One"], tagType: "character")

        XCTAssertTrue(relMatches.contains(501), "Relationship in JSON matches book_tags tag_name exactly")
        XCTAssertTrue(charMatches.contains(501), "Character in JSON matches book_tags tag_name exactly")
    }

    func testBenchmark20kListedPositionMembers() async throws {
        let count = 20_000

        // Bulk insert 20,000 books with relationships
        for chunk in stride(from: 1, through: count, by: 500) {
            let end = min(chunk + 499, count)
            let ids = Array(chunk...end)

            let bookTagsPlaceholders = ids.map {
                "(\($0), 'Target Ship', 'relationship')"
            }.joined(separator: ", ")
            try await metaDB.run("""
                INSERT INTO book_tags (calibre_id, tag_name, tag_type)
                VALUES \(bookTagsPlaceholders)
            """)

            let metaPlaceholders = ids.map {
                "(\($0), '[\"Target Ship\", \"Other Ship\"]', '[\"Hero\"]', '[\"Fandom\"]', '[\"Tag\"]', '2024-01-01T00:00:00Z')"
            }.joined(separator: ", ")
            try await metaDB.run("""
                INSERT INTO ao3_metadata (calibre_id, relationships_json, characters_json, fandoms_json, additional_tags_json, extracted_at)
                VALUES \(metaPlaceholders)
            """)
        }

        // Warm up
        _ = await metaDB.listedPositionMembers(role: .relationship, terms: ["Target Ship"], limit: 1)

        var timings: [Double] = []
        for _ in 1...5 {
            let start = DispatchTime.now()
            let members = await metaDB.listedPositionMembers(role: .relationship, terms: ["Target Ship"], limit: 1)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
            timings.append(elapsedMs)
            XCTAssertEqual(members.count, count)
        }

        timings.sort()
        let p95 = timings[Int(Double(timings.count) * 0.95)]
        print("==> Benchmark 20k books listedPositionMembers p95: \(String(format: "%.2f", p95)) ms (timings: \(timings.map { String(format: "%.2f", $0) }))")
        XCTAssertLessThanOrEqual(p95, 100.0, "Performance gate: listedPositionMembers at 20k books <= 100ms")
    }

    // MARK: - Pass 3 Variant Matching Tests

    func testVariantsOffMatchesOnlyExact() async throws {
        let rec = makeRecord(relationships: ["Thor/Loki"])
        try await metaDB.insertBatch([(rec, 1)], diagnostics: [])

        let matchWithoutVariants = await metaDB.listedPositionMembers(
            role: .relationship,
            terms: ["Loki/Thor"],
            limit: 1,
            variants: false
        )
        XCTAssertTrue(matchWithoutVariants.isEmpty, "With variants off, reordered ship does not match")
    }

    func testVariantsOnMatchesReorderedAndSuffixed() async throws {
        let rec1 = makeRecord(relationships: ["Thor/Loki (Marvel)"])
        let rec2 = makeRecord(relationships: ["Loki x Thor"])
        try await metaDB.insertBatch([(rec1, 1), (rec2, 2)], diagnostics: [])

        let matchWithVariants = await metaDB.listedPositionMembers(
            role: .relationship,
            terms: ["Thor/Loki"],
            limit: 1,
            variants: true
        )
        XCTAssertEqual(matchWithVariants, [1, 2], "Variants match reordered and suffixed forms")
    }

    func testVariantsUnionWithSeedSynonyms() async throws {
        let rec1 = makeRecord(relationships: ["Tony Stark/Steve Rogers"])
        let rec2 = makeRecord(relationships: ["Steve Rogers x Tony Stark"])
        try await metaDB.insertBatch([(rec1, 1), (rec2, 2)], diagnostics: [])

        // User typed "Iron Man/Captain America", which seed expanded to include "Tony Stark/Steve Rogers"
        let terms = ["Iron Man/Captain America", "Tony Stark/Steve Rogers"]
        let matches = await metaDB.listedPositionMembers(
            role: .relationship,
            terms: terms,
            limit: 1,
            variants: true
        )
        XCTAssertEqual(matches, [1, 2], "Variants union cleanly with seed synonym expansions")
    }

    func testVariantsDoNotCrossRoles() async throws {
        let rec1 = makeRecord(relationships: [], characters: ["Thor/Loki (Marvel)"])
        try await metaDB.insertBatch([(rec1, 1)], diagnostics: [])

        let matches = await metaDB.listedPositionMembers(
            role: .relationship,
            terms: ["Thor/Loki"],
            limit: 1,
            variants: true
        )
        XCTAssertTrue(matches.isEmpty, "Variants toggle never crosses between relationship and character roles")
    }

    // MARK: - Pass 4: Relationship Count Tests

    func testCountRawIsOne() async throws {
        let allIDs = await Self.library.allCalibreIDs()
        let id1 = allIDs[0]
        let id2 = allIDs[1]
        let rec1 = makeRecord(relationships: ["Thor/Loki"])
        let rec2 = makeRecord(relationships: ["Thor/Loki", "Steve/Tony"])
        try await metaDB.insertBatch([(rec1, id1), (rec2, id2)], diagnostics: [])

        var expr = FilterExpression()
        expr.groups[0].rules = [FilterRule(field: .relationshipCount, op: .equals, value: "1")]
        let res = await builder.matchingIDs(expression: expr)
        XCTAssertEqual(res.calibreIDs, [id1], "Raw count 1 matches only works with exactly one relationship")
    }

    func testCountIsNotExcludesNoDataBooks() async throws {
        let allIDs = await Self.library.allCalibreIDs()
        let id1 = allIDs[0]
        let id2 = allIDs[1]
        let id3 = allIDs[2]
        // id4 (e.g. allIDs[3]) has no AO3 row
        let rec1 = makeRecord(relationships: ["Thor/Loki"])
        let rec2 = makeRecord(relationships: ["Thor/Loki", "Steve/Tony"])
        let rec3 = makeRecord(relationships: [])
        try await metaDB.insertBatch([(rec1, id1), (rec2, id2), (rec3, id3)], diagnostics: [])

        var expr = FilterExpression()
        expr.groups[0].rules = [FilterRule(field: .relationshipCount, op: .notEquals, value: "1")]
        let res = await builder.matchingIDs(expression: expr)
        // Book 2 has count 2 != 1 and has AO3 data.
        // Book 1 has count 1 == 1.
        // Book 3 has empty array (no data).
        // Book 4 (no AO3 row).
        XCTAssertEqual(res.calibreIDs, [id2], "Decision 4: relationshipCount 'is not' excludes empty arrays and missing AO3 data")
    }

    func testCountValueZeroIsIncomplete() {
        let rule0 = FilterRule(field: .relationshipCount, op: .equals, value: "0")
        XCTAssertFalse(rule0.isComplete, "Count 0 must be incomplete per decision 8")

        let ruleNeg = FilterRule(field: .relationshipCount, op: .equals, value: "-2")
        XCTAssertFalse(ruleNeg.isComplete, "Negative count must be incomplete")

        let ruleText = FilterRule(field: .relationshipCount, op: .equals, value: "abc")
        XCTAssertFalse(ruleText.isComplete, "Non-integer count must be incomplete")

        let rule1 = FilterRule(field: .relationshipCount, op: .equals, value: "1")
        XCTAssertTrue(rule1.isComplete, "Count >= 1 is complete")
    }

    func testCountVariantsMergeSynonymEntries() async throws {
        let allIDs = await Self.library.allCalibreIDs()
        let id1 = allIDs[0]
        let id2 = allIDs[1]
        let rec1 = makeRecord(relationships: ["Thor/Loki", "Loki/Thor"])
        let rec2 = makeRecord(relationships: ["Thor/Loki", "Steve/Tony"])
        try await metaDB.insertBatch([(rec1, id1), (rec2, id2)], diagnostics: [])

        var rule = FilterRule(field: .relationshipCount, op: .equals, value: "1")
        rule.matchVariants = true
        var expr = FilterExpression()
        expr.groups[0].rules = [rule]

        let res = await builder.matchingIDs(expression: expr)
        XCTAssertEqual(res.calibreIDs, [id1], "Variants on merges spelling variants of the same ship, resulting in count 1")
    }

    func testCountDuplicatesCountRawWhenVariantsOff() async throws {
        let allIDs = await Self.library.allCalibreIDs()
        let id1 = allIDs[0]
        let id2 = allIDs[1]
        let rec1 = makeRecord(relationships: ["Thor/Loki", "Loki/Thor"])
        let rec2 = makeRecord(relationships: ["Thor/Loki", "Steve/Tony"])
        try await metaDB.insertBatch([(rec1, id1), (rec2, id2)], diagnostics: [])

        var rule1 = FilterRule(field: .relationshipCount, op: .equals, value: "1")
        rule1.matchVariants = false
        var expr1 = FilterExpression()
        expr1.groups[0].rules = [rule1]
        let res1 = await builder.matchingIDs(expression: expr1)
        XCTAssertTrue(res1.calibreIDs.isEmpty, "With variants off, raw array length of 2 does not match count 1")

        var rule2 = FilterRule(field: .relationshipCount, op: .equals, value: "2")
        rule2.matchVariants = false
        var expr2 = FilterExpression()
        expr2.groups[0].rules = [rule2]
        let res2 = await builder.matchingIDs(expression: expr2)
        XCTAssertEqual(res2.calibreIDs, [id1, id2], "With variants off, both works have raw count 2")
    }

    func testCountVariantsRespectDedupeCap() async throws {
        let allIDs = await Self.library.allCalibreIDs()
        let id1 = allIDs[0]
        let rec1 = makeRecord(relationships: [
            "Thor/Loki", "Loki/Thor", "Thor/Loki (Marvel)",
            "Loki x Thor", "Thor x Loki", "Thor/Loki - Relationship",
            "Thor/Loki | MCU", "Thor/Loki (Avengers)", "Loki/Thor (Thor)"
        ]) // 9 entries, > cap of 8
        try await metaDB.insertBatch([(rec1, id1)], diagnostics: [])

        var rule1 = FilterRule(field: .relationshipCount, op: .equals, value: "1")
        rule1.matchVariants = true
        var expr1 = FilterExpression()
        expr1.groups[0].rules = [rule1]
        let res1 = await builder.matchingIDs(expression: expr1)
        XCTAssertTrue(res1.calibreIDs.isEmpty, "Works exceeding dedupe cap of 8 use raw length and do not deduplicate")

        var rule9 = FilterRule(field: .relationshipCount, op: .equals, value: "9")
        rule9.matchVariants = true
        var expr9 = FilterExpression()
        expr9.groups[0].rules = [rule9]
        let res9 = await builder.matchingIDs(expression: expr9)
        XCTAssertEqual(res9.calibreIDs, [id1], "Works exceeding cap match their raw count under variants")
    }

    func testCountComposesWithFirstRelationship() async throws {
        let allIDs = await Self.library.allCalibreIDs()
        let id1 = allIDs[0]
        let id2 = allIDs[1]
        let id3 = allIDs[2]
        let rec1 = makeRecord(relationships: ["Thor/Loki"])
        let rec2 = makeRecord(relationships: ["Thor/Loki", "Steve/Tony"])
        let rec3 = makeRecord(relationships: ["Steve/Tony"])
        try await metaDB.insertBatch([(rec1, id1), (rec2, id2), (rec3, id3)], diagnostics: [])

        var expr = FilterExpression()
        let shipRule = FilterRule(field: .firstRelationship, op: .equals, value: "Thor/Loki")
        let countRule = FilterRule(field: .relationshipCount, op: .equals, value: "1")
        expr.groups[0].rules = [shipRule, countRule]
        expr.groups[0].conjunction = .and

        let res = await builder.matchingIDs(expression: expr)
        XCTAssertEqual(res.calibreIDs, [id1], "First-listed relationship AND count 1 filters to 'only one ship, and it is X'")
    }

    func testTagRolesLookup() async throws {
        let rec = makeRecord(relationships: ["Thor/Loki"], characters: ["Thor"])
        try await metaDB.insertBatch([(rec, 1)], diagnostics: [])

        let rolesMap = await metaDB.tagRoles(for: ["Thor/Loki", "Thor", "Nonexistent"])
        XCTAssertEqual(rolesMap["Thor/Loki"], [.relationship])
        XCTAssertEqual(rolesMap["Thor"], [.character])
        XCTAssertNil(rolesMap["Nonexistent"])

        let singleRel = await metaDB.tagRoles(for: "Thor/Loki")
        XCTAssertEqual(singleRel, [.relationship])
    }
}
