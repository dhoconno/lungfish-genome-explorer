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
        // The import refuses a Read Only project before it reads the sheet (`canWriteProjectOutputs`), so the task
        // works in a project the app made.
        let project = try ReleaseAppSmokeRobot.newProjectURL(named: "ReleaseFailure")
        let invalid = project.deletingLastPathComponent().appendingPathComponent("invalid.csv")
        try "invented,unsupported,columns\ninvalid,row,only\n".write(to: invalid, atomically: true, encoding: .utf8)
        defer { robot.app.terminate(); try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        try robot.launch()
        try robot.openWritableProject(project) { _ in }
        robot.menu("File", item: "Import Center…")
        guard let button = importButton(onCardTitled: "FASTQ Sample Sheet", in: robot) else {
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

    /// The Import… button on the card titled `title`. SwiftUI gives every element in the card list the list's
    /// identifier (GUI run 1 read `import-center-card-list` on each Import… button), so the card's and the button's
    /// own identifiers (`ImportCenterView.swift`) never reach the tree. The button taken is the one level with the
    /// card's title, after the identifier, which answers if the identifiers ever do.
    @MainActor
    private func importButton(onCardTitled title: String, in robot: ReleaseAppSmokeRobot) -> XCUIElement? {
        let identified = robot.app.buttons["import-center-button-fastq-sample-sheet"].firstMatch
        if identified.waitForExistence(timeout: 2) { return identified }
        let window = robot.app.windows["import-center-window"].firstMatch
        let heading = window.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch
        guard heading.waitForExistence(timeout: 15) else { return nil }
        let top = heading.frame.minY
        return window.buttons.matching(NSPredicate(format: "label == %@ OR title == %@", "Import\u{2026}", "Import\u{2026}"))
            .allElementsBoundByIndex.min { abs($0.frame.minY - top) < abs($1.frame.minY - top) }
    }
}
