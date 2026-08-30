import XCTest
@testable import LungfishApp

final class DebugRelocationSmokeTests: XCTestCase {
    func testRecognizesOnlyTheDedicatedNonUIProbeArgument() {
        XCTAssertEqual(
            DebugRelocationSmoke.outputIfRequested(
                arguments: ["Lungfish", "--debug-relocation-smoke"]
            ),
            "debug-app-executable-smoke-ok"
        )
        XCTAssertNil(DebugRelocationSmoke.outputIfRequested(arguments: ["Lungfish"]))
        XCTAssertNil(
            DebugRelocationSmoke.outputIfRequested(
                arguments: ["Lungfish", "--debug-relocation-smoke", "extra"]
            )
        )
    }
}
