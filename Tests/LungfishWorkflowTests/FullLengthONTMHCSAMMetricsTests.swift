import XCTest
@testable import LungfishWorkflow

final class FullLengthONTMHCSAMMetricsTests: XCTestCase {
    func testExplicitOperatorsProduceIndependentAlignmentMetrics() throws {
        let metrics = try FullLengthONTMHCSAMMetrics(cigar: "100=2X30I40D900=", nm: 72)

        XCTAssertEqual(metrics.snps, 2)
        XCTAssertEqual(metrics.nonIntronIndelBases, 70)
        XCTAssertEqual(metrics.comparableBases, 1_002)
        XCTAssertEqual(metrics.matches, 1_000)
        XCTAssertEqual(metrics.insertedBases, 30)
        XCTAssertEqual(metrics.deletedBases, 40)
    }

    func testSkippedAndSoftClippedBasesContributeOnlyToTheirRespectiveSpans() throws {
        let metrics = try FullLengthONTMHCSAMMetrics(cigar: "5S100=2X3I4D20N10=7S", nm: nil)

        XCTAssertEqual(metrics.skippedReferenceBases, 20)
        XCTAssertEqual(metrics.softClippedBases, 12)
        XCTAssertEqual(metrics.referenceSpan, 136)
        XCTAssertEqual(metrics.querySpan, 127)
        XCTAssertEqual(metrics.comparableBases, 112)
        XCTAssertEqual(metrics.nonIntronIndelBases, 7)
    }

    func testRejectsMalformedAndUnsupportedCIGAROperations() {
        assertMetricsError(cigar: "", nm: nil, equals: .emptyCIGAR)
        assertMetricsError(cigar: "M", nm: 0, equals: .missingOperationLength(operator: "M"))
        assertMetricsError(cigar: "0M", nm: 0, equals: .zeroOperationLength(operator: "M"))
        assertMetricsError(cigar: "10M2", nm: 0, equals: .trailingOperationLength("2"))
        assertMetricsError(cigar: "10H", nm: nil, equals: .unsupportedOperator("H"))
    }

    func testAmbiguousMUsesNMMinusNonIntronIndelsForSNPCount() throws {
        let metrics = try FullLengthONTMHCSAMMetrics(cigar: "4S10M2I3D5N", nm: 7)

        XCTAssertEqual(metrics.matches, 8)
        XCTAssertEqual(metrics.snps, 2)
        XCTAssertEqual(metrics.insertedBases, 2)
        XCTAssertEqual(metrics.deletedBases, 3)
        XCTAssertEqual(metrics.skippedReferenceBases, 5)
        XCTAssertEqual(metrics.softClippedBases, 4)
        XCTAssertEqual(metrics.referenceSpan, 18)
        XCTAssertEqual(metrics.querySpan, 16)
    }

    func testMixedExplicitAndAmbiguousMatchesPreserveExplicitSubstitutions() throws {
        let metrics = try FullLengthONTMHCSAMMetrics(cigar: "5=2X10M1I1D", nm: 5)

        XCTAssertEqual(metrics.matches, 14)
        XCTAssertEqual(metrics.snps, 3)
        XCTAssertEqual(metrics.comparableBases, 17)
    }

    func testMRequiresConsistentNonnegativeNM() {
        assertMetricsError(cigar: "10M", nm: nil, equals: .missingNMForAmbiguousMatch)
        assertMetricsError(cigar: "10M", nm: -1, equals: .negativeNM(-1))
        assertMetricsError(
            cigar: "10M5I",
            nm: 4,
            equals: .nmSmallerThanExplicitDifferences(nm: 4, explicitDifferences: 5)
        )
        assertMetricsError(
            cigar: "10M",
            nm: 11,
            equals: .nmMismatchCountExceedsAmbiguousMatches(mismatchCount: 11, ambiguousMatchBases: 10)
        )
    }

    func testNMDoesNotOverrideExplicitXWhenCIGARHasNoM() throws {
        let metrics = try FullLengthONTMHCSAMMetrics(cigar: "8=2X3I", nm: 99)

        XCTAssertEqual(metrics.matches, 8)
        XCTAssertEqual(metrics.snps, 2)
        XCTAssertEqual(metrics.insertedBases, 3)
    }

    private func assertMetricsError(
        cigar: String,
        nm: Int?,
        equals expectedError: FullLengthONTMHCSAMMetricsError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try FullLengthONTMHCSAMMetrics(cigar: cigar, nm: nm),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? FullLengthONTMHCSAMMetricsError, expectedError, file: file, line: line)
        }
    }
}
