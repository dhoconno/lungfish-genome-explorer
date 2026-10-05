// MSABottomPaneTests.swift - The MSA bottom pane, its routes and the matrix-to-alignment selection sync
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
import LungfishAlignmentUI
import LungfishIO
import LungfishTestSupport

@MainActor
final class MSABottomPaneTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "lungfish-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // These tests start from a hidden pane. The default-open behaviour is in MSABottomPaneDefaultOpenTests.
        defaults.set(false, forKey: MSABottomPaneView.DefaultsKey.isOpen)
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    /// Two rows share the display name "dup" (memory: MSA name-matching trap).
    static let duplicateNameFASTA = ">dup\nACGTACGTAC\n>dup\nACGTTCGAAC\n>other\nACGAACGTTC\n>last\nTCGTACGAAC\n"

    private func bundle(_ fasta: String = duplicateNameFASTA, name: String = "pane") throws -> URL {
        let source = temporaryDirectory.appendingPathComponent("\(name).fa")
        try fasta.write(to: source, atomically: true, encoding: .utf8)
        let bundleURL = temporaryDirectory.appendingPathComponent("\(name).lungfishmsa")
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: source, to: bundleURL)
        return bundleURL
    }

    private func controller(bundleURL: URL? = nil) async throws -> MultipleSequenceAlignmentViewController {
        let controller = MultipleSequenceAlignmentViewController()
        controller.gutterWidthDefaults = defaults
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 700)
        try await controller.displayBundle(at: bundleURL ?? bundle())
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func waitForMatrix(
        _ controller: MultipleSequenceAlignmentViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let ready = await LungfishTestSupport.waitUntil(timeout: .seconds(20)) {
            controller.bottomPane.distancePane.model.status == .ready
        }
        XCTAssertTrue(ready, "the distance matrix never became ready", file: file, line: line)
    }

    // MARK: Pane state

    func testHiddenPaneKeepsOneDividerAndTheDrawerHandleHidden() async throws {
        let controller = try await controller()
        let pane = controller.bottomPane
        XCTAssertFalse(pane.isOpen, "a stored hide stays closed")
        XCTAssertTrue(pane.isHidden)
        XCTAssertEqual(pane.heightConstraint.constant, 0)
        XCTAssertFalse(pane.annotationDrawer.showsDragHandle, "the embedded drawer loses its own handle")
        XCTAssertTrue(pane.annotationDrawer.dragHandle.isHidden)
        XCTAssertEqual(pane.divider.accessibilityRole(), .splitter)
        XCTAssertEqual(pane.tabControl.segmentCount, 2)
        XCTAssertEqual(pane.tabControl.label(forSegment: 0), "Annotations")
        XCTAssertEqual(pane.tabControl.label(forSegment: 1), "Distances")
        XCTAssertTrue(pane.clipsToBounds)
    }

    func testOpenStateTabAndHeightPersistAndRestore() async throws {
        let bundleURL = try bundle()
        let controller = try await controller(bundleURL: bundleURL)
        let pane = controller.bottomPane
        controller.toggleBottomPane()
        XCTAssertTrue(pane.isOpen)
        XCTAssertFalse(pane.isHidden)
        XCTAssertEqual(pane.heightConstraint.constant, MSABottomPaneView.defaultHeight)
        pane.select(.annotations)
        pane.select(.distances)
        pane.resize(by: 40)
        XCTAssertEqual(defaults.bool(forKey: MSABottomPaneView.DefaultsKey.isOpen), true)
        XCTAssertEqual(defaults.string(forKey: MSABottomPaneView.DefaultsKey.tab), "distances")
        XCTAssertEqual(defaults.double(forKey: MSABottomPaneView.DefaultsKey.height), Double(MSABottomPaneView.defaultHeight + 40))

        let reopened = try await self.controller(bundleURL: bundleURL)
        XCTAssertTrue(reopened.bottomPane.isOpen)
        XCTAssertEqual(reopened.bottomPane.selectedTab, .distances)
        XCTAssertEqual(reopened.bottomPane.heightConstraint.constant, MSABottomPaneView.defaultHeight + 40)

        reopened.toggleBottomPane()
        XCTAssertFalse(reopened.bottomPane.isOpen)
        XCTAssertEqual(defaults.bool(forKey: MSABottomPaneView.DefaultsKey.isOpen), false)
    }

    func testHeightClampsToMinimumAndLeavesRoomForTheAlignment() async throws {
        XCTAssertEqual(MSABottomPaneView.clampedHeight(50, hostHeight: 700), 120)
        XCTAssertEqual(MSABottomPaneView.clampedHeight(900, hostHeight: 700), 560)
        XCTAssertEqual(MSABottomPaneView.clampedHeight(300, hostHeight: 700), 300)

        let controller = try await controller()
        controller.toggleBottomPane()
        controller.adjustBottomPaneHeight(by: 2_000)
        XCTAssertEqual(controller.bottomPane.heightConstraint.constant, 700 - MSABottomPaneView.reservedAlignmentHeight)
        controller.bottomPane.divider.resize(by: -2_000)
        XCTAssertEqual(controller.bottomPane.heightConstraint.constant, MSABottomPaneView.minimumHeight)
        XCTAssertEqual(controller.bottomPane.divider.accessibilityValue() as? String, "120 points tall")
    }

    func testReduceMotionOpensWithoutAnimation() async throws {
        let controller = try await controller()
        controller.bottomPane.reduceMotion = { true }
        controller.bottomPane.setOpen(true, animated: true)
        XCTAssertEqual(controller.bottomPane.lastAnimationDuration, 0)
        controller.bottomPane.reduceMotion = { false }
        controller.bottomPane.setOpen(false, animated: true)
        XCTAssertEqual(controller.bottomPane.lastAnimationDuration, MSABottomPaneView.animationDuration)
    }

    // MARK: Routes

    func testToggleDistanceMatrixOpensDistancesAndComputesOnlyWhenShown() async throws {
        let controller = try await controller()
        let pane = controller.bottomPane
        XCTAssertTrue(pane.hasPendingDistanceInput, "nothing is computed while the matrix is hidden")
        XCTAssertEqual(pane.distancePane.model.status, .idle)
        XCTAssertEqual(controller.distanceMatrixToggleButton.state, .off)
        XCTAssertEqual(controller.distanceMatrixToggleButton.accessibilityLabel(), "Distance matrix")

        controller.toggleDistanceMatrix()
        XCTAssertTrue(controller.isDistanceMatrixShowing)
        XCTAssertEqual(pane.visibleTab, .distances)
        XCTAssertFalse(pane.distancePane.isHidden)
        XCTAssertTrue(pane.annotationDrawer.isHidden)
        XCTAssertEqual(controller.distanceMatrixToggleButton.state, .on)
        await waitForMatrix(controller)
        XCTAssertEqual(pane.distancePane.model.matrix?.rowCount, 4)

        controller.toggleDistanceMatrix()
        XCTAssertFalse(pane.isOpen)
        XCTAssertEqual(controller.distanceMatrixToggleButton.state, .off)
    }

    func testToggleBottomPaneKeepsTheLastTab() async throws {
        let controller = try await controller()
        controller.showDistanceMatrix()
        controller.toggleBottomPane()
        XCTAssertFalse(controller.isBottomPaneOpen)
        controller.toggleBottomPane()
        XCTAssertTrue(controller.isDistanceMatrixShowing, "Show Drawer reopens on the last tab")
    }

    func testReadOnlyAlignmentDisablesTheDistancesTab() throws {
        let controller = MultipleSequenceAlignmentViewController()
        controller.gutterWidthDefaults = defaults
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 700)
        try controller.displayReadOnlyAlignment(fasta: ">a\nACGT\n>b\nACGA\n", annotations: [])
        XCTAssertFalse(controller.isDistanceMatrixAvailable)
        XCTAssertFalse(controller.bottomPane.tabControl.isEnabled(forSegment: MSABottomPaneView.Tab.distances.rawValue))
        controller.showDistanceMatrix()
        XCTAssertFalse(controller.isDistanceMatrixShowing)
        XCTAssertFalse(controller.distanceMatrixToggleButton.isEnabled)
    }

    // MARK: Selection sync (ruling U7)

    func testMatrixRecordOrderEqualsViewportRowOrderWithDuplicateNames() async throws {
        let bundleURL = try bundle()
        let controller = try await controller(bundleURL: bundleURL)
        controller.showDistanceMatrix()
        await waitForMatrix(controller)
        let model = controller.bottomPane.distancePane.model
        let fromDisk = try MSAAlignedRecord.loadPrimaryAlignment(of: bundleURL)
        XCTAssertEqual(model.records, fromDisk, "the pane sees the same records, in the same order, as the CLI")
        XCTAssertEqual(model.records.map(\.name), controller.testingRenderedRowNames)
        XCTAssertEqual(model.matrix?.recordIndices, [0, 1, 2, 3])

        // Selecting the second "dup" selects row 1, never the first row with that name.
        controller.bottomPane.distancePane.onSequencesSelected?(IndexSet(integer: 1))
        XCTAssertEqual(controller.testingSelectedRowIndices, IndexSet(integer: 1))
        XCTAssertEqual(controller.testingSelectedFASTARecords, [">dup\nACGTTCGAAC\n"])
    }

    func testMatrixCellSelectionSelectsTheUnionOfRowAndColumnSequences() async throws {
        let controller = try await controller()
        controller.showDistanceMatrix()
        await waitForMatrix(controller)
        let grid = controller.bottomPane.distancePane.gridView
        // Select every cell through the grid's own Select All route.
        grid.selectAll(nil)
        XCTAssertEqual(controller.testingSelectedRowIndices, IndexSet(integersIn: 0...3))
        XCTAssertTrue(grid.selection.cells.count == 16, "the alignment echo does not clear the matrix cells")
    }

    func testRevealPairSelectsBothRows() async throws {
        let controller = try await controller()
        controller.showDistanceMatrix()
        await waitForMatrix(controller)
        controller.bottomPane.distancePane.onRevealPair?(1, 3)
        XCTAssertEqual(controller.testingSelectedRowIndices, IndexSet([1, 3]))
    }

    func testAlignmentSelectionReflectsIntoMatrixHeaders() async throws {
        let controller = try await controller()
        controller.showDistanceMatrix()
        await waitForMatrix(controller)
        let grid = controller.bottomPane.distancePane.gridView
        grid.selectAll(nil)
        controller.testingSelect(row: 2, displayedColumn: 0)
        XCTAssertTrue(grid.selection.cells.isEmpty, "an outside selection clears matrix cells")
        XCTAssertEqual(grid.selection.selectedSequences, IndexSet(integer: 2))
    }

    func testFocusedPairReachesTheControllerCallback() async throws {
        let controller = try await controller()
        var received: [MSAFocusedDistancePair?] = []
        controller.onFocusedDistancePairChanged = { received.append($0) }
        controller.showDistanceMatrix()
        await waitForMatrix(controller)
        let grid = controller.bottomPane.distancePane.gridView
        grid.selectAll(nil)
        grid.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)),
            charactersIgnoringModifiers: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)),
            isARepeat: false, keyCode: 124
        )))
        let pair = try XCTUnwrap(received.compactMap { $0 }.last)
        XCTAssertEqual(pair.model, controller.bottomPane.distancePane.model.effectiveModel)
        XCTAssertGreaterThan(pair.detail.comparableSites, 0)
    }

    // MARK: Accessibility rows

    /// Lane B builds every row and cell element on the first rows query.
    /// The wall-clock bound was dropped (review N10) because it measured the
    /// machine's load, not the code.
    func testFirstAccessibilityRowsQueryOnA200RowMatrix() async throws {
        let rows = (0..<200).map { index -> String in
            let bases = Array("ACGT")
            let sequence = String((0..<24).map { bases[($0 * 7 + index * 3) % 4] })
            return ">s\(index)\n\(sequence)\n"
        }.joined()
        let controller = try await controller(bundleURL: try bundle(rows, name: "two-hundred"))
        controller.showDistanceMatrix()
        let ready = await LungfishTestSupport.waitUntil(timeout: .seconds(30)) {
            controller.bottomPane.distancePane.model.status == .ready
        }
        XCTAssertTrue(ready)
        let grid = controller.bottomPane.distancePane.gridView
        XCTAssertEqual(grid.accessibilityRows()?.count, 200)
    }
}
