import Foundation
@testable import LungfishWorkflow
import XCTest

/// The join table of docs/design L4. A pair is concordant only when both
/// mates give the identical call.
final class TwelveSFragmentCallTests: XCTestCase {

    private let human = TwelveSReadClassification.exact(targetID: "human", indelCount: 0)
    private let humanWithIndel = TwelveSReadClassification.exact(targetID: "human", indelCount: 2)
    private let dog = TwelveSReadClassification.exact(targetID: "dog", indelCount: 0)
    private let humanOrPan = TwelveSReadClassification.ambiguous(targetIDs: ["human", "pan"])
    private let panOrHuman = TwelveSReadClassification.ambiguous(targetIDs: ["pan", "human"])
    private let humanOrPanOrGorilla = TwelveSReadClassification.ambiguous(targetIDs: ["gorilla", "human", "pan"])

    func testIdenticalExactTargetsAreConcordantWhateverTheIndelCount() {
        XCTAssertEqual(TwelveSFragmentCall.join(r1: human, r2: human), .concordant(human))
        XCTAssertEqual(TwelveSFragmentCall.join(r1: human, r2: humanWithIndel), .concordant(human))
    }

    func testDifferentExactTargetsAreDiscordant() {
        XCTAssertEqual(TwelveSFragmentCall.join(r1: human, r2: dog), .discordant(.differentTargets))
        XCTAssertEqual(TwelveSFragmentCall.join(r1: dog, r2: human), .discordant(.differentTargets))
    }

    func testIdenticalCandidateSetsAreConcordantInAnyOrder() {
        XCTAssertEqual(
            TwelveSFragmentCall.join(r1: humanOrPan, r2: panOrHuman),
            .concordant(.ambiguous(targetIDs: ["human", "pan"]))
        )
    }

    func testDifferentCandidateSetsAreDiscordant() {
        XCTAssertEqual(
            TwelveSFragmentCall.join(r1: humanOrPan, r2: humanOrPanOrGorilla),
            .discordant(.differentCandidates)
        )
    }

    func testBothMatesUnresolvedIsAConcordantUnresolvedFragment() {
        XCTAssertEqual(TwelveSFragmentCall.join(r1: .unresolved, r2: .unresolved), .concordant(.unresolved))
    }

    func testOneMateUnresolvedIsDiscordant() {
        XCTAssertEqual(TwelveSFragmentCall.join(r1: human, r2: .unresolved), .discordant(.oneMateUnresolved))
        XCTAssertEqual(TwelveSFragmentCall.join(r1: .unresolved, r2: human), .discordant(.oneMateUnresolved))
        XCTAssertEqual(TwelveSFragmentCall.join(r1: humanOrPan, r2: .unresolved), .discordant(.oneMateUnresolved))
        XCTAssertEqual(TwelveSFragmentCall.join(r1: .unresolved, r2: humanOrPan), .discordant(.oneMateUnresolved))
    }

    func testExactBesideAmbiguousIsDiscordantEvenWhenTheTargetIsACandidate() {
        XCTAssertEqual(TwelveSFragmentCall.join(r1: human, r2: humanOrPan), .discordant(.oneMateAmbiguous))
        XCTAssertEqual(TwelveSFragmentCall.join(r1: humanOrPan, r2: human), .discordant(.oneMateAmbiguous))
    }

    func testReasonsHaveStableRawValuesAndNames() {
        XCTAssertEqual(
            TwelveSPairDiscordance.allCases.map(\.rawValue),
            ["different_targets", "different_candidates", "one_mate_unresolved", "one_mate_ambiguous"]
        )
        XCTAssertEqual(
            TwelveSPairDiscordance.allCases.map(\.displayName),
            ["different targets", "different candidates", "one mate unresolved", "one mate ambiguous"]
        )
    }

    func testFragmentSummaryNamesCountsAndReasons() {
        XCTAssertEqual(
            TwelveSAmpliconMatchingWorkflow.fragmentSummary(singleReads: 4, pairs: 0, discordantByReason: [:]),
            "Counted 4 fragments, all merged or single reads."
        )
        XCTAssertEqual(
            TwelveSAmpliconMatchingWorkflow.fragmentSummary(
                singleReads: 4, pairs: 4,
                discordantByReason: [.oneMateUnresolved: 1, .differentTargets: 1]
            ),
            "Counted 8 fragments, 4 merged or single reads and 4 pairs. "
                + "Left out 2 discordant pairs (1 pair with different targets, 1 pair with one mate unresolved)."
        )
        XCTAssertEqual(
            TwelveSAmpliconMatchingWorkflow.fragmentSummary(singleReads: 0, pairs: 3, discordantByReason: [.oneMateAmbiguous: 1]),
            "Counted 3 fragments, 0 merged or single reads and 3 pairs. Left out 1 discordant pair (1 pair with one mate ambiguous)."
        )
        XCTAssertEqual(
            TwelveSAmpliconMatchingWorkflow.fragmentSummary(singleReads: 0, pairs: 5, discordantByReason: [.differentCandidates: 2]),
            "Counted 5 fragments, 0 merged or single reads and 5 pairs. Left out 2 discordant pairs (2 pairs with different candidates).",
            "each reason names its pairs in the number they take (review B, N1)"
        )
    }

    /// A count of 1 names one fragment, one read or one pair, on the CLI's
    /// stderr and in the Operations panel alike (re-review 2 follow-up).
    func testFragmentSummarySaysOneFragmentAndOnePairForACountOfOne() {
        XCTAssertEqual(
            TwelveSAmpliconMatchingWorkflow.fragmentSummary(singleReads: 1, pairs: 0, discordantByReason: [:]),
            "Counted 1 fragment, a merged or single read."
        )
        XCTAssertEqual(
            TwelveSAmpliconMatchingWorkflow.fragmentSummary(singleReads: 0, pairs: 1, discordantByReason: [:]),
            "Counted 1 fragment, 0 merged or single reads and 1 pair."
        )
        XCTAssertEqual(
            TwelveSAmpliconMatchingWorkflow.fragmentSummary(singleReads: 1, pairs: 1, discordantByReason: [.differentTargets: 1]),
            "Counted 2 fragments, 1 merged or single read and 1 pair. Left out 1 discordant pair (1 pair with different targets)."
        )
    }
}
