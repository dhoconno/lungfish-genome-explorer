// TaxonomySearchFilterTests.swift - Free-text search field and Bracken column tests
// for the Kraken2 taxonomy results viewport.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Testing
import AppKit
@testable import LungfishApp
@testable import LungfishIO
import LungfishKit

// MARK: - Shared Fixture

/// Builds a small taxonomy tree:
///
/// ```
/// Root
///  +-- Viruses
///  |     +-- Coronaviridae
///  |           +-- Severe acute respiratory syndrome-related coronavirus
///  +-- Bacteria
///        +-- Escherichia coli
/// ```
@MainActor
private func makeSearchFixtureTree() -> (
    tree: TaxonTree,
    root: TaxonNode,
    viruses: TaxonNode,
    family: TaxonNode,
    sars: TaxonNode,
    bacteria: TaxonNode,
    ecoli: TaxonNode
) {
    let root = TaxonNode(
        taxId: 1, name: "Root", rank: .root, depth: 0,
        readsDirect: 0, readsClade: 1_000, fractionClade: 1.0, fractionDirect: 0.0, parentTaxId: nil
    )
    let viruses = TaxonNode(
        taxId: 10239, name: "Viruses", rank: .domain, depth: 1,
        readsDirect: 0, readsClade: 300, fractionClade: 0.3, fractionDirect: 0.0, parentTaxId: 1
    )
    let family = TaxonNode(
        taxId: 11118, name: "Coronaviridae", rank: .family, depth: 2,
        readsDirect: 10, readsClade: 300, fractionClade: 0.3, fractionDirect: 0.01, parentTaxId: 10239
    )
    let sars = TaxonNode(
        taxId: 694009,
        name: "Severe acute respiratory syndrome-related coronavirus",
        rank: .species, depth: 3,
        readsDirect: 290, readsClade: 290, fractionClade: 0.29, fractionDirect: 0.29, parentTaxId: 11118
    )
    let bacteria = TaxonNode(
        taxId: 2, name: "Bacteria", rank: .domain, depth: 1,
        readsDirect: 0, readsClade: 700, fractionClade: 0.7, fractionDirect: 0.0, parentTaxId: 1
    )
    let ecoli = TaxonNode(
        taxId: 562, name: "Escherichia coli", rank: .species, depth: 2,
        readsDirect: 700, readsClade: 700, fractionClade: 0.7, fractionDirect: 0.7, parentTaxId: 2
    )

    root.addChild(viruses)
    root.addChild(bacteria)
    viruses.addChild(family)
    family.addChild(sars)
    bacteria.addChild(ecoli)

    let tree = TaxonTree(root: root, unclassifiedNode: nil, totalReads: 1_000)
    return (tree, root, viruses, family, sars, bacteria, ecoli)
}

// MARK: - Search Field

@Suite("Kraken Taxonomy — Free-text search field")
@MainActor
struct TaxonomySearchFieldTests {

    @Test("Taxonomy table hosts a search field with the taxa placeholder")
    func taxonomyTableHasSearchField() {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let field = table.subviews.compactMap { $0 as? NSSearchField }.first
        #expect(field != nil)
        #expect(field?.placeholderString == "Filter taxa\u{2026}")
        #expect(field?.sendsSearchStringImmediately == true)
    }

    @Test("Search match keeps the matching node, its ancestors, and its descendants")
    func searchKeepsAncestorsAndDescendants() {
        let f = makeSearchFixtureTree()
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.tree = f.tree

        table.testingSetFilterText("coronaviridae")

        // Ancestors retained.
        #expect(table.sortedChildren(of: f.root).map(\.name) == ["Viruses"])
        #expect(table.sortedChildren(of: f.viruses).map(\.name) == ["Coronaviridae"])
        // Descendants of the match retained (whole clade).
        #expect(table.sortedChildren(of: f.family).map(\.name)
            == ["Severe acute respiratory syndrome-related coronavirus"])
    }

    @Test("Non-matching siblings are hidden")
    func nonMatchingSiblingsHidden() {
        let f = makeSearchFixtureTree()
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.tree = f.tree

        table.testingSetFilterText("escherichia")

        #expect(table.sortedChildren(of: f.root).map(\.name) == ["Bacteria"])
        #expect(table.sortedChildren(of: f.bacteria).map(\.name) == ["Escherichia coli"])
    }

    @Test("Search matches rank display name and numeric columns")
    func searchMatchesRankAndNumbers() {
        let f = makeSearchFixtureTree()
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.tree = f.tree

        table.testingSetFilterText("family")
        #expect(table.sortedChildren(of: f.viruses).map(\.name) == ["Coronaviridae"])

        table.testingSetFilterText("700")
        #expect(table.sortedChildren(of: f.root).map(\.name) == ["Bacteria"])
    }

    @Test("Clearing the query restores every node")
    func clearingQueryRestoresAll() {
        let f = makeSearchFixtureTree()
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.tree = f.tree

        table.testingSetFilterText("escherichia")
        #expect(table.sortedChildren(of: f.root).map(\.name) == ["Bacteria"])

        table.testingSetFilterText("")
        #expect(Set(table.sortedChildren(of: f.root).map(\.name)) == Set(["Viruses", "Bacteria"]))
        #expect(table.sortedChildren(of: f.viruses).map(\.name) == ["Coronaviridae"])
    }

    @Test("Search composes with an active column filter")
    func searchComposesWithColumnFilter() {
        let f = makeSearchFixtureTree()
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.tree = f.tree

        // Column filter alone keeps only the bacterial clade (Bacteria and
        // E. coli both have >= 500 clade reads).
        table.testingApplyColumnFilter(.init(columnId: "reads", op: .greaterOrEqual, value: "500"))
        #expect(table.sortedChildren(of: f.root).map(\.name) == ["Bacteria"])

        // Adding a search that only matches the virus clade leaves nothing:
        // both predicates must hold for a node to be a direct match.
        table.testingSetFilterText("coronavirus")
        #expect(table.sortedChildren(of: f.root).isEmpty)

        // A search consistent with the column filter keeps the bacterial clade.
        table.testingSetFilterText("escherichia")
        #expect(table.sortedChildren(of: f.root).map(\.name) == ["Bacteria"])
    }

    @Test("Search fires the sunburst dimming hook and clears it on reset")
    func searchFiresFilterChangedHook() throws {
        let f = makeSearchFixtureTree()
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.tree = f.tree

        var observed: [Set<Int>?] = []
        table.onFilterChanged = { observed.append($0) }

        table.testingSetFilterText("escherichia")
        #expect(observed.count == 1)
        let dimmed = try #require(observed.last ?? nil)
        #expect(dimmed.contains(562))
        #expect(dimmed.contains(2))
        #expect(dimmed.contains(694009) == false)

        table.testingSetFilterText("")
        #expect(observed.count == 2)
        #expect((observed.last ?? Set<Int>()) == nil)
    }
}

// MARK: - Bracken Column

@Suite("Kraken Taxonomy — Bracken abundance column")
@MainActor
struct TaxonomyBrackenColumnTests {

    private func brackenColumn(_ table: TaxonomyTableView) -> NSTableColumn? {
        table.outlineView.tableColumns.first { $0.identifier.rawValue == "bracken" }
    }

    @Test("Kraken2-only tree does not expose a Bracken column")
    func krakenOnlyTreeHidesBrackenColumn() {
        let f = makeSearchFixtureTree()
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.tree = f.tree

        #expect(brackenColumn(table)?.isHidden != false)
    }

    @Test("Tree with Bracken estimates exposes a Bracken column with formatted cells")
    func brackenTreeShowsColumn() throws {
        let f = makeSearchFixtureTree()
        var tree = f.tree
        BrackenParser.mergeBracken(
            rows: [
                BrackenRow(
                    name: "Escherichia coli", taxId: 562, taxonomyLevel: "S",
                    krakenAssignedReads: 700, addedReads: 1_500,
                    newEstReads: 2_200, fractionTotalReads: 0.55
                ),
            ],
            into: &tree
        )

        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.tree = tree

        let column = try #require(brackenColumn(table))
        #expect(column.isHidden == false)
        #expect(column.title == "Bracken")

        let ecoliCell = table.outlineView(table.outlineView, viewFor: column, item: f.ecoli) as? NSTableCellView
        #expect(ecoliCell?.textField?.stringValue == "2,200")

        // Nodes without a Bracken estimate render blank.
        let virusCell = table.outlineView(table.outlineView, viewFor: column, item: f.viruses) as? NSTableCellView
        #expect(virusCell?.textField?.stringValue == "")
    }

    @Test("Bracken column filters and sorts on the re-estimated counts")
    func brackenColumnFiltersAndSorts() throws {
        let f = makeSearchFixtureTree()
        var tree = f.tree
        BrackenParser.mergeBracken(
            rows: [
                BrackenRow(
                    name: "Escherichia coli", taxId: 562, taxonomyLevel: "S",
                    krakenAssignedReads: 700, addedReads: 1_500,
                    newEstReads: 2_200, fractionTotalReads: 0.55
                ),
                BrackenRow(
                    name: "Severe acute respiratory syndrome-related coronavirus",
                    taxId: 694009, taxonomyLevel: "S",
                    krakenAssignedReads: 290, addedReads: 10,
                    newEstReads: 300, fractionTotalReads: 0.075
                ),
            ],
            into: &tree
        )

        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.tree = tree

        // Only the species carry Bracken estimates, so a >= 1000 filter keeps
        // E. coli plus its ancestors and hides the virus clade entirely.
        table.testingApplyColumnFilter(.init(columnId: "bracken", op: .greaterOrEqual, value: "1000"))
        #expect(table.sortedChildren(of: f.root).map(\.name) == ["Bacteria"])
        #expect(table.sortedChildren(of: f.bacteria).map(\.name) == ["Escherichia coli"])

        table.testingClearColumnFilters()

        // Sorting by Bracken orders nodes with estimates and pushes the
        // estimate-less nodes to the end in both directions.
        table.testingSortByColumn("bracken", ascending: false)
        #expect(table.sortedChildren(of: f.family).map(\.name)
            == ["Severe acute respiratory syndrome-related coronavirus"])

        let sarsSibling = TaxonNode(
            taxId: 333387, name: "Bat coronavirus", rank: .species, depth: 3,
            readsDirect: 0, readsClade: 0, fractionClade: 0.0, fractionDirect: 0.0, parentTaxId: 11118
        )
        sarsSibling.brackenReads = 50
        f.family.addChild(sarsSibling)
        table.tree = tree

        table.testingSortByColumn("bracken", ascending: false)
        #expect(table.sortedChildren(of: f.family).map(\.name)
            == ["Severe acute respiratory syndrome-related coronavirus", "Bat coronavirus"])
        table.testingSortByColumn("bracken", ascending: true)
        #expect(table.sortedChildren(of: f.family).map(\.name)
            == ["Bat coronavirus", "Severe acute respiratory syndrome-related coronavirus"])
    }

    @Test("Bracken is registered as a standard column name for metadata joins")
    func brackenIsStandardColumnName() {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        #expect(table.metadataColumns.standardColumnNames.contains("Bracken"))
    }
}
