import AppKit
import XCTest

@MainActor
struct SystemPanelRobot {
    let app: XCUIApplication
    private static let defaultFolderBundleID = "com.stclairsoft.DefaultFolderX5"

    private var activePanel: XCUIElement {
        let sheet = app.sheets.firstMatch
        if sheet.exists {
            return sheet
        }

        let dialog = app.dialogs.firstMatch
        if dialog.exists {
            return dialog
        }

        return app.windows.firstMatch
    }

    func openDirectory(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        dismissKnownPanelInterferers()
        let panel = activePanel
        XCTAssertTrue(panel.waitForExistence(timeout: 5), file: file, line: line)

        reveal(url, in: panel, file: file, line: line)
        clickPromptButton(in: panel, labels: ["Open", "Choose"], file: file, line: line)
    }

    func saveProject(at projectURL: URL, file: StaticString = #filePath, line: UInt = #line) {
        dismissKnownPanelInterferers()
        let panel = activePanel
        XCTAssertTrue(panel.waitForExistence(timeout: 5), file: file, line: line)

        reveal(projectURL.deletingLastPathComponent(), in: panel, file: file, line: line)

        let nameField = panel.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), file: file, line: line)
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        nameField.typeText(projectURL.lastPathComponent)

        clickPromptButton(in: panel, labels: ["Create", "Save"], file: file, line: line)
    }

    private func reveal(_ url: URL, in panel: XCUIElement, file: StaticString, line: UInt) {
        dismissKnownPanelInterferers()
        panel.click()
        app.typeKey("g", modifierFlags: [.command, .shift])

        let goToFolderSheetIndex = panel.elementType == .sheet ? 1 : 0
        let goToFolderSheet = app.sheets.element(boundBy: goToFolderSheetIndex)
        XCTAssertTrue(goToFolderSheet.waitForExistence(timeout: 5), file: file, line: line)

        let input = goToFolderSheet.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5), file: file, line: line)
        input.click()
        input.typeKey("a", modifierFlags: .command)
        input.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        input.typeText(url.path)

        let goButton = goToFolderSheet.buttons["Go"]
        if goButton.waitForExistence(timeout: 2) {
            goButton.click()
        } else {
            input.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        }
    }

    private func clickPromptButton(
        in panel: XCUIElement,
        labels: [String],
        file: StaticString,
        line: UInt
    ) {
        let predicate = NSPredicate(format: "label IN %@", labels)
        let button = panel.buttons.matching(predicate).firstMatch
        if button.waitForExistence(timeout: 1) {
            button.click()
        } else {
            app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        }
    }

    private func dismissKnownPanelInterferers() {
        for runningApp in NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.defaultFolderBundleID
        ) {
            _ = runningApp.terminate()
            if !runningApp.isTerminated {
                _ = runningApp.forceTerminate()
            }
        }
    }
}
