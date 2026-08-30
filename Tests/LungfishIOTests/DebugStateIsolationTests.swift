import XCTest
@testable import LungfishIO

final class DebugStateIsolationTests: XCTestCase {
    func testWorkbookAttestationRootIsIsolatedForDebug() throws {
        let applicationSupport = URL(fileURLWithPath: "/tmp/Application Support")

        XCTAssertEqual(
            try ONTGenotypeWorkbookUpdateRecovery.defaultAttestationRootURL(
                appIdentity: .stable,
                applicationSupportDirectory: applicationSupport
            ),
            applicationSupport.appendingPathComponent(
                "Lungfish/workbook-publication-attestations",
                isDirectory: true
            )
        )
        XCTAssertEqual(
            try ONTGenotypeWorkbookUpdateRecovery.defaultAttestationRootURL(
                appIdentity: .debug,
                applicationSupportDirectory: applicationSupport
            ),
            applicationSupport.appendingPathComponent(
                "Lungfish Debug/workbook-publication-attestations",
                isDirectory: true
            )
        )
    }
}
