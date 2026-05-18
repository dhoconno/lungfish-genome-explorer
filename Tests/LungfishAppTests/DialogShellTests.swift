import XCTest
import SwiftUI
@testable import LungfishApp

@MainActor
final class DialogShellTests: XCTestCase {

    func testWizardSheetStandardSizeMatchesDialogGuideline() {
        XCTAssertEqual(WizardSheetSize.standard.width, 520)
        XCTAssertEqual(WizardSheetSize.standard.height, 480)
    }

    func testImportSheetStandardSizeMatchesDialogGuideline() {
        XCTAssertEqual(ImportSheetSize.standard.width, 520)
        XCTAssertEqual(ImportSheetSize.standard.height, 480)
    }

    func testImportSheetSupportsLegacyCompactSize() {
        let compact = ImportSheetSize(width: 500, height: 450)

        XCTAssertEqual(compact.width, 500)
        XCTAssertEqual(compact.height, 450)
    }

    func testImportSheetSupportsCzIdImportFooterContract() {
        let sheet = ImportSheet(
            title: "CZ-ID Import",
            subtitle: "Hosted metagenomics taxon report",
            accessoryText: "sample-a",
            size: ImportSheetSize(width: 520, height: 460),
            statusText: "Scanning CZ-ID export...",
            primaryTitle: "Run",
            isPrimaryEnabled: false,
            onCancel: {},
            onPrimary: {}
        ) {
            EmptyView()
        } content: {
            EmptyView()
        }

        XCTAssertEqual(sheet.title, "CZ-ID Import")
        XCTAssertEqual(sheet.subtitle, "Hosted metagenomics taxon report")
        XCTAssertEqual(sheet.accessoryText, "sample-a")
        XCTAssertEqual(sheet.size.width, 520)
        XCTAssertEqual(sheet.size.height, 460)
        XCTAssertEqual(sheet.statusText, "Scanning CZ-ID export...")
        XCTAssertEqual(sheet.primaryTitle, "Run")
        XCTAssertFalse(sheet.isPrimaryEnabled)
    }
}
