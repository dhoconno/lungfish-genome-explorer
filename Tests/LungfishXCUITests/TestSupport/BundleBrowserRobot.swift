import XCTest

@MainActor
struct BundleBrowserRobot {
    let app: XCUIApplication

    init(app: XCUIApplication = XCUIApplication(bundleIdentifier: "com.lungfish.browser")) {
        self.app = app
    }

    func launch(
        opening projectURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var options = LungfishUITestLaunchOptions(
            projectPath: projectURL,
            fixtureRootPath: LungfishFixtureCatalog.fixturesRoot
        )
        let workspaceCLI = LungfishFixtureCatalog.repoRoot.appendingPathComponent(".build/debug/lungfish-cli")
        if FileManager.default.isExecutableFile(atPath: workspaceCLI.path) {
            options.cliPath = workspaceCLI
        }
        options.apply(to: app)
        app.launchEnvironment["LUNGFISH_DEBUG_BYPASS_REQUIRED_SETUP"] = "1"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), file: file, line: line)
    }

    func openBundle(
        named label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let outline = app.outlines["sidebar-outline"]
        XCTAssertTrue(outline.waitForExistence(timeout: 10), file: file, line: line)
        let displayedLabel = URL(fileURLWithPath: label).deletingPathExtension().lastPathComponent
        let item = outline.staticTexts[label].firstMatch.exists
            ? outline.staticTexts[label].firstMatch
            : outline.staticTexts[displayedLabel].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), file: file, line: line)
        item.click()
    }

    func selectInspectorTab(
        named label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tab = app.buttons[label].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), file: file, line: line)
        tab.click()
    }

    func waitForBrowserLoaded(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(browserView.waitForExistence(timeout: timeout), file: file, line: line)
        XCTAssertTrue(browserTable.waitForExistence(timeout: timeout), file: file, line: line)
    }

    func waitForBrowserRow(
        named name: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForBrowserLoaded(timeout: timeout, file: file, line: line)
        let row = browserTable.staticTexts[name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout), file: file, line: line)
    }

    func selectBrowserRow(
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForBrowserLoaded(file: file, line: line)
        let row = browserTable.staticTexts[name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), file: file, line: line)
        row.click()
    }

    func openSelectedSequence(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForBrowserLoaded(file: file, line: line)
        XCTAssertTrue(openButton.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(openButton.isEnabled, file: file, line: line)
        openButton.click()
    }

    func waitForBackNavigationButton(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(backButton.waitForExistence(timeout: timeout), file: file, line: line)
    }

    func tapBackNavigation(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForBackNavigationButton(file: file, line: line)
        backButton.click()
    }

    func waitForSelectedBrowserRow(
        named name: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForBrowserLoaded(timeout: timeout, file: file, line: line)
        let selectedRow = browserTable
            .descendants(matching: .any)
            .matching(NSPredicate(format: "selected == true"))
            .containing(NSPredicate(format: "label == %@", name))
            .firstMatch
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: selectedRow
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, file: file, line: line)
    }

    func waitForMultipleSequenceAlignmentViewer(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(msaRowTable.waitForExistence(timeout: timeout), file: file, line: line)
        XCTAssertTrue(msaTextView.waitForExistence(timeout: timeout), file: file, line: line)
        XCTAssertTrue(msaSelectedCell.waitForExistence(timeout: timeout), file: file, line: line)
        XCTAssertTrue(app.staticTexts["MHC-A"].firstMatch.waitForExistence(timeout: timeout), file: file, line: line)
    }

    func waitForPhylogeneticTreeViewer(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(treeNodeTable.waitForExistence(timeout: timeout), file: file, line: line)
        XCTAssertTrue(treeCanvasView.waitForExistence(timeout: timeout), file: file, line: line)
        XCTAssertTrue(app.staticTexts["MHC-B"].firstMatch.waitForExistence(timeout: timeout), file: file, line: line)
    }

    var browserView: XCUIElement {
        app.otherElements["bundle-browser-view"]
    }

    var browserTable: XCUIElement {
        app.tables["bundle-browser-table"]
    }

    var openButton: XCUIElement {
        app.buttons["bundle-browser-open-button"]
    }

    var backButton: XCUIElement {
        app.buttons["viewer-back-navigation-button"]
    }

    var msaRowTable: XCUIElement {
        app.descendants(matching: .any)["multiple-sequence-alignment-row-gutter"]
    }

    var msaTextView: XCUIElement {
        app.descendants(matching: .any)["multiple-sequence-alignment-text-view"]
    }

    var msaSelectedCell: XCUIElement {
        app.descendants(matching: .any)["multiple-sequence-alignment-cell-MHC-A-column-1"].firstMatch
    }

    var msaAnnotationTrack: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "multiple-sequence-alignment-annotation-track-MHC-A-"))
            .firstMatch
    }

    var msaAnnotationDrawer: XCUIElement {
        app.descendants(matching: .any)["annotation-table-drawer"]
    }

    var iqTreeOptionsDialog: XCUIElement {
        app.staticTexts["Build Tree with IQ-TREE"].firstMatch
    }

    var iqTreeAdvancedOptionsButton: XCUIElement {
        app.buttons["iqtree-options-advanced-disclosure"].firstMatch
    }

    var iqTreeAdvancedParametersField: XCUIElement {
        app.textFields["iqtree-options-advanced-parameters"].firstMatch
    }

    var iqTreeCancelButton: XCUIElement {
        app.buttons["Cancel"].firstMatch
    }

    var treeNodeTable: XCUIElement {
        app.descendants(matching: .any)["phylogenetic-tree-node-table"]
    }

    var treeCanvasView: XCUIElement {
        app.descendants(matching: .any)["phylogenetic-tree-canvas-view"]
    }

    var treeFitButton: XCUIElement {
        app.buttons["phylogenetic-tree-fit-button"].firstMatch
    }

    var treeZoomInButton: XCUIElement {
        app.buttons["phylogenetic-tree-zoom-in-button"].firstMatch
    }

    var treeZoomOutButton: XCUIElement {
        app.buttons["phylogenetic-tree-zoom-out-button"].firstMatch
    }

    var treeLayoutModeControl: XCUIElement {
        app.segmentedControls["phylogenetic-tree-layout-mode"].firstMatch
    }
}
