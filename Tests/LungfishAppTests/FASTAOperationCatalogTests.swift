import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class FASTAOperationCatalogTests: XCTestCase {
    func testCatalogOnlyReturnsFASTACompatibleOperations() {
        let ids = Set(FASTAOperationCatalog.availableOperationKinds().map(\.rawValue))

        XCTAssertTrue(ids.contains(FASTQDerivativeOperationKind.searchMotif.rawValue))
        XCTAssertTrue(ids.contains(FASTQDerivativeOperationKind.orient.rawValue))
        XCTAssertFalse(ids.contains(FASTQDerivativeOperationKind.qualityTrim.rawValue))
        XCTAssertFalse(ids.contains(FASTQDerivativeOperationKind.demultiplex.rawValue))
    }

    func testDialogStateShowsOnlyFASTACompatibleToolsForTemporaryBundle() throws {
        let bundleURL = try FASTAOperationCatalog.createTemporaryInputBundle(
            fastaRecords: [">seq1\nAACCGGTT\n"],
            suggestedName: "seq1",
            projectURL: nil
        )
        let state = FASTQOperationDialogState(
            initialCategory: .searchSubsetting,
            selectedInputURLs: [bundleURL]
        )

        XCTAssertTrue(state.isFASTAInputMode)
        let toolIDs = Set(state.sidebarItems.map(\.id))
        XCTAssertTrue(toolIDs.contains(FASTQOperationToolID.extractReadsByMotif.rawValue))
        XCTAssertTrue(toolIDs.contains(FASTQOperationToolID.orientReads.rawValue))
        XCTAssertFalse(toolIDs.contains(FASTQOperationToolID.qualityTrim.rawValue))
        XCTAssertFalse(toolIDs.contains(FASTQOperationToolID.demultiplexBarcodes.rawValue))
        XCTAssertEqual(state.dialogTitle, "FASTA Operations")
    }
}
