import XCTest
@testable import LungfishWorkflow

final class TwelveSAbundanceReassignerTests: XCTestCase {

    private let speciesForTarget = ["tH": "human", "tP": "pan"]
    private let canonicalForSpecies = ["human": "tH", "pan": "tP"]

    func testHumanWinsStrictPlurality() {
        let result = TwelveSAbundanceReassigner.reassign(
            ambiguousCandidates: ["S": ["tH", "tP"]],
            unresolvedCounts: ["S": ["SampleA": 7]],
            countsByTarget: ["tH": ["SampleA": 1000]],
            speciesForTarget: speciesForTarget,
            canonicalTargetForSpecies: canonicalForSpecies
        )
        XCTAssertEqual(result.countsByTarget["tH"]?["SampleA"], 1007)
        XCTAssertNil(result.unresolvedCounts["S"])
        XCTAssertEqual(result.moves.count, 1)
        XCTAssertEqual(result.moves.first?.toSpecies, "human")
        XCTAssertEqual(result.moves.first?.reads, 7)
    }

    func testNonzeroLeadWinsEvenWhenRunnerUpNonzero() {
        // human 1000 vs pan 3 → human (any nonzero lead wins).
        let result = TwelveSAbundanceReassigner.reassign(
            ambiguousCandidates: ["S": ["tH", "tP"]],
            unresolvedCounts: ["S": ["SampleA": 5]],
            countsByTarget: ["tH": ["SampleA": 1000], "tP": ["SampleA": 3]],
            speciesForTarget: speciesForTarget,
            canonicalTargetForSpecies: canonicalForSpecies
        )
        XCTAssertEqual(result.countsByTarget["tH"]?["SampleA"], 1005)
        XCTAssertNil(result.unresolvedCounts["S"])
    }

    func testExactTieStaysAmbiguous() {
        let result = TwelveSAbundanceReassigner.reassign(
            ambiguousCandidates: ["S": ["tH", "tP"]],
            unresolvedCounts: ["S": ["SampleA": 7]],
            countsByTarget: ["tH": ["SampleA": 500], "tP": ["SampleA": 500]],
            speciesForTarget: speciesForTarget,
            canonicalTargetForSpecies: canonicalForSpecies
        )
        XCTAssertEqual(result.unresolvedCounts["S"]?["SampleA"], 7)
        XCTAssertTrue(result.moves.isEmpty)
    }

    func testAllZeroStaysAmbiguous() {
        let result = TwelveSAbundanceReassigner.reassign(
            ambiguousCandidates: ["S": ["tH", "tP"]],
            unresolvedCounts: ["S": ["SampleA": 7]],
            countsByTarget: [:],
            speciesForTarget: speciesForTarget,
            canonicalTargetForSpecies: canonicalForSpecies
        )
        XCTAssertEqual(result.unresolvedCounts["S"]?["SampleA"], 7)
        XCTAssertTrue(result.moves.isEmpty)
    }

    func testReadConservation() {
        let result = TwelveSAbundanceReassigner.reassign(
            ambiguousCandidates: ["S": ["tH", "tP"]],
            unresolvedCounts: ["S": ["SampleA": 7, "SampleB": 3]],
            countsByTarget: ["tH": ["SampleA": 10]],
            speciesForTarget: speciesForTarget,
            canonicalTargetForSpecies: canonicalForSpecies
        )
        let totalIn = 7 + 3 + 10
        let totalOut = result.countsByTarget.values.flatMap { $0.values }.reduce(0, +)
                     + result.unresolvedCounts.values.flatMap { $0.values }.reduce(0, +)
        XCTAssertEqual(totalIn, totalOut)
        // reads landed per-sample on the winner
        XCTAssertEqual(result.countsByTarget["tH"]?["SampleA"], 17)
        XCTAssertEqual(result.countsByTarget["tH"]?["SampleB"], 3)
    }

    func testSingleCandidateSpeciesIsNotTouchedHere() {
        // If both candidate targets are the same species, there is no cross-species
        // decision to make; reassigner leaves it (same-species collapse is the
        // classifier's job). With one species and a positive total, it still folds
        // into that species (harmless), but with zero totals it stays.
        let result = TwelveSAbundanceReassigner.reassign(
            ambiguousCandidates: ["S": ["tH", "tH2"]],
            unresolvedCounts: ["S": ["SampleA": 4]],
            countsByTarget: [:],
            speciesForTarget: ["tH": "human", "tH2": "human"],
            canonicalTargetForSpecies: ["human": "tH"]
        )
        XCTAssertEqual(result.unresolvedCounts["S"]?["SampleA"], 4)
        XCTAssertTrue(result.moves.isEmpty)
    }
}
