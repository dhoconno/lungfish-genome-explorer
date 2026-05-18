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

    func testBuildAppDebugBundleUsesDistinctLaunchServicesIdentity() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: packageRoot.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("DEBUG_BUNDLE_ID=\"org.lungfish.genome-browser.debug\""))
        XCTAssertTrue(script.contains("DEBUG_BUNDLE_NAME=\"Lungfish Debug\""))
        XCTAssertTrue(script.contains("DEBUG_BUNDLE_DISPLAY_NAME=\"Lungfish Genome Browser Debug\""))
        XCTAssertTrue(script.contains("<string>$BUNDLE_ID</string>"))
        XCTAssertTrue(script.contains("<string>$BUNDLE_NAME</string>"))
        XCTAssertTrue(script.contains("<string>$BUNDLE_DISPLAY_NAME</string>"))
    }
}
