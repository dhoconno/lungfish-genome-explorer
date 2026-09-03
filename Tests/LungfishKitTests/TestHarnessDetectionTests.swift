import XCTest
@testable import LungfishKit

final class TestHarnessDetectionTests: XCTestCase {
    // This suite runs under a test harness by definition, so a detector that
    // reports false here is broken. The environment-variable form did exactly
    // that under SwiftPM, which is why this test exists.
    func testDetectsTheHarnessItRunsUnder() {
        XCTAssertTrue(TestHarness.isRunning)
    }

    // Pins the reason the environment variable cannot be used: it is absent
    // here, so any check depending on it would be dead code.
    func testTheEnvironmentVariableAloneWouldNotDetectThisRunner() {
        let env = ProcessInfo.processInfo.environment
        XCTAssertNil(env["XCTestConfigurationFilePath"],
                     "if SwiftPM starts setting this, revisit whether the class probe is still needed")
    }
}
