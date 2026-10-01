// BatchTableViewAccessibilityActionsTests.swift - The row-actions hook reaches AX clients
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishKit

/// A `BatchTableView` subclass publishes its row commands by overriding
/// `accessibilityActions(forRow:cellView:)`, and the base class installs the
/// result on every cell from its cell callback.
@MainActor
final class BatchTableViewAccessibilityActionsTests: XCTestCase {
    private struct Row: Equatable {
        let name: String
    }

    private final class ActionsTable: BatchTableView<Row> {
        var copied: [String] = []

        override var columnSpecs: [BatchColumnSpec] {
            [
                BatchColumnSpec(identifier: .init("name"), title: "Name", width: 120, minWidth: 80, defaultAscending: true),
                BatchColumnSpec(identifier: .init("reads"), title: "Reads", width: 80, minWidth: 40, defaultAscending: false),
            ]
        }

        override func cellContent(
            for column: NSUserInterfaceItemIdentifier,
            row: Row
        ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
            (row.name, .left, nil)
        }

        override func accessibilityActions(forRow row: Int, cellView: NSView) -> [NSAccessibilityCustomAction] {
            [
                AccessibilityCellActions.makeAction(name: "Copy Name") { [weak self, weak cellView] in
                    guard let self, let cellView,
                          let current = AccessibilityCellActions.currentRow(of: cellView),
                          let row = self.displayedRow(at: current) else { return }
                    self.copied.append(row.name)
                },
            ]
        }
    }

    func testEveryCellCarriesTheSubclassActionsAndHandlersFollowTheDisplayedRow() throws {
        _ = NSApplication.shared
        let table = ActionsTable(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = table
        defer { window.close() }
        table.configure(rows: [Row(name: "alpha"), Row(name: "beta")])
        table.layoutSubtreeIfNeeded()
        table.tableView.layoutSubtreeIfNeeded()

        let rows = AccessibilityRowProbe.rowProxies(of: table.tableView)
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            for served in AccessibilityRowProbe.servedCellActionNames(row) {
                XCTAssertEqual(served, ["Copy Name"])
            }
        }
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: rows[1]))
        XCTAssertEqual(table.copied, ["beta"])
        XCTAssertNil(table.displayedRow(at: 5))
    }

    func testTheDefaultHookPublishesNothing() throws {
        final class PlainTable: BatchTableView<Row> {
            override var columnSpecs: [BatchColumnSpec] {
                [BatchColumnSpec(identifier: .init("name"), title: "Name", width: 120, minWidth: 80, defaultAscending: true)]
            }
        }
        _ = NSApplication.shared
        let table = PlainTable(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = table
        defer { window.close() }
        table.configure(rows: [Row(name: "alpha")])
        table.layoutSubtreeIfNeeded()
        table.tableView.layoutSubtreeIfNeeded()
        let rows = AccessibilityRowProbe.rowProxies(of: table.tableView)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(AccessibilityRowProbe.firstCellActionNames(rows[0]), [])
    }
}
