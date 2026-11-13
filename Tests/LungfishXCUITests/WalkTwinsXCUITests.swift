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
        let app = robot.app
        // A teardown block and no `defer`. With `continueAfterFailure` false XCTest ends a failed test by raising an
        // Objective-C exception, and that skips the `defer` of a Swift frame. Gate 1 of lane TWINS-b failed at its
        // Escape step, logged no `Terminate` line and left its copy of the package running, and a copy left running
        // keeps the gate from restoring the account's preferences.
        addTeardownBlock {
            MainActor.assumeIsolated { app.terminate() }
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
        guard waitForContextMenu(in: app, toShow: true) else {
            robot.failShowingScreen("The right-click on \(other.row) opened no context menu")
            return
        }
        assertOneResult("with the menu open", first: first, other: other, in: app)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        // An app whose context menu stays after Escape is a finding and no reason to click elsewhere.
        guard waitForContextMenu(in: app, toShow: false) else {
            robot.failShowingScreen("Escape did not close the context menu")
            return
        }
        assertOneResult("after Escape", first: first, other: other, in: app)
    }

    /// The Rename… item of the open context menu, found by what the screen shows. The menu bar's menus exist all the
    /// time with a frame of zero size off the screen, and its Selection menu has an item of the same title, so
    /// `app.menus.firstMatch` took the Apple menu and neither showed the context menu nor could see it close (gate 1
    /// of lane TWINS-b failed on it at `WalkTwinsXCUITests.swift:64`, while the recording of that run shows the menu
    /// open at the right-click and gone after Escape). Only an item of the open menu can be hit.
    @MainActor
    private func openContextMenuItem(in app: XCUIApplication) -> XCUIElement? {
        app.menuItems.matching(NSPredicate(format: "title == %@", "Rename\u{2026}")).allElementsBoundByIndex
            .first { $0.isHittable }
    }

    /// True once the context menu shows (or, with `toShow` false, no longer shows) within `timeout`.
    @MainActor
    private func waitForContextMenu(in app: XCUIApplication, toShow shows: Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if (openContextMenuItem(in: app) != nil) == shows { return true }
            _ = app.windows.firstMatch.waitForNonExistence(timeout: 0.25)
        } while Date() < deadline
        return (openContextMenuItem(in: app) != nil) == shows
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
