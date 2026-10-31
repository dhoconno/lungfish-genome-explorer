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

extension MainWindowNavigationXCUITests {
    @MainActor
    func testReleaseCandidateLaunchAndChannelIdentity() throws {
        let robot = try ReleaseAppSmokeRobot()
        defer { robot.app.terminate() }
        try robot.launch()
    }

    @MainActor
    func testReleaseCandidateImportFailureStatus() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try LungfishProjectFixtureBuilder.makeBundleBrowserProject(named: "ReleaseFailure-\(UUID().uuidString)")
        let invalid = project.deletingLastPathComponent().appendingPathComponent("invalid.csv")
        try "invented,unsupported,columns\ninvalid,row,only\n".write(to: invalid, atomically: true, encoding: .utf8)
        defer { robot.app.terminate(); try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        try robot.launch()
        robot.openProject(project)
        robot.menu("File", item: "Import Center…")
        // The card's Import… button carries the identifier (ImportCenterView.swift). The Release run found no
        // button by it in 5 s (3.0 lane UIP), so the robot also takes the card's own button and waits 15 s.
        let identifier = "import-center-button-fastq-sample-sheet"
        guard let button = robot.firstOf([robot.app.buttons[identifier].firstMatch,
                                          robot.app.descendants(matching: .any)[identifier].firstMatch,
                                          robot.app.descendants(matching: .any)["import-center-card-fastq-sample-sheet"]
                                              .buttons.firstMatch], timeout: 15) else {
            robot.failShowingScreen("The Import Center shows no Import\u{2026} button for the FASTQ Sample Sheet")
            return
        }
        button.click()
        robot.chooseNativePath(invalid)
        XCTAssertTrue(robot.app.staticTexts["Could not read the FASTQ sample sheet"].waitForExistence(timeout: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("invalid.csv").path))
        robot.clickAlertButton("OK")
        XCTAssertTrue(robot.window(project).exists)
    }
}
