// AccessibilityCellActionsTests.swift - Row commands reach AX clients through the cell views
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishKit

/// `AccessibilityCellActions` installs a row's commands on its cell views,
/// which is the only place AppKit's AX bridge reads them. The probe walks the
/// same path an external client does: table, row proxy, AXChildren, cell
/// proxy, accessibilityCustomActions. The outline tests are the go/no-go for
/// every `NSOutlineView` surface.
@MainActor
final class AccessibilityCellActionsTests: XCTestCase {

    // MARK: - Table

    private final class NamesTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var names: [String]
        var performed: [String] = []
        init(names: [String]) { self.names = names }

        func numberOfRows(in tableView: NSTableView) -> Int { names.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let field = NSTextField(labelWithString: "")
                cell.addSubview(field)
                cell.textField = field
                return cell
            }()
            cell.textField?.stringValue = names[row]
            AccessibilityCellActions.install([
                AccessibilityCellActions.makeAction(name: "Copy Name") { [weak self, weak cell] in
                    guard let self, let cell, let row = AccessibilityCellActions.currentRow(of: cell) else { return }
                    self.performed.append(self.names[row])
                },
            ], on: cell)
            return cell
        }
    }

    private func makeTable(_ source: NamesTable, columns: Int = 2) -> (NSTableView, NSWindow) {
        _ = NSApplication.shared
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        for index in 0..<columns {
            table.addTableColumn(NSTableColumn(identifier: .init("col\(index)")))
        }
        table.dataSource = source
        table.delegate = source
        let scroll = NSScrollView(frame: table.frame)
        scroll.documentView = table
        let window = NSWindow(
            contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        return (table, window)
    }

    func testEveryCellOfATableRowPublishesTheInstalledActions() throws {
        let source = NamesTable(names: ["alpha", "beta"])
        let (table, window) = makeTable(source)
        defer { window.close() }

        let rows = AccessibilityRowProbe.rowProxies(of: table)
        XCTAssertEqual(rows.count, 2)
        let cellNames = AccessibilityRowProbe.cellActionNames(try XCTUnwrap(rows.last))
        XCTAssertEqual(cellNames.count, 2, "one cell proxy per column")
        for names in cellNames { XCTAssertEqual(names, ["Copy Name"]) }
        XCTAssertTrue(AccessibilityRowProbe.rowActionNames(rows[1]).isEmpty, "the row proxy itself carries nothing")
    }

    func testTheAXServerSeesEachCellActionExactlyOnceIncludingAfterReload() throws {
        let source = NamesTable(names: ["alpha", "beta"])
        let (table, window) = makeTable(source)
        defer { window.close() }

        // AppKit's cell proxy serves custom actions over the legacy and the
        // modern route; the served list is their union, as a client sees it.
        for row in AccessibilityRowProbe.rowProxies(of: table) {
            for served in AccessibilityRowProbe.servedCellActionNames(row) {
                XCTAssertEqual(served, ["Copy Name"], "a VoiceOver user must hear each action once")
            }
        }

        source.names = ["beta", "alpha", "gamma"]
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        let rows = AccessibilityRowProbe.rowProxies(of: table)
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            for served in AccessibilityRowProbe.servedCellActionNames(row) {
                XCTAssertEqual(served, ["Copy Name"], "reuse and reload must not accumulate actions")
            }
        }
    }

    func testProxyFixKeepsStandardLegacyActionsAndDropsOnlyCustomDuplicates() {
        final class FakeProxy: NSAccessibilityElement {
            override func accessibilityActionDescription(_ action: NSAccessibility.Action) -> String? {
                action.rawValue == "opaque-copy-name" ? "Copy Name" : action.rawValue
            }
        }
        let proxy = FakeProxy()
        proxy.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Copy Name") { true }])
        let kept = TableCellProxyActionFix.legacyNamesWithoutCustomActions(
            ["AXPress" as NSString, "opaque-copy-name" as NSString, "AXShowMenu" as NSString],
            on: proxy
        )
        XCTAssertEqual(kept.map { $0 as? String }, ["AXPress", "AXShowMenu"])
    }

    func testPerformingThroughTheProbeResolvesTheRowTheCellShowsNow() throws {
        let source = NamesTable(names: ["alpha", "beta"])
        let (table, window) = makeTable(source)
        defer { window.close() }

        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: AccessibilityRowProbe.rowProxies(of: table)[1]))
        XCTAssertEqual(source.performed, ["beta"])

        // Reorder and reload: whichever cell views are recycled, the handler
        // acts on the row the cell shows at the moment it runs.
        source.names = ["beta", "alpha"]
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        let rows = AccessibilityRowProbe.rowProxies(of: table)
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: rows[0]))
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: rows[1]))
        XCTAssertEqual(source.performed, ["beta", "beta", "alpha"])
    }

    func testInstallingAnEmptyListClearsTheActions() {
        let cell = NSTableCellView()
        AccessibilityCellActions.install([AccessibilityCellActions.makeAction(name: "X") {}], on: cell)
        XCTAssertEqual(cell.accessibilityCustomActions()?.map(\.name), ["X"])
        AccessibilityCellActions.install([], on: cell)
        XCTAssertNil(cell.accessibilityCustomActions())
    }

    func testCurrentRowIsNilOutsideATable() {
        XCTAssertNil(AccessibilityCellActions.currentRow(of: NSTableCellView()))
        XCTAssertNil(AccessibilityCellActions.currentItem(of: NSTableCellView()))
    }

    // MARK: - Outline

    private final class Node {
        let name: String
        let children: [Node]
        init(_ name: String, _ children: [Node] = []) {
            self.name = name
            self.children = children
        }
    }

    private final class TreeSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let roots: [Node]
        var performed: [String] = []
        init(roots: [Node]) { self.roots = roots }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            ((item as? Node)?.children ?? roots).count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? Node)?.children ?? roots)[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? Node)?.children.isEmpty ?? true)
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let field = NSTextField(labelWithString: "")
                cell.addSubview(field)
                cell.textField = field
                return cell
            }()
            let node = item as! Node
            cell.textField?.stringValue = node.name
            AccessibilityCellActions.install([
                AccessibilityCellActions.makeAction(name: "Copy Path") { [weak self, weak cell] in
                    guard let self, let cell, let current = AccessibilityCellActions.currentItem(of: cell) as? Node else { return }
                    self.performed.append(current.name)
                },
            ], on: cell)
            return cell
        }
    }

    private func makeOutline(_ source: TreeSource) -> (NSOutlineView, NSWindow) {
        _ = NSApplication.shared
        let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = source
        outline.delegate = source
        let scroll = NSScrollView(frame: outline.frame)
        scroll.documentView = outline
        let window = NSWindow(
            contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        outline.reloadData()
        outline.layoutSubtreeIfNeeded()
        return (outline, window)
    }

    func testOutlineRowsPublishCellActionsThroughTheAXBridge() throws {
        let source = TreeSource(roots: [Node("Project", [Node("reads.fastq"), Node("ref.fasta")]), Node("Loose")])
        let (outline, window) = makeOutline(source)
        defer { window.close() }

        var rows = AccessibilityRowProbe.outlineRowProxies(of: outline)
        XCTAssertEqual(rows.count, 2, "collapsed children are not rows")
        XCTAssertEqual(AccessibilityRowProbe.firstCellActionNames(rows[0]), ["Copy Path"])

        outline.expandItem(source.roots[0])
        outline.layoutSubtreeIfNeeded()
        rows = AccessibilityRowProbe.outlineRowProxies(of: outline)
        XCTAssertEqual(rows.count, 4)
        for row in rows {
            XCTAssertEqual(AccessibilityRowProbe.firstCellActionNames(row), ["Copy Path"])
        }

        // Performing on a child row resolves that child's item, not the parent's.
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Path", in: rows[2]))
        XCTAssertEqual(source.performed, ["ref.fasta"])

        outline.collapseItem(source.roots[0])
        outline.layoutSubtreeIfNeeded()
        rows = AccessibilityRowProbe.outlineRowProxies(of: outline)
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Path", in: rows[1]))
        XCTAssertEqual(source.performed, ["ref.fasta", "Loose"])
    }
}
