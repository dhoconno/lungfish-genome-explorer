import XCTest

@MainActor
struct LungfishUITestLaunchOptions {
    private static let managedEnvironmentKeys = [
        "LUNGFISH_UI_TEST_MODE",
        "LUNGFISH_UI_TEST_SCENARIO",
        "LUNGFISH_UI_TEST_PROJECT_PATH",
        "LUNGFISH_UI_TEST_FIXTURE_ROOT",
        "LUNGFISH_UI_TEST_BACKEND_MODE",
        "LUNGFISH_UI_TEST_WELCOME_OPEN_PROJECT_PATH",
        "LUNGFISH_UI_TEST_WELCOME_CREATE_PROJECT_PATH",
        "LUNGFISH_UI_TEST_EVENT_LOG_PATH",
    ]

    var scenario: String?
    var projectPath: URL?
    var fixtureRootPath: URL?
    var backendMode: String = "deterministic"
    var skipWelcome = false
    var welcomeOpenProjectPath: URL?
    var welcomeCreateProjectPath: URL?
    var eventLogPath: URL?

    func apply(to app: XCUIApplication) {
        var arguments = ["--ui-test-mode"]
        if skipWelcome {
            arguments.append("--skip-welcome")
        }
        app.launchArguments = arguments

        var environment = app.launchEnvironment
        for key in Self.managedEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        environment["LUNGFISH_UI_TEST_MODE"] = "1"
        if let scenario {
            environment["LUNGFISH_UI_TEST_SCENARIO"] = scenario
        }
        if let projectPath {
            environment["LUNGFISH_UI_TEST_PROJECT_PATH"] = projectPath.path
        }
        if let fixtureRootPath {
            environment["LUNGFISH_UI_TEST_FIXTURE_ROOT"] = fixtureRootPath.path
        }
        environment["LUNGFISH_UI_TEST_BACKEND_MODE"] = backendMode
        if let welcomeOpenProjectPath {
            environment["LUNGFISH_UI_TEST_WELCOME_OPEN_PROJECT_PATH"] = welcomeOpenProjectPath.path
        }
        if let welcomeCreateProjectPath {
            environment["LUNGFISH_UI_TEST_WELCOME_CREATE_PROJECT_PATH"] = welcomeCreateProjectPath.path
        }
        if let eventLogPath {
            environment["LUNGFISH_UI_TEST_EVENT_LOG_PATH"] = eventLogPath.path
        }
        app.launchEnvironment = environment
    }
}
