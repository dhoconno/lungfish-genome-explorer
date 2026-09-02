import XCTest
@testable import LungfishWorkflow

final class ConsensusCoordinateMapTests: XCTestCase {
    func testIdentityWhenNoIndels() {
        let map = ConsensusCoordinateMap(indels: [])
        XCTAssertEqual(map.consensusPosition(forReference: 1), 1)
        XCTAssertEqual(map.consensusPosition(forReference: 29_903), 29_903)
    }

    func testPositionsBeforeAnIndelAreUnshifted() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 20_297, referenceLength: 4, alternateLength: 1)
        ])
        XCTAssertEqual(map.consensusPosition(forReference: 100), 100)
        XCTAssertEqual(map.consensusPosition(forReference: 20_297), 20_297)
    }

    // The real deletion from the reference dataset: AATT -> A at 20,297 removes
    // three bases, so everything after it shifts back by three.
    func testPositionsAfterADeletionShiftBack() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 20_297, referenceLength: 4, alternateLength: 1)
        ])
        XCTAssertEqual(map.consensusPosition(forReference: 20_301), 20_298)
        XCTAssertEqual(map.consensusPosition(forReference: 29_903), 29_900)
    }

    func testDeletedBasesHaveNoConsensusPosition() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 20_297, referenceLength: 4, alternateLength: 1)
        ])
        XCTAssertNil(map.consensusPosition(forReference: 20_298))
        XCTAssertNil(map.consensusPosition(forReference: 20_300))
    }

    func testInsertionShiftsForward() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 100, referenceLength: 1, alternateLength: 3)
        ])
        XCTAssertEqual(map.consensusPosition(forReference: 101), 103)
    }

    func testMultipleIndelsAccumulate() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 100, referenceLength: 4, alternateLength: 1),
            .init(position: 200, referenceLength: 4, alternateLength: 1),
        ])
        XCTAssertEqual(map.consensusPosition(forReference: 300), 294)
    }

    func testBuildsIndelsFromVCFLinesIgnoringSubstitutionsAndHeaders() {
        let lines = [
            "##fileformat=VCFv4.2",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO",
            "MN908947.3\t17373\t.\tC\tT\t.\tPASS\t.",
            "MN908947.3\t20297\t.\tAATT\tA\t.\tPASS\t.",
        ]

        let indels = ConsensusCoordinateMap.indels(fromVCFLines: lines)

        XCTAssertEqual(indels.count, 1, "a substitution is not an indel")
        XCTAssertEqual(indels.first?.position, 20_297)
        XCTAssertEqual(indels.first?.referenceLength, 4)
        XCTAssertEqual(indels.first?.alternateLength, 1)
    }

    // MARK: - Multi-allelic records

    // ALT[0] is not authoritative for a multi-allelic site: bcftools consensus
    // picks the allele the genotype names. Guessing the first one silently
    // shifts every downstream position by the wrong amount, so a site whose
    // allele cannot be determined is excluded rather than guessed.
    func testMultiAllelicSiteWithoutAGenotypeIsExcluded() {
        let lines = ["MN908947.3\t500\t.\tAAA\tA,AA\t.\tPASS\t."]
        XCTAssertTrue(ConsensusCoordinateMap.indels(fromVCFLines: lines).isEmpty)
    }

    func testMultiAllelicSiteUsesTheAlleleTheGenotypeNames() {
        let lines = [
            "MN908947.3\t500\t.\tAAA\tA,AA\t.\tPASS\t.\tGT\t2",
        ]
        let indels = ConsensusCoordinateMap.indels(fromVCFLines: lines)
        XCTAssertEqual(indels.count, 1)
        XCTAssertEqual(indels.first?.alternateLength, 2, "GT 2 names the second ALT, AA")
    }

    func testMultiAllelicDiploidGenotypeIsUsedWhenBothAllelesAgree() {
        let lines = [
            "MN908947.3\t500\t.\tAAA\tA,AA\t.\tPASS\t.\tGT\t1/1",
        ]
        let indels = ConsensusCoordinateMap.indels(fromVCFLines: lines)
        XCTAssertEqual(indels.first?.alternateLength, 1)
    }

    func testGenotypeNamingTheReferenceAlleleContributesNoIndel() {
        let lines = ["MN908947.3\t500\t.\tAAA\tA,AA\t.\tPASS\t.\tGT\t0"]
        XCTAssertTrue(ConsensusCoordinateMap.indels(fromVCFLines: lines).isEmpty)
    }

    // A single-ALT record is unambiguous, so it needs no genotype.
    func testSingleAlternateNeedsNoGenotype() {
        let lines = ["MN908947.3\t20297\t.\tAATT\tA\t.\tPASS\t."]
        XCTAssertEqual(ConsensusCoordinateMap.indels(fromVCFLines: lines).count, 1)
    }

    // MARK: - FILTER

    // bcftools consensus applies only records that pass the filter, so counting
    // a failing record shifts the map against a consensus that never moved.
    func testFilteredOutRecordsAreNotApplied() {
        let lines = [
            "MN908947.3\t20297\t.\tAATT\tA\t.\tft\t.",
            "MN908947.3\t20400\t.\tGGG\tG\t.\tLowQual;ft\t.",
        ]
        XCTAssertTrue(ConsensusCoordinateMap.indels(fromVCFLines: lines).isEmpty)
    }

    func testPassAndMissingFilterRecordsAreApplied() {
        let lines = [
            "MN908947.3\t100\t.\tAATT\tA\t.\tPASS\t.",
            "MN908947.3\t200\t.\tGGGG\tG\t.\t.\t.",
        ]
        XCTAssertEqual(ConsensusCoordinateMap.indels(fromVCFLines: lines).count, 2)
    }

    // MARK: - Overlapping indels

    // Two deletions covering the same reference bases cannot both be applied:
    // bcftools skips a record overlapping one it already applied. Counting both
    // double-subtracts and drags every downstream position out of place.
    func testOverlappingDeletionsAreNotDoubleCounted() {
        let map = ConsensusCoordinateMap(indels: [
            // Deletes 101...103.
            .init(position: 100, referenceLength: 4, alternateLength: 1),
            // Overlaps the first; bcftools would skip it.
            .init(position: 102, referenceLength: 4, alternateLength: 1),
        ])

        // Only the first deletion applies, so the shift is -3, not -6.
        XCTAssertEqual(map.consensusPosition(forReference: 200), 197)
    }

    func testTheEarlierOverlappingDeletionIsTheOneApplied() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 102, referenceLength: 4, alternateLength: 1),
            .init(position: 100, referenceLength: 4, alternateLength: 1),
        ])

        // 101 falls inside the applied deletion and has no consensus position.
        XCTAssertNil(map.consensusPosition(forReference: 101))
        // 104 was only covered by the skipped record, so it survives.
        XCTAssertEqual(map.consensusPosition(forReference: 104), 101)
    }

    func testAdjacentNonOverlappingDeletionsBothApply() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 100, referenceLength: 4, alternateLength: 1),
            .init(position: 104, referenceLength: 4, alternateLength: 1),
        ])
        XCTAssertEqual(map.consensusPosition(forReference: 200), 194)
    }

    // Insertions consume only the anchor base, so two at distinct positions
    // never overlap and both apply.
    func testInsertionsAtDistinctPositionsBothApply() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 100, referenceLength: 1, alternateLength: 3),
            .init(position: 101, referenceLength: 1, alternateLength: 3),
        ])
        XCTAssertEqual(map.consensusPosition(forReference: 200), 204)
    }
}
