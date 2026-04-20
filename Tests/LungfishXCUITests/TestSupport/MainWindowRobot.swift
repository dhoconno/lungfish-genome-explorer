import XCTest

@MainActor
struct MainWindowRobot {
    let app: XCUIApplication

    init(app: XCUIApplication = XCUIApplication()) {
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
        options.backendMode = "deterministic"
        options.apply(to: app)
        app.launchEnvironment["LUNGFISH_DEBUG_BYPASS_REQUIRED_SETUP"] = "1"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), file: file, line: line)
        XCTAssertTrue(
            app.descendants(matching: .any)["main-window-shell"].waitForExistence(timeout: 10),
            file: file,
            line: line
        )
    }

    func toolbarButton(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5), file: file, line: line)
        return button
    }

    func sidebarGroup(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        return element
    }

    func focusSidebar(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let outline = app.outlines["sidebar-outline"]
        XCTAssertTrue(outline.waitForExistence(timeout: 5), file: file, line: line)
        outline.click()
        let analysesGroup = sidebarGroup("sidebar-group-analyses", file: file, line: line)
        analysesGroup.click()
    }

    func moveSelectionDown(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(selectedSidebarRow.waitForExistence(timeout: 5), file: file, line: line)
    }

    var selectedSidebarRow: XCUIElement {
        app.outlines["sidebar-outline"]
            .descendants(matching: .any)
            .matching(NSPredicate(format: "selected == true"))
            .firstMatch
    }
}
