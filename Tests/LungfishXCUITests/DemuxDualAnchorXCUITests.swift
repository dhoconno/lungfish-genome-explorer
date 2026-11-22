import AppKit
import XCTest

/// The Demultiplex Barcodes rows that background control cannot drive, in XCUI (lane DEMUX-XCUI, 5.4). Rows A and B are
/// the walk rows of the fix of DEMUX-DUAL-UNANCHORED (`preview-notes.md` section 4) and row a is the Fluidigm row of the
/// 2026.11.12 walk (`WALK-2026.11.12.md:24-26`). Each needs a pick from a pop-up of the dialog (the Project File or the
/// Built-In Kit pop-up), which background control refuses. Like `ExactBareWordsXCUITests` the tests read what the screen
/// and the disk hold and not the dialog's state, find every control by its label, and run only on the gate's candidate
/// (`ReleaseAppSmokeRobot` skips without one, and a skip counts as not run). A run with no Cutadapt fails and is never a skip.
final class DemuxDualAnchorXCUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    /// Row A. A custom dual-index file at Both Ends with no sample sheet and both distances at 0 shows no box and no caption,
    /// and its run makes the sample files of the pairs whole at the two ends on either strand (BIO-DUAL-ANCHOR).
    @MainActor
    func testACustomDualListAtBothEndsShowsNoBoxAndRunsToSampleFiles() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try ReleaseAppSmokeRobot.newProjectURL(named: "ReleaseDualEnds")
        // A teardown block and no `defer` (lane TWINS-b, `WalkTwinsXCUITests.swift:33-37`). With `continueAfterFailure` false XCTest
        // ends a failed test by raising an Objective-C exception, which skips the `defer` of a Swift frame. Run new-1 of this class
        // left its copy running that way, and a copy left running keeps the gate from restoring the account's preferences.
        let app = robot.app
        addTeardownBlock {
            MainActor.assumeIsolated { app.terminate() }
            try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
        }
        let dialog = DemuxDialogDriver(robot: robot, project: project)
        try dialog.start(needsCutadapt: true)
        guard dialog.open(), dialog.use(definition: DemuxDualAnchorFixture.twoName), dialog.click("Cutadapt"), dialog.click("Both Ends"),
              dialog.set("Error Rate", to: "0.15"), dialog.set("5' Distance", to: "0"), dialog.set("3' Distance", to: "0")
        else { return }
        // The dialog asks the chance check in the background, so it is watched twice, once as the settings stand and once
        // more after a pause. A box that comes late shows in one of the two windows, and a refused run would show it in the row.
        guard dialog.noBox(for: DemuxWords.watch, caption: DemuxWords.dualCaption, when: "after the definition and settings are set"),
              dialog.noBox(for: DemuxWords.watch, caption: DemuxWords.dualCaption, when: "on the second look") else { return }
        guard dialog.run() else { return }
        dialog.showOperations()
        guard dialog.finishedRow(timeout: 240) != nil else {
            robot.failShowingScreen("No Operations row finished with \"Done in\" within 240 s of Run, and the rows read \"\(dialog.operationRows())\"")
            return
        }
        continueAfterFailure = true
        let folders = ExactBareFixture.runFolders(in: project)
        XCTAssertEqual(folders.count, 1, "The run writes one run folder with its record, not \(folders.map(\.lastPathComponent)), and the project holds \(DemuxDualAnchorFixture.madeFiles(in: project))")
        guard let runFolder = folders.first else { return }
        // A Cutadapt run keeps a sample's reads as `<sample>.fastq.gz` in its bundle, which the fixture unzips and reads by name.
        // The names show which reads each sample took, since 120 reads in S1 would pass a count alone with the wrong 120.
        for (name, count) in DemuxDualAnchorFixture.expectedCounts.sorted(by: { $0.key < $1.key }) {
            let reads: [String]
            do {
                reads = try DemuxDualAnchorFixture.readNames(ofSample: name, in: runFolder)
            } catch {
                XCTFail("\(name) has no readable sample file: \(error.localizedDescription)")
                continue
            }
            XCTAssertEqual(reads.count, count, "\(name) holds the \(count) reads of the input that have the pair whole at the two ends on either strand")
            let prefix = DemuxDualAnchorFixture.readNamePrefix(ofSample: name)
            let strangers = reads.filter { !$0.hasPrefix(prefix) }
            XCTAssertTrue(strangers.isEmpty, "\(name) holds only reads named \(prefix)... and also holds \(strangers.prefix(5))")
        }
    }

    /// Row B. 96 pairs with both distances at 5 take 6,912 Cutadapt search lines, more than a run can take, so the run is
    /// refused after Run with the cap words and makes nothing. The control at 3 and 3 takes 3,072 lines and starts.
    @MainActor
    func testNinetySixPairsAtFiveAndFiveAreRefusedWithTheCapWordsAndAtThreeAndThreeAreNot() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try ReleaseAppSmokeRobot.newProjectURL(named: "ReleaseDual96")
        // A teardown block and no `defer` (lane TWINS-b, `WalkTwinsXCUITests.swift:33-37`). With `continueAfterFailure` false XCTest
        // ends a failed test by raising an Objective-C exception, which skips the `defer` of a Swift frame. Run new-1 of this class
        // left its copy running that way, and a copy left running keeps the gate from restoring the account's preferences.
        let app = robot.app
        addTeardownBlock {
            MainActor.assumeIsolated { app.terminate() }
            try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
        }
        let dialog = DemuxDialogDriver(robot: robot, project: project)
        try dialog.start(needsCutadapt: true)
        guard dialog.open(), dialog.use(definition: DemuxDualAnchorFixture.ninetySixName), dialog.click("Cutadapt"), dialog.click("Both Ends"),
              dialog.set("Error Rate", to: "0.15"), dialog.set("5' Distance", to: "5"), dialog.set("3' Distance", to: "5")
        else { return }
        // Before Run no box and no caption show, because the dialog swallows the throw of its own check, and that is not a failure.
        guard dialog.noBox(for: DemuxWords.watch, caption: DemuxWords.dualCaption, when: "before Run at 5 and 5") else { return }
        let before = DemuxDualAnchorFixture.madeFiles(in: project)
        guard dialog.run() else { return }
        dialog.showOperations()
        guard let words = dialog.waitForWords(DemuxWords.capOpening, timeout: 90) else {
            robot.failShowingScreen("No row or log holds \"\(DemuxWords.capOpening)\" within 90 s of Run at 5 and 5, and the rows read \"\(dialog.operationRows())\"")
            return
        }
        continueAfterFailure = true
        let text = dialog.words(words)
        for clause in DemuxWords.capClauses {
            XCTAssertTrue(text.contains(clause), "The cap words hold \"\(clause)\" and read \"\(text)\"")
        }
        XCTAssertEqual(DemuxDualAnchorFixture.madeFiles(in: project), before, "The refused run makes no folder and no sample file")
        let capRows = dialog.count(of: DemuxWords.capOpening)

        // The control. At 3 and 3 the lines are 4 x 4 x 2 x 96 = 3,072, under the cap, so the run starts and shows no cap words.
        // It is stopped once it has started, since Cutadapt spends about 90 s on its lines before it reads.
        continueAfterFailure = false
        guard dialog.open(), dialog.use(definition: DemuxDualAnchorFixture.ninetySixName), dialog.click("Cutadapt"), dialog.click("Both Ends"),
              dialog.set("5' Distance", to: "3"), dialog.set("3' Distance", to: "3") else { return }
        guard dialog.run() else { return }
        dialog.showOperations()
        let cancel = robot.app.buttons["operations-cancel-button"].firstMatch
        guard cancel.waitForExistence(timeout: 90) else {
            robot.failShowingScreen("The control run at 3 and 3 shows no running row with a Stop button within 90 s, and the rows read \"\(dialog.operationRows())\"")
            return
        }
        continueAfterFailure = true
        XCTAssertFalse(dialog.countRises(above: capRows, of: DemuxWords.capOpening, within: DemuxWords.watch),
                       "The control at 3 and 3 shows the cap words again, and the rows read \"\(dialog.operationRows())\"")
        if cancel.exists { cancel.click() }
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 90), "Stop ends the control run within 90 s")
    }

    /// Row a of the 2026.11.12 walk. The Fluidigm Access Array kit shows the box with its caption, a kit that the chance check
    /// can judge shows none, and the unticked run is refused in the refusal's words and makes no folder and no sample file.
    @MainActor
    func testTheFluidigmKitShowsTheBoxAndItsUntickedRunIsRefusedWithNothingMade() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try ReleaseAppSmokeRobot.newProjectURL(named: "ReleaseFluidigm")
        // A teardown block and no `defer` (lane TWINS-b, `WalkTwinsXCUITests.swift:33-37`). With `continueAfterFailure` false XCTest
        // ends a failed test by raising an Objective-C exception, which skips the `defer` of a Swift frame. Run new-1 of this class
        // left its copy running that way, and a copy left running keeps the gate from restoring the account's preferences.
        let app = robot.app
        addTeardownBlock {
            MainActor.assumeIsolated { app.terminate() }
            try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
        }
        let dialog = DemuxDialogDriver(robot: robot, project: project)
        try dialog.start(needsCutadapt: false)
        guard dialog.open(), dialog.click("Cutadapt"), dialog.click("Both Ends"), dialog.choose(kit: ["Fluidigm Access Array"]) else { return }
        guard dialog.boxElement().waitForExistence(timeout: 30), dialog.staticText(containing: DemuxWords.fluidigmCaption).waitForExistence(timeout: 10) else {
            robot.failShowingScreen("The Fluidigm Access Array kit shows no box Keep Unchecked Samples with its caption within 30 s")
            return
        }
        continueAfterFailure = true
        XCTAssertEqual(String(describing: dialog.boxElement().value ?? ""), "0", "The box shows unticked")
        continueAfterFailure = false
        // The control. A kit that the chance check can judge takes the box away, which shows that the dialog answered.
        guard dialog.choose(kit: ["Native Barcoding", "24"]) else { return }
        guard dialog.boxElement().waitForNonExistence(timeout: 30) else {
            robot.failShowingScreen("The ONT Native Barcoding 24 kit still shows the box Keep Unchecked Samples 30 s after the pick")
            return
        }
        guard dialog.choose(kit: ["Fluidigm Access Array"]), dialog.boxElement().waitForExistence(timeout: 30) else {
            robot.failShowingScreen("The Fluidigm Access Array kit shows no box again within 30 s")
            return
        }
        let before = DemuxDualAnchorFixture.madeFiles(in: project)
        guard dialog.run() else { return }
        dialog.showOperations()
        guard let words = dialog.waitForWords(DemuxWords.fluidigmRefusal, timeout: 90) else {
            robot.failShowingScreen("No row or log holds \"\(DemuxWords.fluidigmRefusal)\" within 90 s of the unticked run, and the rows read \"\(dialog.operationRows())\"")
            return
        }
        continueAfterFailure = true
        let text = dialog.words(words)
        for clause in DemuxWords.fluidigmClauses {
            XCTAssertTrue(text.contains(clause), "The refusal holds \"\(clause)\" and reads \"\(text)\"")
        }
        XCTAssertEqual(DemuxDualAnchorFixture.madeFiles(in: project), before, "The refused run makes no folder and no sample file")
    }
}

/// The words the tests read, as clauses and not whole strings, so a rewrap cannot turn a test red but a changed word can
/// (`FASTQOperationDialogState+ChanceCaption.swift:101-110`, `DemultiplexError.swift:71-77`).
private enum DemuxWords {
    static let boxLabel = "Keep Unchecked Samples"
    static let dualCaption = "Many reads without barcodes would match this kit's barcodes by chance"
    static let fluidigmCaption = "Cutadapt searches for each kit barcode anywhere in the read"
    static let fluidigmRefusal = "Cutadapt searches each barcode of the kit \""
    static let fluidigmClauses = ["anywhere in the read", "ONT Fluidigm Sample Split", "Read Names", "Keep Unchecked Samples"]
    static let capOpening = "Searching the 96 barcode pairs of"
    static let capClauses = ["6,912 Cutadapt search lines", "more than the 6,000 a run can take", "nothing was run"]
    /// How long the dialog is watched for a box that has not come. The chance check of a kit or a list is a few hundred
    /// milliseconds on a quiet machine, so a box that is going to show has shown well inside this window.
    static let watch: TimeInterval = 8
}

/// What a person does in the dialog, by label. The dialog carries no accessibility identifier.
@MainActor
private final class DemuxDialogDriver {
    let robot: ReleaseAppSmokeRobot
    let project: URL
    var app: XCUIApplication { robot.app }

    init(robot: ReleaseAppSmokeRobot, project: URL) {
        self.robot = robot
        self.project = project
    }

    /// Launches the candidate, makes the project with the input and selects the bundle. A test that runs Cutadapt launches it
    /// with the account's tool store (the smoke's launch home is empty, and Cutadapt is a managed tool). The Fluidigm test runs
    /// no tool and keeps the empty home that the base runs of the smoke use, where the app plans no tool update.
    func start(needsCutadapt: Bool) throws {
        if needsCutadapt {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: DemuxDualAnchorFixture.cutadaptURL().path),
                          "Cutadapt is installed at \(DemuxDualAnchorFixture.cutadaptURL().path). A run with no Cutadapt fails and is never skipped")
            app.launchEnvironment["LUNGFISH_STORAGE_ROOT"] = DemuxDualAnchorFixture.accountToolRoot().path
        }
        try robot.launch()
        if needsCutadapt { guard dismissUpdateToolsSheet(waiting: 15) else { return } }
        try robot.openWritableProject(project) { try DemuxDualAnchorFixture.add(to: $0) }
        XCTAssertEqual(try ExactBareFixture.readCount(ofFASTQAt: DemuxDualAnchorFixture.readsURL(in: project)),
                       DemuxDualAnchorFixture.readTotal, "The input holds 270 reads")
        ReleaseSmokeFixtures.openSidebarItem(containing: DemuxDualAnchorFixture.bundleName, in: app)
        guard app.descendants(matching: .any)["fastq-dataset-view"].firstMatch.waitForExistence(timeout: 15) else {
            robot.failShowingScreen("The \(DemuxDualAnchorFixture.bundleName) bundle shows no FASTQ dataset view")
            return
        }
    }

    /// The Update Tools sheet, which the app puts over the Welcome window after the launch when the tool store it was given is
    /// older than its own list of tools (`AppDelegate+DependencyReconciliation.swift:44-99`). A store with no receipt and
    /// nothing installed gets none, which is why the smoke's empty home never met it. Run new-1 launched with the account's
    /// `~/.lungfish`, whose Kraken2 Standard-16 database is older than the build's, and all three tests failed on it: File > New
    /// Project opened its panel as a sheet of that sheet, so `goToFolder` took the panel's name field for its own Go to Folder
    /// field (`ProjectLifecycleXCUITests.swift:233-245`) and typed into a field with no keyboard focus. An optional update
    /// offers Later, which this clicks. Later downloads nothing and records the deferral in the launch home. A required update
    /// offers Quit and no Later, and then the test fails with the words, since a smoke run installs no tool. The app plans
    /// the update after the launch, so the sheet is waited for `seconds`. It took under 5 s in run new-1.
    func dismissUpdateToolsSheet(waiting seconds: TimeInterval) -> Bool {
        let heading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Update tools to", "Update tools to")).firstMatch
        guard heading.waitForExistence(timeout: seconds) else { return true }
        let later = app.buttons.matching(NSPredicate(format: "label == %@ OR title == %@", "Later", "Later")).firstMatch
        guard later.waitForExistence(timeout: 5) else {
            robot.failShowingScreen("The app offers to update the tools of the account's store and shows no Later button, so the update is required. Update the tools in the app and run again")
            return false
        }
        later.click()
        guard heading.waitForNonExistence(timeout: 15) else {
            robot.failShowingScreen("The Update Tools sheet stays 15 s after Later")
            return false
        }
        return true
    }

    /// Closes the Operations window if it shows. It is a normal window that lies in front of the main window, and the dialog is a
    /// sheet of the main window that is 980 by 700 points, so the window covers the dialog's controls and XCUI finds them but never
    /// as hittable. Run new-2 opened the dialog a second time after the first run had shown the window, and the tree at the
    /// failure holds the Custom Definition button at {933, 305} under the window at {830, 123} that is 900 by 682, so the control
    /// run found no hittable Custom Definition in 10 s. Closing the window keeps every row, and `showOperations` shows it again.
    func closeOperationsWindow() -> Bool {
        let window = app.windows.matching(NSPredicate(format: "title == %@", "Operations")).firstMatch
        guard window.exists else { return true }
        window.buttons[XCUIIdentifierCloseWindow].firstMatch.click()
        guard window.waitForNonExistence(timeout: 10) else {
            robot.failShowingScreen("The Operations window stays 10 s after its close button")
            return false
        }
        return true
    }

    /// Tools > Demultiplexing > Demultiplex Barcodes… on the bundle selected in the sidebar, with no window over the dialog.
    func open() -> Bool {
        guard closeOperationsWindow(), dismissUpdateToolsSheet(waiting: 0) else { return false }
        let tools = app.menuBars.menuBarItems["Tools"]
        guard tools.waitForExistence(timeout: 5) else { robot.failShowingScreen("The menu bar has no Tools menu"); return false }
        tools.click()
        let category = app.menuItems["Demultiplexing"]
        guard category.waitForExistence(timeout: 5) else { robot.failShowingScreen("The Tools menu has no Demultiplexing submenu"); return false }
        category.click()
        let tool = app.menuItems["Demultiplex Barcodes\u{2026}"]
        guard tool.waitForExistence(timeout: 5), tool.isEnabled else {
            robot.failShowingScreen("The Demultiplexing submenu has no live Demultiplex Barcodes\u{2026} item")
            return false
        }
        tool.click()
        return true
    }

    /// A segmented pick. AppKit names a segment as a radio button or a button.
    func click(_ title: String) -> Bool {
        let candidates = [app.radioButtons[title].firstMatch, app.segmentedControls.buttons[title].firstMatch, app.buttons[title].firstMatch]
        guard let control = robot.firstOf(candidates, timeout: 10, hittable: true) else {
            robot.failShowingScreen("The dialog shows no \(title) control within 10 s")
            return false
        }
        control.click()
        return true
    }

    /// Custom Definition, then the file from the Project File pop-up, which SwiftUI draws as a pop-up whose value is the chosen
    /// item's words (`ExactBareWordsXCUITests.swift:66-68`).
    func use(definition name: String) -> Bool {
        guard click("Custom Definition") else { return false }
        let projectFile = app.popUpButtons.matching(NSPredicate(format: "value == %@ OR value CONTAINS %@", "Choose project file", ".csv")).firstMatch
        guard projectFile.waitForExistence(timeout: 10) else {
            robot.failShowingScreen("The dialog shows no Project File picker for the custom definition")
            return false
        }
        projectFile.click()
        let item = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", name)).firstMatch
        guard item.waitForExistence(timeout: 5) else { robot.failShowingScreen("The Project File picker lists no \(name)"); return false }
        item.click()
        return true
    }

    /// The Built-In Kit pop-up, found beside its label, then the item whose title holds every word of `words`.
    func choose(kit words: [String]) -> Bool {
        guard let popUp = neighbour(of: "Built-In Kit", in: app.popUpButtons) else {
            robot.failShowingScreen("The dialog shows no Built-In Kit pop-up")
            return false
        }
        popUp.click()
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: words.map { NSPredicate(format: "title CONTAINS %@", $0) })
        let item = app.menuItems.matching(predicate).firstMatch
        guard item.waitForExistence(timeout: 5) else { robot.failShowingScreen("The Built-In Kit pop-up lists no kit with \(words)"); return false }
        item.click()
        return true
    }

    /// A text field of the dialog, found beside its label, set and read back. The fields carry no label of their own.
    func set(_ label: String, to text: String) -> Bool {
        guard let field = neighbour(of: label, in: app.textFields) else {
            robot.failShowingScreen("The dialog shows no \(label) field")
            return false
        }
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
        field.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
        let shown = String(describing: field.value ?? "")
        guard shown == text else { robot.failShowingScreen("The \(label) field reads \"\(shown)\" after \"\(text)\" was typed"); return false }
        return true
    }

    /// The first element of `query` to the right of the static text `label` on the same line.
    private func neighbour(of label: String, in query: XCUIElementQuery) -> XCUIElement? {
        let title = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", label, label)).firstMatch
        guard title.waitForExistence(timeout: 10) else { return nil }
        let anchor = title.frame
        return query.allElementsBoundByIndex
            .filter { $0.exists && abs($0.frame.midY - anchor.midY) < max(anchor.height, 14) && $0.frame.minX >= anchor.maxX - 2 }
            .min { $0.frame.minX < $1.frame.minX }
    }

    func boxElement() -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR title == %@", DemuxWords.boxLabel, DemuxWords.boxLabel)).firstMatch
    }

    func staticText(containing clause: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", clause, clause)).firstMatch
    }

    /// True when neither the box nor `caption` shows for `seconds`. `waitForExistence` ends at once when the box shows, so a
    /// false answer after the whole window means that it never did.
    func noBox(for seconds: TimeInterval, caption: String, when moment: String) -> Bool {
        if boxElement().waitForExistence(timeout: seconds) || staticText(containing: caption).exists {
            robot.failShowingScreen("The dialog shows the box Keep Unchecked Samples or the caption \"\(caption)\" \(moment)")
            return false
        }
        return true
    }

    func run() -> Bool {
        guard let run = robot.firstOf([app.sheets.buttons["Run"].firstMatch, app.dialogs.buttons["Run"].firstMatch,
                                       app.windows.buttons["Run"].firstMatch], timeout: 10, hittable: true) else {
            robot.failShowingScreen("The dialog shows no Run button")
            return false
        }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: run)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, "Run is live")
        run.click()
        return true
    }

    /// The Operations panel, shown when the run did not show it.
    func showOperations() {
        if !app.descendants(matching: .any)["operations-table"].firstMatch.waitForExistence(timeout: 3) {
            robot.menu("Operations", item: "Show Operations Panel")
        }
    }

    func finishedRow(timeout: TimeInterval) -> XCUIElement? {
        let finished = NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "operations-detail-", "Done in", "Done in")
        let row = app.staticTexts.matching(finished).firstMatch
        return row.waitForExistence(timeout: timeout) ? row : nil
    }

    func operationRows() -> String {
        let rows = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "operations-detail-")).allElementsBoundByIndex
        return rows.map { words($0) }.joined(separator: " | ")
    }

    func words(_ element: XCUIElement) -> String {
        "\(element.label) \((element.value as? String) ?? "")"
    }

    /// The row or the Log text that holds `clause`, once it shows.
    func waitForWords(_ clause: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let candidates = [staticText(containing: clause), app.textViews.matching(NSPredicate(format: "value CONTAINS %@", clause)).firstMatch]
            if let found = candidates.first(where: { $0.exists }) { return found }
            pause(0.5)
        } while Date() < deadline
        return nil
    }

    func count(of clause: String) -> Int {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", clause, clause)).count
            + app.textViews.matching(NSPredicate(format: "value CONTAINS %@", clause)).count
    }

    /// Whether more elements hold `clause` than `count` at any time within `seconds`.
    func countRises(above limit: Int, of clause: String, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if count(of: clause) > limit { return true }
            pause(0.5)
        } while Date() < deadline
        return false
    }

    /// A wait on an expectation that nothing fulfils, which XCTest runs the app's events through.
    private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "pause")], timeout: seconds)
    }
}
