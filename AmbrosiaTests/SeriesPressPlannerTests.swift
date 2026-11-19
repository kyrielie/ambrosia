import XCTest
@testable import Ambrosia

final class SeriesPressPlannerTests: XCTestCase {
    func testFlagWithExclusionsCompletesBeforeClearing() {
        XCTAssertEqual(SeriesPressPlanner.plan(flagIsSet: true, exclusions: [2], displayedMemberIDs: [1, 2],
                                               effectiveIDs: [1], explicitIDs: []).actions, [.clearExclusions])
        XCTAssertEqual(SeriesPressPlanner.plan(flagIsSet: true, exclusions: [], displayedMemberIDs: [1, 2],
                                               effectiveIDs: [1, 2], explicitIDs: []).actions, [.clearFlag])
    }

    func testAllExplicitClearsOnlyExplicitMembers() {
        let plan = SeriesPressPlanner.plan(flagIsSet: false, exclusions: [], displayedMemberIDs: [1, 2],
                                           effectiveIDs: [1, 2], explicitIDs: [1, 2])
        XCTAssertEqual(plan.actions, [.clearExplicit([1, 2])])
    }

    func testAllCoveredWithNoExplicitFlagsDoesNotMutateOtherSeries() {
        let plan = SeriesPressPlanner.plan(flagIsSet: false, exclusions: [], displayedMemberIDs: [1, 2],
                                           effectiveIDs: [1, 2], explicitIDs: [],
                                           coveringSeriesByMember: [1: "Series B", 2: "Series B"])
        XCTAssertTrue(plan.actions.isEmpty)
        XCTAssertEqual(plan.coveringSeriesName, "Series B")
    }

    func testPartialExplicitMembershipSetsSeriesFlag() {
        XCTAssertEqual(SeriesPressPlanner.plan(flagIsSet: false, exclusions: [], displayedMemberIDs: [1, 2],
                                               effectiveIDs: [1], explicitIDs: [1]).actions, [.setFlag])
    }
}
