// FASTQDrawerKeepsEditOnQuitTests.swift - An edit typed in the FASTQ drawer outlives Quit and the close of its window
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ux-text lane DRAWERS-2 (FASTQ-DRAWER-EDIT-LOST-ON-QUIT, S1). Lane DRAWERS kept a waiting drawer edit when the person
// leaves the dataset, but Quit and the close of the project window never reach the drawer, so a typed sample name, kit,
// plan or primer-trim setting was lost with no words. Both now save it through Save's own path first.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishIO
import LungfishTestSupport

@MainActor
final class FASTQDrawerKeepsEditOnQuitTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        try requireNoPendingAnnotationEditsForTest()
        OperationCenter.useTemporaryFailureReportsForTesting()
        root = try TestTempDirectory.make(prefix: "fastq-drawer-keeps-edit-on-quit")
    }

    override func tearDown() async throws {
        if let root { TestTempDirectory.cleanup(root) }
        root = nil
        try await super.tearDown()
    }

    /// The person types a sample name in the drawer, does not press Save, and quits. Quit goes on, and the name is in
    /// the dataset's sidecar.
    func testQuitWithATypedDrawerEditStoresTheEdit() async throws {
        let (delegate, viewer) = try projectWindow()
        let first = try await fastq(named: "First", savedSampleName: "Saved name")
        try openDrawer(on: first, in: viewer)
        try type("Typed name", intoSampleNameOfRow: 0, in: try XCTUnwrap(viewer.fastqMetadataDrawerView))
        XCTAssertEqual(sampleName(savedFor: first), "Saved name", "Precondition: the typed name is not saved yet.")

        var replies: [Bool] = []
        let immediate = delegate.testingApplicationShouldTerminate { replies.append($0) }

        XCTAssertEqual(sampleName(savedFor: first), "Typed name", "Quit lost the sample name typed in the FASTQ drawer")
        XCTAssertEqual(immediate, .terminateNow, "a drawer edit that was saved held the Quit")
        XCTAssertEqual(replies, [])
    }

    /// The person types a sample name, does not press Save, and closes the project window with its close button or
    /// Cmd-W. The window may close, and the name is in the dataset's sidecar.
    func testClosingTheWindowWithATypedDrawerEditStoresTheEdit() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let first = try await fastq(named: "First", savedSampleName: "Saved name")
        try openDrawer(on: first, in: viewer)
        try type("Typed name", intoSampleNameOfRow: 0, in: try XCTUnwrap(viewer.fastqMetadataDrawerView))

        let mayClose = harness.controller.windowShouldClose(harness.window)

        XCTAssertEqual(sampleName(savedFor: first), "Typed name", "closing the window lost the sample name typed in the FASTQ drawer")
        XCTAssertTrue(mayClose, "a drawer edit that was saved held the close")
    }

    /// The control: a drawer the person only looked at writes nothing on Quit, and Quit asks nothing.
    func testQuitWithNoWaitingDrawerEditWritesNothingAndAsksNothing() async throws {
        let (delegate, viewer) = try projectWindow()
        let first = try await fastq(named: "First", savedSampleName: "Saved name")
        let sidecar = FASTQMetadataStore.metadataURL(for: first)
        let before = try Data(contentsOf: sidecar)
        try openDrawer(on: first, in: viewer)

        var replies: [Bool] = []
        let immediate = delegate.testingApplicationShouldTerminate { replies.append($0) }

        XCTAssertEqual(immediate, .terminateNow, "Quit was held with no drawer edit waiting")
        XCTAssertEqual(replies, [])
        XCTAssertEqual(try Data(contentsOf: sidecar), before, "Quit with no drawer edit rewrote the sidecar")
    }

    // MARK: - Fixture

    /// A project window of a fresh app delegate, ordered out, whose window state goes to the test's own folder.
    private func projectWindow() throws -> (AppDelegate, ViewerViewController) {
        let delegate = AppDelegate()
        delegate.projectWindowStateStore = ProjectWindowStateStore(stateURL: root.appendingPathComponent("windows.json"))
        let controller = delegate.createAndShowMainWindow()
        controller.window?.setFrameAutosaveName("")
        controller.window?.toolbar?.autosavesConfiguration = false
        controller.window?.animationBehavior = .none
        controller.window?.orderOut(nil)
        addTeardownBlock { controller.close() }
        let viewer = try XCTUnwrap(controller.mainSplitViewController?.viewerController, "the project window has no viewer")
        return (delegate, viewer)
    }

    /// A FASTQ bundle with cached statistics and a saved sample row named `savedSampleName`.
    private func fastq(named name: String, savedSampleName: String) async throws -> URL {
        let (_, fastq) = try await RoutingSafetyNetFixtures.fastqBundle(in: root.appendingPathComponent(name, isDirectory: true))
        var persisted = FASTQMetadataStore.load(for: fastq) ?? PersistedFASTQMetadata()
        persisted.demultiplexMetadata = FASTQDemultiplexMetadata(sampleAssignments: [
            FASTQSampleBarcodeAssignment(sampleID: "bc01", sampleName: savedSampleName, forwardBarcodeID: "bc01"),
        ])
        try FASTQMetadataStore.write(persisted, for: fastq)
        return fastq
    }

    private func openDrawer(on fastq: URL, in viewer: ViewerViewController) throws {
        let opened = viewer.displayFASTQDataset(
            statistics: .countsOnlyFixture(readCount: 4, baseCount: 400), records: [], fastqURL: fastq
        )
        XCTAssertTrue(opened, "the dashboard of \(fastq.lastPathComponent) did not open")
        viewer.toggleFASTQMetadataDrawer()
        XCTAssertNotNil(viewer.fastqMetadataDrawerView, "the drawer did not open")
    }

    private func sampleName(savedFor fastq: URL) -> String? {
        FASTQMetadataStore.load(for: fastq)?.demultiplexMetadata?.sampleAssignments.first?.sampleName
    }

    /// What the table does when a person ends typing in a cell: it hands the cell's text to its data source.
    private func type(_ text: String, intoSampleNameOfRow row: Int, in drawer: FASTQMetadataDrawerView) throws {
        let table = try XCTUnwrap(Self.tables(in: drawer).first { $0.tableColumn(withIdentifier: .init("sampleName")) != nil },
                                  "the drawer has no sample table")
        let column = try XCTUnwrap(table.tableColumn(withIdentifier: .init("sampleName")))
        XCTAssertGreaterThan(table.numberOfRows, row, "the sample table has no row \(row)")
        drawer.tableView(table, setObjectValue: text, for: column, row: row)
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        view.subviews.flatMap { subview in (subview as? NSTableView).map { [$0] } ?? tables(in: subview) }
    }
}
