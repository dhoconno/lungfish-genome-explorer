import XCTest

final class BundleBrowserXCUITests: XCTestCase {
    @MainActor
    func testOpeningReferenceBundleShowsBrowserAndPreservesSelection() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeBundleBrowserProject(
            named: "BundleBrowserFixture"
        )
        let robot = BundleBrowserRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL)
        robot.openBundle(named: "TestGenome.lungfishref")
        robot.waitForBrowserLoaded()
        robot.waitForBrowserRow(named: "chr1")

        robot.selectBrowserRow(named: "chr2")
        robot.waitForSelectedBrowserRow(named: "chr2")
    }
}

extension BundleBrowserXCUITests {
    @MainActor
    func testReleaseCandidateNativeBundleBrowser() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try LungfishProjectFixtureBuilder.makeBundleBrowserProject(named: "ReleaseBrowser-\(UUID().uuidString)")
        defer { robot.app.terminate(); try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        try robot.launch()
        robot.openProject(project)
        let browser = BundleBrowserRobot(app: robot.app)
        browser.openBundle(named: "TestGenome.lungfishref")
        browser.waitForBrowserRow(named: "chr1")
        browser.selectBrowserRow(named: "chr2")
        browser.waitForSelectedBrowserRow(named: "chr2")
    }
}
