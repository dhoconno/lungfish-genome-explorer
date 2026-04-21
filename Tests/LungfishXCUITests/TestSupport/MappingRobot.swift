import XCTest

@MainActor
struct MappingRobot {
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
        let eventLogURL = URL(fileURLWithPath: "/tmp/lungfish-mapping-ui-events.log")
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

    func openMappingDialog(
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

        let mappingMenuItem = app.menuItems["Mapping…"]
        XCTAssertTrue(mappingMenuItem.waitForExistence(timeout: 5), file: file, line: line)
        mappingMenuItem.click()

        XCTAssertTrue(mappingDialog.waitForExistence(timeout: 5), file: file, line: line)
    }

    func chooseMapper(
        _ displayName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sidebarButton = mappingDialog.buttons[toolSidebarIdentifier(for: displayName)].firstMatch
        XCTAssertTrue(sidebarButton.waitForExistence(timeout: 5), file: file, line: line)
        sidebarButton.click()
    }

    private func toolSidebarIdentifier(for displayName: String) -> String {
        let slug = displayName
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "fastq-operations-mapping-tool-\(slug)"
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
            XCTWaiter.wait(for: [expectation], timeout: 30),
            .completed,
            file: file,
            line: line
        )
        button.click()
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

    var mappingDialog: XCUIElement {
        app.descendants(matching: .any)["fastq-operations-mapping-dialog"]
    }

    var primaryActionButton: XCUIElement {
        app.descendants(matching: .any)["fastq-operations-mapping-primary-action"]
    }

    var resultView: XCUIElement {
        app.descendants(matching: .any)["mapping-result-view"]
    }

    var resultTable: XCUIElement {
        app.tables["mapping-result-contig-table"]
    }
}
