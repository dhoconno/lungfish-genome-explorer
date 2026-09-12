import XCTest
@testable import LungfishApp

final class MSAPrimerTrackTests: XCTestCase {
    func testSparseForwardAndReverseTracksRetainReferenceInsertionColumns() throws {
        let forward = try MSAReadOnlyPrimerTrack.make(id: "f", name: "Forward", sequence: "AYG", strand: "+", columns: [1, 2, 4])
        XCTAssertEqual(forward.alignedBases[1], "A")
        XCTAssertNil(forward.alignedBases[3])
        XCTAssertEqual(forward.displayedResidue("C", column: 2), ".")
        XCTAssertEqual(forward.displayedResidue("c", column: 2), ".")
        XCTAssertEqual(forward.displayedResidue("a", column: 2), "a")
        XCTAssertEqual(forward.displayedResidue("n", column: 2), "n")
        XCTAssertTrue(forward.isDefiniteMismatch("a", column: 2))
        XCTAssertFalse(forward.isDefiniteMismatch("c", column: 2))
        XCTAssertFalse(forward.isDefiniteMismatch("n", column: 2))
        XCTAssertEqual(forward.displayedResidue("A", column: 2), "A")
        XCTAssertEqual(forward.displayedResidue("N", column: 2), "N")
        XCTAssertEqual(forward.displayedResidue("-", column: 2), "-")
        XCTAssertEqual(forward.displayedResidue("A", column: 0), "A")
        XCTAssertFalse(forward.isDefiniteMismatch("N", column: 2))
        XCTAssertFalse(forward.isDefiniteMismatch("-", column: 2))
        XCTAssertFalse(forward.isDefiniteMismatch("T", column: 0))
        XCTAssertTrue(forward.isDefiniteMismatch("A", column: 2))
        var letters = forward
        letters.showIdentityDots = false
        XCTAssertEqual(letters.displayedResidue("C", column: 2), "C")
        let reverse = try MSAReadOnlyPrimerTrack.make(id: "r", name: "Reverse", sequence: "ARY", strand: "-", columns: [1, 2, 4])
        XCTAssertEqual([1, 2, 4].compactMap { reverse.alignedBases[$0] }, Array("RYT"))
        XCTAssertTrue(reverse.label.contains("reverse complement"))
        XCTAssertThrowsError(try MSAReadOnlyPrimerTrack.make(id: "bad", name: "Bad", sequence: "AC", strand: "+", columns: [1]))
    }

    func testLegendTracksActualComparisonMode() {
        XCTAssertTrue(PrimerBindingInspectionView.legend(hasTrack: true, showIdentityDots: true).contains("Dots:"))
        XCTAssertTrue(PrimerBindingInspectionView.legend(hasTrack: true, showIdentityDots: false).contains("including matches"))
        XCTAssertFalse(PrimerBindingInspectionView.legend(hasTrack: false, showIdentityDots: true).contains("known primer mismatches"))
        XCTAssertFalse(PrimerBindingInspectionView.legend(hasTrack: true, showIdentityDots: true).contains("Blue"))
    }

    @MainActor
    func testPrimerTrackDoesNotAlterSourceRowsOrConsensus() throws {
        let controller = MultipleSequenceAlignmentViewController()
        try controller.displayReadOnlyAlignment(fasta: ">a\nACGT\n>b\nATNT\n", annotations: [])
        let summary = controller.testingOverviewSignalSummary
        let before = controller.testingVisibleAlignmentRowsPreview(rowCount: 1, columnCount: 4)
        let track = try MSAReadOnlyPrimerTrack.make(id: "p", name: "Primer", sequence: "AC", strand: "+", columns: [0, 1])
        controller.applyReadOnlyPrimerTrack(track)
        XCTAssertFalse(controller.testingReferenceActionsEnabled)
        controller.testingInvokeReferenceActions()
        controller.applyReferenceRowID("inspection-row-1")
        controller.applyResidueIdentityDisplayMode(.dotsToReference)
        XCTAssertNil(controller.testingReferenceGutterMarker)
        XCTAssertEqual(controller.testingAlignmentMatrixPreview(rowCount: 2, columnCount: 4), ["a ..GT", "b .TNT"])
        XCTAssertEqual(controller.testingVisibleAlignmentRowsPreview(rowCount: 1, columnCount: 4), before)
        XCTAssertEqual(controller.testingOverviewSignalSummary, summary)
        XCTAssertEqual(controller.testingDifferenceVisibilityPreview(rowCount: 2, columnCount: 4), ["a ....", "b .!.."])
        XCTAssertNil(controller.bundleURL)
        controller.applyReadOnlyPrimerTrack(nil)
        XCTAssertTrue(controller.testingReferenceActionsEnabled)
        XCTAssertEqual(controller.testingAlignmentMatrixPreview(rowCount: 2, columnCount: 4), ["a ACGT", "b ATNT"])
    }
}
