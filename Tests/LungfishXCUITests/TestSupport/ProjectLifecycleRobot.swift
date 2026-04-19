import XCTest

@MainActor
struct ProjectLifecycleRobot {
    let app: XCUIApplication

    init(app: XCUIApplication = XCUIApplication()) {
        self.app = app
    }

    var welcomeWindow: XCUIElement {
        app.windows.matching(identifier: "welcome-window").firstMatch
    }

    var createProjectButton: XCUIElement {
        app.descendants(matching: .any)["welcome-create-project"]
    }

    var openProjectButton: XCUIElement {
        app.descendants(matching: .any)["welcome-open-project"]
    }

    func projectWindow(for projectURL: URL) -> XCUIElement {
        let projectName = projectURL.deletingPathExtension().lastPathComponent
        let predicate = NSPredicate(format: "title CONTAINS %@", projectName)
        return app.windows.matching(predicate).firstMatch
    }

    func launchToWelcome(
        openingProject projectURL: URL? = nil,
        creatingProject createProjectURL: URL? = nil,
        eventLogPath: URL? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        configureBaseLaunch()
        var options = LungfishUITestLaunchOptions(
            fixtureRootPath: LungfishFixtureCatalog.fixturesRoot
        )
        options.welcomeOpenProjectPath = projectURL
        options.welcomeCreateProjectPath = createProjectURL
        options.eventLogPath = eventLogPath
        options.apply(to: app)

        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), file: file, line: line)
        XCTAssertTrue(welcomeWindow.waitForExistence(timeout: 10), file: file, line: line)
    }

    func launch(openingProject projectURL: URL, file: StaticString = #filePath, line: UInt = #line) {
        configureBaseLaunch()
        var options = LungfishUITestLaunchOptions(
            projectPath: projectURL,
            fixtureRootPath: LungfishFixtureCatalog.fixturesRoot
        )
        options.backendMode = "deterministic"
        options.apply(to: app)

        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), file: file, line: line)
    }

    func tapOpenProjectButton(file: StaticString = #filePath, line: UInt = #line) {
        let button = openProjectButton
        XCTAssertTrue(button.waitForExistence(timeout: 5), file: file, line: line)
        button.click()
    }

    func tapCreateProjectButton(file: StaticString = #filePath, line: UInt = #line) {
        let button = createProjectButton
        XCTAssertTrue(button.waitForExistence(timeout: 5), file: file, line: line)
        button.click()
    }

    func waitForEventLogLine(
        _ expectedLine: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if eventLogContainsLine(expectedLine) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("Timed out waiting for event log line: \(expectedLine)", file: file, line: line)
    }

    private func eventLogContainsLine(_ expectedLine: String) -> Bool {
        guard let eventLogPath = currentEventLogPath else {
            return false
        }
        guard let content = try? String(contentsOf: eventLogPath, encoding: .utf8) else {
            return false
        }
        return content.components(separatedBy: .newlines).contains(expectedLine)
    }

    private var currentEventLogPath: URL? {
        app.launchEnvironment["LUNGFISH_UI_TEST_EVENT_LOG_PATH"].map(URL.init(fileURLWithPath:))
    }

    private func configureBaseLaunch() {
        LungfishUITestLaunchOptions().apply(to: app)
        app.launchEnvironment["LUNGFISH_DEBUG_BYPASS_REQUIRED_SETUP"] = "1"
    }
}
