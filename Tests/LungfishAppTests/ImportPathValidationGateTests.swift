import XCTest
@testable import LungfishApp

final class ImportPathValidationGateTests: XCTestCase {
    func testOnlyActiveImportPathValidationResultIsAccepted() {
        var gate = ImportPathValidationGate<Int>()

        let first = gate.begin(path: URL(fileURLWithPath: "/tmp/import-A"))
        let second = gate.begin(path: URL(fileURLWithPath: "/tmp/import-B"))

        XCTAssertFalse(gate.shouldAccept(first))
        XCTAssertTrue(gate.shouldAccept(second))
    }

    func testCancelRejectsPendingImportPathValidationResult() {
        var gate = ImportPathValidationGate<Int>()

        let token = gate.begin(path: URL(fileURLWithPath: "/tmp/import"))
        gate.cancel()

        XCTAssertFalse(gate.shouldAccept(token))
    }
}
