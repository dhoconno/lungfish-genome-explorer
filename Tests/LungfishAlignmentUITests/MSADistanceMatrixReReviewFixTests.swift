// MSADistanceMatrixReReviewFixTests.swift - Re-review fixes SF1, SF-B, N1, N2 and N3 for the distance grid and pane
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishAlignmentUI
import LungfishIO
import LungfishTestSupport

@MainActor
final class MSADistanceMatrixReReviewFixTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "MSADistanceMatrixReReviewFixTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    /// Alpha and beta share no ungapped column, so their pair is `nan`.
    private func readyPaneWithANotDefinedCell() async throws -> MSADistanceMatrixPaneView {
        let pane = MSADistanceMatrixPaneView(model: MSADistanceMatrixPaneModel(defaults: defaults))
        pane.model.gaps = .pairwise
        pane.model.model = .pDistance
        pane.model.fixedUnitRange = false
        pane.model.showsValues = true
        pane.load(records: [
            MSAAlignedRecord(name: "alpha", sequence: "ACGTA-----"),
            MSAAlignedRecord(name: "beta", sequence: "-----CGTAC"),
            MSAAlignedRecord(name: "gamma", sequence: "ACGTACGTAC"),
        ], alphabet: .nucleotide)
        let ready = await waitUntil(timeout: .seconds(10)) { pane.model.status == .ready }
        XCTAssertTrue(ready)
        let matrix = try XCTUnwrap(pane.model.matrix)
        XCTAssertTrue(matrix.values.joined().contains(where: \.isNaN), "the fixture needs a nan cell")
        return pane
    }

    // MARK: SF1 display toggles keep the selection when a cell is nan

    func testDisplayTogglesKeepSelectionFocusAndPairWithANotDefinedCell() async throws {
        let pane = try await readyPaneWithANotDefinedCell()
        var pairs: [String?] = []
        pane.onFocusedPairChanged = { detail, row, column in
            pairs.append(detail == nil ? nil : "\(row)|\(column)")
        }
        let cell = MSADistanceCell(row: 2, column: 0)
        pane.gridView.updateSelection { $0.click(cell) }
        XCTAssertEqual(pairs.last, "gamma|alpha")
        XCTAssertFalse(pane.footerLabel.stringValue.isEmpty)
        pairs.removeAll()
        let revision = pane.model.matrixRevision
        let layouts = pane.gridView.layoutCount

        pane.model.showsValues.toggle()
        pane.model.fixedUnitRange.toggle()
        pane.model.showsValues.toggle()

        XCTAssertEqual(pane.gridView.selection.focus, cell, "focus survives Show Values and Fixed 0-1")
        XCTAssertEqual(pane.gridView.selection.cells, [cell], "the selected cell survives")
        XCTAssertFalse(pane.footerLabel.stringValue.isEmpty, "the footer keeps the focused pair")
        XCTAssertFalse(pairs.contains(where: { $0 == nil }), "the Inspector pair is never cleared")
        XCTAssertEqual(pane.model.matrixRevision, revision, "display toggles publish no new matrix")
        XCTAssertGreaterThan(pane.gridView.layoutCount, layouts, "Show Values still relays out the grid")
    }

    func testANewMatrixStillResetsTheSelection() async throws {
        let pane = try await readyPaneWithANotDefinedCell()
        pane.gridView.updateSelection { $0.click(MSADistanceCell(row: 2, column: 0)) }
        pane.model.model = .identity
        let ready = await waitUntil(timeout: .seconds(10)) {
            pane.model.status == .ready && pane.model.matrix?.options.model == .identity
        }
        XCTAssertTrue(ready)
        XCTAssertNil(pane.gridView.selection.focus, "a recompute changes what indices mean")
    }

    // MARK: N1 reveal records the alignment selection

    func testRevealSetsTheAlignmentSelection() async throws {
        let pane = try await readyPaneWithANotDefinedCell()
        var revealed: (Int, Int)?
        pane.onRevealPair = { revealed = ($0, $1) }
        pane.gridView.onReveal?(MSADistanceCell(row: 2, column: 0))
        XCTAssertEqual(revealed?.0, 2)
        XCTAssertEqual(revealed?.1, 0)
        XCTAssertEqual(pane.alignmentSelection, IndexSet([0, 2]))
    }

    // MARK: N2 stacks give way just below default high

    func testFrameLaidStacksClipJustBelowDefaultHigh() {
        let pane = MSADistanceMatrixPaneView(model: MSADistanceMatrixPaneModel(defaults: defaults))
        for stack in [pane.headerBar, pane.statusStack] {
            for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
                XCTAssertEqual(stack.clippingResistancePriority(for: orientation), .defaultHigh - 1)
            }
        }
    }

    // MARK: N3 and re-review SF-B: the pane forwards a selection only when the alignment would change

    func testOptionArrowMovesTheFocusWithoutReporting() {
        let grid = MSADistanceMatrixGridView(pasteboard: RecordingPasteboard())
        grid.setMatrix(StubDistanceMatrix.make(4))
        var reports: [IndexSet] = []
        grid.onSelectionChanged = { reports.append($0.sequenceIndices) }

        grid.updateSelection { $0.click(MSADistanceCell(row: 0, column: 1)) }
        XCTAssertEqual(reports, [IndexSet([0, 1])])
        grid.keyDown(with: Self.arrowEvent(NSDownArrowFunctionKey, keyCode: 125, flags: .option))
        XCTAssertEqual(grid.selection.focus, MSADistanceCell(row: 1, column: 1), "Option moves only the focus")
        XCTAssertEqual(reports, [IndexSet([0, 1])], "a focus-only move selects nothing new")
    }

    func testPaneForwardsOnlyWhenTheAlignmentSelectionWouldChange() async throws {
        let pane = try await readyPaneWithANotDefinedCell()
        let matrix = try XCTUnwrap(pane.model.matrix)
        var forwarded: [IndexSet] = []
        pane.onSequencesSelected = { forwarded.append($0) }
        pane.onRevealPair = { _, _ in }
        func record(_ position: Int) -> Int { matrix.recordIndices[position] }

        pane.gridView.updateSelection { $0.click(MSADistanceCell(row: 2, column: 0)) }
        pane.gridView.updateSelection { $0.click(MSADistanceCell(row: 0, column: 2)) }
        XCTAssertEqual(forwarded, [IndexSet([record(0), record(2)])], "the mirror cell selects the same two sequences")

        // A reveal of another pair moves the alignment, so the same click is news again.
        pane.gridView.onReveal?(MSADistanceCell(row: 1, column: 0))
        pane.gridView.updateSelection { $0.click(MSADistanceCell(row: 2, column: 0)) }
        XCTAssertEqual(forwarded.count, 2)
        XCTAssertEqual(forwarded.last, IndexSet([record(0), record(2)]))

        // A selection made in the alignment, such as one base, is replaced by a header click on the same row.
        pane.reflectAlignmentSelection(IndexSet(integer: record(1)))
        pane.gridView.headerClicked(1, modifiers: [])
        XCTAssertEqual(forwarded.count, 3, "the header click turns the alignment selection into whole rows")
        XCTAssertEqual(forwarded.last, IndexSet(integer: record(1)))
        pane.gridView.headerClicked(1, modifiers: [])
        XCTAssertEqual(forwarded.count, 3, "repeating it changes nothing")
    }

    static func arrowEvent(_ key: Int, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        let characters = String(Character(UnicodeScalar(UInt32(key))!))
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags.union([.numericPad, .function]),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
