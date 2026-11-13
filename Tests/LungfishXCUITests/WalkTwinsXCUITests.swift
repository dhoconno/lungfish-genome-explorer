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
    /// which is no fail (the row says so). The EsViritu result holds the detection table of a real run
    /// (`giveEsVirituResultItsDetections`), since the shared fixture's table has columns that `build-db esviritu` does
    /// not read, so its database held no row and the table showed none: the gate runs of lane TWINS-e, f and g clicked
    /// the viewer and never a table.
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
        try Self.giveEsVirituResultItsDetections(in: project, named: Self.esVirituRow)
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
        // The focus goes into the result's table, as it does for a person who worked in it. A table that shows no row
        // fails the twin with its words: a click on the viewer would leave the precondition of the row (the table holds
        // the focus and not the sidebar) untested, as it was in the gate runs of lane TWINS before `giveEsVirituResult`.
        let tableRow = app.outlines["esviritu-detection-outline-view"].firstMatch.outlineRows.firstMatch
        guard tableRow.waitForExistence(timeout: 20) else {
            robot.failShowingScreen("The EsViritu table shows no row, so the focus cannot go into a table")
            return
        }
        tableRow.click()
        // A click that selects a row of an NSTableView makes the table the first responder of the window, so a row that
        // the click left unselected means the table did not take the focus.
        guard Self.poll(5, in: app, until: { tableRow.exists && tableRow.isSelected }) else {
            robot.failShowingScreen("The click on a row of the EsViritu table selected no row, so the table did not take the focus")
            return
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

    /// Old row 14 of the 2026.11.5 owner list (W-30, S2 if a viewer shows the stored numbers of a result over an empty
    /// table with no words). One project holds two SPAdes results with the same stored numbers (2 contigs, 183 bp). The
    /// first keeps its contigs, so its summary strip shows Contigs and Total bp, which proves that the selectors see the
    /// strip. The second has a contigs file that holds bytes and no contig, as the damaged `spades-walk39` result of the
    /// walk did. Opening it must say in words that the contigs file could not be read, and the strip must not show the
    /// stored numbers over the empty table.
    /// It covers a contigs file that holds bytes and no contig. An empty (0-byte) file is not covered: the viewer reads it as an assembly that found nothing (`AssemblyResultViewController.swift:512` refuses a file only when it holds bytes).
    @MainActor
    func testAnAssemblyWhoseContigsFileHoldsNoContigSaysSoAndShowsNoStoredNumbers() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try ReleaseSmokeFixtures.makeClassifierResultsProject(named: "TwinContigs-\(UUID().uuidString)")
        let app = robot.app
        addTeardownBlock {
            MainActor.assumeIsolated { app.terminate() }
            try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
        }
        try ReleaseSmokeFixtures.addAssemblyResult(to: project)
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        let (held, damaged) = ("spades-2026-01-15T13-00-00", "spades-2026-01-15T14-00-00")
        try Self.copyAssemblyResult(named: held, as: damaged, in: analyses)
        try "This is not a FASTA file. No line of it starts with a greater-than sign.\n"
            .write(to: analyses.appendingPathComponent(damaged).appendingPathComponent("contigs.fasta"),
                   atomically: true, encoding: .utf8)
        try robot.launch()
        robot.openProject(project)
        robot.printLaunchRecord(of: #function)
        let any = app.descendants(matching: .any)
        let strip = ["assembly-result-summary-contigs", "assembly-result-summary-total-bp"].map { any[$0].firstMatch }

        ReleaseSmokeFixtures.openSidebarItem(containing: held, in: app)
        guard any["assembly-result-view"].firstMatch.waitForExistence(timeout: 15) else {
            robot.failShowingScreen("The assembly \(held) shows no viewer")
            return
        }
        for field in strip {
            XCTAssertTrue(field.waitForExistence(timeout: 10), "The strip of the assembly with its contigs shows no \(field.identifier)")
        }

        ReleaseSmokeFixtures.openSidebarItem(containing: damaged, in: app)
        for fragment in ["could not read the contigs file of this assembly", "the table is empty and no contig can be selected"] {
            let said = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)
            XCTAssertTrue(app.staticTexts.matching(said).firstMatch.waitForExistence(timeout: 20),
                          "No words say \"\(fragment)\" after the assembly with a damaged contigs file opened")
        }
        guard let alert = robot.firstOf([app.sheets.firstMatch, app.dialogs.firstMatch], timeout: 5) else {
            robot.failShowingScreen("The words about the contigs file stand in no sheet or dialog")
            return
        }
        alert.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "The alert about the contigs file stays after Return")
        for field in strip {
            XCTAssertTrue(field.waitForNonExistence(timeout: 10),
                          "The strip still shows its stored \(field.identifier) over the empty table of the damaged assembly")
        }
    }

    /// Old row 19 of the 2026.11.5 owner list (NTC-P export, S1 for a false clean). The walk's TaxTriage batch named its
    /// control "NTC 1" and the pipeline named its results `NTC_1`. The result is built from `Tests/Fixtures/taxtriage-ntc-p`
    /// (the `patient` and `NTC_1` folders of that batch) with a sidecar that marks "NTC 1" as the control. The control
    /// holds three organisms, so the organism matrix must read Yes for those and No for the one organism only the patient
    /// holds, and the batch report must name "NTC 1 (named NTC_1 in the results)" and list the organisms the control
    /// holds. It must never say "No organisms detected in negative controls". Both files come out of the viewer's Export
    /// menu and its save sheet, as a person takes them.
    @MainActor
    func testTheExportsOfABatchWhoseControlHoldsOrganismsAreNeverFalseClean() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try LungfishProjectFixtureBuilder.makeBundleBrowserProject(named: "TwinNTCP-\(UUID().uuidString)")
        let app = robot.app
        addTeardownBlock {
            MainActor.assumeIsolated { app.terminate() }
            try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
        }
        let row = "taxtriage-2026-01-15T15-00-00"
        try Self.addNTCPBatch(to: project, named: row)
        try robot.launch()
        robot.openProject(project)
        robot.printLaunchRecord(of: #function)

        ReleaseSmokeFixtures.openSidebarItem(containing: row, in: app)
        guard app.descendants(matching: .any)["taxtriage-result-view"].firstMatch.waitForExistence(timeout: 30) else {
            robot.failShowingScreen("The TaxTriage batch \(row) shows no viewer")
            return
        }
        let folder = project.deletingLastPathComponent()
        guard let matrix = Self.exportText(choosing: "Export Organism Matrix (CSV)\u{2026}", as: "organism_matrix.csv", in: folder, robot: robot),
              let report = Self.exportText(choosing: "Export Batch Report\u{2026}", as: "batch_report.txt", in: folder, robot: robot) else {
            return
        }

        let lines = matrix.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.first, "Organism,Mean TASS,Samples Detected,Contamination Risk,NTC_1,patient", "The matrix header:\n\(matrix)")
        let risk = { (organism: String) -> String? in
            guard let line = lines.first(where: { $0.hasPrefix(organism + ",") }) else { return nil }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            return fields.count > 3 ? String(fields[3]) : nil
        }
        for held in ["Severe acute respiratory syndrome coronavirus 2", "Sewage-associated gemycircularvirus 4",
                     "Influenza A virus (A/New York/392/2004(H3N2))"] {
            XCTAssertEqual(risk(held), "Yes", "The matrix does not read Yes for \(held), which the control NTC_1 holds:\n\(matrix)")
        }
        XCTAssertEqual(risk("Bovine coronavirus"), "No", "The matrix does not read No for the organism only the patient holds:\n\(matrix)")

        XCTAssertFalse(report.contains("No organisms detected in negative controls"),
                       "The batch report says no organism was detected in a control that holds three:\n\(report)")
        XCTAssertTrue(report.contains("Negative Controls: NTC 1 (named NTC_1 in the results)"),
                      "The batch report does not name the control as typed and as the results name it:\n\(report)")
        XCTAssertTrue(report.contains("NTC_1 [NTC]: 3 organisms"), "The per-sample summary does not mark NTC_1 as a control:\n\(report)")
        let section = report.components(separatedBy: "--- Contamination Risk Organisms ---").dropFirst().first?
            .components(separatedBy: "--- High-Confidence").first ?? ""
        for held in ["Severe acute respiratory syndrome coronavirus 2", "Influenza A virus (A/New York/392/2004(H3N2))"] {
            XCTAssertTrue(section.contains("\(held) (detected in:") && section.contains("NTC_1"),
                          "The contamination section does not list \(held) as held by NTC_1:\n\(report)")
        }
    }

    /// The `patient` and `NTC_1` folders of `Tests/Fixtures/taxtriage-ntc-p` as one TaxTriage result under Analyses, with
    /// the sidecar of a run whose samples were typed "NTC 1" (a control) and "patient". The app builds the database when
    /// it opens the result, as it does for any result that holds none. The copy leaves each sample's `minimap2`
    /// alignments out (see the comment in the body).
    @MainActor
    private static func addNTCPBatch(to project: URL, named folder: String) throws {
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        let result = analyses.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: LungfishFixtureCatalog.fixturesRoot.appendingPathComponent("taxtriage-ntc-p", isDirectory: true),
                                         to: result)
        try? FileManager.default.removeItem(at: result.appendingPathComponent("README.md"))
        // The release smoke starts the app on an empty home, and that home holds no managed samtools. `build-db` counts
        // every alignment it finds with that samtools, so with the BAMs in place it built the rows, said "Managed
        // samtools is required to compute build-db read counts" and exited 1, and the app showed "Build failed" over
        // the batch (gate run of TWINS-f, `lungfish-cli build-db taxtriage --force` with an empty HOME). The matrix and
        // the report take their words from the rows of the organism reports and the reference maps, so the copy leaves
        // the alignments out and `build-db` finds no BAM to count.
        for sample in ["NTC_1", "patient"] {
            try FileManager.default.removeItem(at: result.appendingPathComponent(sample, isDirectory: true)
                .appendingPathComponent("minimap2", isDirectory: true))
        }
        let sample = { (name: String, file: String, control: Bool) -> [String: Any] in
            ["sampleId": name, "fastq1": "file:///nonexistent/\(file).fastq.gz", "platform": "ILLUMINA", "isNegativeControl": control]
        }
        let config: [String: Any] = ["samples": [sample("NTC 1", "ntc1", true), sample("patient", "patient", false)],
                                     "platform": "ILLUMINA", "outputDirectory": result.absoluteString]
        let sidecar: [String: Any] = ["config": config, "runtime": 120.5, "exitCode": 0, "outputDirectory": result.absoluteString]
        try JSONSerialization.data(withJSONObject: sidecar, options: [.prettyPrinted, .sortedKeys])
            .write(to: result.appendingPathComponent("taxtriage-result.json"))
        try ReleaseSmokeFixtures.writeAnalysisMetadata(tool: "taxtriage", in: result)
    }

    /// Replaces the detection table of the EsViritu result `folder` in the copy of the classifier project with the table
    /// of a real EsViritu run (`Tests/Fixtures/esviritu-mini`, 14 detections). The table of the shared fixture
    /// (`Tests/Fixtures/analyses`) has the columns `virus_name` and `num_reads`, and `build-db esviritu` reads `Name`,
    /// `Accession` and `read_count`: the packaged CLI parsed 0 detection rows from it and built `esviritu.sqlite` with 0
    /// rows (lane TWINS-h), so the table of the viewer showed no row. The shared fixture stays as it is for the tests
    /// that read it with the model parser. `build-db` names the sample by the file name (`testSample`), whatever the
    /// table's `sample_ID` column says.
    @MainActor
    private static func giveEsVirituResultItsDetections(in project: URL, named folder: String) throws {
        let real = LungfishFixtureCatalog.fixturesRoot
            .appendingPathComponent("esviritu-mini/SRR35517703/SRR35517703.detected_virus.info.tsv")
        let held = project.appendingPathComponent("Analyses/\(folder)/testSample.detected_virus.info.tsv")
        try FileManager.default.removeItem(at: held)
        try FileManager.default.copyItem(at: real, to: held)
    }

    /// True once `condition` holds, polled on the app's own run loop for at most `timeout` seconds.
    @MainActor
    private static func poll(_ timeout: TimeInterval, in app: XCUIApplication, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            _ = app.windows.firstMatch.waitForNonExistence(timeout: 0.25)
        } while Date() < deadline
        return condition()
    }

    /// Chooses `item` in the viewer's Export menu, saves as `name` in `folder` through the save sheet (its Go to Folder
    /// field and its name field, as a person would) and returns the text of the file once the export has written it.
    /// Returns nil after recording the failure when a step does not come.
    @MainActor
    private static func exportText(choosing item: String, as name: String, in folder: URL, robot: ReleaseAppSmokeRobot) -> String? {
        let app = robot.app
        let hittable = { (query: XCUIElementQuery) in query.allElementsBoundByIndex.first { $0.exists && $0.isHittable && $0.isEnabled } }
        let button = app.buttons.matching(NSPredicate(format: "label == %@ OR title == %@", "Export", "Export"))
        guard poll(60, in: app, until: { hittable(button) != nil }), let export = hittable(button) else {
            robot.failShowingScreen("The viewer shows no Export button that takes a click")
            return nil
        }
        export.click()
        let menuItem = app.menuItems.matching(NSPredicate(format: "title == %@", item))
        guard poll(10, in: app, until: { hittable(menuItem) != nil }), let entry = hittable(menuItem) else {
            robot.failShowingScreen("The Export menu shows no item \"\(item)\"")
            return nil
        }
        entry.click()
        let nameField = NSPredicate(format: "elementType == %d AND (identifier == %@ OR value BEGINSWITH %@)",
                                    XCUIElement.ElementType.textField.rawValue, "saveAsNameTextField", String(name.prefix(5)))
        guard let panel = robot.firstOf([app.sheets.containing(nameField).firstMatch, app.dialogs.containing(nameField).firstMatch,
                                         app.windows.containing(nameField).firstMatch]) else {
            robot.failShowingScreen("\"\(item)\" opens no save sheet with a name field")
            return nil
        }
        let field = panel.descendants(matching: .textField).matching(nameField).firstMatch
        guard field.waitForExistence(timeout: 5), robot.goToFolder(folder.path, in: panel, focusing: field) else { return nil }
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name)
        field.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let file = folder.appendingPathComponent(name)
        let written = NSPredicate { _, _ in FileManager.default.fileExists(atPath: file.path) }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: written, object: nil)], timeout: 60) == .completed,
              let text = try? String(contentsOf: file, encoding: .utf8) else {
            robot.failShowingScreen("\"\(item)\" wrote no file \(name) within 60 s")
            return nil
        }
        return text
    }

    /// Copies the result folder `name` as `copy` and points the copy's sidecar at its own folder (`outputDirectory`).
    private static func copyAssemblyResult(named name: String, as copy: String, in analyses: URL) throws {
        let destination = analyses.appendingPathComponent(copy, isDirectory: true)
        try FileManager.default.copyItem(at: analyses.appendingPathComponent(name, isDirectory: true), to: destination)
        let sidecar = destination.appendingPathComponent("assembly-result.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        json["outputDirectory"] = destination.path
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: sidecar)
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
    /// selected row is the row of that viewer. The surfaces move after a right-click (the selection lands first, the
    /// viewer follows 0.1 s later, and a result that holds no database builds one, which writes into the watched project
    /// and makes the sidebar rescan), so the read waits up to 20 s for them to agree. A mismatch that lasts the 20 s
    /// fails, and its message lists every selected row of the sidebar.
    @MainActor
    private func assertOneResult(_ moment: String, first: (row: String, viewer: XCUIElement),
                                 other: (row: String, viewer: XCUIElement), in app: XCUIApplication) {
        // `row.exists` first, so a row that is being rebuilt reads as not selected and ends no test with "no matches".
        let isOn = { (name: String) -> Bool in
            let row = self.selectedRow(named: name, in: app)
            return row.exists && row.isSelected
        }
        let agree = { () -> Bool in
            let shows = [first.viewer.exists, other.viewer.exists]
            return shows.filter { $0 }.count == 1 && isOn(first.row) == shows[0] && isOn(other.row) == shows[1]
        }
        _ = Self.poll(20, in: app, until: agree)
        let showsFirst = first.viewer.exists
        let showsOther = other.viewer.exists
        let selectsFirst = isOn(first.row)
        let selectsOther = isOn(other.row)
        // Read only for a failing assertion: the viewers that show and every selected row of the sidebar.
        let state = { () -> String in
            let selected = self.selectedSidebarRows(in: app)
            return "viewer \(showsFirst ? first.row : "")\(showsOther ? other.row : ""), "
                + "selected \(selected.isEmpty ? "(none)" : selected.joined(separator: " | "))"
        }
        XCTAssertEqual([showsFirst, showsOther].filter { $0 }.count, 1, "\(moment): not exactly one result viewer shows (\(state()))")
        XCTAssertEqual(selectsFirst, showsFirst, "\(moment): the sidebar and the viewer name different results (\(state()))")
        XCTAssertEqual(selectsOther, showsOther, "\(moment): the sidebar and the viewer name different results (\(state()))")
    }

    /// The words of every selected row of the sidebar, as the row shows them (its first static text).
    @MainActor
    private func selectedSidebarRows(in app: XCUIApplication) -> [String] {
        app.outlines["sidebar-outline"].firstMatch.outlineRows.allElementsBoundByIndex.filter { $0.isSelected }.map { row in
            let text = row.staticTexts.firstMatch
            guard text.exists else { return row.label }
            return (text.value as? String) ?? text.label
        }
    }

    @MainActor
    private func selectedRow(named text: String, in app: XCUIApplication) -> XCUIElement {
        let matching = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        return app.outlines["sidebar-outline"].firstMatch.outlineRows.containing(matching).firstMatch
    }
}
