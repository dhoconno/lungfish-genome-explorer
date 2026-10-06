import AppKit
@testable import LungfishIO
@testable import LungfishTwelveSUI
import XCTest

/// The viewport states the pairs a run left out, with their reasons, beside
/// the exact and unresolved figures (Phase 2.1 lane L4).
@MainActor
final class TwelveSReadFateSummaryTests: XCTestCase {

    func testNothingIsSaidWhenNoPairWasLeftOut() {
        let result = TwelveSFixtures.twoSampleResult()

        XCTAssertNil(TwelveSReadFateSummary.leftOutText(for: result.readFate))
        XCTAssertEqual(
            TwelveSReadFateSummary.statusText(for: result),
            "2 samples | 65 exact reads | 35.0% unresolved | 1 chimera candidate"
        )
    }

    func testLeftOutPairsAreNamedWithTheirReasonsInOrder() {
        let result = TwelveSFixtures.twoSampleResult(
            discordantPairs: 3,
            discordantPairsByReason: ["one_mate_unresolved": 2, "different_targets": 1]
        )

        XCTAssertEqual(
            TwelveSReadFateSummary.leftOutText(for: result.readFate),
            "3 discordant pairs left out (1 different targets, 2 one mate unresolved)"
        )
        XCTAssertTrue(
            TwelveSReadFateSummary.statusText(for: result)
                .hasSuffix("| 3 discordant pairs left out (1 different targets, 2 one mate unresolved)")
        )
    }

    func testOneLeftOutPairReadsAsSingular() {
        let result = TwelveSFixtures.twoSampleResult(
            discordantPairs: 1,
            discordantPairsByReason: ["one_mate_ambiguous": 1]
        )

        XCTAssertEqual(
            TwelveSReadFateSummary.leftOutText(for: result.readFate),
            "1 discordant pair left out (1 one mate ambiguous)"
        )
    }

    func testAnUnknownReasonStillShows() {
        let result = TwelveSFixtures.twoSampleResult(
            discordantPairs: 2,
            discordantPairsByReason: ["different_targets": 1, "some_future_reason": 1]
        )

        XCTAssertEqual(
            TwelveSReadFateSummary.leftOutText(for: result.readFate),
            "2 discordant pairs left out (1 different targets, 1 some future reason)"
        )
    }

    func testControllerSummaryShowsTheLeftOutPairs() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()

        controller.configure(result: TwelveSFixtures.twoSampleResult(
            discordantPairs: 2,
            discordantPairsByReason: ["different_targets": 1, "one_mate_unresolved": 1]
        ))

        XCTAssertEqual(
            controller.summaryTextForTesting,
            "2 samples | 65 exact reads | 35.0% unresolved | 1 chimera candidate | "
                + "2 discordant pairs left out (1 different targets, 1 one mate unresolved)"
        )
    }
}
