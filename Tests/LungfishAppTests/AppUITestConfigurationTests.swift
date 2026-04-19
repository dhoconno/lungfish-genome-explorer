import XCTest
@testable import LungfishApp

final class AppUITestConfigurationTests: XCTestCase {
    func testLaunchArgumentEnablesUITestModeAndCapturesScenario() {
        let config = AppUITestConfiguration(
            arguments: ["Lungfish", "--skip-welcome", "--ui-test-mode"],
            environment: ["LUNGFISH_UI_TEST_SCENARIO": "database-search-basic"]
        )

        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.scenarioName, "database-search-basic")
    }

    func testEnvironmentFlagAlsoEnablesUITestMode() {
        let config = AppUITestConfiguration(
            arguments: ["Lungfish"],
            environment: ["LUNGFISH_UI_TEST_MODE": "1"]
        )

        XCTAssertTrue(config.isEnabled)
        XCTAssertNil(config.scenarioName)
    }

    func testNormalLaunchLeavesUITestModeDisabled() {
        let config = AppUITestConfiguration(
            arguments: ["Lungfish"],
            environment: [:]
        )

        XCTAssertFalse(config.isEnabled)
        XCTAssertNil(config.scenarioName)
    }

    func testLaunchEnvironmentParsesProjectPathFixtureRootAndBackendMode() {
        let config = AppUITestConfiguration(
            arguments: ["Lungfish", "--ui-test-mode"],
            environment: [
                "LUNGFISH_UI_TEST_SCENARIO": "welcome-project-open",
                "LUNGFISH_UI_TEST_PROJECT_PATH": "/tmp/Fixture.lungfish",
                "LUNGFISH_UI_TEST_FIXTURE_ROOT": "/tmp/Fixtures",
                "LUNGFISH_UI_TEST_BACKEND_MODE": "deterministic",
            ]
        )

        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.scenarioName, "welcome-project-open")
        XCTAssertEqual(config.projectPath, URL(fileURLWithPath: "/tmp/Fixture.lungfish"))
        XCTAssertEqual(config.fixtureRootPath, URL(fileURLWithPath: "/tmp/Fixtures"))
        XCTAssertEqual(config.backendMode, .deterministic)
    }

    func testLaunchEnvironmentParsesWelcomeDirectPathsAndEventLogPath() {
        let config = AppUITestConfiguration(
            arguments: ["Lungfish", "--ui-test-mode"],
            environment: [
                "LUNGFISH_UI_TEST_FIXTURE_ROOT": "/tmp/Fixtures",
                "LUNGFISH_UI_TEST_WELCOME_OPEN_PROJECT_PATH": "projects/OpenMe.lungfish",
                "LUNGFISH_UI_TEST_WELCOME_CREATE_PROJECT_PATH": "projects/NewGenome",
                "LUNGFISH_UI_TEST_EVENT_LOG_PATH": "logs/ui-test-events.log",
            ]
        )

        XCTAssertEqual(
            config.welcomeOpenProjectPath,
            URL(fileURLWithPath: "/tmp/Fixtures")
                .appendingPathComponent("projects/OpenMe.lungfish", isDirectory: true)
        )
        XCTAssertEqual(
            config.welcomeCreateProjectPath,
            URL(fileURLWithPath: "/tmp/Fixtures")
                .appendingPathComponent("projects/NewGenome", isDirectory: true)
        )
        XCTAssertEqual(
            config.eventLogPath,
            URL(fileURLWithPath: "/tmp/Fixtures")
                .appendingPathComponent("logs/ui-test-events.log", isDirectory: false)
        )
    }

    func testUnknownBackendModeFallsBackToDeterministic() {
        let config = AppUITestConfiguration(
            arguments: ["Lungfish", "--ui-test-mode"],
            environment: ["LUNGFISH_UI_TEST_BACKEND_MODE": "mystery-mode"]
        )

        XCTAssertEqual(config.backendMode, .deterministic)
    }

    func testRelativeProjectPathResolvesAgainstFixtureRoot() {
        let config = AppUITestConfiguration(
            arguments: ["Lungfish", "--ui-test-mode"],
            environment: [
                "LUNGFISH_UI_TEST_PROJECT_PATH": "projects/Fixture.lungfish",
                "LUNGFISH_UI_TEST_FIXTURE_ROOT": "/tmp/Fixtures",
            ]
        )

        XCTAssertEqual(
            config.projectPath,
            URL(fileURLWithPath: "/tmp/Fixtures")
                .appendingPathComponent("projects/Fixture.lungfish", isDirectory: true)
        )
    }

    func testAppendEventAppendsLineDelimitedEntriesToEventLog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("ui-test-events.log")
        let config = AppUITestConfiguration(
            arguments: ["Lungfish", "--ui-test-mode"],
            environment: ["LUNGFISH_UI_TEST_EVENT_LOG_PATH": logURL.path]
        )

        config.appendEvent("welcome.dialog.open.requested")
        config.appendEvent("welcome.dialog.create.requested")

        let content = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(
            content,
            "welcome.dialog.open.requested\nwelcome.dialog.create.requested\n"
        )
    }
}
