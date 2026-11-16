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

/// A named wait in the manner of `WaitBudget` (LungfishTestSupport). This target does not link that module, so the
/// name travels in the failure words and one constant holds the seconds.
private struct SmokeWaitBudget: Sendable {
    let name: String
    let seconds: TimeInterval
}

extension MainWindowNavigationXCUITests {
    /// How long the second launch is watched for Sparkle's permission window. The window came 3.0 s and 3.2 s after
    /// launch in the two runs that were diagnosed (SMOKE-SPARKLE-PROMPT-LAUNCHES-2-TO-13), so 8 s is more than twice
    /// that. A run that has no window waits the whole budget, since nothing else says the window is not coming.
    private static let sparklePermissionWindow = SmokeWaitBudget(name: "sparkle-permission-window", seconds: 8)

    /// Launches the candidate, quits it and launches it again, because Sparkle asks permission to check for updates
    /// on every launch after its first until someone answers. Its window is app-modal over the welcome window and
    /// has stopped gate runs at the open panel and the import button (SMOKE-SPARKLE-PROMPT-LAUNCHES-2-TO-13). The
    /// first launch ends once `launch()` has seen the app in front and its File menu, which the app answers from its
    /// main thread. Sparkle's first update cycle, queued on the main queue before the run loop starts, writes
    /// `SUHasLaunchedBefore` before that (`SPUUpdater.m`, `startUpdater:` and `startUpdateCycle`). No condition
    /// names the key itself, which lives in the account's preference domain.
    /// The welcome window must be the app's only window. `isEnabled` would not tell that: the application and every
    /// window read `Disabled` in the tree with Sparkle's window and in the tree without it, Sparkle's own window
    /// included (SMOKE-SPARKLE-PROMPT-LAUNCHES-2-TO-13).
    @MainActor
    func testReleaseCandidateLaunchAndChannelIdentity() throws {
        let robot = try ReleaseAppSmokeRobot()
        defer { robot.app.terminate() }
        try robot.launch()
        robot.app.terminate()
        try robot.launch()

        let budget = Self.sparklePermissionWindow
        if robot.app.buttons["Check Automatically"].firstMatch.waitForExistence(timeout: budget.seconds) {
            robot.failShowingScreen("Sparkle asked permission to check for updates on the second launch, since its Check Automatically button came within \(Int(budget.seconds)) s (\(budget.name))")
        }
        let welcome = robot.app.windows.matching(identifier: "welcome-window").firstMatch
        guard welcome.exists else {
            robot.failShowingScreen("The second launch shows no welcome window")
            return
        }
        let windowCount = robot.app.windows.count
        if windowCount != 1 {
            robot.failShowingScreen("The second launch shows \(windowCount) windows and not the welcome window alone, so a window beside it can cover the welcome window")
        }
        XCTAssertTrue(welcome.isHittable, "The welcome window can be clicked")
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
