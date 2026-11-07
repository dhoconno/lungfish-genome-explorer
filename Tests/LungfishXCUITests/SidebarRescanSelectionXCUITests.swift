import AppKit
import XCTest

/// Owner row 35 (RESCAN-RESULT-LEFT-ON-SCREEN), the real-click twin of `SidebarRescanSelectionTests` in
/// LungfishAppTests (3.3 lane RESCAN35). The test process copies a result folder into the project, so the sidebar's
/// watcher starts a rescan, and at once clicks another result's row with real input. Each viewer is found by its own
/// identifier, so a result left on screen reads as the old viewer still there. If the app test passes and this one
/// fails, the fault is in the click route and not in the rescan. It needs the console session and an unlocked screen,
/// and it is not in `gates.appSmokeTests`.
final class SidebarRescanSelectionXCUITests: XCTestCase {
    private static let taxTriageRow = "taxtriage-2026-01-15T12-00-00"
    private static let esVirituRow = "esviritu-2026-01-15T10-00-00"

    @MainActor
    func testClickingAnotherResultRightAfterARescanShowsTheClickedResult() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try ReleaseSmokeFixtures.makeClassifierResultsProject(named: "ReleaseRescan-\(UUID().uuidString)")
        defer { robot.app.terminate(); try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        try robot.launch()
        robot.openProject(project)
        let any = robot.app.descendants(matching: .any)
        let taxTriage = (row: Self.taxTriageRow, viewer: any["taxtriage-result-view"].firstMatch)
        let esViritu = (row: Self.esVirituRow, viewer: any["esviritu-result-view"].firstMatch)

        ReleaseSmokeFixtures.openSidebarItem(containing: taxTriage.row, in: robot.app)
        guard taxTriage.viewer.waitForExistence(timeout: 15) else {
            robot.failShowingScreen("The TaxTriage result shows no viewer before the first rescan")
            return
        }
        var shown = taxTriage
        for round in 1...4 {
            let next = shown.row == taxTriage.row ? esViritu : taxTriage
            let copy = String(format: "esviritu-2026-01-15T10-%02d-00", round)
            let destination = analyses.appendingPathComponent(copy, isDirectory: true)
            try FileManager.default.copyItem(at: LungfishFixtureCatalog.analyses.appendingPathComponent(Self.esVirituRow),
                                             to: destination)
            try ReleaseSmokeFixtures.writeAnalysisMetadata(tool: "esviritu", in: destination)
            // At once, before the rescan reports, as the walk clicked right after the new folder arrived.
            ReleaseSmokeFixtures.openSidebarItem(containing: next.row, in: robot.app)
            guard next.viewer.waitForExistence(timeout: 15) else {
                robot.failShowingScreen("Round \(round): the clicked \(next.row) shows no viewer after the rescan")
                return
            }
            XCTAssertTrue(shown.viewer.waitForNonExistence(timeout: 5),
                          "Round \(round): \(shown.row) stays on screen after \(next.row) was clicked during a rescan")
            XCTAssertTrue(ReleaseSmokeFixtures.sidebarRow(containing: copy, in: robot.app).exists,
                          "Round \(round): the sidebar never listed the copied result \(copy)")
            XCTAssertTrue(next.viewer.exists, "Round \(round): the rescan took \(next.row) off the screen")
            XCTAssertTrue(selectedRow(named: next.row, in: robot.app).isSelected,
                          "Round \(round): the sidebar does not select the clicked \(next.row)")
            XCTAssertTrue(ReleaseSmokeFixtures.showInspectorSummary(robot),
                          "Round \(round): the Inspector shows no Summary for \(next.row)")
            shown = next
        }
    }

    @MainActor
    private func selectedRow(named text: String, in app: XCUIApplication) -> XCUIElement {
        let matching = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        return app.outlines["sidebar-outline"].firstMatch.outlineRows.containing(matching).firstMatch
    }
}
