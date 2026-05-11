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

        let fastqOperationsMenu = app.menuItems["FASTQ/FASTA Operations"]
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

    func selectSidebarItem(
        prefix: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
        let item = app.outlines["sidebar-outline"]
            .descendants(matching: .any)
            .matching(predicate)
            .firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), file: file, line: line)
        item.click()
    }

    func clickInspectorSourceLink(
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let identifier = "mapping-source-data-\(accessibilitySlug(for: label))"
        let identifiedElement = app.descendants(matching: .any)[identifier].firstMatch
        if identifiedElement.waitForExistence(timeout: 10) {
            identifiedElement.click()
            return
        }

        let labeledElement = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
        XCTAssertTrue(labeledElement.waitForExistence(timeout: 10), file: file, line: line)
        labeledElement.click()
    }

    func waitForSelectedSidebarItem(
        containing label: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let selectedRow = app.outlines["sidebar-outline"]
            .descendants(matching: .any)
            .matching(NSPredicate(format: "selected == true"))
            .containing(NSPredicate(format: "label CONTAINS %@", label))
            .firstMatch
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: selectedRow
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, file: file, line: line)
    }

    func focusResultView(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let view = resultView
        XCTAssertTrue(view.waitForExistence(timeout: 10), file: file, line: line)
        view.click()
    }

    func pressResultZoomShortcut(
        _ shortcut: MappingZoomShortcut,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        focusResultView(file: file, line: line)
        switch shortcut {
        case .zoomIn:
            app.typeKey("=", modifierFlags: .command)
        case .zoomOut:
            app.typeKey("-", modifierFlags: .command)
        case .zoomToFit:
            app.typeKey("0", modifierFlags: .command)
        }
    }

    var mappingDialog: XCUIElement {
        app.descendants(matching: .any)["fastq-operations-mapping-dialog"]
    }

    var primaryActionButton: XCUIElement {
        app.descendants(matching: .any)["fastq-operations-mapping-primary-action"]
    }

    var resultView: XCUIElement {
        app.descendants(matching: .any)["reference-bundle-view"]
    }

    var resultTable: XCUIElement {
        app.tables["mapping-result-contig-table"]
    }

    var referenceBundleSequenceTable: XCUIElement {
        app.tables["reference-bundle-sequence-table"]
    }

    func waitForResultViewport(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(resultView.waitForExistence(timeout: timeout), file: file, line: line)
        XCTAssertTrue(resultTable.waitForExistence(timeout: timeout), file: file, line: line)
    }

    private func accessibilitySlug(for text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

enum MappingZoomShortcut {
    case zoomIn
    case zoomOut
    case zoomToFit
}
