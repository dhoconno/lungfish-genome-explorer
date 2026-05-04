import XCTest

final class AlignmentTreeBundleXCUITests: XCTestCase {
    @MainActor
    func testOpeningNativeAlignmentAndTreeBundlesShowsDedicatedViewers() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeAlignmentTreeBundleProject(
            named: "AlignmentTreeFixture"
        )
        let robot = BundleBrowserRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL)

        robot.openBundle(named: "MHC Alignment.lungfishmsa")
        robot.waitForMultipleSequenceAlignmentViewer()
        XCTAssertTrue(robot.msaAnnotationTrack.waitForExistence(timeout: 5))
        XCTAssertTrue(robot.msaAnnotationDrawer.waitForExistence(timeout: 5))
        XCTAssertTrue(robot.app.staticTexts["MHC-domain"].firstMatch.waitForExistence(timeout: 5))
        robot.msaSelectedCell.rightClick()
        let buildTreeMenuItem = robot.app.menuItems["Build Tree with IQ-TREE…"].firstMatch
        XCTAssertTrue(buildTreeMenuItem.waitForExistence(timeout: 5))
        buildTreeMenuItem.click()
        XCTAssertTrue(robot.iqTreeOptionsDialog.waitForExistence(timeout: 5))
        XCTAssertTrue(robot.iqTreeAdvancedOptionsButton.waitForExistence(timeout: 5))
        XCTAssertTrue(robot.app.staticTexts["Sequence Type"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(robot.app.staticTexts["Branch Support"].firstMatch.waitForExistence(timeout: 5))
        robot.iqTreeAdvancedOptionsButton.click()
        XCTAssertTrue(robot.iqTreeAdvancedParametersField.waitForExistence(timeout: 5))
        robot.iqTreeCancelButton.click()

        robot.openBundle(named: "MHC Tree.lungfishtree")
        robot.waitForPhylogeneticTreeViewer()
        XCTAssertTrue(robot.treeFitButton.waitForExistence(timeout: 5))
        XCTAssertTrue(robot.treeZoomInButton.waitForExistence(timeout: 5))
        XCTAssertTrue(robot.treeZoomOutButton.waitForExistence(timeout: 5))
        XCTAssertTrue(robot.treeLayoutModeControl.waitForExistence(timeout: 5))
    }
}
