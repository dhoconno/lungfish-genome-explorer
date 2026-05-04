import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class AppShellAccessibilityTests: XCTestCase {

    func testMainMenuExposesStableIdentifiersForShellActions() throws {
        let _ = NSApplication.shared
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

        let windowMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Window" })?.submenu)
        XCTAssertNil(
            windowMenu.items.first(where: { $0.title == "Move & Resize" }),
            "The app must not create a duplicate Move & Resize menu; macOS supplies that menu at runtime."
        )

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

    func testSetSizeInstallsIntoExistingMoveAndResizeMenu() throws {
        let _ = NSApplication.shared
        let windowMenu = NSMenu(title: "Window")
        let systemMoveAndResizeItem = NSMenuItem(title: "Move & Resize", action: nil, keyEquivalent: "")
        let systemMoveAndResizeMenu = NSMenu(title: "Move & Resize")
        systemMoveAndResizeMenu.addItem(withTitle: "Center", action: nil, keyEquivalent: "")
        systemMoveAndResizeItem.submenu = systemMoveAndResizeMenu
        windowMenu.addItem(systemMoveAndResizeItem)

        MainMenu.installWindowSizeItem(in: windowMenu)
        MainMenu.installWindowSizeItem(in: windowMenu)

        XCTAssertEqual(windowMenu.items.filter { $0.title == "Move & Resize" }.count, 1)
        let setSizeItems = systemMoveAndResizeMenu.items.filter {
            $0.identifier?.rawValue == MainMenuAccessibilityID.setWindowSize
        }
        XCTAssertEqual(setSizeItems.count, 1)
        let setSizeItem = try XCTUnwrap(setSizeItems.first)
        XCTAssertEqual(setSizeItem.title, "Set Size...")
        XCTAssertEqual(setSizeItem.action, #selector(AppDelegate.showWindowSizeDialog(_:)))
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

    func testAlignmentAndTreeViewersExposeStableAccessibilityIdentifiers() throws {
        let alignmentController = MultipleSequenceAlignmentViewController()
        let alignmentView = alignmentController.view
        XCTAssertEqual(alignmentView.accessibilityIdentifier(), "multiple-sequence-alignment-bundle-view")
        XCTAssertNotNil(alignmentView.descendant(matching: "multiple-sequence-alignment-text-view"))
        XCTAssertNotNil(alignmentView.descendant(matching: "multiple-sequence-alignment-matrix-view"))
        XCTAssertNotNil(alignmentView.descendant(matching: "multiple-sequence-alignment-row-gutter"))
        XCTAssertNotNil(alignmentView.descendant(matching: "multiple-sequence-alignment-column-header"))
        XCTAssertNotNil(alignmentView.descendant(matching: "annotation-table-drawer"))
        XCTAssertNotNil(alignmentView.descendant(matching: "multiple-sequence-alignment-search-field"))
        XCTAssertNotNil(alignmentView.descendant(matching: "multiple-sequence-alignment-site-mode"))
        XCTAssertNil(alignmentView.descendant(matching: "multiple-sequence-alignment-detail"))

        let treeController = PhylogeneticTreeViewController()
        let treeView = treeController.view
        XCTAssertEqual(treeView.accessibilityIdentifier(), "phylogenetic-tree-bundle-view")
        XCTAssertNotNil(treeView.descendant(matching: "phylogenetic-tree-summary"))
        XCTAssertNotNil(treeView.descendant(matching: "phylogenetic-tree-node-table"))
        XCTAssertNotNil(treeView.descendant(matching: "phylogenetic-tree-canvas-view"))
        XCTAssertNotNil(treeView.descendant(matching: "phylogenetic-tree-search-field"))
        XCTAssertNotNil(treeView.descendant(matching: "phylogenetic-tree-detail"))
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
