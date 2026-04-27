import XCTest

final class NFCoreWorkflowXCUITests: XCTestCase {
    @MainActor
    func testNFCoreWorkflowDialogRunsDeterministicWorkflowIntoOperationsPanel() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeIlluminaAssemblyProject(named: "NFCoreWorkflowFixture")
        try "sample,run_accession\nfixture,SRR123456\n".write(
            to: projectURL.appendingPathComponent("accessions.csv"),
            atomically: true,
            encoding: .utf8
        )
        let eventLogURL = makeTemporaryEventLogURL(named: "NFCoreWorkflow")
        let app = XCUIApplication()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        var options = LungfishUITestLaunchOptions(
            scenario: "nfcore-workflow-dialog",
            projectPath: projectURL,
            fixtureRootPath: LungfishFixtureCatalog.fixturesRoot,
            skipWelcome: true,
            eventLogPath: eventLogURL
        )
        options.backendMode = "deterministic"
        options.apply(to: app)
        app.launchEnvironment["LUNGFISH_DEBUG_BYPASS_REQUIRED_SETUP"] = "1"
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        openNFCoreDialog(in: app)

        XCTAssertTrue(app.scrollViews["nf-core-sidebar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["nf-core-tool-download-public-sequencing-reads"].waitForExistence(timeout: 5))
        let detailTitle = app.staticTexts["nf-core-workflow-detail-title"]
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Download public sequencing reads"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["nf-core-fetchngs-usage"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["nf-core-version-label"].exists)
        XCTAssertFalse(app.textFields["nf-core-version-field"].exists)
        XCTAssertFalse(app.segmentedControls["nf-core-executor-picker"].exists)
        XCTAssertFalse(app.staticTexts["nf-core-command-preview"].exists)
        XCTAssertTrue(app.checkBoxes["nf-core-input-row-accessions.csv"].waitForExistence(timeout: 5))

        app.buttons["nf-core-select-all-inputs"].click()
        app.buttons["nf-core-primary-action"].click()

        let invocation = waitForEvent(prefix: "nfcore.cli.invoked", in: eventLogURL, timeout: 5)
        XCTAssertTrue(invocation.contains("workflow run nf-core/fetchngs"))

        let completion = waitForEvent(prefix: "nfcore.workflow.completed", in: eventLogURL, timeout: 5)
        XCTAssertTrue(completion.contains("nf-core/fetchngs"))

        openOperationsPanel(in: app)
        XCTAssertTrue(app.staticTexts["Run nf-core/fetchngs"].waitForExistence(timeout: 5))
    }

    private func openNFCoreDialog(in app: XCUIApplication) {
        app.activate()
        let toolsMenu = app.menuBars.menuBarItems["Tools"]
        XCTAssertTrue(toolsMenu.waitForExistence(timeout: 5))
        toolsMenu.click()

        let item = app.menuItems["nf-core Workflows…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
    }

    private func openOperationsPanel(in app: XCUIApplication) {
        app.activate()
        let operationsMenu = app.menuBars.menuBarItems["Operations"]
        XCTAssertTrue(operationsMenu.waitForExistence(timeout: 5))
        operationsMenu.click()

        let panelItem = app.menuItems["Show Operations Panel"]
        XCTAssertTrue(panelItem.waitForExistence(timeout: 5))
        panelItem.click()
        XCTAssertTrue(app.tables["operations-table"].waitForExistence(timeout: 5))
    }

    private func makeTemporaryEventLogURL(named name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-xcui-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("\(name)-events.log", isDirectory: false)
    }

    private func waitForEvent(prefix: String, in eventLogURL: URL, timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let content = try? String(contentsOf: eventLogURL, encoding: .utf8),
               let line = content
                .components(separatedBy: .newlines)
                .first(where: { $0.hasPrefix(prefix) }) {
                return line
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Timed out waiting for event prefix \(prefix)")
        return ""
    }
}
