import XCTest
@testable import LungfishWorkflow

final class TwelveSAbundanceReassignerTests: XCTestCase {

    private let speciesForTarget = ["tH": "human", "tP": "pan"]
    private let canonicalForSpecies = ["human": "tH", "pan": "tP"]

    private func reassign(
        ambiguous: [String: [String]],
        unresolved: [String: [String: Int]],
        counts: [String: [String: Int]],
        policy: TwelveSAbundanceReassigner.ResolutionPolicy = .anyNonzeroLead,
        species: [String: String]? = nil,
        canonical: [String: String]? = nil
    ) -> TwelveSAbundanceReassigner.Result {
        TwelveSAbundanceReassigner.reassign(
            ambiguousCandidates: ambiguous,
            unresolvedCounts: unresolved,
            countsByTarget: counts,
            speciesForTarget: species ?? speciesForTarget,
            canonicalTargetForSpecies: canonical ?? canonicalForSpecies,
            policy: policy
        )
    }

    // MARK: - Per-sample resolution (the key fix)

    func testPerSampleWinnerDiffersFromGlobal() {
        // X abundant in A, Y abundant in B. Ambiguous seq S in both samples.
        // Per-sample: A's reads → X, B's reads → Y (global pooling would send both to X).
        let result = reassign(
            ambiguous: ["S": ["tX", "tY"]],
            unresolved: ["S": ["A": 100, "B": 100]],
            counts: ["tX": ["A": 5000], "tY": ["B": 800]],
            species: ["tX": "x", "tY": "y"],
            canonical: ["x": "tX", "y": "tY"]
        )
        XCTAssertEqual(result.countsByTarget["tX"]?["A"], 5100)
        XCTAssertEqual(result.countsByTarget["tY"]?["B"], 900)
        // S fully consumed across both samples
        XCTAssertNil(result.unresolvedCounts["S"]?["A"])
        XCTAssertNil(result.unresolvedCounts["S"]?["B"])
        XCTAssertEqual(Set(result.moves.map(\.decidedBy)), [.perSample])
    }

    func testHumanWinsPerSampleAnyNonzeroLead() {
        let result = reassign(
            ambiguous: ["S": ["tH", "tP"]],
            unresolved: ["S": ["A": 7]],
            counts: ["tH": ["A": 1000]]
        )
        XCTAssertEqual(result.countsByTarget["tH"]?["A"], 1007)
        XCTAssertNil(result.unresolvedCounts["S"])
        XCTAssertEqual(result.moves.first?.toSpecies, "human")
        XCTAssertEqual(result.moves.first?.sample, "A")
    }

    func testPooledFallbackBlockedWhenGlobalWinnerAbsentLocally() {
        // Sample B has no local unambiguous evidence for any candidate.
        // Global winner is X (abundant in A). But X has 0 in B → do NOT import X into B.
        let result = reassign(
            ambiguous: ["S": ["tX", "tY"]],
            unresolved: ["S": ["B": 50]],
            counts: ["tX": ["A": 5000]], // nothing in B for either candidate
            species: ["tX": "x", "tY": "y"],
            canonical: ["x": "tX", "y": "tY"]
        )
        // unchanged: stays unresolved in B
        XCTAssertEqual(result.unresolvedCounts["S"]?["B"], 50)
        XCTAssertTrue(result.moves.isEmpty)
    }

    func testExactTieStaysUnassigned() {
        let result = reassign(
            ambiguous: ["S": ["tH", "tP"]],
            unresolved: ["S": ["A": 7]],
            counts: ["tH": ["A": 500], "tP": ["A": 500]]
        )
        XCTAssertEqual(result.unresolvedCounts["S"]?["A"], 7)
        XCTAssertTrue(result.moves.isEmpty)
    }

    func testAllZeroStaysUnassigned() {
        let result = reassign(
            ambiguous: ["S": ["tH", "tP"]],
            unresolved: ["S": ["A": 7]],
            counts: [:]
        )
        XCTAssertEqual(result.unresolvedCounts["S"]?["A"], 7)
        XCTAssertTrue(result.moves.isEmpty)
    }

    func testSingleCandidateSpeciesNotTouched() {
        let result = reassign(
            ambiguous: ["S": ["tH", "tH2"]],
            unresolved: ["S": ["A": 4]],
            counts: ["tH": ["A": 10]],
            species: ["tH": "human", "tH2": "human"],
            canonical: ["human": "tH"]
        )
        XCTAssertEqual(result.unresolvedCounts["S"]?["A"], 4)
        XCTAssertTrue(result.moves.isEmpty)
    }

    // MARK: - Conservative profile

    func testConservativeLeavesLowMarginUnresolvedButAnyLeadResolves() {
        let ambiguous = ["S": ["tH", "tP"]]
        let unresolved = ["S": ["A": 5]]
        let counts = ["tH": ["A": 4], "tP": ["A": 3]] // 4 vs 3: not 2x, below floor 10

        let lenient = reassign(ambiguous: ambiguous, unresolved: unresolved, counts: counts,
                               policy: .anyNonzeroLead)
        XCTAssertEqual(lenient.countsByTarget["tH"]?["A"], 9) // 4 + 5 moved

        let conservative = reassign(ambiguous: ambiguous, unresolved: unresolved, counts: counts,
                                    policy: .conservative(minFoldRatio: 2.0, absoluteFloor: 10))
        XCTAssertEqual(conservative.unresolvedCounts["S"]?["A"], 5) // unresolved: fails floor + ratio
        XCTAssertTrue(conservative.moves.isEmpty)
    }

    func testConservativeResolvesClearWinner() {
        // human 1000 vs pan 3: passes floor(>=10) and ratio(>=2x).
        let result = reassign(
            ambiguous: ["S": ["tH", "tP"]],
            unresolved: ["S": ["A": 5]],
            counts: ["tH": ["A": 1000], "tP": ["A": 3]],
            policy: .conservative(minFoldRatio: 2.0, absoluteFloor: 10)
        )
        XCTAssertEqual(result.countsByTarget["tH"]?["A"], 1005)
        XCTAssertNil(result.unresolvedCounts["S"])
    }

    // MARK: - Conservation

    func testReadConservationAcrossSamples() {
        let result = reassign(
            ambiguous: ["S": ["tH", "tP"]],
            unresolved: ["S": ["A": 7, "B": 3]],
            counts: ["tH": ["A": 10, "B": 20]]
        )
        let totalIn = 7 + 3 + 10 + 20
        let totalOut = result.countsByTarget.values.flatMap { $0.values }.reduce(0, +)
                     + result.unresolvedCounts.values.flatMap { $0.values }.reduce(0, +)
        XCTAssertEqual(totalIn, totalOut)
    }
}
