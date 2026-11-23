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

    /// A rerun with other counts. The data key is made from the loaded counts, so a touched file would not change it.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        let folder = try XCTUnwrap(fixture.item.url)
        let database = folder.appendingPathComponent("kraken2.sqlite")
        try FileManager.default.removeItem(at: database)
        _ = try Kraken2Database.create(
            at: database,
            rows: [
                Kraken2ClassificationRow(
                    sample: "HG002", taxonName: "Homo sapiens", taxId: 9606, rank: "S",
                    rankDisplayName: "Species", readsDirect: 60, readsClade: 120, percentage: 1.0,
                    parentTaxId: nil, depth: 0, fractionDirect: 0.0
                ),
            ],
            metadata: ["tool": "kraken2"]
        )
    }

    func readingAfterChangedBundle(changed: [String]) -> [String] {
        TaxonomyViewStateControls.readingAfterChangedBundle(changed: changed)
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

    /// Converts the report again with one more taxon row, so the manifest's row count and the tree's counts change.
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

    func readingAfterChangedBundle(changed: [String]) -> [String] {
        TaxonomyViewStateControls.readingAfterChangedBundle(changed: changed)
    }

    var lineAfterChangedBundle: String? { filtersNotKeptLine }
}

// MARK: - EsViritu

@MainActor
struct EsVirituViewStateDriver: ViewStateDriver {
    let kind = "EsViritu"

    private func viewer(in harness: ViewSwitchWindowHarness) -> EsVirituResultViewController? {
        (harness.split.viewerController.surfaceHost.activeViewport as? EsVirituSurface)?.controller
    }

    func isShown(in harness: ViewSwitchWindowHarness) -> Bool { viewer(in: harness) != nil }

    /// The filter field, the sort by name through the header menu's path, the first row selected and collapsed.
    func change(in harness: ViewSwitchWindowHarness) throws {
        let table = try XCTUnwrap(viewer(in: harness)).detectionTableView
        table.testingSubmitSearchTextImmediately("adeno")
        table.columnHeaderFilterMenu(sortByKey: "name", ascending: true)
        let outline = table.outlineView
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        if let item = outline.item(atRow: 0), outline.isExpandable(item) { outline.collapseItem(item) }
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

    /// A rerun with a second detection in the assembly, so the sample's virus count and the key change. The assembly
    /// stays collapsed, so the rows shown are the same.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        let folder = try XCTUnwrap(fixture.item.url)
        let database = folder.appendingPathComponent("esviritu.sqlite")
        try FileManager.default.removeItem(at: database)
        func row(_ accession: String) -> EsVirituDetectionRow {
            EsVirituDetectionRow(
                sample: "HG002", virusName: "Human mastadenovirus C", description: nil,
                contigLength: 1_000, segment: nil, accession: accession,
                assembly: "GCF_000845085.1", assemblyLength: 35_937, kingdom: nil, phylum: nil,
                tclass: nil, torder: nil, family: nil, genus: nil, species: nil,
                subspecies: nil, rpkmf: 1, readCount: 4, uniqueReads: 3,
                coveredBases: 1_000, meanCoverage: 1, avgReadIdentity: 0.99,
                pi: nil, filteredReadsInSample: 4, bamPath: nil, bamIndexPath: nil
            )
        }
        try EsVirituDatabase.create(
            at: database, rows: [row("NC_001405.1"), row("NC_001406.1")], metadata: ["tool": "esviritu"]
        )
    }

    func readingAfterChangedBundle(changed: [String]) -> [String] {
        var reading = changed
        reading[0] = "filter "
        return reading
    }

    var lineAfterChangedBundle: String? { filtersNotKeptLine }
}
