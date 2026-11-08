import AppKit
import XCTest

/// Owner row 35 (RESCAN-RESULT-LEFT-ON-SCREEN), the real-click twin of `SidebarRescanSelectionTests` in
/// LungfishAppTests (3.3 lanes RESCAN35 and RESCANFIX). The test process copies a result folder into the project, so
/// the sidebar's watcher starts a rescan, and at once clicks another result's row with real input. Each viewer is
/// found by its own identifier, so a result left on screen reads as the old viewer still there. If the app test passes
/// and this one fails, the fault is in the click route and not in the rescan.
///
/// It runs on the Debug app with its launch hooks (`ProjectLifecycleRobot`), the app `scripts/testing/run-macos-xcui.sh`
/// builds, so it needs the console session and an unlocked screen but no packaged candidate. It is not in
/// `gates.appSmokeTests`. The click cannot force an order against the watcher (the app test forces all three), so a
/// green run shows that a real click works in whichever order it hit.
final class SidebarRescanSelectionXCUITests: XCTestCase {
    private static let taxTriageRow = "taxtriage-2026-01-15T12-00-00"
    private static let esVirituRow = "esviritu-2026-01-15T10-00-00"

    /// Synchronous, because an XCTest interrupt of a test whose class has async set-up or tear-down hung for 11 minutes
    /// in `_interruptTest` (lane RESCANFIX, `frame-hang-sample.txt`).
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testClickingAnotherResultRightAfterARescanShowsTheClickedResult() throws {
        let project = try ReleaseSmokeFixtures.makeClassifierResultsProject(named: "Rescan-\(UUID().uuidString)")
        let robot = ProjectLifecycleRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
        }
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        robot.launch(openingProject: project)
        let window = robot.projectWindow(for: project)
        guard window.waitForExistence(timeout: 15) else {
            XCTFail("The Debug app opened no window for \(project.lastPathComponent)")
            return
        }
        guard closeReadOnlySheet(on: window) else { return }
        let any = robot.app.descendants(matching: .any)
        let taxTriage = (row: Self.taxTriageRow, viewer: any["taxtriage-result-view"].firstMatch)
        let esViritu = (row: Self.esVirituRow, viewer: any["esviritu-result-view"].firstMatch)

        ReleaseSmokeFixtures.openSidebarItem(containing: taxTriage.row, in: robot.app)
        guard taxTriage.viewer.waitForExistence(timeout: 15) else {
            XCTFail("The TaxTriage result shows no viewer before the first rescan")
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
                XCTFail("Round \(round): the clicked \(next.row) shows no viewer after the rescan")
                return
            }
            XCTAssertTrue(shown.viewer.waitForNonExistence(timeout: 5),
                          "Round \(round): \(shown.row) stays on screen after \(next.row) was clicked during a rescan")
            XCTAssertTrue(ReleaseSmokeFixtures.sidebarRow(containing: copy, in: robot.app).exists,
                          "Round \(round): the sidebar never listed the copied result \(copy)")
            XCTAssertTrue(next.viewer.exists, "Round \(round): the rescan took \(next.row) off the screen")
            XCTAssertTrue(selectedRow(named: next.row, in: robot.app).isSelected,
                          "Round \(round): the sidebar does not select the clicked \(next.row)")
            XCTAssertTrue(showInspectorSummary(in: robot.app),
                          "Round \(round): the Inspector shows no Summary for \(next.row)")
            shown = next
        }
    }

    /// The fixture project has no project store (`.project.db`), so the app opens it Read Only and says so in an "Opened
    /// Read Only" sheet on its window (`AppDelegate.completeProjectOpen`, the filesystem fallback). A sheet takes every
    /// click in its window. The first run of this twin (candidate chain 12) clicked the TaxTriage row under that sheet,
    /// got no viewer and stopped at its first wait, before any rescan. The test needs no store, since the test process
    /// copies the result folders in itself and the sidebar's watcher scans the folder with or without one, so it
    /// presses OK before its first click. A window that shows no sheet within 10 s has nothing to close.
    @MainActor
    private func closeReadOnlySheet(on window: XCUIElement) -> Bool {
        let sheet = window.sheets.firstMatch
        guard sheet.waitForExistence(timeout: 10) else { return true }
        let words = sheet.staticTexts.allElementsBoundByIndex
            .map { $0.label.isEmpty ? String(describing: $0.value ?? "") : $0.label }
            .joined(separator: " | ")
        let ok = sheet.buttons["OK"].firstMatch
        guard ok.waitForExistence(timeout: 5) else {
            XCTFail("The sheet on the project window has no OK button, so every click in the window stays blocked: \(words)")
            return false
        }
        ok.click()
        guard sheet.waitForNonExistence(timeout: 5) else {
            XCTFail("The sheet on the project window stays after OK: \(words)")
            return false
        }
        return true
    }

    @MainActor
    private func selectedRow(named text: String, in app: XCUIApplication) -> XCUIElement {
        let matching = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        return app.outlines["sidebar-outline"].firstMatch.outlineRows.containing(matching).firstMatch
    }

    /// `ReleaseSmokeFixtures.showInspectorSummary` on the Debug app: the Inspector toggle is pressed only when no
    /// Summary shows, so a visible Inspector is never hidden.
    @MainActor
    private func showInspectorSummary(in app: XCUIApplication) -> Bool {
        let summary = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Summary")).firstMatch
        if !summary.waitForExistence(timeout: 5) {
            app.buttons["main-window-toggle-inspector"].firstMatch.click()
        }
        guard summary.waitForExistence(timeout: 10) else { return false }
        if summary.elementType == .button, summary.isHittable { summary.click() }
        return true
    }
}
