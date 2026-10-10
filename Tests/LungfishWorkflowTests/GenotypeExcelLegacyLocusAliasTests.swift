import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// A review and a comment saved before N9 at a full-length call's
/// pseudo-locus still reach that call's cell in the workbook.
final class GenotypeExcelLegacyLocusAliasTests: XCTestCase {
    private let timestamp = "2026-10-01T00:00:00Z"

    func testALegacyCellReviewAndCommentReachTheStampedCell() throws {
        let metadata = ONTGenotypeReferenceMetadata(
            fields: [GenBankRecordDatabase.FieldDefinition(
                key: "feature.allele", displayTitle: "Allele", valueType: "text", sourceCategory: "feature", preferredOrder: 0)],
            recordsBySequenceName: [
                "NHP01270": ["feature.allele": "Mafa-A2*05:25:01:01", "feature.gene": "A2"],
                "NHP01718": ["feature.allele": "Mafa-A1*018:01:01:01", "feature.gene": "A1"],
            ],
            alleleFieldKey: "feature.allele"
        )
        let result = GenotypeTestFixtures.makeResult(
            calls: [
                GenotypeTestFixtures.makeCall(sample: "CR1178", genotype: "NHP01270", reads: 674),
                GenotypeTestFixtures.makeCall(sample: "CR1178", genotype: "NHP01718", reads: 712),
            ],
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            referenceMetadata: metadata
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
        let legacy = GenotypeAnnotationSidecar.MatrixTarget.cell(locus: "MHC-NHP01270", genotype: "NHP01270", sample: "CR1178")
        sidecar.matrixReviews = [.init(target: legacy, disposition: .falsePositive, author: "QA", timestamp: timestamp)]
        sidecar.matrixComments = [.init(target: legacy, body: "saved before N9", author: "QA", timestamp: timestamp)]

        let snapshot = try GenotypeExcelSnapshotBuilder.capture(
            result: result, sidecar: sidecar,
            allProjection: nil, filteredProjection: nil, generatedAt: timestamp,
            authority: .init(analysis: nil), filter: .unfiltered
        )
        let row = try XCTUnwrap(snapshot.allMatrix.rows.first { $0.target.genotype == "NHP01270" })
        XCTAssertEqual(row.target.locus, "MHC-A")
        XCTAssertEqual(row.cells.first?.review, "false-positive")
        XCTAssertEqual(row.cells.first?.comment, "saved before N9")
    }
}
