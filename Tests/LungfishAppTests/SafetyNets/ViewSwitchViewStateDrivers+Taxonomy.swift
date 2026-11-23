// ViewSwitchViewStateDrivers+Taxonomy.swift - The Kraken2, EsViritu and CZ ID drivers for the view state cases (VS-TAX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each driver makes a person's change through the viewer's own controls and reads the same controls back (QA 2), never
// the state a capture holds. The fixtures are the routing table's one-sample results, so the sort and the filter are
// read from the controls and the selected row is read from the name cell of the outline.
//
// Kraken2 and CZ ID share one `TaxonomyViewController`, so they share `TaxonomyViewStateControls`. The sort is
// set through the header menu's path (`testingSortByColumn`), which leaves the outline's sort descriptors alone, so the
// case fails if a capture reads the descriptors instead of the table's own key.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishIO
@testable import LungfishEsVirituUI
@testable import LungfishTaxonomyUI
import LungfishWorkflow

/// The one line a changed bundle shows when the filter text drops (word 2, `.filters`).
private let filtersNotKeptLine = "The data changed since your last visit, so your filters were not kept."

/// When the fixture's run was built, and when the rerun of the changed-bundle case was, as `build-db` records them in
/// the database's `created_at` (`BuildDbCommand+Kraken2Core.swift`, `BuildDbCommand+EsVirituCore.swift`).
private let firstRunStamp = "2026-01-15T11:00:00Z"
private let rerunStamp = "2026-11-23T09:00:00Z"

/// What a person changes in a taxonomy viewer and what the viewer's controls show, for Kraken2 and CZ ID.
@MainActor
enum TaxonomyViewStateControls {
    /// The filter field, the sort by name, the last row selected, the sunburst zoom and the Collections drawer.
    static func change(_ viewer: TaxonomyViewController, filter: String) {
        let table = viewer.taxonomyTableView
        table.testingSetFilterText(filter)
        table.testingSortByColumn("name", ascending: true)
        let outline = table.outlineView
        if outline.numberOfRows > 0 {
            outline.selectRowIndexes(IndexSet(integer: outline.numberOfRows - 1), byExtendingSelection: false)
        }
        if let node = firstInnerNode(of: viewer.tree) {
            viewer.sunburstView.centerNode = node
            viewer.breadcrumbBar.update(zoomNode: node)
        }
        viewer.toggleTaxaCollectionsDrawer()
    }

    /// One line a field. The rows line is left out when the filter changes the count the reading would compare.
    static func read(_ viewer: TaxonomyViewController, includeRows: Bool) -> [String] {
        let table = viewer.taxonomyTableView
        let outline = table.outlineView
        let selected = outline.selectedRowIndexes.map { nameText(of: $0, in: outline) }
        var reading = [
            "filter \(table.searchField.stringValue)",
            "sort \(table.currentSortKey) \(table.currentSortAscending ? "ascending" : "descending")",
            "selected \(selected.joined(separator: ", "))",
            "zoom \(viewer.sunburstView.centerNode?.name ?? "none")",
            "drawer \(viewer.isTaxaCollectionsDrawerOpen ? "open" : "closed")",
        ]
        if includeRows { reading.append("rows \(outline.numberOfRows)") }
        return reading
    }

    /// The text of a row's name cell, made if the outline has not drawn it yet.
    static func nameText(of row: Int, in outline: NSOutlineView) -> String {
        let column = outline.column(withIdentifier: .init("name"))
        guard column >= 0,
              let cell = outline.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView else { return "?" }
        return cell.textField?.stringValue ?? "?"
    }

    /// The first node below the root that has children, else the root's first child, which a zoom can centre on.
    private static func firstInnerNode(of tree: TaxonTree?) -> TaxonNode? {
        guard let root = tree?.root else { return nil }
        var pending = root.children
        while !pending.isEmpty {
            let node = pending.removeFirst()
            if !node.children.isEmpty { return node }
            pending.append(contentsOf: node.children)
        }
        return root.children.first
    }

    /// A changed bundle drops the filter text and keeps the rest, so only the first line differs.
    static func readingAfterChangedBundle(changed: [String]) -> [String] {
        var reading = changed
        reading[0] = "filter "
        return reading
    }
}

// MARK: - Kraken2

@MainActor
struct Kraken2ViewStateDriver: ViewStateDriver {
    let kind = "Kraken2"

    private func viewer(in harness: ViewSwitchWindowHarness) -> TaxonomyViewController? {
        (harness.split.viewerController.surfaceHost.activeViewport as? Kraken2Surface)?.controller
    }

    func isShown(in harness: ViewSwitchWindowHarness) -> Bool { viewer(in: harness) != nil }

    func change(in harness: ViewSwitchWindowHarness) throws {
        TaxonomyViewStateControls.change(try XCTUnwrap(viewer(in: harness)), filter: "Homo")
    }

    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        TaxonomyViewStateControls.read(try XCTUnwrap(viewer(in: harness)), includeRows: true)
    }

    /// The routing fixture's one row is the tree's root, so the outline draws no row and a pick or a zoom has nothing
    /// to act on. The database is built again as a run makes it: a root, two genera and a species under each.
    func prepare(_ fixture: ViewSwitchFixture) throws {
        try Self.build(in: try XCTUnwrap(fixture.item.url), stamp: firstRunStamp)
    }

    /// A rerun in place with the same counts, which `build-db` stamps with a new `created_at`. A rerun must change the
    /// data key (VS B1), so the filter drops even though every count is the same.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        try Self.build(in: try XCTUnwrap(fixture.item.url), stamp: rerunStamp)
    }

    /// The filter drops, so every taxon below the root shows again: the outline opens the root's children, which
    /// shows both genera and both species.
    func readingAfterChangedBundle(changed: [String]) -> [String] {
        var reading = TaxonomyViewStateControls.readingAfterChangedBundle(changed: changed)
        reading[reading.count - 1] = "rows 4"
        return reading
    }

    private static func build(in folder: URL, stamp: String) throws {
        let database = folder.appendingPathComponent("kraken2.sqlite")
        try? FileManager.default.removeItem(at: database)
        func row(_ name: String, _ taxId: Int, _ rank: String, _ reads: Int, _ parent: Int?, _ depth: Int) -> Kraken2ClassificationRow {
            Kraken2ClassificationRow(
                sample: "HG002", taxonName: name, taxId: taxId, rank: rank, rankDisplayName: rank,
                readsDirect: rank == "S" ? reads : 0, readsClade: reads, percentage: Double(reads) / 2,
                parentTaxId: parent, depth: depth, fractionDirect: 0.0
            )
        }
        _ = try Kraken2Database.create(
            at: database,
            rows: [
                row("root", 1, "R", 200, nil, 0),
                row("Homo", 9605, "G", 120, 1, 1), row("Homo sapiens", 9606, "S", 120, 9605, 2),
                row("Mus", 10088, "G", 80, 1, 1), row("Mus musculus", 10090, "S", 80, 10088, 2),
            ],
            metadata: ["tool": "kraken2", "created_at": stamp, "total_reads_HG002": "200", "classified_reads_HG002": "200"]
        )
    }

    var lineAfterChangedBundle: String? { filtersNotKeptLine }
}

// MARK: - CZ ID

@MainActor
struct CzIdViewStateDriver: ViewStateDriver {
    let kind = "CZ ID"

    private func viewer(in harness: ViewSwitchWindowHarness) -> TaxonomyViewController? {
        (harness.split.viewerController.surfaceHost.activeViewport as? CzIdSurface)?.controller?.taxonomyViewController
    }

    func isShown(in harness: ViewSwitchWindowHarness) -> Bool { viewer(in: harness) != nil }

    func change(in harness: ViewSwitchWindowHarness) throws {
        TaxonomyViewStateControls.change(try XCTUnwrap(viewer(in: harness)), filter: "virus")
    }

    /// The row count is left out, since the filter hides rows that a changed bundle shows again.
    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        TaxonomyViewStateControls.read(try XCTUnwrap(viewer(in: harness)), includeRows: false)
    }

    /// Imports the report again with one more taxon row into a new folder at the same path, as a person who deletes an
    /// import and imports again does. The record keeps the folder's file number and creation date, and a new folder
    /// has others, so the whole record drops and the view opens at its start with the reset line (VS A3, word 3). An
    /// import has no rerun in place, so this is CZ ID's changed bundle.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        let bundle = try XCTUnwrap(fixture.item.url)
        let report = try String(contentsOf: SafetyNetPaths.fixture("czid/minimal_taxon_report.tsv"), encoding: .utf8)
        var lines = report.components(separatedBy: "\n").filter { !$0.isEmpty }
        var fields = try XCTUnwrap(lines.last).components(separatedBy: "\t")
        fields[5] = "9999999"
        fields[6] = "Changed test virus"
        lines.append(fields.joined(separator: "\t"))
        let edited = bundle.deletingLastPathComponent().appendingPathComponent("changed-taxon-report.tsv")
        try (lines.joined(separator: "\n") + "\n").write(to: edited, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: bundle)
        _ = try CzIdDataConverter.convertTaxonReport(at: edited, outputDirectory: bundle)
    }

    /// The starting view: no filter, the default sort by reads, no row, no zoom and the drawer closed.
    func readingAfterChangedBundle(changed: [String]) -> [String] {
        ["filter ", "sort reads descending", "selected ", "zoom none", "drawer closed"]
    }

    var lineAfterChangedBundle: String? { "The data changed since your last visit, so the view was reset." }
}

// MARK: - EsViritu

@MainActor
struct EsVirituViewStateDriver: ViewStateDriver {
    let kind = "EsViritu"

    private func viewer(in harness: ViewSwitchWindowHarness) -> EsVirituResultViewController? {
        (harness.split.viewerController.surfaceHost.activeViewport as? EsVirituSurface)?.controller
    }

    func isShown(in harness: ViewSwitchWindowHarness) -> Bool { viewer(in: harness) != nil }

    /// The filter field, the sort by name through the header menu's path, and the first row selected with its
    /// disclosure turned from how the viewer opened it.
    func change(in harness: ViewSwitchWindowHarness) throws {
        let table = try XCTUnwrap(viewer(in: harness)).detectionTableView
        table.testingSubmitSearchTextImmediately("adeno")
        table.columnHeaderFilterMenu(sortByKey: "name", ascending: true)
        let outline = table.outlineView
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let item = try XCTUnwrap(outline.item(atRow: 0))
        XCTAssertTrue(outline.isExpandable(item), "the adenovirus assembly holds two detections")
        if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
    }

    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        let table = try XCTUnwrap(viewer(in: harness)).detectionTableView
        let outline = table.outlineView
        let selected = outline.selectedRowIndexes.map { TaxonomyViewStateControls.nameText(of: $0, in: outline) }
        let expansion: [String] = (0..<outline.numberOfRows).compactMap { row in
            guard let item = outline.item(atRow: row), outline.isExpandable(item) else { return nil }
            return outline.isItemExpanded(item) ? "open" : "closed"
        }
        return [
            "filter \(table.testingSearchField.stringValue)",
            "sort \(table.exportSortKey) \(table.exportSortAscending ? "ascending" : "descending")",
            "selected \(selected.joined(separator: ", "))",
            "assemblies \(expansion.joined(separator: ", "))",
            "rows \(outline.numberOfRows)",
        ]
    }

    /// The routing fixture's assembly holds one detection, which the outline draws as a row with no disclosure. The
    /// database is built again with two detections of an adenovirus assembly and one of an HIV assembly, so the
    /// adenovirus row opens and closes and the filter hides the HIV row.
    func prepare(_ fixture: ViewSwitchFixture) throws {
        try Self.build(in: try XCTUnwrap(fixture.item.url), stamp: firstRunStamp)
    }

    /// A rerun in place with the same rows, which `build-db` stamps with a new `created_at`. A rerun must change the
    /// data key (VS B1), so the filter drops even though every count is the same.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        try Self.build(in: try XCTUnwrap(fixture.item.url), stamp: rerunStamp)
    }

    /// The filter drops and the HIV row shows again. The adenovirus assembly is the same assembly of the same sample,
    /// so its disclosure comes back as the person left it (VS B4): it is a presentation of rows the assembly row
    /// sums, not a filter (VS B6).
    func readingAfterChangedBundle(changed: [String]) -> [String] {
        var reading = changed
        reading[0] = "filter "
        let collapsed = changed[3] == "assemblies closed"
        reading[4] = collapsed ? "rows 2" : "rows 4"
        return reading
    }

    private static func build(in folder: URL, stamp: String) throws {
        let database = folder.appendingPathComponent("esviritu.sqlite")
        try? FileManager.default.removeItem(at: database)
        func row(_ virus: String, _ accession: String, _ assembly: String) -> EsVirituDetectionRow {
            EsVirituDetectionRow(
                sample: "HG002", virusName: virus, description: nil,
                contigLength: 1_000, segment: nil, accession: accession,
                assembly: assembly, assemblyLength: 35_937, kingdom: nil, phylum: nil,
                tclass: nil, torder: nil, family: nil, genus: nil, species: nil,
                subspecies: nil, rpkmf: 1, readCount: 4, uniqueReads: 3,
                coveredBases: 1_000, meanCoverage: 1, avgReadIdentity: 0.99,
                pi: nil, filteredReadsInSample: 12, bamPath: nil, bamIndexPath: nil
            )
        }
        try EsVirituDatabase.create(
            at: database,
            rows: [
                row("Human mastadenovirus C", "NC_001405.1", "GCF_000845085.1"),
                row("Human mastadenovirus C", "NC_001406.1", "GCF_000845085.1"),
                row("Human immunodeficiency virus 1", "NC_001802.1", "GCF_000864765.1"),
            ],
            metadata: ["tool": "esviritu", "created_at": stamp]
        )
    }

    var lineAfterChangedBundle: String? { filtersNotKeptLine }
}
