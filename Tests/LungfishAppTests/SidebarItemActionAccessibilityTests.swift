// SidebarItemActionAccessibilityTests.swift - The sidebar's commands reach the keyboard and AX clients
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishCore

/// The sidebar's context menu, Selection > Sidebar Item and each row's
/// accessibility actions are built from one availability rule
/// (`availableSidebarItemActions(for:)`), so the three surfaces offer the
/// same commands under the same titles. The outline probe test is the
/// go/no-go for every `NSOutlineView` surface of this pass.
@MainActor
final class SidebarItemActionAccessibilityTests: XCTestCase {
    private var tempRoot: URL!
    private var projectURL: URL!
    private var bundleURL: URL!
    private var folderURL: URL!
    private var fastaURL: URL!
    private var secondFastaURL: URL!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarItemActionAccessibilityTests-\(UUID().uuidString)", isDirectory: true)
        projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        bundleURL = projectURL.appendingPathComponent("Ref.lungfishref", isDirectory: true)
        folderURL = projectURL.appendingPathComponent("Reads", isDirectory: true)
        fastaURL = folderURL.appendingPathComponent("a.fasta")
        secondFastaURL = folderURL.appendingPathComponent("b.fasta")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try ">a\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        try ">b\nACGT\n".write(to: secondFastaURL, atomically: true, encoding: .utf8)
        try writeReferenceBundle(at: bundleURL)
    }

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func writeReferenceBundle(at bundleURL: URL) throws {
        let genomeURL = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeURL, withIntermediateDirectories: true)
        try Data().write(to: genomeURL.appendingPathComponent("sequence.fa.gz"))
        try Data().write(to: genomeURL.appendingPathComponent("sequence.fa.gz.fai"))
        let manifest = BundleManifest(
            name: "Ref",
            identifier: "org.test.sidebar.ref",
            source: SourceInfo(organism: "Fixture", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 100,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 100, offset: 0, lineBases: 80, lineWidth: 81)]
            )
        )
        try manifest.save(to: bundleURL)
    }

    /// A sidebar with the fixture project open. `hosted` puts its view in a
    /// window beside a text field, which is what the focus-dependent tests
    /// and the AX probe need (cell views exist only once the outline has
    /// laid out in a window).
    private func makeSidebar(hosted: Bool = false) -> (SidebarViewController, NSTextField?) {
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        var textField: NSTextField?
        if hosted {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
            sidebar.view.frame = NSRect(x: 0, y: 40, width: 320, height: 560)
            sidebar.view.autoresizingMask = [.width, .height]
            container.addSubview(sidebar.view)
            let field = NSTextField(frame: NSRect(x: 8, y: 8, width: 300, height: 24))
            field.isEditable = true
            container.addSubview(field)
            textField = field
            let window = NSWindow(
                contentRect: container.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = container
            windows.append(window)
        }
        sidebar.openProject(at: projectURL)
        if hosted {
            sidebar.outlineView.expandItem(nil, expandChildren: true)
            sidebar.view.layoutSubtreeIfNeeded()
            sidebar.outlineView.layoutSubtreeIfNeeded()
        }
        return (sidebar, textField)
    }

    private func contextMenu(_ sidebar: SidebarViewController, for items: [SidebarItem]) -> NSMenu {
        let menu = NSMenu()
        for item in sidebar.testContextMenuItems(for: items) { menu.addItem(item) }
        return menu
    }

    private func commandTitles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem && $0.submenu == nil }.map(\.title)
    }

    private func select(_ url: URL, in sidebar: SidebarViewController, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(sidebar.selectItem(forURL: url), "could not select \(url.lastPathComponent)", file: file, line: line)
    }

    private func selectionMenuItem(_ action: SidebarItemAction, in mainMenu: NSMenu) throws -> NSMenuItem {
        let identifier = action == .showInInspector
            ? MainMenuAccessibilityID.selectionShowInInspector
            : MainMenuAccessibilityID.selectionSidebarItemAction(action)
        func find(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.identifier?.rawValue == identifier { return item }
                if let submenu = item.submenu, let found = find(in: submenu) { return found }
            }
            return nil
        }
        return try XCTUnwrap(find(in: mainMenu), "no menu bar item for \(action)")
    }

    // MARK: - One availability rule for every surface

    func testContextMenuListsExactlyTheAvailableCommandsWithTheSharedTitles() throws {
        let (sidebar, _) = makeSidebar()
        defer { sidebar.closeProject() }

        for url in [bundleURL!, fastaURL!, folderURL!] {
            select(url, in: sidebar)
            let items = sidebar.selectedItems()
            let expected = sidebar.availableSidebarItemActions(for: items)
                .flatMap { $0 }
                .map { $0.contextTitle(selectionCount: items.count) }
            XCTAssertEqual(commandTitles(contextMenu(sidebar, for: items)), expected, url.lastPathComponent)
        }

        // Two files: the counted title, and no single-item commands.
        select(fastaURL, in: sidebar)
        let rowA = sidebar.outlineView.selectedRow
        select(secondFastaURL, in: sidebar)
        let rowB = sidebar.outlineView.selectedRow
        sidebar.outlineView.selectRowIndexes(IndexSet([rowA, rowB]), byExtendingSelection: false)
        let two = sidebar.selectedItems()
        XCTAssertEqual(two.count, 2, "both FASTA rows selected")
        let titles = commandTitles(contextMenu(sidebar, for: two))
        XCTAssertTrue(titles.contains("Move 2 Items to Trash"), "titles: \(titles)")
        XCTAssertFalse(titles.contains("Copy Path"), "Copy Path is single-item only: \(titles)")
        XCTAssertFalse(titles.contains("Rename\u{2026}"), "titles: \(titles)")
    }

    func testBundleContextMenuKeepsTheBaselineCommandsInAppleTitleCase() {
        let (sidebar, _) = makeSidebar()
        defer { sidebar.closeProject() }
        select(bundleURL, in: sidebar)
        let titles = commandTitles(contextMenu(sidebar, for: sidebar.selectedItems()))
        for expected in [
            "Export Sequences\u{2026}", "Open Bundle", "Show Package Contents", "Get Bundle Info",
            "Import Sample Metadata\u{2026}", "New Folder\u{2026}", "Show in Finder", "Copy Path",
            "Show in Inspector", "Rename\u{2026}", "Move to Trash",
        ] {
            XCTAssertTrue(titles.contains(expected), "missing \(expected) in \(titles)")
        }
        XCTAssertFalse(titles.contains("Rename..."), "three dots are not an ellipsis")
        XCTAssertFalse(titles.contains("Open"), "a bundle opens with Open Bundle, not Open")
        XCTAssertTrue(titles.allSatisfy { !$0.contains("...") }, "titles: \(titles)")
    }

    func testFolderContextMenuOffersFolderMetadataOnlyWithFASTQChildren() {
        let (sidebar, _) = makeSidebar()
        defer { sidebar.closeProject() }
        select(folderURL, in: sidebar)
        let titles = commandTitles(contextMenu(sidebar, for: sidebar.selectedItems()))
        XCTAssertFalse(titles.contains("Edit Folder Sample Metadata\u{2026}"), "titles: \(titles)")
        XCTAssertTrue(titles.contains("New Folder\u{2026}"), "titles: \(titles)")
        XCTAssertTrue(titles.contains("Duplicate"), "titles: \(titles)")
        XCTAssertFalse(titles.contains("Open Bundle"), "titles: \(titles)")
    }

    func testSelectSiblingsIsOfferedOnlyWhenTheItemHasSiblings() {
        let (sidebar, _) = makeSidebar()
        defer { sidebar.closeProject() }
        select(fastaURL, in: sidebar)
        XCTAssertTrue(sidebar.canPerformSidebarItemAction(.selectSiblings), "a.fasta sits beside b.fasta")
        let titles = commandTitles(contextMenu(sidebar, for: sidebar.selectedItems()))
        XCTAssertTrue(titles.contains("Select Siblings"), "titles: \(titles)")

        sidebar.selectSiblingSidebarItems(nil)
        XCTAssertEqual(
            Set(sidebar.selectedItems().compactMap { $0.url?.lastPathComponent }),
            ["a.fasta", "b.fasta"]
        )
    }

    // MARK: - Menu bar routing and validation

    func testEveryMenuBarSidebarCommandHasAHandlerOnTheSidebar() {
        let (sidebar, _) = makeSidebar()
        defer { sidebar.closeProject() }
        for action in SidebarItemAction.menuSections.flatMap({ $0 }) + [.showInInspector] {
            XCTAssertTrue(sidebar.responds(to: action.menuSelector), "\(action) has no handler on the sidebar")
        }
        XCTAssertTrue(sidebar.responds(to: #selector(ResultRowMenuActions.showSelectedRowInInspector(_:))))
    }

    func testMenuBarItemsValidateOnlyWhileTheOutlineIsFirstResponder() throws {
        let (sidebar, textField) = makeSidebar(hosted: true)
        defer { sidebar.closeProject() }
        let window = try XCTUnwrap(sidebar.view.window)
        let mainMenu = MainMenu.createMainMenu()
        select(bundleURL, in: sidebar)

        let moveToTrash = try selectionMenuItem(.moveToTrash, in: mainMenu)
        let copyPath = try selectionMenuItem(.copyPath, in: mainMenu)
        let showInInspector = try selectionMenuItem(.showInInspector, in: mainMenu)
        let openBundle = try selectionMenuItem(.openBundle, in: mainMenu)

        // A text field has focus: Cmd-Delete must stay the field's own.
        XCTAssertTrue(window.makeFirstResponder(textField))
        XCTAssertFalse(sidebar.sidebarOutlineHasKeyboardFocus)
        XCTAssertFalse(sidebar.validateMenuItem(moveToTrash))
        XCTAssertFalse(sidebar.validateMenuItem(copyPath))
        XCTAssertFalse(sidebar.validateMenuItem(showInInspector))

        // The outline has focus: the selection decides.
        XCTAssertTrue(window.makeFirstResponder(sidebar.outlineView))
        XCTAssertTrue(sidebar.sidebarOutlineHasKeyboardFocus)
        XCTAssertTrue(sidebar.validateMenuItem(moveToTrash))
        XCTAssertTrue(sidebar.validateMenuItem(copyPath))
        XCTAssertTrue(sidebar.validateMenuItem(showInInspector))
        XCTAssertTrue(sidebar.validateMenuItem(openBundle))

        // A folder: Open Bundle no longer applies, Move to Trash still does.
        select(folderURL, in: sidebar)
        XCTAssertFalse(sidebar.validateMenuItem(openBundle))
        XCTAssertTrue(sidebar.validateMenuItem(moveToTrash))

        // Nothing selected: nothing to act on.
        sidebar.outlineView.deselectAll(nil)
        XCTAssertFalse(sidebar.validateMenuItem(moveToTrash))
        XCTAssertFalse(sidebar.validateMenuItem(copyPath))
    }

    /// Cmd-Delete in a text field is the field's own (delete to the start of
    /// the line). A real key event goes through the application's key
    /// handling, the menu bar first, and must neither move an item to the
    /// Trash nor lose its text editing meaning.
    func testCommandDeleteInATextFieldEditsTextAndTrashesNothing() throws {
        let (sidebar, textField) = makeSidebar(hosted: true)
        defer { sidebar.closeProject() }
        let field = try XCTUnwrap(textField)
        let window = try XCTUnwrap(sidebar.view.window)
        let previousMenu = NSApp.mainMenu
        NSApp.mainMenu = MainMenu.createMainMenu()
        defer { NSApp.mainMenu = previousMenu }
        window.makeKeyAndOrderFront(nil)
        select(bundleURL, in: sidebar)

        field.stringValue = "hello world"
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 11, length: 0))

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
            isARepeat: false, keyCode: 51
        ))
        // The menu bar sees the chord first and declines it.
        XCTAssertFalse(NSApp.mainMenu?.performKeyEquivalent(with: event) ?? true, "the sidebar command is disabled in a text field")
        // Then the focused field handles it.
        window.sendEvent(event)
        XCTAssertEqual(field.stringValue, "", "Cmd-Delete deleted to the start of the line")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path), "nothing was moved to the Trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
        XCTAssertEqual(sidebar.selectedItems().compactMap { $0.url?.lastPathComponent }, ["Ref.lungfishref"])
    }

    func testContextMenuItemsValidateFromTheSelectionAlone() throws {
        let (sidebar, textField) = makeSidebar(hosted: true)
        defer { sidebar.closeProject() }
        let window = try XCTUnwrap(sidebar.view.window)
        select(bundleURL, in: sidebar)
        XCTAssertTrue(window.makeFirstResponder(textField))

        let contextMenu = try XCTUnwrap(sidebar.outlineView.menu)
        contextMenu.removeAllItems()
        for item in sidebar.testContextMenuItems(for: sidebar.selectedItems()) { contextMenu.addItem(item) }
        let copyPath = try XCTUnwrap(contextMenu.items.first { $0.title == "Copy Path" })
        XCTAssertTrue(sidebar.validateMenuItem(copyPath), "the context menu belongs to the outline")
    }

    func testMenuBarCopyPathAndShowInInspectorActOnTheSelection() throws {
        let (sidebar, _) = makeSidebar(hosted: true)
        defer { sidebar.closeProject() }
        select(bundleURL, in: sidebar)

        NSPasteboard.general.clearContents()
        sidebar.copySelectedSidebarItemPath(nil)
        XCTAssertEqual(copiedPath(), bundleURL.resolvingSymlinksInPath().path)

        // The post is synchronous, so a plain observer sees it before the
        // handler returns.
        let observer = InspectorRequestObserver()
        NotificationCenter.default.addObserver(
            observer, selector: #selector(InspectorRequestObserver.received(_:)),
            name: .showInspectorRequested, object: sidebar
        )
        defer { NotificationCenter.default.removeObserver(observer) }
        sidebar.showSelectedRowInInspector(nil)
        XCTAssertEqual(observer.requestedTabs, ["document"])
    }

    /// The pasteboard's string with its symlinks resolved, so a temporary
    /// directory under /var compares equal to the same path under /private.
    private func copiedPath() -> String? {
        NSPasteboard.general.string(forType: .string).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    // MARK: - The outline probe (go/no-go for every NSOutlineView surface)

    func testOutlineRowCellsListEachCommandOnceAndCopyPathPerformsThroughAX() throws {
        let (sidebar, _) = makeSidebar(hosted: true)
        defer { sidebar.closeProject() }
        select(bundleURL, in: sidebar)
        let bundleItem = try XCTUnwrap(sidebar.selectedItems().first)
        let row = sidebar.outlineView.row(forItem: bundleItem)
        XCTAssertGreaterThanOrEqual(row, 0)

        let proxies = AccessibilityRowProbe.outlineRowProxies(of: sidebar.outlineView)
        XCTAssertEqual(proxies.count, sidebar.outlineView.numberOfRows, "one AX row per outline row")
        let rowProxy = proxies[row]

        let expected = sidebar.availableSidebarItemActions(for: [bundleItem], includingManifestChecks: false)
            .flatMap { $0 }
            .map(\.title)
        XCTAssertFalse(expected.isEmpty)
        let served = AccessibilityRowProbe.servedCellActionNames(rowProxy)
        XCTAssertFalse(served.isEmpty, "the row has no cell proxies")
        for names in served {
            XCTAssertEqual(names, expected, "each cell lists every command exactly once, as the AX server serves it")
        }
        XCTAssertTrue(AccessibilityRowProbe.rowActionNames(rowProxy).isEmpty, "the row proxy itself carries nothing")

        // Perform through the proxy, as an AX client would, with another row
        // selected first: the action resolves its own row.
        select(fastaURL, in: sidebar)
        NSPasteboard.general.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Path", in: rowProxy))
        XCTAssertEqual(copiedPath(), bundleURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(
            sidebar.selectedItems().compactMap { $0.url?.resolvingSymlinksInPath() },
            [bundleURL.resolvingSymlinksInPath()],
            "the action selected its row"
        )
    }

    func testEveryContextMenuCommandHasACellActionOrAMenuBarRoute() throws {
        let (sidebar, _) = makeSidebar(hosted: true)
        defer { sidebar.closeProject() }
        let mainMenu = MainMenu.createMainMenu()

        for url in [bundleURL!, fastaURL!, folderURL!] {
            select(url, in: sidebar)
            let item = try XCTUnwrap(sidebar.selectedItems().first)
            let row = sidebar.outlineView.row(forItem: item)
            let rowProxy = AccessibilityRowProbe.outlineRowProxies(of: sidebar.outlineView)[row]
            ContextMenuParityAssert.assertParity(
                contextMenu: contextMenu(sidebar, for: [item]),
                cellActionNames: AccessibilityRowProbe.firstCellActionNames(rowProxy),
                mainMenu: mainMenu
            )
        }
    }

    func testNewFolderFromTheMenuBarTargetsTheSelectedFolderWithoutAClick() {
        let (sidebar, _) = makeSidebar()
        defer { sidebar.closeProject() }
        select(folderURL, in: sidebar)
        XCTAssertEqual(sidebar.newFolderParentURL(clickedEmptySpace: false)?.standardizedFileURL, folderURL.standardizedFileURL)
        select(fastaURL, in: sidebar)
        XCTAssertEqual(sidebar.newFolderParentURL(clickedEmptySpace: false)?.standardizedFileURL, projectURL.standardizedFileURL)
        select(folderURL, in: sidebar)
        XCTAssertEqual(
            sidebar.newFolderParentURL(clickedEmptySpace: true)?.standardizedFileURL, projectURL.standardizedFileURL,
            "the empty-space item always creates at the root"
        )
    }
}

@MainActor
private final class InspectorRequestObserver: NSObject {
    var requestedTabs: [String] = []

    @objc func received(_ note: Notification) {
        requestedTabs.append(note.userInfo?[NotificationUserInfoKey.inspectorTab] as? String ?? "")
    }
}
