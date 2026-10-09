import XCTest
@testable import LungfishIO

/// Decision D2 of the Phase 2.3 follow-up. The partners a tied call shares
/// its reads with are the members of its tie list that are calls of the same
/// animal.
final class ONTGenotypeCallSharedReadPartnersTests: XCTestCase {
    func testATiedCallNamesItsPartnersInTheListsOrder() {
        let tie = ["Mamu-A1*001:03", "Mamu-A1*001:01", "Mamu-A1*001:02"]
        let calls = tie.map { call("S1", $0, ambiguousWith: tie) } + [call("S1", "Mamu-A1*002:01")]

        XCTAssertEqual(calls[1].sharedReadPartners(in: calls), ["Mamu-A1*001:03", "Mamu-A1*001:02"])
        XCTAssertEqual(calls[0].sharedReadPartners(in: calls), ["Mamu-A1*001:01", "Mamu-A1*001:02"])
        XCTAssertEqual(calls[3].sharedReadPartners(in: calls), [], "an ordinary call shares reads with nothing")
    }

    func testOnlyCallsOfTheSameAnimalArePartners() {
        let tie = ["Mamu-A1*001:01", "Mamu-A1*001:02"]
        let calls = [
            call("S1", tie[0], ambiguousWith: tie),
            call("S2", tie[1]),
            call("S2", tie[0], ambiguousWith: tie),
            call("S2", tie[1], ambiguousWith: tie),
        ]

        XCTAssertEqual(calls[0].sharedReadPartners(in: calls), [], "S1 has no call of the partner, only S2 does")
        XCTAssertEqual(calls[2].sharedReadPartners(in: calls), [tie[1]])
        XCTAssertEqual(calls[2].sharedReadPartners(in: calls.filter { $0.sample == "S2" }), [tie[1]])
    }

    func testAnAmpliconGroupWhoseAliasesAreNotCallsHasNoPartners() {
        let group = call("S1", "MHC_001g1", ambiguousWith: ["MHC_001g1", "MHC_002g2", "MHC_003g3"])
        let calls = [group, call("S1", "MHC_004g4")]

        XCTAssertEqual(group.sharedReadPartners(in: calls), [])
    }

    private func call(_ sample: String, _ genotype: String, ambiguousWith: [String]? = nil) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: 100,
            passedUniqueReads: 100,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil,
            ambiguousWith: ambiguousWith
        )
    }
}
