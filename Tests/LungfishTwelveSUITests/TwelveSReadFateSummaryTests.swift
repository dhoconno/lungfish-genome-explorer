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
            "3 discordant pairs left out (1 pair with different targets, 2 pairs with one mate unresolved)"
        )
        XCTAssertTrue(
            TwelveSReadFateSummary.statusText(for: result)
                .hasSuffix("| 3 discordant pairs left out (1 pair with different targets, 2 pairs with one mate unresolved)")
        )
    }

    func testOneLeftOutPairReadsAsSingular() {
        let result = TwelveSFixtures.twoSampleResult(
            discordantPairs: 1,
            discordantPairsByReason: ["one_mate_ambiguous": 1]
        )

        XCTAssertEqual(
            TwelveSReadFateSummary.leftOutText(for: result.readFate),
            "1 discordant pair left out (1 pair with one mate ambiguous)"
        )
    }

    func testAnUnknownReasonStillShows() {
        let result = TwelveSFixtures.twoSampleResult(
            discordantPairs: 2,
            discordantPairsByReason: ["different_targets": 1, "some_future_reason": 1]
        )

        XCTAssertEqual(
            TwelveSReadFateSummary.leftOutText(for: result.readFate),
            "2 discordant pairs left out (1 pair with different targets, 1 pair with some future reason)"
        )
    }

    func testControllerSummaryShowsTheLeftOutPairs() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()

        controller.configure(result: TwelveSFixtures.twoSampleResult(
            discordantPairs: 2,
            discordantPairsByReason: ["different_targets": 1, "one_mate_unresolved": 1],
            pairedFragments: 4
        ))

        XCTAssertEqual(
            controller.summaryTextForTesting,
            "2 samples | 65 exact fragments | 35.0% unresolved | 1 chimera candidate | "
                + "2 discordant pairs left out (1 pair with different targets, 1 pair with one mate unresolved)"
        )
    }

    // MARK: - The unit the counts are named in (review B, N1)

    func testTheCountUnitFollowsThePairsTheRunRead() {
        let mergedOnly = TwelveSCountUnit(readFate: TwelveSFixtures.twoSampleResult().readFate)
        let paired = TwelveSCountUnit(readFate: TwelveSFixtures.twoSampleResult(pairedFragments: 4).readFate)

        XCTAssertEqual(mergedOnly, .reads)
        XCTAssertEqual(paired, .fragments)
        XCTAssertEqual([mergedOnly.exactTitle, paired.exactTitle], ["Exact Reads", "Exact Fragments"])
        XCTAssertEqual([mergedOnly.title, paired.title], ["Reads", "Fragments"])
        XCTAssertEqual([paired.noun(for: 1), paired.noun(for: 2)], ["fragment", "fragments"])
        XCTAssertEqual([mergedOnly.noun(for: 1), mergedOnly.noun(for: 2)], ["read", "reads"])
    }

    func testAPairedResultNamesItsCountsInFragments() {
        XCTAssertEqual(
            TwelveSReadFateSummary.statusText(for: TwelveSFixtures.twoSampleResult(pairedFragments: 4)),
            "2 samples | 65 exact fragments | 35.0% unresolved | 1 chimera candidate"
        )
        XCTAssertEqual(
            TwelveSReadFateSummary.statusText(for: TwelveSFixtures.twoSampleResult()),
            "2 samples | 65 exact reads | 35.0% unresolved | 1 chimera candidate",
            "a merged-only result reads as before"
        )
    }

    func testControllerNamesFragmentsInItsColumnsAndDetailWhenTheRunReadPairs() throws {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        var emitted: TwelveSDetailPayload?
        controller.onSelectedRowDetailChanged = { emitted = $0 }

        controller.configure(result: TwelveSFixtures.twoSampleResult(pairedFragments: 4))

        let exact = try XCTUnwrap(controller.testingActiveTableView.tableColumn(withIdentifier: .init("totalExactReads")))
        XCTAssertEqual(exact.title, "Exact Fragments")
        XCTAssertEqual(exact.headerCell.stringValue, "Exact Fragments", "the header the user and VoiceOver read")
        XCTAssertEqual(exact.headerToolTip, TwelveSCountUnit.fragments.columnHelp)
        controller.selectTargetForTesting(row: 0)
        XCTAssertEqual(emitted?.countUnit, .fragments, "the Inspector names the selection's counts in fragments")

        controller.showUnresolvedForTesting()
        let count = try XCTUnwrap(controller.testingActiveTableView.tableColumn(withIdentifier: .init("readCount")))
        XCTAssertEqual(count.title, "Fragments")
        XCTAssertEqual(count.headerToolTip, TwelveSCountUnit.fragments.columnHelp)
    }

    func testControllerKeepsReadsForAMergedOnlyResult() throws {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        var emitted: TwelveSDetailPayload?
        controller.onSelectedRowDetailChanged = { emitted = $0 }

        controller.configure(result: TwelveSFixtures.twoSampleResult())

        let exact = try XCTUnwrap(controller.testingActiveTableView.tableColumn(withIdentifier: .init("totalExactReads")))
        XCTAssertEqual(exact.title, "Exact Reads")
        XCTAssertEqual(exact.headerToolTip, "Read count in reads.")
        controller.selectTargetForTesting(row: 0)
        XCTAssertEqual(emitted?.countUnit, .reads)
        controller.showUnresolvedForTesting()
        XCTAssertEqual(controller.testingActiveTableView.tableColumn(withIdentifier: .init("readCount"))?.title, "Reads")
    }

    /// Sorting and choosing samples run the table's filter pass again, which
    /// puts back the title each column had at the first pass, so that title
    /// must already name fragments.
    func testLaterFilterPassesKeepTheFragmentsTitle() throws {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        controller.configure(result: TwelveSFixtures.twoSampleResult(pairedFragments: 4))
        let exact = try XCTUnwrap(controller.testingActiveTableView.tableColumn(withIdentifier: .init("totalExactReads")))

        controller.testingSetTargetSort(key: "totalExactReads", ascending: true)
        controller.testingSetSelectedSamples(["SampleA"])

        XCTAssertEqual(exact.title, "Exact Fragments")
        XCTAssertEqual(exact.headerToolTip, TwelveSCountUnit.fragments.columnHelp)
    }
}
