// SidebarNewFolderEmptySpaceTests.swift - New Folder… on an empty part of the sidebar
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp

/// Right-clicking an empty part of the sidebar offers New Folder… whenever a
/// project is open, whatever is selected, and the item creates its folder at
/// the project root.
///
/// A test outline has no click, so its `clickedRow` is -1, which is the
/// empty-space case of the sidebar's real `menuNeedsUpdate`. The tests build
/// the outline's own context menu through that delegate method, read each
/// item's state the way AppKit does when the menu opens (`menu.update()`
/// asks `validateMenuItem`), then run the item the way a click does and answer
/// its sheet. They assert the item's state and the folders on disk.
@MainActor
final class SidebarNewFolderEmptySpaceTests: XCTestCase {
    private static let newFolderTitle = "New Folder\u{2026}"

    private var tempRoot: URL!
    private var projectURL: URL!
    private var readsURL: URL!
    private var fastaURL: URL!
    private var windows: [NSWindow] = []
    /// A pasteboard of this test's own, since the general one is shared by every process on the machine.
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        pasteboard = NSPasteboard.withUniqueName()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarNewFolderEmptySpaceTests-\(UUID().uuidString)", isDirectory: true)
        projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        readsURL = projectURL.appendingPathComponent("Reads", isDirectory: true)
        fastaURL = readsURL.appendingPathComponent("a.fasta")
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try ">a\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        for window in windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
        }
        windows.removeAll()
        pasteboard.releaseGlobally()
        pasteboard = nil
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    // MARK: - Pins that hold before and after the fix

    /// Without a project there is nowhere to create a folder, so the
    /// empty-space menu offers nothing and the rule offers no command.
    func testEmptySpaceMenuOffersNothingWithoutAProject() throws {
        let (sidebar, _) = makeSidebar(openingProject: false)
        let menu = try openContextMenu(sidebar)
        XCTAssertTrue(menu.items.isEmpty, "titles: \(menu.items.map(\.title))")
        XCTAssertFalse(sidebar.canPerformSidebarItemAction(.newFolder))
        XCTAssertNil(sidebar.newFolderParentURL(clickedEmptySpace: true))
    }

    /// A selected row does not change what an empty-space click does. The item
    /// was always enabled then, and it creates at the project root, not inside
    /// the selected folder.
    func testEmptySpaceItemWithAFolderSelectedCreatesAtTheProjectRoot() throws {
        let (sidebar, window) = makeSidebar()
        defer { sidebar.closeProject() }
        XCTAssertTrue(sidebar.selectItem(forURL: readsURL), "could not select Reads")
        XCTAssertEqual(sidebar.selectedItems().count, 1)

        let before = try visibleEntries(of: projectURL)
        let menu = try openContextMenu(sidebar)
        XCTAssertEqual(menu.items.map(\.title), [Self.newFolderTitle])
        let item = try newFolderItem(in: menu)
        XCTAssertTrue(item.isEnabled, "AppKit leaves the item enabled")
        XCTAssertTrue(sidebar.validateMenuItem(item))
        XCTAssertEqual(try visibleEntries(of: projectURL), before, "opening the menu writes nothing")

        try chooseNewFolder(item, named: "From Empty Space", in: window)
        XCTAssertEqual(try visibleEntries(of: projectURL), ["From Empty Space", "Reads"])
        XCTAssertEqual(try visibleEntries(of: readsURL), ["a.fasta"], "nothing was created inside the selected folder")
    }

    /// New Folder… is the one command that needs no row. Every other command
    /// stays unavailable while nothing is selected, and with no project open
    /// nothing is available at all.
    func testNothingSelectedOffersNoCommandOtherThanNewFolder() {
        let (open, _) = makeSidebar()
        defer { open.closeProject() }
        open.outlineView.deselectAll(nil)
        XCTAssertTrue(open.selectedItems().isEmpty)
        for action in SidebarItemAction.allCases where action != .newFolder {
            XCTAssertFalse(open.canPerformSidebarItemAction(action), "\(action) needs a row")
        }

        let (closed, _) = makeSidebar(openingProject: false)
        for action in SidebarItemAction.allCases {
            XCTAssertFalse(closed.canPerformSidebarItemAction(action), "\(action) with no project and no row")
        }
    }

    // MARK: - New Folder… with nothing selected

    func testRightClickOnEmptySpaceWithNothingSelectedEnablesNewFolderAndCreatesAtTheProjectRoot() throws {
        let (sidebar, window) = makeSidebar()
        defer { sidebar.closeProject() }
        sidebar.outlineView.deselectAll(nil)
        XCTAssertTrue(sidebar.selectedItems().isEmpty, "nothing is selected")

        let before = try visibleEntries(of: projectURL)
        let menu = try openContextMenu(sidebar)
        XCTAssertEqual(menu.items.map(\.title), [Self.newFolderTitle], "empty space offers New Folder… and nothing else")
        let item = try newFolderItem(in: menu)
        XCTAssertTrue(item.isEnabled, "AppKit leaves the item enabled")
        XCTAssertTrue(sidebar.validateMenuItem(item), "validateMenuItem agrees with the menu that offered the item")
        XCTAssertEqual(try visibleEntries(of: projectURL), before, "opening the menu writes nothing")

        try chooseNewFolder(item, named: "From Empty Space", in: window)
        XCTAssertEqual(try visibleEntries(of: projectURL), ["From Empty Space", "Reads"], "one folder, at the project root")
    }

    /// The rule behind the context menu, Selection > Sidebar Item and the row
    /// actions. With nothing selected in an open project the one command that
    /// applies is New Folder…, and with no project nothing does.
    func testNothingSelectedInAnOpenProjectOffersNewFolderAndNothingElse() {
        let (open, _) = makeSidebar()
        defer { open.closeProject() }
        open.outlineView.deselectAll(nil)
        XCTAssertEqual(open.availableSidebarItemActions(for: []), [[.newFolder]])
        XCTAssertTrue(open.canPerformSidebarItemAction(.newFolder))

        let (closed, _) = makeSidebar(openingProject: false)
        XCTAssertEqual(closed.availableSidebarItemActions(for: []), [])
        XCTAssertFalse(closed.canPerformSidebarItemAction(.newFolder))
    }

    /// The menu bar reads the same rule. With the outline focused and nothing
    /// selected, Selection > Sidebar Item > New Folder… is enabled, and with no
    /// click to name a parent it targets the project root.
    func testMenuBarNewFolderWithNothingSelectedTargetsTheProjectRoot() throws {
        let (sidebar, window) = makeSidebar()
        defer { sidebar.closeProject() }
        sidebar.outlineView.deselectAll(nil)
        XCTAssertTrue(window.makeFirstResponder(sidebar.outlineView))
        let menuBarItem = NSMenuItem(
            title: Self.newFolderTitle, action: SidebarItemAction.newFolder.menuSelector, keyEquivalent: ""
        )
        XCTAssertTrue(sidebar.validateMenuItem(menuBarItem))
        XCTAssertEqual(
            sidebar.newFolderParentURL(clickedEmptySpace: false)?.standardizedFileURL, projectURL.standardizedFileURL
        )
    }

    // MARK: - Copy Path with several rows

    /// One row copies its path alone, with no line break after it.
    func testCopyPathOfOneRowCopiesThePathAlone() throws {
        let (sidebar, _) = makeSidebar()
        defer { sidebar.closeProject() }
        XCTAssertTrue(sidebar.selectItem(forURL: fastaURL), "could not select a.fasta")
        pasteboard.clearContents()
        sidebar.copySelectedSidebarItemPath(nil)
        XCTAssertEqual(copiedPaths(), [fastaURL.resolvingSymlinksInPath().path])
    }

    /// The pasteboard's lines with their symlinks resolved, so a temporary
    /// folder reached through a symlink reads the same. A line break after the
    /// last path shows as an empty line.
    private func copiedPaths() -> [String] {
        (pasteboard.string(forType: .string) ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : URL(fileURLWithPath: String($0)).resolvingSymlinksInPath().path }
    }

    // MARK: - Helpers

    /// A sidebar in a window of its own, with the fixture project open unless
    /// `openingProject` is false. The window holds the sheet New Folder… shows.
    private func makeSidebar(openingProject: Bool = true) -> (SidebarViewController, NSWindow) {
        let sidebar = SidebarViewController()
        sidebar.copyPasteboard = pasteboard
        sidebar.loadViewIfNeeded()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        sidebar.view.frame = container.bounds
        sidebar.view.autoresizingMask = [.width, .height]
        container.addSubview(sidebar.view)
        let window = NSWindow(
            contentRect: container.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        windows.append(window)
        if openingProject {
            sidebar.openProject(at: projectURL)
            sidebar.outlineView.expandItem(nil, expandChildren: true)
            sidebar.view.layoutSubtreeIfNeeded()
            sidebar.outlineView.layoutSubtreeIfNeeded()
        }
        return (sidebar, window)
    }

    /// Opens the outline's own context menu as AppKit does for a click on empty
    /// space. The delegate builds the items, and `update()` enables each one
    /// through the sidebar's `validateMenuItem`.
    private func openContextMenu(_ sidebar: SidebarViewController) throws -> NSMenu {
        let menu = try XCTUnwrap(sidebar.outlineView.menu, "the outline has no context menu")
        XCTAssertEqual(sidebar.outlineView.clickedRow, -1, "no click happened, so the menu opens on empty space")
        sidebar.menuNeedsUpdate(menu)
        menu.update()
        return menu
    }

    private func newFolderItem(in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(
            menu.items.first { $0.title == Self.newFolderTitle },
            "no New Folder… item in \(menu.items.map(\.title))"
        )
    }

    /// Chooses the item as a click does, types `name` into the sheet's field and
    /// clicks Create, then waits for the folder to appear in the project root.
    private func chooseNewFolder(_ item: NSMenuItem, named name: String, in window: NSWindow) throws {
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item), "nothing handled New Folder…")
        XCTAssertTrue(pollUntil(timeout: 5) { window.attachedSheet != nil }, "the New Folder sheet did not appear")
        let sheet = try XCTUnwrap(window.attachedSheet)
        let field = try XCTUnwrap(
            views(of: NSTextField.self, in: sheet.contentView).first { $0.isEditable }, "the sheet has no name field"
        )
        field.stringValue = name
        let create = try XCTUnwrap(
            views(of: NSButton.self, in: sheet.contentView).first { $0.title == "Create" }, "the sheet has no Create button"
        )
        create.performClick(nil)
        let created = projectURL.appendingPathComponent(name, isDirectory: true)
        XCTAssertTrue(
            pollUntil(timeout: 30) { FileManager.default.fileExists(atPath: created.path) },
            "no folder named \(name) appeared in the project root"
        )
    }

    /// The visible entries of `folder`, sorted. A hidden entry may come from the
    /// sidebar's own bookkeeping, so only what the user sees counts as a write.
    private func visibleEntries(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Every view of type `T` under `root`, `root` included, in depth-first order.
    private func views<T: NSView>(of type: T.Type, in root: NSView?) -> [T] {
        guard let root else { return [] }
        var found: [T] = []
        if let match = root as? T { found.append(match) }
        for child in root.subviews { found += views(of: type, in: child) }
        return found
    }

    /// Runs the main run loop until `condition` holds or `timeout` passes.
    private func pollUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }
}
