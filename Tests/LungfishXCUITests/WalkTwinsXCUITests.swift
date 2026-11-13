import AppKit
import XCTest

/// XCUI twins of owner-list rows that the walks could not drive (lane TWINS, trust session). They run on the packaged
/// app through `ReleaseAppSmokeRobot` with fixtures the test builds, selected by the `ui-twins` profile of
/// `config/test-catalog.json` (`scripts/release/app_smoke_gate.py --profile ui-twins`), which writes `binding: false`
/// and never counts toward a release. A skip counts as not run, so each twin fails and does not skip.
final class WalkTwinsXCUITests: XCTestCase {
    private static let esVirituRow = "esviritu-2026-01-15T10-00-00"
    private static let taxTriageRow = "taxtriage-2026-01-15T12-00-00"

    /// Synchronous, as in `SidebarRescanSelectionXCUITests`, since an interrupt of a test whose class has async set-up or
    /// tear-down hung for 11 minutes in `_interruptTest`.
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    /// Row 7 of the 2026.11.5 owner list (FOCUSDROP, S1 if the sidebar or the Inspector names result B while the table
    /// lists the samples of result A, S2 if the highlight goes back with no words). A result is shown, a click inside its
    /// table gives the table the focus, and a real right-click lands on the row of another result that is not selected.
    /// Whatever the right-click selects, the sidebar's selected row and the viewer on screen must name the same result
    /// with the menu open and after Escape. If the right-click selected nothing, both still name the first result,
    /// which is no fail (the row says so).
    @MainActor
    func testRightClickingAnUnselectedSidebarRowLeavesOneResultOnEverySurface() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try ReleaseSmokeFixtures.makeClassifierResultsProject(named: "TwinRightClick-\(UUID().uuidString)")
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
        }
        try robot.launch()
        robot.openProject(project)
        robot.printLaunchRecord(of: #function)
        let any = robot.app.descendants(matching: .any)
        let first = (row: Self.esVirituRow, viewer: any["esviritu-result-view"].firstMatch)
        let other = (row: Self.taxTriageRow, viewer: any["taxtriage-result-view"].firstMatch)

        ReleaseSmokeFixtures.openSidebarItem(containing: first.row, in: robot.app)
        guard first.viewer.waitForExistence(timeout: 15) else {
            XCTFail("The EsViritu result \(first.row) shows no viewer before the right-click")
            return
        }
        // The focus goes into the result's table, as it does for a person who worked in it.
        let tableRow = robot.app.outlines["esviritu-detection-outline-view"].firstMatch.outlineRows.firstMatch
        if tableRow.waitForExistence(timeout: 10) {
            tableRow.click()
        } else {
            XCTContext.runActivity(named: "The EsViritu table has no row, so the focus goes to the viewer") { _ in }
            first.viewer.click()
        }

        let otherRow = ReleaseSmokeFixtures.sidebarRow(containing: other.row, in: robot.app)
        guard otherRow.waitForExistence(timeout: 10) else {
            XCTFail("The sidebar lists no row for \(other.row)")
            return
        }
        otherRow.rightClick()
        let menu = robot.app.menus.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "The right-click on \(other.row) opened no context menu")
        assertOneResult("with the menu open", first: first, other: other, in: robot.app)
        robot.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5), "Escape did not close the context menu")
        assertOneResult("after Escape", first: first, other: other, in: robot.app)
    }

    /// The viewers on screen and the selected sidebar rows must name one result: exactly one viewer shows, and the
    /// selected row is the row of that viewer.
    @MainActor
    private func assertOneResult(_ moment: String, first: (row: String, viewer: XCUIElement),
                                 other: (row: String, viewer: XCUIElement), in app: XCUIApplication) {
        let showsFirst = first.viewer.exists
        let showsOther = other.viewer.exists
        let selectsFirst = selectedRow(named: first.row, in: app).isSelected
        let selectsOther = selectedRow(named: other.row, in: app).isSelected
        let state = "viewer \(showsFirst ? first.row : "")\(showsOther ? other.row : ""), selected \(selectsFirst ? first.row : "")\(selectsOther ? other.row : "")"
        XCTAssertEqual([showsFirst, showsOther].filter { $0 }.count, 1, "\(moment): not exactly one result viewer shows (\(state))")
        XCTAssertEqual(selectsFirst, showsFirst, "\(moment): the sidebar and the viewer name different results (\(state))")
        XCTAssertEqual(selectsOther, showsOther, "\(moment): the sidebar and the viewer name different results (\(state))")
    }

    @MainActor
    private func selectedRow(named text: String, in app: XCUIApplication) -> XCUIElement {
        let matching = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        return app.outlines["sidebar-outline"].firstMatch.outlineRows.containing(matching).firstMatch
    }
}
