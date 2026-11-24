// FASTQDrawerKeepsEditOnSelectTests.swift - An edit typed in the FASTQ drawer outlives the selection of another dataset
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ux-text lane DRAWERS (FASTQ-DRAWER-EDIT-LOST-ON-SELECT, S1). A sample name typed in the drawer's table and not yet
// saved was dropped with no words when the person selected another dataset, since the drawer went with the
// dashboard and the next load read the sidecar again. Leaving the dataset now saves the edit through Save's own path.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishIO
import LungfishTestSupport

@MainActor
final class FASTQDrawerKeepsEditOnSelectTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "fastq-drawer-keeps-edit")
    }

    override func tearDown() async throws {
        if let root { TestTempDirectory.cleanup(root) }
        root = nil
        try await super.tearDown()
    }

    /// The person renames a saved sample in the drawer's table, does not press Save, and selects another dataset.
    /// The name they typed is in the first dataset's sidecar, and the drawer shows it when they come back.
    func testASampleNameTypedAndNotSavedIsInTheStoreAfterAnotherDatasetIsSelected() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let first = try await fastq(named: "First", savedSampleName: "Saved name")
        let second = try await fastq(named: "Second", savedSampleName: nil)

        try show(first, in: viewer)
        viewer.toggleFASTQMetadataDrawer()
        let drawer = try XCTUnwrap(viewer.fastqMetadataDrawerView, "the drawer did not open")
        try type("Typed name", intoSampleNameOfRow: 0, in: drawer)
        XCTAssertEqual(sampleName(savedFor: first), "Saved name", "Precondition: the typed name is not saved yet.")

        try show(second, in: viewer)

        XCTAssertEqual(sampleName(savedFor: first), "Typed name", "the typed sample name was lost when another dataset was selected")
        XCTAssertNil(sampleName(savedFor: second), "the edit went to the dataset selected next")

        try show(first, in: viewer)
        viewer.toggleFASTQMetadataDrawer()
        let shown = try XCTUnwrap(viewer.fastqMetadataDrawerView).currentMetadata().sampleAssignments.first?.sampleName
        XCTAssertEqual(shown, "Typed name", "the drawer did not show the kept name on the way back")
    }

    /// A drawer the person only looked at writes nothing when they leave, so a sidecar changes only for an edit.
    func testADrawerWithNoEditWritesNothingWhenAnotherDatasetIsSelected() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let first = try await fastq(named: "First", savedSampleName: "Saved name")
        let second = try await fastq(named: "Second", savedSampleName: nil)
        let sidecar = FASTQMetadataStore.metadataURL(for: first)
        let before = try Data(contentsOf: sidecar)

        try show(first, in: viewer)
        viewer.toggleFASTQMetadataDrawer()
        try show(second, in: viewer)

        XCTAssertEqual(try Data(contentsOf: sidecar), before, "leaving a drawer with no edit rewrote the sidecar")
    }

    /// When the edit cannot be written on leaving, because the reads are gone, a sheet on the window says so and why,
    /// and names the dataset. The seam stands in for the sheet, so no real sheet opens in a test.
    func testAnEditThatCannotBeSavedOnLeavingIsSaidInASheet() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let first = try await fastq(named: "First", savedSampleName: "Saved name")
        let second = try await fastq(named: "Second", savedSampleName: nil)
        var asked: [(alert: NSAlert, window: NSWindow?)] = []
        let present = ViewerViewController.presentUnkeptFASTQDrawerEdit
        ViewerViewController.presentUnkeptFASTQDrawerEdit = { asked.append(($0, $1)) }
        defer { ViewerViewController.presentUnkeptFASTQDrawerEdit = present }

        try show(first, in: viewer)
        viewer.toggleFASTQMetadataDrawer()
        try type("Typed name", intoSampleNameOfRow: 0, in: try XCTUnwrap(viewer.fastqMetadataDrawerView))
        try FileManager.default.removeItem(at: first)
        try show(second, in: viewer)

        XCTAssertEqual(asked.count, 1, "the edit that could not be saved was dropped with no sheet")
        let alert = try XCTUnwrap(asked.first?.alert)
        XCTAssertTrue(asked.first?.window === harness.window, "the sheet was not put on the dataset's window")
        XCTAssertEqual(alert.messageText, "The FASTQ drawer\u{2019}s edits for illumina-reads were not saved.")
        XCTAssertTrue(alert.informativeText.contains("The settings saved earlier are unchanged."), alert.informativeText)
        XCTAssertTrue(alert.informativeText.hasSuffix("then select it and make the edits again."), alert.informativeText)
        XCTAssertEqual(alert.buttons.map(\.title), ["OK"])
    }

    /// A Save the person presses that cannot write, because the reads are gone, does not say it saved (DRAWERS-UX SF1).
    func testAHandPressedSaveThatCannotWriteDoesNotSayItSaved() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let first = try await fastq(named: "First", savedSampleName: "Saved name")

        try show(first, in: viewer)
        viewer.toggleFASTQMetadataDrawer()
        let drawer = try XCTUnwrap(viewer.fastqMetadataDrawerView, "the drawer did not open")
        try type("Typed name", intoSampleNameOfRow: 0, in: drawer)
        try FileManager.default.removeItem(at: first)
        let save = try XCTUnwrap(Self.buttons(in: drawer).first { $0.action == Selector(("saveClicked:")) }, "the drawer has no Save")
        save.performClick(nil)

        let readable = Self.readableText(in: drawer)
        XCTAssertFalse(readable.contains { $0.contains("Saved with this dataset") }, "a Save that could not write said it saved: \(readable)")
        XCTAssertTrue(readable.contains { $0.contains("Not saved") }, "a Save that could not write said nothing: \(readable)")
    }

    // MARK: - Fixture

    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview in [subview as? NSButton].compactMap { $0 } + buttons(in: subview) }
    }

    /// Every string a person can read in the drawer, from its visible labels and fields.
    private static func readableText(in view: NSView) -> [String] {
        guard !view.isHidden else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap(readableText)
    }

    /// A FASTQ bundle with cached statistics, and a saved sample row named `savedSampleName` when one is given.
    private func fastq(named name: String, savedSampleName: String?) async throws -> URL {
        let (_, fastq) = try await RoutingSafetyNetFixtures.fastqBundle(in: root.appendingPathComponent(name, isDirectory: true))
        guard let savedSampleName else { return fastq }
        var persisted = FASTQMetadataStore.load(for: fastq) ?? PersistedFASTQMetadata()
        persisted.demultiplexMetadata = FASTQDemultiplexMetadata(sampleAssignments: [
            FASTQSampleBarcodeAssignment(sampleID: "bc01", sampleName: savedSampleName, forwardBarcodeID: "bc01"),
        ])
        try FASTQMetadataStore.write(persisted, for: fastq)
        return fastq
    }

    private func show(_ fastq: URL, in viewer: ViewerViewController, file: StaticString = #filePath, line: UInt = #line) throws {
        let opened = viewer.displayFASTQDataset(
            statistics: .countsOnlyFixture(readCount: 4, baseCount: 400), records: [], fastqURL: fastq
        )
        XCTAssertTrue(opened, "the dashboard of \(fastq.lastPathComponent) did not open", file: file, line: line)
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
