import XCTest
import LungfishCore
@testable import LungfishIO
import LungfishTestSupport

/// Matrix annotations saved before N9 name a full-length call's pseudo-locus
/// (MHC-NHP01270). They still apply to the call at its current locus, and
/// the sidecar keeps the targets as saved.
final class GenotypeMatrixTargetLocusAliasTests: XCTestCase {
    private typealias Target = GenotypeAnnotationSidecar.MatrixTarget
    private let timestamp = "2026-10-01T00:00:00Z"

    private func result(kind: String = GenotypeReferenceRecordLocusTests.fullLength) -> ONTGenotypeResultBundleData {
        GenotypeReferenceRecordLocusTests.result(calls: [
            GenotypeReferenceRecordLocusTests.call("CR1178", "NHP01270", 674),
            GenotypeReferenceRecordLocusTests.call("CR1178", "NHP01718", 712),
        ], kind: kind)
    }

    private let legacyCell = Target.cell(locus: "MHC-NHP01270", genotype: "NHP01270", sample: "CR1178")
    private let currentCell = Target.cell(locus: "MHC-A", genotype: "NHP01270", sample: "CR1178")

    func testALegacyTargetReadsAtTheCallsCurrentLocus() {
        let alias = GenotypeMatrixTargetLocusAlias(result: result())
        XCTAssertFalse(alias.isEmpty)
        XCTAssertEqual(alias.current(legacyCell), currentCell)
        XCTAssertEqual(alias.current(.row(locus: "MHC-NHP01270", genotype: "NHP01270")),
                       .row(locus: "MHC-A", genotype: "NHP01270"))
        XCTAssertEqual(alias.current(currentCell), currentCell, "a current target is unchanged")
        XCTAssertEqual(alias.current(.column(sample: "CR1178")), .column(sample: "CR1178"))
        let candidate = Target.cell(locus: "MHC-NHP01270", genotype: "NHP01270", sample: "CR1178", stableClusterID: "c1")
        XCTAssertEqual(alias.current(candidate), candidate, "a candidate target is never moved")
        let otherGenotype = Target.cell(locus: "MHC-NHP01270", genotype: "NHP01718", sample: "CR1178")
        XCTAssertEqual(alias.current(otherGenotype), otherGenotype, "the alias is keyed by locus and genotype")
    }

    func testAnUnstampedResultHasNoAlias() {
        let amplicon = GenotypeMatrixTargetLocusAlias(result: result(kind: GenotypeReferenceRecordLocusTests.amplicon))
        XCTAssertTrue(amplicon.isEmpty)
        XCTAssertEqual(amplicon.current(legacyCell), legacyCell)
    }

    func testTheReadViewMovesStylesCommentsAndReviewsAndKeepsTheSidecar() {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
        let style = GenotypeAnnotationSidecar.MatrixStyle(
            fillColor: "#FF0000", textColor: nil, borderColor: nil, isBold: true, isItalic: false,
            boldOverride: nil, italicOverride: nil)
        sidecar.matrixStyles = [.init(target: legacyCell, style: style, author: "QA", timestamp: timestamp)]
        sidecar.matrixComments = [.init(target: legacyCell, body: "old note", author: "QA", timestamp: timestamp)]
        sidecar.matrixReviews = [.init(target: legacyCell, disposition: .falsePositive, author: "QA", timestamp: timestamp)]

        let view = GenotypeMatrixTargetLocusAlias(result: result()).readView(of: sidecar)
        XCTAssertEqual(view.matrixStyles.map(\.target), [currentCell])
        XCTAssertEqual(view.matrixComments.map(\.target), [currentCell])
        XCTAssertEqual(view.resolvedMatrixComments[currentCell]?.body, "old note")
        XCTAssertEqual(view.matrixReviews.map(\.target), [currentCell])
        XCTAssertEqual(sidecar.matrixReviews.map(\.target), [legacyCell], "the stored sidecar keeps its targets")
    }

    func testAnEntrySavedAtTheCurrentLocusWinsOverTheLegacyOne() {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
        sidecar.matrixReviews = [
            .init(target: legacyCell, disposition: .falsePositive, author: "QA", timestamp: timestamp),
            .init(target: currentCell, disposition: .falseNegative, author: "QA", timestamp: "2026-10-02T00:00:00Z"),
        ]
        let view = GenotypeMatrixTargetLocusAlias(result: result()).readView(of: sidecar)
        XCTAssertEqual(view.matrixReviews.map(\.disposition), [.falseNegative])
    }

    /// A false-positive review saved at the pseudo-locus still keeps the call
    /// out of haplotype inference.
    func testALegacyFalsePositiveReviewStillExcludesTheCallFromInference() {
        let calls = result().calls
        let review = GenotypeAnnotationSidecar.MatrixReviewAnnotation(
            target: legacyCell, disposition: .falsePositive, author: "QA", timestamp: timestamp)
        let kept = GenotypeReviewedHaplotypeEvidence.callsForInference(calls, reviews: [review])
        XCTAssertEqual(kept.map(\.genotype), ["NHP01718"])
    }

    /// The matrix and the workbook read a legacy review as eligible at the
    /// call's current cell.
    func testALegacyReviewIsEligibleAtTheCurrentCell() {
        let result = result()
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
        sidecar.matrixReviews = [.init(target: legacyCell, disposition: .falsePositive, author: "QA", timestamp: timestamp)]
        let support = GenotypeMatrixReviewEligibility.rawSupport(in: result)
        XCTAssertEqual(support[currentCell], 674)
        XCTAssertNil(support[legacyCell])
        let view = GenotypeMatrixTargetLocusAlias(result: result).readView(of: sidecar)
        let eligible = GenotypeMatrixReviewEligibility.eligibleReviews(view.matrixReviews) { support[$0] }
        XCTAssertEqual(eligible[currentCell]?.disposition, .falsePositive)
    }
}
