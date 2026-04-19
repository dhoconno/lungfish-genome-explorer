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
