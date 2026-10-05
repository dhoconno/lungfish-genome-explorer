// MSABottomPaneReviewFixTests.swift - UI review fixes S1, S3, S5, N1, N2, N5 and science N2 for the MSA bottom pane
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
import LungfishAlignmentUI
import LungfishIO
import LungfishTestSupport

@MainActor
final class MSABottomPaneReviewFixTests: XCTestCase {
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

    private func bundle(name: String = "fix") throws -> URL {
        let source = temporaryDirectory.appendingPathComponent("\(name).fa")
        try ">a\nACGTACGTAC\n>b\nACGTTCGAAC\n>c\nACGAACGTTC\n>d\nTCGTACGAAC\n"
            .write(to: source, atomically: true, encoding: .utf8)
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
        controller.bottomPane.reduceMotion = { true }
        return controller
    }

    private func waitForMatrix(
        _ controller: MultipleSequenceAlignmentViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let ready = await waitUntil(timeout: .seconds(20)) {
            controller.bottomPane.distancePane.model.status == .ready
        }
        XCTAssertTrue(ready, "the distance matrix never became ready", file: file, line: line)
    }

    // MARK: S1 the Inspector keeps its tab while the pane drives selection

    func testPaneDrivenSelectionKeepsTheInspectorTab() async throws {
        let windowController = MainWindowController()
        defer { windowController.close() }
        let split = try XCTUnwrap(windowController.mainSplitViewController)
        _ = split.view
        let viewer = try XCTUnwrap(split.viewerController)
        try await viewer.displayMultipleSequenceAlignmentBundle(at: try bundle())
        let msa = try XCTUnwrap(viewer.multipleSequenceAlignmentViewController)
        msa.bottomPane.defaults = defaults
        split.wireMultipleSequenceAlignmentInspector(msa, isCurrent: { true })
        let inspector = try XCTUnwrap(split.inspectorController)
        msa.showDistanceMatrix()
        await waitForMatrix(msa)

        inspector.viewModel.selectedTab = .bundle
        msa.bottomPane.distancePane.gridView.selectAll(nil)
        XCTAssertEqual(msa.testingSelectedRowIndices, IndexSet(integersIn: 0...3))
        XCTAssertEqual(inspector.viewModel.selectedTab, .bundle, "the Pairwise Distance breakdown stays in view")

        msa.testingSelect(row: 2, displayedColumn: 0)
        XCTAssertEqual(inspector.viewModel.selectedTab, .selectedItem, "a selection in the alignment still shows Selected Item")
    }

    // MARK: S3 key view loop

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

    func testKeyViewLoopRunsThroughThePaneAndOut() async throws {
        let controller = try await controller()
        let previous = NSButton(title: "Before", target: nil, action: nil)
        let next = NSButton(title: "After", target: nil, action: nil)
        previous.nextKeyView = controller.alignmentKeyView
        controller.alignmentKeyView.nextKeyView = next
        let window = host(controller)
        defer { window.close() }
        let pane = controller.bottomPane
        let distances = pane.distancePane
        pane.select(.distances)
        XCTAssertTrue(controller.alignmentKeyView.nextKeyView === pane.divider)
        XCTAssertTrue(pane.divider.nextKeyView === pane.tabControl)
        XCTAssertTrue(pane.tabControl.nextKeyView === distances.firstKeyView)
        XCTAssertTrue(distances.firstKeyView.previousKeyView === pane.tabControl, "Shift-Tab from the controls reaches the tab control")

        var view: NSView? = distances.firstKeyView
        var steps = 0
        while let current = view, current !== distances.gridView, steps < 20 {
            view = current.nextKeyView
            steps += 1
        }
        XCTAssertTrue(view === distances.gridView, "the header controls lead to the grid")
        let afterGrid = try XCTUnwrap(distances.gridView.nextKeyView)
        XCTAssertFalse(afterGrid.isDescendant(of: pane), "Tab from the grid leaves the pane")
        XCTAssertTrue(afterGrid === next, "the pane sits between the alignment and its original next view")
        XCTAssertTrue(next.previousKeyView === distances.gridView)
        XCTAssertTrue(controller.alignmentKeyView.previousKeyView === previous, "the alignment keeps its previous view")
    }

    /// Re-review SF2 and SF-A: with no original next view the grid hands
    /// Tab back to the alignment, and the alignment keeps its previous view.
    func testKeyViewLoopWithoutANextViewReturnsToTheAlignment() async throws {
        let controller = try await controller()
        let previous = NSButton(title: "Before", target: nil, action: nil)
        previous.nextKeyView = controller.alignmentKeyView
        controller.alignmentKeyView.nextKeyView = nil
        let window = host(controller)
        defer { window.close() }
        let pane = controller.bottomPane
        XCTAssertTrue(controller.alignmentKeyView.nextKeyView === pane.divider)
        XCTAssertTrue(pane.distancePane.gridView.nextKeyView === controller.alignmentKeyView)
        XCTAssertTrue(controller.alignmentKeyView.previousKeyView === previous)

        // Moving to another window does not splice the pane in twice.
        let other = host(controller)
        defer { other.close() }
        XCTAssertTrue(controller.alignmentKeyView.nextKeyView === pane.divider)
        XCTAssertTrue(pane.distancePane.gridView.nextKeyView === controller.alignmentKeyView)
        XCTAssertTrue(controller.alignmentKeyView.previousKeyView === previous)
    }

    // MARK: S5 reverse sync on first show

    func testAlignmentSelectionMadeBeforeTheMatrixShowsReachesIt() async throws {
        let controller = try await controller()
        controller.testingSelect(row: 2, displayedColumn: 0)
        controller.showDistanceMatrix()
        await waitForMatrix(controller)
        XCTAssertEqual(controller.bottomPane.distancePane.gridView.selection.selectedSequences, IndexSet(integer: 2))
    }

    // MARK: N1 clearing the matrix clears the alignment

    func testClearingTheMatrixSelectionClearsTheAlignmentRows() async throws {
        let controller = try await controller()
        controller.showDistanceMatrix()
        await waitForMatrix(controller)
        let grid = controller.bottomPane.distancePane.gridView
        grid.selectAll(nil)
        XCTAssertEqual(controller.testingSelectedRowIndices, IndexSet(integersIn: 0...3))
        grid.cancelOperation(nil)
        XCTAssertTrue(controller.testingSelectedRowIndices.isEmpty)
    }

    // MARK: N2 Show Drawer close moves focus out of the grid

    func testClosingThePaneFromShowDrawerMovesFocusToTheAlignment() async throws {
        let controller = try await controller()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
        controller.showDistanceMatrix()
        XCTAssertTrue(window.firstResponder === controller.bottomPane.distancePane.gridView)
        controller.toggleBottomPane()
        XCTAssertFalse(controller.isBottomPaneOpen)
        XCTAssertTrue(window.firstResponder === controller.alignmentKeyView)
    }

    // MARK: N5 the window toolbar button hears every open or close

    func testEveryPaneToggleReportsTheNewState() async throws {
        let controller = try await controller()
        var reports = 0
        controller.onBottomPaneStateChanged = { reports += 1 }
        controller.toggleDistanceMatrixFromToolbar(nil)
        XCTAssertTrue(controller.isBottomPaneOpen)
        XCTAssertGreaterThan(reports, 0, "the MSA toolbar button opened the pane")
        reports = 0
        controller.toggleDistanceMatrixFromToolbar(nil)
        XCTAssertGreaterThan(reports, 0, "and closed it")
    }

    func testTheViewerWiresTheToolbarSync() async throws {
        let windowController = MainWindowController()
        defer { windowController.close() }
        let split = try XCTUnwrap(windowController.mainSplitViewController)
        _ = split.view
        let viewer = try XCTUnwrap(split.viewerController)
        try await viewer.displayMultipleSequenceAlignmentBundle(at: try bundle())
        XCTAssertNotNil(viewer.multipleSequenceAlignmentViewController?.onBottomPaneStateChanged)
    }

    // MARK: Science N2 an unreadable alphabet is an error, not a nucleotide guess

    func testUnreadableAlphabetShowsAPaneError() async throws {
        let bundleURL = try bundle(name: "no-alphabet")
        let controller = try await controller(bundleURL: bundleURL)
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest.removeValue(forKey: "alphabet")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)

        controller.showDistanceMatrix()
        guard case .failed(let message) = controller.bottomPane.distancePane.model.status else {
            return XCTFail("expected a failure, got \(controller.bottomPane.distancePane.model.status)")
        }
        XCTAssertTrue(message.contains("alphabet"), message)
        XCTAssertNil(controller.bottomPane.distancePane.model.matrix)
    }
}
