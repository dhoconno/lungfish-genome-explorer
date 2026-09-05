import AppKit
import XCTest

final class ProjectLifecycleXCUITests: XCTestCase {
    @MainActor
    func testWelcomeOpenProjectLogsRequestAndOpensInjectedProject() throws {
        let projectURL = try makeProjectFixture(named: "OpenProjectFixture")
        let eventLogURL = makeTemporaryEventLogURL(named: "OpenProject")
        let robot = ProjectLifecycleRobot()
        defer { robot.app.terminate() }

        robot.launchToWelcome(openingProject: projectURL, eventLogPath: eventLogURL)
        robot.tapOpenProjectButton()
        robot.waitForEventLogLine("welcome.dialog.open.requested")

        XCTAssertTrue(robot.projectWindow(for: projectURL).waitForExistence(timeout: 10))
        XCTAssertFalse(robot.welcomeWindow.exists)
    }

    @MainActor
    func testWelcomeCreateProjectLogsRequestAndCreatesInjectedProject() throws {
        let parentDirectory = makeTemporaryDirectory(named: "CreateProject")
        let projectURL = parentDirectory.appendingPathComponent("CreatedFromXCUI-\(UUID().uuidString).lungfish", isDirectory: true)
        let eventLogURL = makeTemporaryEventLogURL(named: "CreateProject")
        let robot = ProjectLifecycleRobot()
        defer { robot.app.terminate() }

        robot.launchToWelcome(creatingProject: projectURL, eventLogPath: eventLogURL)
        robot.tapCreateProjectButton()
        robot.waitForEventLogLine("welcome.dialog.create.requested")

        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("metadata.json").path))
        XCTAssertTrue(robot.projectWindow(for: projectURL).waitForExistence(timeout: 10))
        XCTAssertFalse(robot.welcomeWindow.exists)
    }

    @MainActor
    func testUITestProjectPathLaunchOpensProjectWithoutWelcome() throws {
        let projectURL = try makeProjectFixture(named: "StartupProjectFixture")
        let robot = ProjectLifecycleRobot()
        defer { robot.app.terminate() }

        robot.launch(openingProject: projectURL)

        XCTAssertTrue(robot.projectWindow(for: projectURL).waitForExistence(timeout: 10))
        XCTAssertFalse(robot.welcomeWindow.exists)
    }

    private func makeProjectFixture(named name: String) throws -> URL {
        let projectURL = try LungfishProjectFixtureBuilder.makeAnalysesProject(named: name)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }
        return projectURL
    }

    private func makeTemporaryDirectory(named name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-xcui-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeTemporaryEventLogURL(named name: String) -> URL {
        let directory = makeTemporaryDirectory(named: "\(name)-events")
        return directory.appendingPathComponent("ui-test-events.log", isDirectory: false)
    }
}

/// Uses the assembled Release app and ordinary UI, without DEBUG fixture hooks.
@MainActor
struct ReleaseAppSmokeRobot {
    let app: XCUIApplication
    let candidateURL: URL

    init() throws {
        guard let path = ProcessInfo.processInfo.environment["LUNGFISH_RELEASE_SMOKE_APP"] else {
            throw XCTSkip("Selected only by the exact-candidate graphical release gate")
        }
        candidateURL = URL(fileURLWithPath: path).standardizedFileURL
        app = XCUIApplication(url: candidateURL)
    }

    func launch() throws {
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        let bundle = try XCTUnwrap(Bundle(url: candidateURL))
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "LungfishReleaseChannel") as? String, "stable")
        XCTAssertEqual(ProcessInfo.processInfo.environment["LUNGFISH_RELEASE_SMOKE_CHANNEL"], "stable")
        let identifier = try XCTUnwrap(bundle.bundleIdentifier)
        let matching = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.bundleURL?.standardizedFileURL == candidateURL }
        XCTAssertEqual(matching.count, 1, "The running process must be the exact candidate URL")
        XCTAssertTrue(app.menuBars.menuBarItems["File"].waitForExistence(timeout: 10))
    }

    func openProject(_ url: URL) {
        menu("File", item: "Open Project Folder...")
        chooseNativePath(url)
        XCTAssertTrue(window(url).waitForExistence(timeout: 15))
    }

    func window(_ url: URL) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title CONTAINS %@", url.deletingPathExtension().lastPathComponent)).firstMatch
    }

    func menu(_ name: String, item: String) {
        app.menuBars.menuBarItems[name].click()
        let target = app.menuItems[item]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertTrue(target.isEnabled)
        target.click()
    }

    func chooseNativePath(_ url: URL) {
        let panel = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        panel.click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let goSheet = app.sheets.element(boundBy: panel.elementType == .sheet ? 1 : 0)
        let input = goSheet.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        input.typeKey("a", modifierFlags: .command)
        input.typeText(url.path)
        input.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let open = panel.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(open.isEnabled)
        open.click()
    }
}

extension ProjectLifecycleXCUITests {
    @MainActor
    func testReleaseCandidateNativeOpenSaveCloseReopen() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try LungfishProjectFixtureBuilder.makeBundleBrowserProject(named: "ReleaseLifecycle-\(UUID().uuidString)")
        defer { robot.app.terminate(); try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        try robot.launch()
        robot.openProject(project)
        robot.app.menuBars.menuBarItems["File"].click()
        XCTAssertFalse(robot.app.menuItems["Save"].exists, "There is no unsupported save-all command")
        robot.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        robot.menu("File", item: "About Saving…")
        XCTAssertTrue(robot.app.staticTexts["Saving in Lungfish"].waitForExistence(timeout: 5))
        robot.app.buttons["OK"].firstMatch.click()
        robot.window(project).click()
        robot.menu("File", item: "Close")
        XCTAssertTrue(robot.window(project).waitForNonExistence(timeout: 10))
        robot.openProject(project)
        XCTAssertTrue(robot.window(project).outlines["sidebar-outline"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testReleaseCandidateTwoWindowOwnership() throws {
        let robot = try ReleaseAppSmokeRobot()
        let first = try LungfishProjectFixtureBuilder.makeBundleBrowserProject(named: "ReleaseFirst-\(UUID().uuidString)")
        let second = try LungfishProjectFixtureBuilder.makeBundleBrowserProject(named: "ReleaseSecond-\(UUID().uuidString)")
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        try robot.launch()
        robot.openProject(first)
        robot.openProject(second)
        XCTAssertTrue(robot.window(first).exists)
        robot.window(second).click()
        robot.menu("File", item: "Close")
        XCTAssertTrue(robot.window(second).waitForNonExistence(timeout: 10))
        XCTAssertTrue(robot.window(first).exists)
        XCTAssertTrue(robot.window(first).outlines["sidebar-outline"].exists)
        robot.openProject(second)
        XCTAssertTrue(robot.window(first).exists)
        XCTAssertTrue(robot.window(second).exists)
    }
}
