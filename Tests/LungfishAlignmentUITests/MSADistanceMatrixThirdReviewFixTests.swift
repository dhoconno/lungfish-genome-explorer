// MSADistanceMatrixThirdReviewFixTests.swift - Third review fixes N1 and N2 for the distance grid and pane
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishAlignmentUI
import LungfishIO
import LungfishTestSupport

@MainActor
final class MSADistanceMatrixThirdReviewFixTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "MSADistanceMatrixThirdReviewFixTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func readyPane() async throws -> MSADistanceMatrixPaneView {
        let pane = MSADistanceMatrixPaneView(model: MSADistanceMatrixPaneModel(defaults: defaults))
        pane.load(records: [
            MSAAlignedRecord(name: "Macaca_mulatta", sequence: "ACGTACGTAC"),
            MSAAlignedRecord(name: "Macaca_fascicularis", sequence: "ACGTTCGAAC"),
            MSAAlignedRecord(name: "Homo_sapiens", sequence: "ACGAACGTTC"),
            MSAAlignedRecord(name: "Macaca_nemestrina", sequence: "TCGTACGAAC"),
        ], alphabet: .nucleotide)
        let ready = await waitUntil(timeout: .seconds(10)) { pane.model.status == .ready }
        XCTAssertTrue(ready)
        return pane
    }

    private static let escape = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false,
        keyCode: 53
    )!

    private static let returnKey = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "\r",
        charactersIgnoringModifiers: "\r",
        isARepeat: false,
        keyCode: 36
    )!

    // MARK: N1 Escape with nothing selected anywhere forwards nothing

    func testEscapeWithNothingSelectedForwardsNothing() async throws {
        let pane = try await readyPane()
        var forwarded: [IndexSet] = []
        pane.onSequencesSelected = { forwarded.append($0) }

        pane.gridView.keyDown(with: Self.escape)
        XCTAssertEqual(forwarded, [], "an empty grid and an empty alignment selection stay quiet")

        pane.gridView.updateSelection { $0.click(MSADistanceCell(row: 1, column: 0)) }
        XCTAssertEqual(forwarded.count, 1)
        pane.gridView.keyDown(with: Self.escape)
        XCTAssertEqual(forwarded.last, IndexSet(), "Escape still clears a selection the matrix made")
        XCTAssertEqual(forwarded.count, 2)
    }

    // MARK: N2 Return selects the revealed cell so grid and alignment agree

    func testReturnRevealSelectsTheRevealedCell() async throws {
        let pane = try await readyPane()
        let matrix = try XCTUnwrap(pane.model.matrix)
        var forwarded: [IndexSet] = []
        var revealed: [(Int, Int)] = []
        pane.onSequencesSelected = { forwarded.append($0) }
        pane.onRevealPair = { revealed.append(($0, $1)) }

        pane.gridView.updateSelection { $0.click(MSADistanceCell(row: 0, column: 1)) }
        // Option moves the focus alone to (2, 3), leaving (0, 1) selected.
        pane.gridView.updateSelection({ $0.move(.down, focusOnly: true) }, notify: false)
        pane.gridView.updateSelection({ $0.move(.down, focusOnly: true) }, notify: false)
        pane.gridView.updateSelection({ $0.move(.right, focusOnly: true) }, notify: false)
        pane.gridView.updateSelection({ $0.move(.right, focusOnly: true) }, notify: false)
        let target = MSADistanceCell(row: 2, column: 3)
        XCTAssertEqual(pane.gridView.selection.focus, target)
        XCTAssertEqual(pane.gridView.selection.cells, [MSADistanceCell(row: 0, column: 1)])
        let forwardsBefore = forwarded.count

        pane.gridView.keyDown(with: Self.returnKey)
        XCTAssertEqual(revealed.count, 1)
        XCTAssertEqual(revealed.first?.0, matrix.recordIndices[2])
        XCTAssertEqual(revealed.first?.1, matrix.recordIndices[3])
        XCTAssertEqual(pane.gridView.selection.cells, [target], "the grid selects the revealed cell")
        XCTAssertEqual(pane.gridView.selection.focus, target)
        XCTAssertEqual(forwarded.count, forwardsBefore, "the reveal itself tells the alignment")
        XCTAssertEqual(pane.alignmentSelection, IndexSet([matrix.recordIndices[2], matrix.recordIndices[3]]))
    }
}
