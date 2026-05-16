import XCTest
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
}
