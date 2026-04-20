import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class AppShellAccessibilityTests: XCTestCase {

    func testMainMenuExposesStableIdentifiersForShellActions() throws {
        let mainMenu = MainMenu.createMainMenu()

        let appMenu = try XCTUnwrap(mainMenu.items.first?.submenu)
        let aboutItem = try XCTUnwrap(appMenu.items.first(where: { $0.title == "About Lungfish Genome Explorer" }))
        let settingsItem = try XCTUnwrap(appMenu.items.first(where: { $0.title == "Settings..." }))
        XCTAssertEqual(aboutItem.identifier?.rawValue, "main-menu-about")
        XCTAssertEqual(settingsItem.identifier?.rawValue, "main-menu-settings")

        let fileMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "File" })?.submenu)
        let openProjectFolderItem = try XCTUnwrap(fileMenu.items.first(where: { $0.title == "Open Project Folder..." }))
        let importCenterItem = try XCTUnwrap(fileMenu.items.first(where: { $0.title == "Import Center…" }))
        let clearTemporaryFilesItem = try XCTUnwrap(fileMenu.items.first(where: { $0.title == "Clear Temporary Files…" }))
        XCTAssertEqual(openProjectFolderItem.identifier?.rawValue, "file-menu-open-project-folder")
        XCTAssertEqual(importCenterItem.identifier?.rawValue, "file-menu-import-center")
        XCTAssertEqual(clearTemporaryFilesItem.identifier?.rawValue, "file-menu-clear-temporary-files")

        let helpMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Help" })?.submenu)
        let helpItem = try XCTUnwrap(helpMenu.items.first(where: { $0.title == "Lungfish Genome Explorer Help" }))
        let gettingStartedItem = try XCTUnwrap(helpMenu.items.first(where: { $0.title == "Getting Started" }))
        let vcfGuideItem = try XCTUnwrap(helpMenu.items.first(where: { $0.title == "VCF Variants Guide" }))
        let aiGuideItem = try XCTUnwrap(helpMenu.items.first(where: { $0.title == "AI Assistant Guide" }))
        let releaseNotesItem = try XCTUnwrap(helpMenu.items.first(where: { $0.title == "Release Notes" }))
        let reportIssueItem = try XCTUnwrap(helpMenu.items.first(where: { $0.title == "Report an Issue..." }))
        XCTAssertEqual(helpItem.identifier?.rawValue, "help-menu-lungfish-help")
        XCTAssertEqual(gettingStartedItem.identifier?.rawValue, "help-menu-getting-started")
        XCTAssertEqual(vcfGuideItem.identifier?.rawValue, "help-menu-vcf-variants-guide")
        XCTAssertEqual(aiGuideItem.identifier?.rawValue, "help-menu-ai-assistant-guide")
        XCTAssertEqual(releaseNotesItem.identifier?.rawValue, "help-menu-release-notes")
        XCTAssertEqual(reportIssueItem.identifier?.rawValue, "help-menu-report-issue")
    }

    func testAboutWindowExposesStableAccessibilityIdentifiers() throws {
        let controller = AboutWindowController()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.identifier?.rawValue, "about-window")

        let root = try XCTUnwrap(window.contentView)
        XCTAssertNotNil(root.descendant(matching: "about-root"))
        XCTAssertNotNil(root.descendant(matching: "about-credits-text-view"))
        XCTAssertNotNil(root.descendant(matching: "about-third-party-licenses-button"))
        XCTAssertNotNil(root.descendant(matching: "about-lab-website-button"))
    }

    func testThirdPartyLicensesWindowExposesStableAccessibilityIdentifiers() throws {
        let controller = ThirdPartyLicensesWindowController()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.identifier?.rawValue, "third-party-licenses-window")

        let root = try XCTUnwrap(window.contentView)
        XCTAssertNotNil(root.descendant(matching: "third-party-licenses-scroll-view"))
        XCTAssertNotNil(root.descendant(matching: "third-party-licenses-text-view"))
    }
}

private extension NSView {
    func descendant(matching identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.descendant(matching: identifier) {
                return match
            }
        }
        return nil
    }
}
