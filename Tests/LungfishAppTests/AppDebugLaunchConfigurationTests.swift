import XCTest
@testable import LungfishApp

final class AppDebugLaunchConfigurationTests: XCTestCase {
    func testEnvVarEnablesRequiredSetupBypassInDebug() {
        let config = AppDebugLaunchConfiguration(
            environment: ["LUNGFISH_DEBUG_BYPASS_REQUIRED_SETUP": "1"]
        )

        #if DEBUG
        XCTAssertTrue(config.bypassRequiredSetup)
        #else
        XCTAssertFalse(config.bypassRequiredSetup)
        #endif
    }

    func testBypassDefaultsToDisabled() {
        let config = AppDebugLaunchConfiguration(environment: [:])

        XCTAssertFalse(config.bypassRequiredSetup)
    }
}
