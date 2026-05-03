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
        XCTAssertTrue(robot.app.menuItems["Build Tree with IQ-TREE…"].firstMatch.waitForExistence(timeout: 5))
        robot.app.typeKey(.escape, modifierFlags: [])

        robot.openBundle(named: "MHC Tree.lungfishtree")
        robot.waitForPhylogeneticTreeViewer()
    }
}
