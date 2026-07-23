import XCTest
@testable import LungfishWorkflow

final class FullLengthONTMHCCDNAStructuralClassifierTests: XCTestCase {
    func testCohortBoundaryUsesIndividualStructuralSegments() throws {
        let nineteen = try FullLengthONTMHCCDNAStructuralClassifier.classifyCohort(
            referenceSequenceID: "cDNA",
            clusterID: "cluster",
            cDNAReferenceLength: 1_000,
            clusterLength: 1_019,
            targetStart: 1,
            isReverse: false,
            metrics: FullLengthONTMHCSAMMetrics(cigar: "500=19N500=", nm: 0)
        )
        let twenty = try FullLengthONTMHCCDNAStructuralClassifier.classifyCohort(
            referenceSequenceID: "cDNA",
            clusterID: "cluster",
            cDNAReferenceLength: 1_000,
            clusterLength: 1_020,
            targetStart: 1,
            isReverse: false,
            metrics: FullLengthONTMHCSAMMetrics(cigar: "500=20N500=", nm: 0)
        )

        XCTAssertEqual(nineteen.relationship, .known)
        XCTAssertEqual(twenty.relationship, .extension)
        XCTAssertEqual(twenty.largestClusterStructuralSegmentBases, 20)
    }

    func testReciprocalSoftClippedClusterSequenceIsExtensionEvidence() throws {
        let interpretation = try FullLengthONTMHCCDNAStructuralClassifier.classifyReciprocal(
            referenceSequenceID: "cDNA",
            clusterID: "cluster",
            cDNAReferenceLength: 1_000,
            clusterLength: 3_000,
            referenceStart: 1,
            isReverse: false,
            metrics: FullLengthONTMHCSAMMetrics(cigar: "1000=2000S", nm: 0)
        )

        XCTAssertEqual(interpretation.relationship, .extension)
        XCTAssertEqual(interpretation.cDNAReferenceCoverage, 1, accuracy: 0.000_001)
        XCTAssertEqual(interpretation.clusterCoverage, 1, accuracy: 0.000_001)
        XCTAssertEqual(interpretation.largestClusterStructuralSegmentBases, 2_000)
    }

    func testCohortHardClippedCDNAQueryIsIneligible() throws {
        let interpretation = try FullLengthONTMHCCDNAStructuralClassifier.classifyCohort(
            referenceSequenceID: "cDNA",
            clusterID: "cluster",
            cDNAReferenceLength: 1_000,
            clusterLength: 999,
            targetStart: 1,
            isReverse: false,
            metrics: FullLengthONTMHCSAMMetrics(cigar: "1H999=", nm: 0)
        )

        XCTAssertEqual(interpretation.relationship, .ineligible)
        XCTAssertEqual(interpretation.largestCDNADeficitSegmentBases, 1)
    }

    func testReciprocalLargeMissingCDNASegmentIsIneligible() throws {
        let interpretation = try FullLengthONTMHCCDNAStructuralClassifier.classifyReciprocal(
            referenceSequenceID: "cDNA",
            clusterID: "cluster",
            cDNAReferenceLength: 1_000,
            clusterLength: 980,
            referenceStart: 1,
            isReverse: false,
            metrics: FullLengthONTMHCSAMMetrics(cigar: "490=20D490=", nm: 20)
        )

        XCTAssertEqual(interpretation.relationship, .ineligible)
        XCTAssertEqual(interpretation.largestCDNADeficitSegmentBases, 20)
    }

    func testCohortDistributedSmallCDNADeficitsDoNotCountAsCoveredBases() throws {
        let interpretation = try FullLengthONTMHCCDNAStructuralClassifier.classifyCohort(
            referenceSequenceID: "cDNA",
            clusterID: "cluster",
            cDNAReferenceLength: 1_000,
            clusterLength: 940,
            targetStart: 1,
            isReverse: false,
            metrics: FullLengthONTMHCSAMMetrics(
                cigar: "100=10I100=10I100=10I100=10I100=10I100=10I340=",
                nm: 60
            )
        )

        XCTAssertEqual(interpretation.cDNAReferenceCoverage, 0.94, accuracy: 0.000_001)
        XCTAssertEqual(interpretation.largestCDNADeficitSegmentBases, 10)
        XCTAssertEqual(interpretation.relationship, .ineligible)
    }

    func testReciprocalDistributedSmallCDNADeficitsDoNotCountAsCoveredBases() throws {
        let interpretation = try FullLengthONTMHCCDNAStructuralClassifier.classifyReciprocal(
            referenceSequenceID: "cDNA",
            clusterID: "cluster",
            cDNAReferenceLength: 1_000,
            clusterLength: 940,
            referenceStart: 1,
            isReverse: false,
            metrics: FullLengthONTMHCSAMMetrics(
                cigar: "100=10D100=10D100=10D100=10D100=10D100=10D340=",
                nm: 60
            )
        )

        XCTAssertEqual(interpretation.cDNAReferenceCoverage, 0.94, accuracy: 0.000_001)
        XCTAssertEqual(interpretation.largestCDNADeficitSegmentBases, 10)
        XCTAssertEqual(interpretation.relationship, .ineligible)
    }

    func testOneBaseCDNADeficitsRemainEligibleKnownMatches() throws {
        let cohort = try FullLengthONTMHCCDNAStructuralClassifier.classifyCohort(
            referenceSequenceID: "cDNA",
            clusterID: "cluster",
            cDNAReferenceLength: 1_000,
            clusterLength: 999,
            targetStart: 1,
            isReverse: false,
            metrics: FullLengthONTMHCSAMMetrics(cigar: "500=1I499=", nm: 1)
        )
        let reciprocal = try FullLengthONTMHCCDNAStructuralClassifier.classifyReciprocal(
            referenceSequenceID: "cDNA",
            clusterID: "cluster",
            cDNAReferenceLength: 1_000,
            clusterLength: 999,
            referenceStart: 1,
            isReverse: false,
            metrics: FullLengthONTMHCSAMMetrics(cigar: "500=1D499=", nm: 1)
        )

        XCTAssertEqual(cohort.cDNAReferenceCoverage, 0.999, accuracy: 0.000_001)
        XCTAssertEqual(reciprocal.cDNAReferenceCoverage, 0.999, accuracy: 0.000_001)
        XCTAssertEqual(cohort.relationship, .known)
        XCTAssertEqual(reciprocal.relationship, .known)
    }
}
