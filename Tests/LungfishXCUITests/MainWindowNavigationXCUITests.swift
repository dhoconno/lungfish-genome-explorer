import XCTest

final class MainWindowNavigationXCUITests: XCTestCase {
    @MainActor
    func testOperationsPanelFailedOperationOpensPrefilledGitHubIssueWithoutNetwork() throws {
        let app = XCUIApplication()
        let eventLogURL = makeTemporaryEventLogURL(named: "OperationsGitHubIssue")
        defer { app.terminate() }

        var options = LungfishUITestLaunchOptions(
            scenario: "operations-failed-operation",
            fixtureRootPath: LungfishFixtureCatalog.fixturesRoot,
            skipWelcome: true,
            eventLogPath: eventLogURL
        )
        options.backendMode = "deterministic"
        options.apply(to: app)
        app.launchEnvironment["LUNGFISH_DEBUG_BYPASS_REQUIRED_SETUP"] = "1"
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        openOperationsPanel(in: app)

        let reportButton = app.buttons["operations-open-github-issue-button"].firstMatch
        XCTAssertTrue(reportButton.waitForExistence(timeout: 5))
        reportButton.click()

        let event = waitForEvent(
            prefix: "githubIssueOpened:",
            in: eventLogURL,
            timeout: 5
        )
        XCTAssertTrue(event.contains("https://github.com/dhoconno/lungfish-genome-explorer/issues/new"))
        XCTAssertTrue(event.contains("Operation%20failure"))
        XCTAssertTrue(event.contains("UI%20test%20failed%20operation"))
    }

    @MainActor
    func testToolbarAndAnalysesGroupAreReachableByPointerAndKeyboard() throws {
        let projectURL = try makeAnalysesProject()
        let robot = MainWindowRobot()
        defer { robot.app.terminate() }

        robot.launch(opening: projectURL)

        XCTAssertTrue(robot.toolbarButton("main-window-toggle-sidebar").waitForExistence(timeout: 5))
        XCTAssertTrue(robot.toolbarButton("main-window-toggle-inspector").waitForExistence(timeout: 5))
        XCTAssertTrue(robot.sidebarGroup("sidebar-group-analyses").waitForExistence(timeout: 5))

        robot.focusSidebar()
        robot.moveSelectionDown()

        XCTAssertTrue(robot.selectedSidebarRow.exists)
    }

    private func makeAnalysesProject() throws -> URL {
        let projectURL = try LungfishProjectFixtureBuilder.makeAnalysesProject(named: "MainWindowFixture")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }
        return projectURL
    }

    private func openOperationsPanel(in app: XCUIApplication) {
        app.activate()
        let operationsMenu = app.menuBars.menuBarItems["Operations"]
        XCTAssertTrue(operationsMenu.waitForExistence(timeout: 5))
        operationsMenu.click()

        let panelItem = app.menuItems["Show Operations Panel"]
        XCTAssertTrue(panelItem.waitForExistence(timeout: 5))
        panelItem.click()

        XCTAssertTrue(app.tables["operations-table"].waitForExistence(timeout: 5))
    }

    private func makeTemporaryEventLogURL(named name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-xcui-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("\(name)-events.log", isDirectory: false)
    }

    private func waitForEvent(prefix: String, in eventLogURL: URL, timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let content = try? String(contentsOf: eventLogURL, encoding: .utf8),
               let line = content
                .components(separatedBy: .newlines)
                .first(where: { $0.hasPrefix(prefix) }) {
                return line
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Timed out waiting for event prefix \(prefix)")
        return ""
    }
}
