import XCTest
@testable import LungfishApp

final class AlignmentFilterCommandBuilderTests: XCTestCase {
    func testMappedPrimaryDuplicateExcludedExactMatchBuildsFlagsAndExpression() throws {
        let request = AlignmentFilterRequest(
            sourceTrackID: "track-1",
            sourceTrackName: "Example",
            outputTrackName: "Example [filtered exact-match]",
            minimumMAPQ: 20,
            mappedOnly: true,
            primaryOnly: true,
            properPairsOnly: false,
            bothMatesMapped: false,
            duplicateMode: .excludeMarked,
            identityFilter: .exactMatchesOnly,
            regions: []
        )

        let plan = try AlignmentFilterCommandBuilder.build(
            request: request,
            inputBAMURL: URL(fileURLWithPath: "/tmp/in.bam"),
            outputBAMURL: URL(fileURLWithPath: "/tmp/out.filtered.bam")
        )

        XCTAssertEqual(plan.requiredTags, ["NM"])
        XCTAssertTrue(plan.arguments.contains("-q"))
        XCTAssertTrue(plan.arguments.contains("20"))
        XCTAssertTrue(plan.arguments.contains("-F"))
        XCTAssertTrue(plan.arguments.contains("3332"))
        XCTAssertTrue(plan.arguments.contains("-e"))
        XCTAssertTrue(plan.arguments.contains("exists([NM]) && [NM] == 0"))
        XCTAssertEqual(plan.summary, "MAPQ ≥ 20; mapped only; primary only; duplicate-marked reads excluded; exact matches only")
    }

    func testMinimumIdentityBuildsNMExpressionFromAlignedQueryBases() throws {
        let request = AlignmentFilterRequest(
            sourceTrackID: "track-1",
            sourceTrackName: "Example",
            outputTrackName: "Example [filtered id99]",
            minimumMAPQ: 0,
            mappedOnly: true,
            primaryOnly: false,
            properPairsOnly: false,
            bothMatesMapped: false,
            duplicateMode: .keepAll,
            identityFilter: .minimumPercent(99.0),
            regions: []
        )

        let plan = try AlignmentFilterCommandBuilder.build(
            request: request,
            inputBAMURL: URL(fileURLWithPath: "/tmp/in.bam"),
            outputBAMURL: URL(fileURLWithPath: "/tmp/out.filtered.bam")
        )

        XCTAssertEqual(plan.requiredTags, ["NM"])
        XCTAssertTrue(plan.arguments.contains("-e"))
        XCTAssertTrue(
            plan.arguments.contains("exists([NM]) && qlen > sclen && (((qlen-sclen)-[NM])/(qlen-sclen)) >= 0.99")
        )
        XCTAssertEqual(plan.summary, "mapped only; identity ≥ 99.0%")
    }
}
