// MappingListViewportKeptTests.swift - A sort or a filter of the mapping list keeps the viewer's zoom
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishTestSupport

/// RM-LIST-VIEWPORT. After a sort or a filter the mapping list emits its selected row again, and the viewer
/// showed the whole contig again, so a zoomed region and its reads were lost. A sort or a filter that keeps
/// the row keeps the zoomed region and the read settings. A click on another row still shows that contig.
@MainActor
final class MappingListViewportKeptTests: XCTestCase {
    private func contig(_ name: String, length: Int, reads: Int) -> MappingContigSummary {
        MappingContigSummary(
            contigName: name, contigLength: length, mappedReads: reads, mappedReadPercent: Double(reads),
            meanDepth: 2, coverageBreadth: 0.5, medianMAPQ: 60, meanIdentity: 0.99
        )
    }

    /// chr1 (5,000 bp, 90 reads) above chr2 (3,000 bp, 40 reads) in the default Mapped Reads order,
    /// with chr1 selected and shown whole.
    private func makeViewport(in root: URL) throws -> ReferenceBundleViewportController {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "List Viewport",
            chromosomes: [.init(name: "chr1", length: 5_000), .init(name: "chr2", length: 3_000)],
            in: root
        )
        let resultURL = root.appendingPathComponent("mapping-result", isDirectory: true)
        let viewport = ReferenceBundleViewportController()
        _ = viewport.view
        viewport.configureForTesting(
            result: MappingRoutingFixture.makeMappingResult(
                resultDirectory: resultURL,
                viewerBundleURL: bundleURL,
                contigs: [contig("chr1", length: 5_000, reads: 90), contig("chr2", length: 3_000, reads: 40)]
            ),
            resultDirectoryURL: resultURL
        )
        XCTAssertEqual(viewport.testContigTableView.displayedRows.map(\.contigName), ["chr1", "chr2"])
        XCTAssertEqual(viewport.testSelectedContigName, "chr1")
        return viewport
    }

    private func assertRegion(
        _ viewer: ViewerViewController,
        _ chromosome: String,
        _ start: Int,
        _ end: Int,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let frame = try XCTUnwrap(viewer.referenceFrame, message, file: file, line: line)
        XCTAssertEqual(frame.chromosome, chromosome, message, file: file, line: line)
        XCTAssertEqual(Int(frame.start), start, message, file: file, line: line)
        XCTAssertEqual(Int(frame.end), end, message, file: file, line: line)
    }

    private func selectThroughTheList(_ name: String, in table: MappingContigTableView) throws {
        let index = try XCTUnwrap(table.displayedRows.firstIndex { $0.contigName == name })
        table.tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    func testSortAndFilterThatKeepTheRowKeepTheZoomedRegion() throws {
        let root = try TestTempDirectory.make(prefix: "MappingListViewportKept")
        defer { TestTempDirectory.cleanup(root) }
        let viewport = try makeViewport(in: root)
        let viewer = viewport.testEmbeddedViewerController
        let table = viewport.testContigTableView
        try assertRegion(viewer, "chr1", 0, 5_000, "the selected contig opens whole")

        XCTAssertTrue(viewer.navigateToPosition(chromosome: "chr1", start: 1_000, end: 1_600))
        // A second display of the contig sets the viewer to the row's own read groups, which are none.
        viewer.viewerView.selectedReadGroupsSetting = ["kept-rg"]

        table.tableView.sortDescriptors = [NSSortDescriptor(key: "contig", ascending: false)]
        XCTAssertEqual(table.displayedRows.map(\.contigName), ["chr2", "chr1"], "the sort ran and moved the row")
        XCTAssertEqual(viewport.testSelectedContigName, "chr1")
        try assertRegion(viewer, "chr1", 1_000, 1_600, "a sort keeps the zoomed region")
        XCTAssertEqual(viewer.viewerView.selectedReadGroupsSetting, ["kept-rg"], "a sort does not display the contig again")

        table.setFilterText("chr1")
        XCTAssertEqual(table.displayedRows.map(\.contigName), ["chr1"])
        XCTAssertEqual(viewport.testSelectedContigName, "chr1")
        try assertRegion(viewer, "chr1", 1_000, 1_600, "a filter that keeps the row keeps the zoomed region")
        XCTAssertEqual(viewer.viewerView.selectedReadGroupsSetting, ["kept-rg"], "a filter does not display the contig again")

        table.setFilterText("")
        XCTAssertEqual(viewport.testSelectedContigName, "chr1")
        try assertRegion(viewer, "chr1", 1_000, 1_600, "clearing the filter keeps the zoomed region")
    }

    func testSelectingAnotherContigStillDisplaysIt() throws {
        let root = try TestTempDirectory.make(prefix: "MappingListViewportKept")
        defer { TestTempDirectory.cleanup(root) }
        let viewport = try makeViewport(in: root)
        let viewer = viewport.testEmbeddedViewerController
        let table = viewport.testContigTableView
        XCTAssertTrue(viewer.navigateToPosition(chromosome: "chr1", start: 1_000, end: 1_600))

        try selectThroughTheList("chr2", in: table)
        XCTAssertEqual(viewport.testSelectedContigName, "chr2")
        try assertRegion(viewer, "chr2", 0, 3_000, "a click on another contig shows that contig whole")

        XCTAssertTrue(viewer.navigateToPosition(chromosome: "chr2", start: 500, end: 900))
        try selectThroughTheList("chr1", in: table)
        XCTAssertEqual(viewport.testSelectedContigName, "chr1")
        try assertRegion(viewer, "chr1", 0, 5_000, "a click back shows the first contig whole again")
    }

    func testContigShowsAgainAfterTheListHidItsSelection() throws {
        let root = try TestTempDirectory.make(prefix: "MappingListViewportKept")
        defer { TestTempDirectory.cleanup(root) }
        let viewport = try makeViewport(in: root)
        let viewer = viewport.testEmbeddedViewerController
        let table = viewport.testContigTableView
        XCTAssertTrue(viewer.navigateToPosition(chromosome: "chr1", start: 1_000, end: 1_600))

        // A filter that hides the selected row clears the selection and the viewer gives way to the words.
        table.setFilterText("chr2")
        XCTAssertEqual(viewport.testDetailPlaceholderMessage, "Select a mapped contig to inspect mapped reads.")
        XCTAssertTrue(viewer.view.isHidden)

        // The person picks the same contig again from the list. It is a new display, not a repeat.
        table.setFilterText("")
        try selectThroughTheList("chr1", in: table)
        XCTAssertFalse(viewer.view.isHidden, "the contig shows again after the words")
        try assertRegion(viewer, "chr1", 0, 5_000, "a contig picked again after the words opens whole")
    }
}
