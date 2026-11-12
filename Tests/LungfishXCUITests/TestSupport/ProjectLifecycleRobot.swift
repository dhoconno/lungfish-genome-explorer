import XCTest

@MainActor
struct ProjectLifecycleRobot {
    let app: XCUIApplication
    /// Set when the exact-candidate gate names a packaged app (`LUNGFISH_RELEASE_SMOKE_APP`). The packaged app has no
    /// launch hooks, so `launch(openingProject:)` opens the project through File > Open Project Folder... as
    /// `ReleaseAppSmokeRobot` does, and the tests of the `ui-twins` profile run on the package (lane TWINS).
    private let packaged: ReleaseAppSmokeRobot?
    private let packagedFailure: String?

    init(app: XCUIApplication = XCUIApplication(), testName: String = #function) {
        var candidate: ReleaseAppSmokeRobot?
        var failure: String?
        if ProcessInfo.processInfo.environment["LUNGFISH_RELEASE_SMOKE_APP"] != nil {
            do { candidate = try ReleaseAppSmokeRobot(testName: testName) } catch { failure = String(describing: error) }
        }
        self.packaged = candidate
        self.packagedFailure = failure
        self.app = candidate?.app ?? app
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
        if let packagedFailure {
            XCTFail("The packaged app could not be prepared for the launch: \(packagedFailure)", file: file, line: line)
            return
        }
        if let packaged {
            do {
                try packaged.launch()
                packaged.openProject(projectURL)
            } catch {
                XCTFail("The packaged app did not launch: \(error)", file: file, line: line)
            }
            return
        }
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
