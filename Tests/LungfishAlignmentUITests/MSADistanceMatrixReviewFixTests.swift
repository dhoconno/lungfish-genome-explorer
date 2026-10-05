// MSADistanceMatrixReviewFixTests.swift - UI review fixes S2, S5, S6, N4 and N8 for the distance grid and pane
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishAlignmentUI
import LungfishIO
import LungfishTestSupport

@MainActor
final class MSADistanceMatrixReviewFixTests: XCTestCase {
    private func arrow(_ special: NSEvent.SpecialKey) -> NSEvent {
        let character = String(Character(UnicodeScalar(special.rawValue)!))
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: 0
        )!
    }

    private func grid(_ matrix: StubDistanceMatrix) -> MSADistanceMatrixGridView {
        let grid = MSADistanceMatrixGridView(pasteboard: RecordingPasteboard())
        grid.setMatrix(matrix)
        return grid
    }

    // MARK: S2 focused element and hit test

    /// The table's own focused-element getter cannot return a cached cell
    /// without a concurrency hatch (module AGENTS.md trap), so focus reaches
    /// VoiceOver through the focused flag and the focus-changed notification.
    func testFocusedCellCarriesTheFocusFlag() throws {
        let grid = grid(.make(4))
        grid.accessibilityClientOverride = true
        grid.updateSelection { $0.click(MSADistanceCell(row: 2, column: 1)) }
        let focused = grid.axCellElement(for: MSADistanceCell(row: 2, column: 1))
        XCTAssertTrue(focused.isAccessibilityFocused())
        XCTAssertFalse(grid.axCellElement(for: MSADistanceCell(row: 1, column: 1)).isAccessibilityFocused())
    }

    func testHitTestMapsAScreenPointToTheCellUnderIt() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 300, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let grid = grid(.make(4))
        window.contentView?.addSubview(grid)
        grid.setFrameOrigin(NSPoint(x: 10, y: 10))
        let side = grid.cellSide
        // Row 3, column 2 in the flipped grid.
        let local = NSPoint(x: side * 2 + side / 2, y: side * 3 + side / 2)
        let screen = window.convertPoint(toScreen: grid.convert(local, to: nil))
        // AX frames are unflipped: row 0 is the top row on screen (review S2).
        let gridOnScreen = window.convertToScreen(grid.convert(grid.bounds, to: nil))
        XCTAssertEqual(grid.axRowElement(for: 0).accessibilityFrame().maxY, gridOnScreen.maxY, accuracy: 0.5)
        let hit = try XCTUnwrap(grid.accessibilityHitTest(screen) as? NSAccessibilityElement)
        XCTAssertEqual(hit.accessibilityRowIndexRange(), NSRange(location: 3, length: 1))
        XCTAssertEqual(hit.accessibilityColumnIndexRange(), NSRange(location: 2, length: 1))

        let outside = window.convertPoint(toScreen: grid.convert(NSPoint(x: side * 9, y: side * 9), to: nil))
        XCTAssertTrue(grid.accessibilityHitTest(outside) as AnyObject === grid)
    }

    // MARK: N4 no AX cell elements without a client

    func testFocusMovesBuildNoCellElementsWithoutAnAccessibilityClient() {
        let grid = grid(.make(50))
        grid.accessibilityClientOverride = false
        grid.updateSelection { $0.click(MSADistanceCell(row: 0, column: 1)) }
        for _ in 0..<5 { grid.keyDown(with: arrow(.downArrow)) }
        XCTAssertTrue(grid.axCache.cells.isEmpty, "no client asked, so no row of cells was built")

        grid.accessibilityClientOverride = true
        grid.keyDown(with: arrow(.downArrow))
        XCTAssertEqual(grid.axCache.cells.count, 50, "a client gets the focused cell's row")
    }

    // MARK: S6 compact n/a cells carry a mark

    func testCompactNotDefinedCellDrawsTheLegendMark() throws {
        let matrix = StubDistanceMatrix(
            displayNames: ["a", "b"],
            displayRecordIndices: [0, 1],
            displayValues: [[0, .nan], [.nan, 0]]
        )
        let grid = MSADistanceMatrixGridView(pasteboard: RecordingPasteboard())
        grid.appearance = NSAppearance(named: .aqua)
        grid.showsValues = false
        grid.setMatrix(matrix)
        let rep = try XCTUnwrap(grid.bitmapImageRepForCachingDisplay(in: grid.bounds))
        grid.cacheDisplay(in: grid.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / grid.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / grid.bounds.height
        let side = grid.cellSide
        // Cell (row 0, column 1) spans x side...2*side, y 0...side.
        func brightness(_ x: CGFloat, _ y: CGFloat) throws -> CGFloat {
            let colour = try XCTUnwrap(rep.colorAt(x: Int(x * scaleX), y: Int(y * scaleY))?.usingColorSpace(.sRGB))
            return (colour.redComponent + colour.greenComponent + colour.blueComponent) / 3
        }
        let background = try brightness(side * 1.5, side / 2)
        var darkest = background
        for step in 0..<Int(side * scaleX) {
            let x = side + CGFloat(step) / scaleX
            darkest = min(darkest, try brightness(x, side / 2))
        }
        XCTAssertLessThan(darkest, background - 0.2, "the n/a cell shows an outline, not just the background")
    }

    // MARK: N8 singular site count

    func testOneComparableSiteReadsSingular() {
        let one = MSADistanceMatrixText.cellLabel(rowName: "a", columnName: "b", value: 0, comparableSites: 1, isDiagonal: false)
        XCTAssertTrue(one.hasSuffix("1 site compared"), one)
        let many = MSADistanceMatrixText.cellLabel(rowName: "a", columnName: "b", value: 0, comparableSites: 2, isDiagonal: false)
        XCTAssertTrue(many.hasSuffix("2 sites compared"), many)
    }

    // MARK: S5 reverse sync survives first show and a recompute

    func testAlignmentSelectionIsReappliedWhenTheMatrixBecomesReady() async throws {
        let suite = "MSADistanceMatrixReviewFixTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pane = MSADistanceMatrixPaneView(model: MSADistanceMatrixPaneModel(defaults: defaults))
        pane.reflectAlignmentSelection(IndexSet(integer: 2))
        pane.load(records: [
            MSAAlignedRecord(name: "alpha", sequence: "ACGTACGTAC"),
            MSAAlignedRecord(name: "beta", sequence: "ACGTACGTTT"),
            MSAAlignedRecord(name: "gamma", sequence: "ACGAACGTAC"),
        ], alphabet: .nucleotide)
        let ready = await waitUntil(timeout: .seconds(10)) { pane.model.status == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(pane.gridView.selection.selectedSequences, IndexSet(integer: 2), "first show")

        pane.model.gaps = pane.model.gaps == .pairwise ? .complete : .pairwise
        let recomputed = await waitUntil(timeout: .seconds(10)) {
            pane.model.status == .ready && pane.model.matrix?.options.gaps == pane.model.gaps
        }
        XCTAssertTrue(recomputed)
        XCTAssertEqual(pane.gridView.selection.selectedSequences, IndexSet(integer: 2), "after a recompute")
    }

    func testLoadFailureShowsAnError() {
        let pane = MSADistanceMatrixPaneView()
        pane.showLoadFailure("No alphabet.")
        XCTAssertEqual(pane.model.status, .failed("No alphabet."))
        XCTAssertFalse(pane.statusStack.isHidden)
        XCTAssertTrue(pane.statusLabel.stringValue.contains("No alphabet."))
    }
}
