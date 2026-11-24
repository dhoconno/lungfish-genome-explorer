// ViewSwitchViewStateDrivers+Datasets.swift - The FASTQ, assembly and FASTA collection drivers for the view state cases (VS-DATA)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each driver reads the view's own controls, found in the view tree where the controller keeps them private (QA 2).
// FASTQ: the routing fixture's bundle with cached statistics. The change opens the Reads tab and widens the
// operations list to 260 points. Assembly: the SPAdes fixture's two contigs. The change filters for NODE_2, sorts by
// length, longest first, and selects NODE_2. FASTA collection: `Inputs/clusters.fasta` with cluster_1 (12 bp) and
// cluster_2 (8 bp). The change filters for cluster_2, sorts by length, selects it and sets the detail pane to 150 points.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishAssemblyUI
@testable import LungfishKit
import LungfishTestSupport

/// Every view of `type` under `view`, depth first.
@MainActor
func viewStateDescendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
    view.subviews.flatMap { child -> [T] in
        ((child as? T).map { [$0] } ?? []) + viewStateDescendants(of: child, as: type)
    }
}

/// Whether the installed surface's kept view has been applied: a surface whose own load runs on gets a handle, which
/// applies when that load commits (VS A2). A surface that keeps no view, or one with no handle, has nothing to wait for.
@MainActor
func viewStateIsSettled(in harness: ViewSwitchWindowHarness) -> Bool {
    guard let adopter = harness.split.viewerController.surfaceHost.activeViewport as? any ViewMemoryAdopting else {
        return true
    }
    return handleIsApplied(adopter)
}

@MainActor
private func handleIsApplied<Adopter: ViewMemoryAdopting>(_ adopter: Adopter) -> Bool {
    adopter.viewMemoryHandle?.isApplied ?? true
}

// MARK: - FASTQ

@MainActor
struct FASTQViewStateDriver: ViewStateDriver {
    let kind = "FASTQ"

    private func dashboard(in harness: ViewSwitchWindowHarness) -> FASTQDatasetViewController? {
        harness.split.viewerController.fastqDatasetController
    }

    /// The Operations and Reads control.
    private func tabControl(of dashboard: FASTQDatasetViewController) -> NSSegmentedControl? {
        viewStateDescendants(of: dashboard.view, as: NSSegmentedControl.self).first {
            $0.segmentCount == 2 && $0.label(forSegment: 1) == "Reads"
        }
    }

    /// The side by side split of the operations list and the preview, whose delegate is the dashboard.
    private func middleSplit(of dashboard: FASTQDatasetViewController) -> NSSplitView? {
        viewStateDescendants(of: dashboard.view, as: NSSplitView.self).first {
            $0.isVertical && $0.delegate === dashboard
        }
    }

    /// The dashboard shows once its operations list has a width, which the first layout places.
    func isShown(in harness: ViewSwitchWindowHarness) -> Bool {
        guard let dashboard = dashboard(in: harness), let split = middleSplit(of: dashboard) else { return false }
        return (split.subviews.first?.frame.width ?? 0) > 0
    }

    func change(in harness: ViewSwitchWindowHarness) async throws {
        let dashboard = try XCTUnwrap(dashboard(in: harness))
        let tabs = try XCTUnwrap(tabControl(of: dashboard))
        tabs.selectedSegment = 1
        _ = tabs.sendAction(tabs.action, to: tabs.target)
        try XCTUnwrap(middleSplit(of: dashboard)).setPosition(260, ofDividerAt: 0)
    }

    /// The tab on show and the width of the operations list.
    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        let dashboard = try XCTUnwrap(dashboard(in: harness))
        let tabs = try XCTUnwrap(tabControl(of: dashboard))
        let width = try XCTUnwrap(middleSplit(of: dashboard)).subviews.first?.frame.width ?? 0
        return [
            "tab \(tabs.label(forSegment: tabs.selectedSegment) ?? "none")",
            "operations list width \(Int(width.rounded()))",
        ]
    }

    /// Moves the reads file's date, so its stamp and the data key change.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        let bundle = try XCTUnwrap(fixture.item.url)
        let reads = bundle.appendingPathComponent("illumina-reads.fastq")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: reads.path)
    }

    /// The tab and the width are presentation, which comes back on any data key with no line (VS B2 to B9).
    func readingAfterChangedBundle(changed: [String]) -> [String] { changed }

    var lineAfterChangedBundle: String? { nil }
}

// MARK: - Assembly

@MainActor
struct AssemblyViewStateDriver: ViewStateDriver {
    let kind = "Assembly"
    static let kept = "NODE_2_length_300_cov_15.1"

    private func viewer(in harness: ViewSwitchWindowHarness) -> AssemblyResultViewController? {
        harness.split.viewerController.assemblyResultController
    }

    func isShown(in harness: ViewSwitchWindowHarness) -> Bool {
        guard let viewer = viewer(in: harness) else { return false }
        return viewer.heldContigsStamp != nil
    }

    /// Waits for the kept view, applied when the contigs load (VS A2), and for the selection's own read, which sets the
    /// contigs that Extract, Export and BLAST act on.
    func settle(in harness: ViewSwitchWindowHarness) async {
        _ = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            guard viewStateIsSettled(in: harness), let viewer = viewer(in: harness) else { return false }
            return viewer.selectedContigNames == selectedNames(in: viewer)
        }
    }

    private func selectedNames(in viewer: AssemblyResultViewController) -> [String] {
        let table = viewer.testContigTableView
        return table.tableView.selectedRowIndexes.compactMap { table.record(at: $0)?.name }
    }

    func change(in harness: ViewSwitchWindowHarness) async throws {
        let table = try XCTUnwrap(viewer(in: harness)).testContigTableView
        table.setFilterText("NODE_2")
        table.tableView.sortDescriptors = [NSSortDescriptor(key: "length", ascending: false)]
        table.selectContigs(named: [Self.kept])
    }

    /// The filter field, the sort, the rows, the selected rows, and the contigs the actions read.
    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        let viewer = try XCTUnwrap(viewer(in: harness))
        let table = viewer.testContigTableView
        let sort = table.tableView.sortDescriptors.first
        return [
            "filter \(table.currentFilterText)",
            "sort \(sort?.key ?? "none") \(sort.map { $0.ascending ? "ascending" : "descending" } ?? "")",
            "rows \(table.tableView.numberOfRows)",
            "selected \(selectedNames(in: viewer).joined(separator: ", "))",
            "actions read \(viewer.selectedContigNames.joined(separator: ", "))",
        ]
    }

    /// Moves the contigs file's date, so its stamp and the data key change.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        let result = try XCTUnwrap(fixture.item.url)
        let contigs = result.appendingPathComponent("contigs.fasta")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: contigs.path)
    }

    /// The filter text is a search text, so a changed key drops it and both contigs show. The sort and the selected
    /// contig by its name come back (VS B4, B6).
    func readingAfterChangedBundle(changed: [String]) -> [String] {
        var reading = changed
        reading[0] = "filter "
        reading[2] = "rows 2"
        return reading
    }

    var lineAfterChangedBundle: String? { ViewMemoryWords.dataChanged(.filters) }
}

// MARK: - FASTA collection

@MainActor
struct FASTACollectionViewStateDriver: ViewStateDriver {
    let kind = "FASTA collection"
    static let detailHeight = 150

    private func list(in harness: ViewSwitchWindowHarness) -> FASTACollectionViewController? {
        harness.split.viewerController.fastaCollectionController
    }

    func isShown(in harness: ViewSwitchWindowHarness) -> Bool {
        guard let list = list(in: harness) else { return false }
        return list.testTableView.numberOfRows > 0
    }

    /// The detail pane takes its kept height once the list has its size, on the turn after the install.
    func settle(in harness: ViewSwitchWindowHarness) async {
        _ = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            guard let list = list(in: harness) else { return false }
            return list.testDetailIsCollapsed || Int(list.testDetailHeight.rounded()) == Self.detailHeight
        }
    }

    func change(in harness: ViewSwitchWindowHarness) async throws {
        let list = try XCTUnwrap(list(in: harness))
        list.testFilter("cluster_2")
        list.testTableView.sortDescriptors = [NSSortDescriptor(key: "length", ascending: true)]
        list.testSelectRows([0])
        list.testSetDetailHeight(CGFloat(Self.detailHeight))
    }

    /// The filter field, the sort, the rows, the selected records and the detail pane.
    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        let list = try XCTUnwrap(list(in: harness))
        let field = try XCTUnwrap(viewStateDescendants(of: list.view, as: NSSearchField.self).first)
        let sort = list.testTableView.sortDescriptors.first
        return [
            "filter \(field.stringValue)",
            "sort \(sort?.key ?? "none") \(sort.map { $0.ascending ? "ascending" : "descending" } ?? "")",
            "rows \(list.testTableView.numberOfRows)",
            "selected \(list.selectedSequences().map(\.name).joined(separator: ", "))",
            list.testDetailIsCollapsed ? "detail closed" : "detail \(Int(list.testDetailHeight.rounded()))",
        ]
    }

    /// Moves the file's date, so its stamp and the data key change.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        let file = try XCTUnwrap(fixture.item.url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: file.path)
    }

    /// The filter text is a search text, so a changed key drops it and both records show. The sort, the selected
    /// record by its name and the detail pane come back (VS B4, B6).
    func readingAfterChangedBundle(changed: [String]) -> [String] {
        var reading = changed
        reading[0] = "filter "
        reading[2] = "rows 2"
        return reading
    }

    var lineAfterChangedBundle: String? { ViewMemoryWords.dataChanged(.filters) }
}
