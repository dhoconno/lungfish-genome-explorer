import XCTest

@MainActor
struct AssemblyRobot {
    let app: XCUIApplication

    init(app: XCUIApplication = XCUIApplication()) {
        self.app = app
    }

    func launch(
        opening projectURL: URL,
        backendMode: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let eventLogURL = URL(fileURLWithPath: "/tmp/lungfish-assembly-ui-events.log")
        try? FileManager.default.removeItem(at: eventLogURL)

        var options = LungfishUITestLaunchOptions(
            projectPath: projectURL,
            fixtureRootPath: LungfishFixtureCatalog.fixturesRoot
        )
        options.backendMode = backendMode
        options.eventLogPath = eventLogURL
        let workspaceCLI = LungfishFixtureCatalog.repoRoot.appendingPathComponent(".build/debug/lungfish-cli")
        if FileManager.default.isExecutableFile(atPath: workspaceCLI.path) {
            options.cliPath = workspaceCLI
        }
        options.apply(to: app)
        app.launchEnvironment["LUNGFISH_DEBUG_BYPASS_REQUIRED_SETUP"] = "1"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), file: file, line: line)
    }

    func selectSidebarItem(
        named label: String,
        extendingSelection: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let outline = app.outlines["sidebar-outline"]
        XCTAssertTrue(outline.waitForExistence(timeout: 5), file: file, line: line)
        let item = outline.staticTexts[label].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), file: file, line: line)
        item.click()
        if extendingSelection {
            app.typeKey(.downArrow, modifierFlags: .shift)
        }
    }

    func openAssemblyDialog(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        app.activate()

        let toolsMenu = app.menuBars.menuBarItems["Tools"]
        XCTAssertTrue(toolsMenu.waitForExistence(timeout: 5), file: file, line: line)
        toolsMenu.click()

        let fastqOperationsMenu = app.menuItems["FASTQ Operations"]
        XCTAssertTrue(fastqOperationsMenu.waitForExistence(timeout: 5), file: file, line: line)
        fastqOperationsMenu.click()

        let assemblyMenuItem = app.menuItems["Assembly…"]
        XCTAssertTrue(assemblyMenuItem.waitForExistence(timeout: 5), file: file, line: line)
        assemblyMenuItem.click()

        XCTAssertTrue(assemblyDialog.waitForExistence(timeout: 5), file: file, line: line)
    }

    func chooseAssembler(
        _ displayName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sidebarButton = assemblyDialog.buttons[toolSidebarIdentifier(for: displayName)].firstMatch
        let segmentedButton = assemblyDialog.segmentedControls.buttons[displayName].firstMatch
        let plainButton = assemblyDialog.buttons[displayName].firstMatch
        let radioButton = assemblyDialog.radioButtons[displayName].firstMatch
        let button: XCUIElement

        if sidebarButton.waitForExistence(timeout: 1) {
            button = sidebarButton
        } else if segmentedButton.waitForExistence(timeout: 1) {
            button = segmentedButton
        } else if plainButton.waitForExistence(timeout: 1) {
            button = plainButton
        } else {
            XCTAssertTrue(radioButton.waitForExistence(timeout: 5), file: file, line: line)
            button = radioButton
        }

        button.click()
    }

    private func toolSidebarIdentifier(for displayName: String) -> String {
        let slug = displayName
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "fastq-operations-assembly-tool-\(slug)"
    }

    func clickPrimaryAction(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let button = primaryActionButton
        XCTAssertTrue(button.waitForExistence(timeout: 5), file: file, line: line)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: button
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 10),
            .completed,
            file: file,
            line: line
        )
        button.click()
    }

    func expandAdvancedOptionsIfNeeded(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let disclosure = app.descendants(matching: .any)["assembly-advanced-disclosure"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), file: file, line: line)

        let carefulToggle = spadesCarefulToggle
        let flyeToggle = flyeMetagenomeToggle
        let hifiasmToggle = hifiasmPrimaryOnlyToggle
        if carefulToggle.exists || flyeToggle.exists || hifiasmToggle.exists {
            return
        }

        disclosure.click()
    }

    func reveal(
        _ element: XCUIElement,
        maxSwipes: Int = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scrollView = app.scrollViews["assembly-configuration-scrollview"].firstMatch
        for _ in 0..<maxSwipes where !element.exists {
            if scrollView.exists {
                scrollView.swipeUp()
            } else {
                assemblyDialog.swipeUp()
            }
        }
        XCTAssertTrue(element.exists, file: file, line: line)
    }

    func waitForAnalysisRow(
        prefix: String,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
        let analysisRow = app.outlines["sidebar-outline"]
            .descendants(matching: .any)
            .matching(predicate)
            .firstMatch
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: analysisRow
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, file: file, line: line)
    }

    var assemblyDialog: XCUIElement {
        app.descendants(matching: .any)["fastq-operations-assembly-dialog"]
    }

    var primaryActionButton: XCUIElement {
        app.descendants(matching: .any)["fastq-operations-assembly-primary-action"]
    }

    var profilePicker: XCUIElement {
        app.descendants(matching: .any)["assembly-profile-picker"]
    }

    var memorySlider: XCUIElement {
        app.descendants(matching: .any)["assembly-memory-slider"]
    }

    var minContigStepper: XCUIElement {
        let row = app.descendants(matching: .any)["assembly-min-contig-row"]
        return row.exists ? row : app.descendants(matching: .any)["assembly-min-contig-stepper"]
    }

    var spadesCarefulToggle: XCUIElement {
        let identified = app.descendants(matching: .any)["assembly-spades-careful-toggle"]
        return identified.exists ? identified : assemblyDialog.checkBoxes["Careful mode"].firstMatch
    }

    var flyeMetagenomeToggle: XCUIElement {
        let identified = app.descendants(matching: .any)["assembly-flye-metagenome-toggle"]
        return identified.exists ? identified : assemblyDialog.checkBoxes["Metagenome mode"].firstMatch
    }

    var hifiasmPrimaryOnlyToggle: XCUIElement {
        let identified = app.descendants(matching: .any)["assembly-hifiasm-primary-only-toggle"]
        return identified.exists ? identified : assemblyDialog.checkBoxes["Primary contigs only"].firstMatch
    }

    var readinessMessage: XCUIElement {
        app.descendants(matching: .any)["assembly-readiness-message"]
    }

    var resultView: XCUIElement {
        app.descendants(matching: .any)["assembly-result-view"]
    }

    var resultTable: XCUIElement {
        app.tables["assembly-result-contig-table"]
    }
}
