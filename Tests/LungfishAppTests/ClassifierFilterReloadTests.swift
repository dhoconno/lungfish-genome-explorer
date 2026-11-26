// ClassifierFilterReloadTests.swift - A Kraken2 or EsViritu table keeps its filter's effect with its text (VS-FILTER-RELOAD)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishEsVirituUI
@testable import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishTaxonomyUI

/// A person types a filter, shows another result and comes back. The restore applies the filter, and then the
/// Inspector's Samples group takes the new result's picker and posts `metagenomicsSampleSelectionChanged`. The viewer
/// used to draw the samples it already showed, which loaded the table's data again and dropped the filter's effect
/// while the field kept its text (walk row A11). The tests read the count label against the tables' own count words.
@MainActor
final class ClassifierFilterReloadTests: XCTestCase {
    private var window: ScopeOwningWindowController!

    override func setUp() async throws {
        try await super.setUp()
        window = ScopeOwningWindowController()
    }

    override func tearDown() async throws {
        window.close()
        window = nil
        try await super.tearDown()
    }

    /// The post the Samples group makes as it takes the picker of the result that was just shown.
    private func postTheSamplesGroupsSelectionChange() {
        NotificationCenter.default.post(
            name: .metagenomicsSampleSelectionChanged,
            object: nil,
            userInfo: ScopedEventFilter.scopedUserInfo(scope: window.windowStateScope)
        )
    }

    private func makeResultDirectory() throws -> URL {
        let root = try TestTempDirectory.make(prefix: "ClassifierFilterReload")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        return root
    }

    // MARK: - The table keeps the field and its effect together

    func testATaxonomyTableKeepsItsFilterWhenNewDataLoads() {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        table.metadataColumns.userDefaults = makeTestDefaultsSuite(prefix: "ClassifierFilterReload").defaults
        let names = ["Ribosomal virus", "Alpha virus", "Ribo phage", "Beta virus"]
        table.tree = Self.tree(named: names)
        table.testingSetFilterText("Ribo")
        let narrowed = table.testingCountLabelText
        XCTAssertNotEqual(narrowed, TaxonomyTableView.countLabelText(filtered: nil, total: names.count + 1), "the filter narrowed nothing")

        table.tree = Self.tree(named: names)

        XCTAssertEqual(table.searchField.stringValue, "Ribo")
        XCTAssertEqual(table.testingCountLabelText, narrowed, "the field still holds the filter and the table shows every row")
    }

    // MARK: - A post that names the samples already shown draws nothing

    func testAKrakenViewportKeepsItsFilterWhenThePostNamesTheSamplesAlreadyShown() throws {
        let root = try makeResultDirectory()
        let database = try Kraken2Database.create(
            at: root.appendingPathComponent("kraken2.sqlite"),
            rows: ["sample-a", "sample-b"].flatMap { sample in
                [Self.krakenRow(sample, "root", taxId: 1, parent: nil), Self.krakenRow(sample, "Ribo virus", taxId: 100, parent: 1),
                 Self.krakenRow(sample, "Other virus", taxId: 200, parent: 1)]
            },
            metadata: [:]
        )
        let viewport = TaxonomyViewController()
        isolateLayouts(viewport)
        window.host(viewport.view)
        viewport.configureFromDatabase(database)
        let table = viewport.testTableView
        // The restore's own two assignments: the field's text, then the filter.
        table.testingSetFilterText("Ribo")
        let shown = try XCTUnwrap(table.tree)
        let narrowed = table.testingCountLabelText
        XCTAssertNotEqual(narrowed, TaxonomyTableView.countLabelText(filtered: nil, total: shown.allNodes().count), "the filter narrowed nothing")

        postTheSamplesGroupsSelectionChange()

        XCTAssertEqual(table.testingCountLabelText, narrowed, "the field holds the filter and the table shows every row")
        XCTAssertTrue(table.tree?.root === shown.root, "the samples already shown were drawn again")
    }

    func testAnEsVirituViewportKeepsItsFilterWhenThePostNamesTheSamplesAlreadyShown() throws {
        let root = try makeResultDirectory()
        let database = try EsVirituDatabase.create(
            at: root.appendingPathComponent("esviritu.sqlite"),
            rows: [
                Self.esVirituRow(sample: "sample-a", virusName: "Ribo virus", accession: "NC_000001.1", assembly: "ASM_1"),
                Self.esVirituRow(sample: "sample-b", virusName: "Other virus", accession: "NC_000002.1", assembly: "ASM_2"),
            ],
            metadata: [:]
        )
        let viewport = EsVirituResultViewController()
        isolateLayouts(viewport)
        window.host(viewport.view)
        viewport.configureFromDatabase(database, resultURL: root)
        let table = viewport.testDetectionTableView
        table.testingSubmitSearchTextImmediately("Ribo")
        let narrowed = ViralDetectionTableView.countLabelText(filtered: 1, total: 2)
        XCTAssertEqual(table.testingCountLabelText, narrowed)
        let loadsBefore = table.testingItemRebuildCount

        postTheSamplesGroupsSelectionChange()

        XCTAssertEqual(table.testingCountLabelText, narrowed, "the field holds the filter and the table shows every row")
        XCTAssertEqual(table.testingItemRebuildCount, loadsBefore, "the samples already shown were drawn again")
    }

    // MARK: - Fixtures

    private static func tree(named names: [String]) -> TaxonTree {
        let root = TaxonNode(
            taxId: 1, name: "root", rank: .root, depth: 0, readsDirect: 0, readsClade: names.count,
            fractionClade: 1, fractionDirect: 0, parentTaxId: nil
        )
        for (index, name) in names.enumerated() {
            root.addChild(TaxonNode(
                taxId: 10_000 + index, name: name, rank: .species, depth: 1, readsDirect: 1, readsClade: 1,
                fractionClade: 1, fractionDirect: 1, parentTaxId: root.taxId
            ))
        }
        return TaxonTree(root: root, unclassifiedNode: nil, totalReads: names.count)
    }

    private static func krakenRow(_ sample: String, _ name: String, taxId: Int, parent: Int?) -> Kraken2ClassificationRow {
        Kraken2ClassificationRow(
            sample: sample, taxonName: name, taxId: taxId, rank: parent == nil ? "R" : "S",
            rankDisplayName: parent == nil ? "Root" : "Species", readsDirect: parent == nil ? 0 : 5, readsClade: 10,
            percentage: 50, parentTaxId: parent, depth: parent == nil ? 0 : 1, fractionDirect: 0.5
        )
    }

    private static func esVirituRow(
        sample: String,
        virusName: String,
        accession: String,
        assembly: String
    ) -> EsVirituDetectionRow {
        EsVirituDetectionRow(
            sample: sample, virusName: virusName, description: nil,
            contigLength: 1_000, segment: nil, accession: accession,
            assembly: assembly, assemblyLength: 1_000, kingdom: nil, phylum: nil,
            tclass: nil, torder: nil, family: nil, genus: nil, species: nil,
            subspecies: nil, rpkmf: 1, readCount: 4, uniqueReads: 3,
            coveredBases: 1_000, meanCoverage: 1, avgReadIdentity: 0.99,
            pi: nil, filteredReadsInSample: 4, bamPath: nil, bamIndexPath: nil
        )
    }
}
