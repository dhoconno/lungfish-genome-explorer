import XCTest

@MainActor
struct LungfishAppRobot {
    let app: XCUIApplication

    init(app: XCUIApplication = XCUIApplication()) {
        self.app = app
    }

    func launch(
        scenario: String = "database-search-basic",
        pathoplexusConsentAccepted: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        app.launchArguments = [
            "--skip-welcome",
            "--ui-test-mode",
            "-PathoplexusABSConsentAccepted",
            pathoplexusConsentAccepted ? "YES" : "NO",
        ]
        app.launchEnvironment["LUNGFISH_UI_TEST_SCENARIO"] = scenario
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), file: file, line: line)
    }

    @discardableResult
    func openDatabaseSearch(
        destinationMenuTitle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        app.activate()

        let toolsMenu = app.menuBars.menuBarItems["Tools"]
        XCTAssertTrue(toolsMenu.waitForExistence(timeout: 5), file: file, line: line)
        toolsMenu.click()

        let searchDatabasesMenu = app.menuItems["Search Online Databases"]
        XCTAssertTrue(searchDatabasesMenu.waitForExistence(timeout: 5), file: file, line: line)
        searchDatabasesMenu.click()

        let destinationMenuItem = app.menuItems[destinationMenuTitle]
        XCTAssertTrue(destinationMenuItem.waitForExistence(timeout: 5), file: file, line: line)
        destinationMenuItem.click()

        let dialog = databaseSearchDialog
        if !dialog.waitForExistence(timeout: 5) {
            XCTAssertTrue(queryField.waitForExistence(timeout: 5), file: file, line: line)
        }
        return dialog
    }

    var databaseSearchDialog: XCUIElement {
        app.descendants(matching: .any)["database-search-dialog"]
    }

    var queryField: XCUIElement {
        app.descendants(matching: .any)["database-search-query-field"]
    }

    var primaryActionButton: XCUIElement {
        app.descendants(matching: .any)["database-search-primary-action"]
    }

    func sidebarToolButton(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let button = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5), file: file, line: line)
        return button
    }

    func resultRow(
        accession: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let row = app.descendants(matching: .any)["database-search-result-\(accession)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
        return row
    }

    func enterQuery(
        _ query: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let field = queryField
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        field.click()
        field.typeText(query)
    }

    func queryValue(file: StaticString = #filePath, line: UInt = #line) -> String {
        let field = queryField
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        return field.value as? String ?? ""
    }

    func waitForPrimaryActionLabel(
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: primaryActionButton
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed, file: file, line: line)
    }
}
