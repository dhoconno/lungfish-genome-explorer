import XCTest
import LungfishIO
@testable import LungfishApp

final class BuiltInPrimerSchemeServiceTests: XCTestCase {
    func testListBuiltInSchemesReturnsBundledSchemes() throws {
        let schemes = BuiltInPrimerSchemeService.listBuiltInSchemes()
        XCTAssertFalse(schemes.isEmpty, "expected at least one built-in primer scheme")
        XCTAssertTrue(schemes.contains { $0.manifest.name == "QIASeqDIRECT-SARS2" })
    }

    func testInjectedBundleOverrideRemainsAuthoritative() {
        let schemes = BuiltInPrimerSchemeService.listBuiltInSchemes(in: Bundle.module)
        XCTAssertTrue(schemes.isEmpty)
    }
}
