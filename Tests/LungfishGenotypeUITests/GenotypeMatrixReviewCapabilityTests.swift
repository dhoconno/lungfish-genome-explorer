import XCTest
import LungfishIO
@testable import LungfishGenotypeUI

final class GenotypeMatrixReviewCapabilityTests: XCTestCase {
    typealias Target = GenotypeAnnotationSidecar.MatrixTarget
    typealias Review = GenotypeAnnotationSidecar.MatrixReviewAnnotation
    typealias Comment = GenotypeAnnotationSidecar.MatrixComment

    private let supported = Target.cell(
        locus: "MHC-A1",
        genotype: "Mafa-A1*001:01",
        sample: "Animal-1",
        stableClusterID: "cluster-a"
    )
    private let zero = Target.cell(
        locus: "MHC-A1",
        genotype: "Mafa-A1*002:01",
        sample: "Animal-1",
        stableClusterID: "cluster-b"
    )
    private let absent = Target.cell(
        locus: "MHC-A1",
        genotype: "Mafa-A1*003:01",
        sample: "Animal-2",
        stableClusterID: "cluster-c"
    )

    func testExactCellEvidenceClassifiesPositiveZeroAndAbsentSupport() {
        let evidence = GenotypeMatrixEvidenceIndex([
            supported: 12,
            zero: 0,
        ])

        XCTAssertEqual(evidence.passedUniqueReads(for: supported), 12)
        XCTAssertEqual(evidence.passedUniqueReads(for: zero), 0)
        XCTAssertNil(evidence.passedUniqueReads(for: absent))

        let allSupported = GenotypeMatrixReviewCapability.evaluate(
            selection: [supported],
            evidence: evidence,
            reviews: [],
            comments: [],
            isWritable: true
        )
        XCTAssertEqual(allSupported.selectionShape, .cells)
        XCTAssertEqual(allSupported.support, .init(supportedCount: 1, unsupportedCount: 0, unknownCount: 0))
        XCTAssertEqual(allSupported.falsePositive, .enabled)
        XCTAssertEqual(
            allSupported.falseNegative,
            .disabled(reason: "False negative requires no read support in every selected cell.")
        )

        let allUnsupported = GenotypeMatrixReviewCapability.evaluate(
            selection: [zero, absent],
            evidence: evidence,
            reviews: [],
            comments: [],
            isWritable: true
        )
        XCTAssertEqual(allUnsupported.support, .init(supportedCount: 0, unsupportedCount: 2, unknownCount: 0))
        XCTAssertEqual(allUnsupported.falseNegative, .enabled)
        XCTAssertEqual(
            allUnsupported.falsePositive,
            .disabled(reason: "False positive requires read support in every selected cell.")
        )
    }

    func testMixedCellEvidenceDisablesBothReviewCommandsWithSharedReason() {
        let state = GenotypeMatrixReviewCapability.evaluate(
            selection: [supported, absent],
            evidence: GenotypeMatrixEvidenceIndex([supported: 1]),
            reviews: [],
            comments: [],
            isWritable: true
        )
        let reason = "Selection contains cells with and without read support. Review classifications require one evidence state."

        XCTAssertEqual(state.support, .init(supportedCount: 1, unsupportedCount: 1, unknownCount: 0))
        XCTAssertEqual(state.falsePositive, .disabled(reason: reason))
        XCTAssertEqual(state.falseNegative, .disabled(reason: reason))
    }

    func testRowColumnAndMixedSelectionsReportShapeAndDisableReviews() {
        let row = Target.row(locus: "MHC-A1", genotype: "Mafa-A1*001:01", stableClusterID: "cluster-a")
        let column = Target.column(sample: "Animal-1")
        let reason = "Review classifications are available only for genotype cells."

        let rowState = GenotypeMatrixReviewCapability.evaluate(
            selection: [row],
            evidence: .init(),
            reviews: [],
            comments: [],
            isWritable: true
        )
        XCTAssertEqual(rowState.selectionShape, .rows)
        XCTAssertEqual(rowState.support, .init(supportedCount: 0, unsupportedCount: 0, unknownCount: 1))
        XCTAssertEqual(rowState.falsePositive, .disabled(reason: reason))
        XCTAssertEqual(rowState.falseNegative, .disabled(reason: reason))
        XCTAssertEqual(rowState.upsertComment, .enabled)

        let columnState = GenotypeMatrixReviewCapability.evaluate(
            selection: [column],
            evidence: .init(),
            reviews: [],
            comments: [],
            isWritable: true
        )
        XCTAssertEqual(columnState.selectionShape, .columns)

        let mixedState = GenotypeMatrixReviewCapability.evaluate(
            selection: [supported, row, column],
            evidence: .init([supported: 1]),
            reviews: [],
            comments: [],
            isWritable: true
        )
        XCTAssertEqual(mixedState.selectionShape, .mixed)
        XCTAssertEqual(mixedState.support, .init(supportedCount: 1, unsupportedCount: 0, unknownCount: 2))
        XCTAssertEqual(mixedState.falsePositive, .disabled(reason: reason))
    }

    func testCurrentReviewStateIsNoneUniformOrMixedForSelection() {
        let falsePositive = Review(
            target: supported,
            disposition: .falsePositive,
            author: "A",
            timestamp: "2026-07-24T12:00:00Z"
        )
        let falseNegative = Review(
            target: absent,
            disposition: .falseNegative,
            author: "B",
            timestamp: "2026-07-24T12:01:00Z"
        )
        let evidence = GenotypeMatrixEvidenceIndex([supported: 2])

        XCTAssertEqual(
            GenotypeMatrixReviewCapability.evaluate(
                selection: [supported],
                evidence: evidence,
                reviews: [],
                comments: [],
                isWritable: true
            ).reviewState,
            .none
        )
        XCTAssertEqual(
            GenotypeMatrixReviewCapability.evaluate(
                selection: [supported],
                evidence: evidence,
                reviews: [falsePositive],
                comments: [],
                isWritable: true
            ).reviewState,
            .uniform(.falsePositive)
        )
        XCTAssertEqual(
            GenotypeMatrixReviewCapability.evaluate(
                selection: [supported, absent],
                evidence: evidence,
                reviews: [falsePositive, falseNegative],
                comments: [],
                isWritable: true
            ).reviewState,
            .mixed
        )
    }

    func testCurrentCommentStateIsEmptyUniformOrMixedForSelection() {
        let first = Comment(target: supported, body: "same", author: "A", timestamp: "2026-07-24T12:00:00Z")
        let second = Comment(target: absent, body: "same", author: "B", timestamp: "2026-07-24T12:01:00Z")
        let different = Comment(target: absent, body: "different", author: "B", timestamp: "2026-07-24T12:02:00Z")

        XCTAssertEqual(
            GenotypeMatrixReviewCapability.evaluate(
                selection: [supported],
                evidence: .init(),
                reviews: [],
                comments: [],
                isWritable: true
            ).commentState,
            .none
        )
        XCTAssertEqual(
            GenotypeMatrixReviewCapability.evaluate(
                selection: [supported, absent],
                evidence: .init(),
                reviews: [],
                comments: [first, second],
                isWritable: true
            ).commentState,
            .uniform("same")
        )
        XCTAssertEqual(
            GenotypeMatrixReviewCapability.evaluate(
                selection: [supported, absent],
                evidence: .init(),
                reviews: [],
                comments: [first, different],
                isWritable: true
            ).commentState,
            .mixed
        )
    }

    func testClearAndRemoveAvailabilityFollowCurrentValues() {
        let review = Review(
            target: supported,
            disposition: .falsePositive,
            author: "A",
            timestamp: "2026-07-24T12:00:00Z"
        )
        let comment = Comment(
            target: supported,
            body: "body",
            author: "A",
            timestamp: "2026-07-24T12:00:00Z"
        )
        let empty = GenotypeMatrixReviewCapability.evaluate(
            selection: [supported],
            evidence: .init([supported: 1]),
            reviews: [],
            comments: [],
            isWritable: true
        )
        XCTAssertEqual(empty.clearReview, .disabled(reason: "No review marks to clear."))
        XCTAssertEqual(empty.removeComments, .disabled(reason: "No comments to remove."))

        let populated = GenotypeMatrixReviewCapability.evaluate(
            selection: [supported],
            evidence: .init([supported: 1]),
            reviews: [review],
            comments: [comment],
            isWritable: true
        )
        XCTAssertEqual(populated.clearReview, .enabled)
        XCTAssertEqual(populated.removeComments, .enabled)
    }

    func testReadOnlyAndEmptySelectionDisableEveryMutationWithExactReason() {
        let readOnly = GenotypeMatrixReviewCapability.evaluate(
            selection: [supported],
            evidence: .init([supported: 1]),
            reviews: [],
            comments: [],
            isWritable: false
        )
        for command in readOnly.allCommands {
            XCTAssertEqual(command, .disabled(reason: "This bundle is read-only."))
        }

        let empty = GenotypeMatrixReviewCapability.evaluate(
            selection: [],
            evidence: .init(),
            reviews: [],
            comments: [],
            isWritable: true
        )
        XCTAssertEqual(empty.selectionShape, .none)
        for command in empty.allCommands {
            XCTAssertEqual(command, .disabled(reason: "Select one or more matrix targets."))
        }
    }
}
