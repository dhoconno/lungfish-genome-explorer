import XCTest

final class MainWindowNavigationXCUITests: XCTestCase {
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
}
