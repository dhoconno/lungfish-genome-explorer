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

    /// Process ids of the candidate copies this runner launched, so a later task tells its own leftover copy
    /// from one the smoke did not start.
    private static var startedBySmoke: Set<pid_t> = []

    init(testName: String = #function) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LUNGFISH_RELEASE_SMOKE_APP"] else {
            throw XCTSkip("Selected only by the exact-candidate graphical release gate")
        }
        let homes = try XCTUnwrap(environment["LUNGFISH_RELEASE_SMOKE_HOME"], "The gate names a fresh candidate home")
        candidateURL = URL(fileURLWithPath: path).standardizedFileURL
        // A copy already running would be taken over or ended by the launch, so the smoke stops instead. A copy an
        // earlier task of this run started is the smoke's own, and this launch replaces it.
        let identifier = try XCTUnwrap(Bundle(url: candidateURL)?.bundleIdentifier, "The candidate has no bundle identifier")
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { !$0.isTerminated && !Self.startedBySmoke.contains($0.processIdentifier) }
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
        if let identifier = Bundle(url: candidateURL)?.bundleIdentifier {
            // init refused every copy the smoke did not start, so each copy running now is the smoke's own.
            Self.startedBySmoke.formUnion(NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .map(\.processIdentifier))
        }
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
        menu("File", item: "Open Project Folder\u{2026}")
        chooseNativePath(url)
        guard window(url).waitForExistence(timeout: 15) else {
            failShowingScreen("No window for \(url.lastPathComponent) came within 15 s of Open")
            return
        }
        closeSheetRecordingIt(on: window(url))
    }

    /// The first of `candidates` to exist (and be hittable when asked) within `timeout`, or nil.
    func firstOf(_ candidates: [XCUIElement], timeout: TimeInterval = 10, hittable: Bool = false) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let found = candidates.first(where: { $0.exists && (!hittable || $0.isHittable) }) { return found }
            _ = candidates[0].waitForExistence(timeout: 1)
        } while Date() < deadline
        return nil
    }

    /// Clicks `title` in the alert, sheet or dialog in front. An unscoped `buttons["OK"]` took a Touch Bar
    /// button of the same title on the Release app (3.0 lane UIP, NativeOpenSaveCloseReopen).
    func clickAlertButton(_ title: String, timeout: TimeInterval = 10) {
        let candidates = [app.sheets.buttons[title].firstMatch, app.dialogs.buttons[title].firstMatch,
                          app.windows.buttons[title].firstMatch]
        guard let button = firstOf(candidates, timeout: timeout, hittable: true) else {
            failShowingScreen("No \(title) button came in a sheet, dialog or window within \(Int(timeout)) s")
            return
        }
        button.click()
    }

    /// A sheet that comes with a freshly opened project window takes every click in it. The run records its
    /// words and the app's tree, then closes it with its default button so the task reaches its own check.
    func closeSheetRecordingIt(on window: XCUIElement) {
        let sheet = window.sheets.firstMatch
        guard sheet.waitForExistence(timeout: 5) else { return }
        let words = sheet.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        let record = XCTAttachment(string: sheet.debugDescription)
        record.name = "Sheet on the opened project window: \(words)"
        record.lifetime = .keepAlways
        XCTContext.runActivity(named: "A sheet came with the project window: \(words)") { $0.add(record) }
        sheet.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "The sheet on the project window closes: \(words)")
    }

    /// The open panel, found by the identifier AppKit gives an NSOpenPanel (`open-panel`) whether it runs as a
    /// window, a sheet or a dialog, then by its title. 3.0 lane UIP saw `sheets.firstMatch` take an alert sheet
    /// while the panel was the window `open-panel` titled "Open Project Folder".
    func openPanel(timeout: TimeInterval = 10) -> XCUIElement? {
        firstOf([app.windows["open-panel"].firstMatch, app.sheets["open-panel"].firstMatch,
                 app.dialogs["open-panel"].firstMatch,
                 app.windows.matching(NSPredicate(format: "title == %@", "Open Project Folder")).firstMatch],
                timeout: timeout)
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
        // The panel comes a moment after the menu or button click, as a window, a sheet or a dialog.
        guard let panel = openPanel() else {
            failShowingScreen("No open panel came within 10 s")
            return
        }
        panel.click()
        panel.typeKey("g", modifierFlags: [.command, .shift])
        // Go to Folder opens as a sheet of the panel itself, so the field is looked for inside the panel only.
        let editable = NSPredicate(format: "elementType == %d OR elementType == %d",
                                   XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.comboBox.rawValue)
        let input = panel.sheets.firstMatch.descendants(matching: .any).matching(editable).firstMatch
        guard input.waitForExistence(timeout: 5) else {
            failShowingScreen("The open panel (\(panel.elementType.rawValue)) shows no Go to Folder field")
            return
        }
        input.click()
        input.typeKey("a", modifierFlags: .command)
        input.typeText(url.path)
        input.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let open = panel.buttons.matching(NSPredicate(format: "label == %@ OR title == %@", "Open", "Open")).firstMatch
        guard open.waitForExistence(timeout: 5) else {
            failShowingScreen("The open panel shows no Open button after Go to Folder \(url.path)")
            return
        }
        XCTAssertTrue(open.isEnabled, "The open panel's Open button takes \(url.path)")
        open.click()
    }

    /// Fails with what the app shows, attached in full and written into the run's log.
    func failShowingScreen(_ reason: String) {
        let screen = XCTAttachment(string: app.debugDescription)
        screen.name = reason
        screen.lifetime = .keepAlways
        XCTContext.runActivity(named: reason) { $0.add(screen) }
        XCTFail("\(reason). The app shows:\n\(app.debugDescription)")
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
        robot.clickAlertButton("OK")
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
