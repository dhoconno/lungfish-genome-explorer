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
///
/// Every launch gets a fresh home under the gate's `LUNGFISH_RELEASE_SMOKE_HOME`, so the candidate
/// starts as on a new Mac and writes nothing into the account that runs the smoke.
@MainActor
struct ReleaseAppSmokeRobot {
    let app: XCUIApplication
    let candidateURL: URL
    let launchHome: URL

    init(testName: String = #function) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LUNGFISH_RELEASE_SMOKE_APP"] else {
            throw XCTSkip("Selected only by the exact-candidate graphical release gate")
        }
        let homes = try XCTUnwrap(environment["LUNGFISH_RELEASE_SMOKE_HOME"], "The gate names a fresh candidate home")
        candidateURL = URL(fileURLWithPath: path).standardizedFileURL
        // A copy already running would be taken over or ended by the launch, so the smoke stops instead.
        let identifier = try XCTUnwrap(Bundle(url: candidateURL)?.bundleIdentifier, "The candidate has no bundle identifier")
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { !$0.isTerminated }
        guard running.isEmpty else {
            throw NSError(domain: "ReleaseAppSmokeRobot", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Lungfish is already running as process \(running[0].processIdentifier). Quit every copy of Lungfish and run the smoke again, since the run would take over that copy."])
        }
        // The gate makes one empty home per selected test, named for the test. The sandboxed
        // runner may not create a folder outside its own container, so it creates nothing here.
        let name = testName.hasSuffix("()") ? String(testName.dropLast(2)) : testName
        launchHome = URL(fileURLWithPath: homes, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: launchHome.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw NSError(domain: "ReleaseAppSmokeRobot", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The gate made no launch home for \(name) at \(launchHome.path)"])
        }
        app = XCUIApplication(url: candidateURL)
        app.launchEnvironment["HOME"] = launchHome.path
        app.launchEnvironment["CFFIXED_USER_HOME"] = launchHome.path
    }

    func launch() throws {
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        let bundle = try XCTUnwrap(Bundle(url: candidateURL))
        let channel = try XCTUnwrap(ProcessInfo.processInfo.environment["LUNGFISH_RELEASE_SMOKE_CHANNEL"],
                                    "The gate names the candidate's channel")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "LungfishReleaseChannel") as? String, channel)
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
