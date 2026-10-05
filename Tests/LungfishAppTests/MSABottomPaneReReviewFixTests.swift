// MSABottomPaneReReviewFixTests.swift - Re-review fixes SF-A, SF-B and the Annotations key view route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishAlignmentUI
import LungfishIO
import LungfishTestSupport

@MainActor
final class MSABottomPaneReReviewFixTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "lungfish-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func controller() async throws -> MultipleSequenceAlignmentViewController {
        let source = temporaryDirectory.appendingPathComponent("rereview.fa")
        try ">Macaca_mulatta_A1\nACGTACGTAC\n>Macaca_fascicularis_B2\nACGTTCGAAC\n>Homo_sapiens_reference_C3\nACGAACGTTC\n>Macaca_nemestrina_D4\nTCGTACGAAC\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let bundleURL = temporaryDirectory.appendingPathComponent("rereview.lungfishmsa")
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: source, to: bundleURL)
        let controller = MultipleSequenceAlignmentViewController()
        controller.gutterWidthDefaults = defaults
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 700)
        try await controller.displayBundle(at: bundleURL)
        controller.view.layoutSubtreeIfNeeded()
        controller.bottomPane.reduceMotion = { true }
        return controller
    }

    private func host(_ controller: MultipleSequenceAlignmentViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        return window
    }

    private func readyMatrix(_ controller: MultipleSequenceAlignmentViewController) async throws -> MSADistanceMatrix {
        controller.showDistanceMatrix()
        let ready = await waitUntil(timeout: .seconds(20)) {
            controller.bottomPane.distancePane.model.status == .ready
        }
        XCTAssertTrue(ready, "the distance matrix never became ready")
        return try XCTUnwrap(controller.bottomPane.distancePane.model.matrix)
    }

    private static func keyEvent(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private static func optionArrow(_ key: Int, keyCode: UInt16) -> NSEvent {
        keyEvent(
            String(Character(UnicodeScalar(UInt32(key))!)),
            keyCode: keyCode,
            flags: [.option, .numericPad, .function]
        )
    }

    /// Option-arrow presses that move the grid focus from its current cell to `target`.
    private func moveFocusWithOption(_ grid: MSADistanceMatrixGridView, to target: MSADistanceCell) {
        var steps = 0
        while let focus = grid.selection.focus, focus != target, steps < 20 {
            steps += 1
            if focus.row < target.row {
                grid.keyDown(with: Self.optionArrow(NSDownArrowFunctionKey, keyCode: 125))
            } else if focus.row > target.row {
                grid.keyDown(with: Self.optionArrow(NSUpArrowFunctionKey, keyCode: 126))
            } else if focus.column < target.column {
                grid.keyDown(with: Self.optionArrow(NSRightArrowFunctionKey, keyCode: 124))
            } else {
                grid.keyDown(with: Self.optionArrow(NSLeftArrowFunctionKey, keyCode: 123))
            }
        }
        XCTAssertEqual(grid.selection.focus, target)
    }

    // MARK: SF-A Tab from the grid leaves the pane

    func testTabFromTheGridLeavesThePaneInTheRealHierarchy() async throws {
        let controller = try await controller()
        let window = host(controller)
        defer { window.close() }
        controller.showDistanceMatrix()
        let pane = controller.bottomPane
        let exit = try XCTUnwrap(pane.distancePane.gridView.nextValidKeyView, "Tab from the grid goes somewhere")
        XCTAssertFalse(exit.isDescendant(of: pane), "and that view is outside the pane")
    }

    // MARK: Annotations tab key view route

    func testTheTabControlLeadsToTheVisibleTabsContent() async throws {
        let controller = try await controller()
        let previous = NSButton(title: "Before", target: nil, action: nil)
        let next = NSButton(title: "After", target: nil, action: nil)
        previous.nextKeyView = controller.alignmentKeyView
        controller.alignmentKeyView.nextKeyView = next
        let window = host(controller)
        defer { window.close() }
        let pane = controller.bottomPane
        let table = pane.annotationDrawer.tableView

        pane.select(.annotations)
        XCTAssertTrue(pane.tabControl.nextKeyView === table, "the annotation table has a keyboard route")
        XCTAssertTrue(table.nextKeyView === next, "and Tab from the table leaves the pane")
        XCTAssertTrue(next.previousKeyView === table, "Shift-Tab from the next view returns to the table")

        pane.select(.distances)
        XCTAssertTrue(pane.tabControl.nextKeyView === pane.distancePane.firstKeyView)
        XCTAssertTrue(pane.distancePane.gridView.nextKeyView === next)
        XCTAssertTrue(next.previousKeyView === pane.distancePane.gridView)
        XCTAssertTrue(controller.alignmentKeyView.previousKeyView === previous)
    }

    // MARK: SF-B the matrix and the alignment stay in step after a reveal

    func testClickingAPairAgainAfterARevealSelectsItInTheAlignment() async throws {
        let controller = try await controller()
        let matrix = try await readyMatrix(controller)
        let grid = controller.bottomPane.distancePane.gridView
        func position(_ record: Int) throws -> Int { try XCTUnwrap(matrix.recordIndices.firstIndex(of: record)) }
        let ab = MSADistanceCell(row: try position(0), column: try position(1))
        let cd = MSADistanceCell(row: try position(2), column: try position(3))

        grid.updateSelection { $0.click(ab) }
        XCTAssertEqual(controller.testingSelectedRowIndices, IndexSet([0, 1]))
        moveFocusWithOption(grid, to: cd)
        XCTAssertEqual(controller.testingSelectedRowIndices, IndexSet([0, 1]), "Option-arrow moves only the focus")
        grid.keyDown(with: Self.keyEvent("\r", keyCode: 36))
        XCTAssertEqual(controller.testingSelectedRowIndices, IndexSet([2, 3]), "Return reveals the focused pair")

        grid.updateSelection { $0.click(ab) }
        XCTAssertEqual(controller.testingSelectedRowIndices, IndexSet([0, 1]), "the alignment follows the click")
    }

    func testHeaderClickAfterASingleBaseSelectionSelectsTheWholeRow() async throws {
        let controller = try await controller()
        let matrix = try await readyMatrix(controller)
        let grid = controller.bottomPane.distancePane.gridView
        var state: MultipleSequenceAlignmentSelectionState?
        controller.onSelectionStateChanged = { state = $0 }
        let isWholeRow: () -> Bool = {
            state?.detailRows.contains { $0.0 == "Selection" && $0.1 == "1 whole row" } ?? false
        }

        controller.testingSelect(row: 2, displayedColumn: 0)
        XCTAssertNotNil(state)
        XCTAssertFalse(isWholeRow(), "the fixture starts from a single base")
        grid.headerClicked(try XCTUnwrap(matrix.recordIndices.firstIndex(of: 2)), modifiers: [])
        XCTAssertEqual(controller.testingSelectedRowIndices, IndexSet(integer: 2))
        XCTAssertTrue(isWholeRow(), "the header click switches the alignment to the whole row")
    }
}
