import XCTest
import LungfishWorkflow
@testable import LungfishGenotypeUI

/// The Phase 2.3 refusal wording decision. A GUI Excel export that is refused
/// before anything is written reads in plain words in the Inspector status,
/// while the builder's developer text stays for the CLI and for direct
/// captures.
final class GenotypeExcelExportRefusalWordingTests: XCTestCase {
    func testABuilderRefusalReadsAsTheWorkbookNotMatchingTheMatrix() {
        let error = GenotypeExcelSnapshotBuilder.CaptureError.incoherent(
            "projected native matrix column values disagree with scientific authority"
        )

        XCTAssertEqual(
            GenotypeExcelExportRefusal.message(for: error),
            "The workbook would not match the matrix on screen, so nothing was written "
                + "(projected native matrix column values disagree with scientific authority). Please report this."
        )
        XCTAssertEqual(
            error.localizedDescription,
            "Incoherent Excel capture: projected native matrix column values disagree with scientific authority",
            "the builder keeps its developer text for the CLI and for direct captures"
        )
    }

    func testTheStillSavingRefusalReadsInPlainWords() {
        let refusal = GenotypeExcelExportRefusal.annotationsStillSaving

        XCTAssertEqual(
            refusal.localizedDescription,
            "Annotations are still saving. Wait for the save to finish, then export again."
        )
        XCTAssertEqual(GenotypeExcelExportRefusal.message(for: refusal), refusal.localizedDescription)
    }

    func testAnyOtherErrorKeepsItsOwnDescription() {
        struct DiskFull: LocalizedError {
            var errorDescription: String? { "disk full" }
        }

        XCTAssertEqual(GenotypeExcelExportRefusal.message(for: DiskFull()), "disk full")
    }
}
