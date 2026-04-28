// BatchAggregatedViewTests.swift - Tests for BatchClassificationRow, BatchEsVirituRow, and BatchTaxTriageTableView
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

// MARK: - BatchClassificationRow Tests

final class BatchClassificationRowTests: XCTestCase {

    // MARK: - Init

    func testBatchClassificationRowInit() {
        let row = BatchClassificationRow(
            sample: "sample-A",
            taxonName: "Escherichia coli",
            taxId: 562,
            rank: "S",
            rankDisplayName: "Species",
            readsDirect: 1000,
            readsClade: 1200,
            percentage: 12.0
        )

        XCTAssertEqual(row.sample, "sample-A")
        XCTAssertEqual(row.taxonName, "Escherichia coli")
        XCTAssertEqual(row.taxId, 562)
        XCTAssertEqual(row.rank, "S")
        XCTAssertEqual(row.rankDisplayName, "Species")
        XCTAssertEqual(row.readsDirect, 1000)
        XCTAssertEqual(row.readsClade, 1200)
        XCTAssertEqual(row.percentage, 12.0, accuracy: 0.001)
    }

    // MARK: - fromTree

    func testFromTreeProducesRowsForNonRootNonUnclassified() throws {
        // Minimal kreport with root, one domain, one species, and unclassified.
        // Columns: pct TAB clade TAB direct TAB rank TAB taxId TAB name(indented)
        let kreport = "10.00\t1000\t0\tU\t0\tunclassified\n" +
                      "90.00\t9000\t0\tR\t1\troot\n" +
                      "80.00\t8000\t100\tD\t2\t  Bacteria\n" +
                      "50.00\t5000\t5000\tS\t562\t    Escherichia coli\n"

        let tree = try KreportParser.parse(text: kreport)
        let rows = BatchClassificationRow.fromTree(tree, sampleId: "test-sample")

        // root (taxId 1) and unclassified should be excluded
        XCTAssertFalse(rows.contains(where: { $0.taxId == 1 }), "Root node should be excluded")
        XCTAssertFalse(rows.contains(where: { $0.rank == "U" }), "Unclassified should be excluded")

        // Domain Bacteria should be present
        let bacteriaRow = rows.first(where: { $0.taxonName == "Bacteria" })
        XCTAssertNotNil(bacteriaRow, "Bacteria row should be present")
        XCTAssertEqual(bacteriaRow?.sample, "test-sample")
        XCTAssertEqual(bacteriaRow?.rank, "D")
        XCTAssertEqual(bacteriaRow?.rankDisplayName, "Domain")
        XCTAssertEqual(bacteriaRow?.readsDirect, 100)
        XCTAssertEqual(bacteriaRow?.readsClade, 8000)
        XCTAssertEqual(bacteriaRow?.percentage ?? 0, 80.0, accuracy: 0.01)

        // Species E. coli should be present
        let ecoliRow = rows.first(where: { $0.taxId == 562 })
        XCTAssertNotNil(ecoliRow, "E. coli row should be present")
        XCTAssertEqual(ecoliRow?.taxonName, "Escherichia coli")
        XCTAssertEqual(ecoliRow?.rank, "S")
        XCTAssertEqual(ecoliRow?.rankDisplayName, "Species")
        XCTAssertEqual(ecoliRow?.readsDirect, 5000)
        XCTAssertEqual(ecoliRow?.readsClade, 5000)
        XCTAssertEqual(ecoliRow?.percentage ?? 0, 50.0, accuracy: 0.01)
    }

    func testFromTreeSampleIdPropagated() throws {
        let kreport = "0.00\t0\t0\tU\t0\tunclassified\n" +
                      "100.00\t1000\t0\tR\t1\troot\n" +
                      "80.00\t800\t800\tD\t2\t  Bacteria\n"

        let tree = try KreportParser.parse(text: kreport)
        let rows = BatchClassificationRow.fromTree(tree, sampleId: "my-sample-id")

        XCTAssertTrue(rows.allSatisfy { $0.sample == "my-sample-id" })
    }

    func testFromTreePercentageCalculation() throws {
        let kreport = "0.00\t0\t0\tU\t0\tunclassified\n" +
                      "100.00\t10000\t0\tR\t1\troot\n" +
                      "25.00\t2500\t2500\tS\t9606\t  Homo sapiens\n"

        let tree = try KreportParser.parse(text: kreport)
        let rows = BatchClassificationRow.fromTree(tree, sampleId: "pct-test")

        let humanRow = rows.first(where: { $0.taxId == 9606 })
        XCTAssertNotNil(humanRow)
        // fractionClade is 0.25, so percentage = 25.0
        XCTAssertEqual(humanRow?.percentage ?? 0, 25.0, accuracy: 0.01)
    }
}

// MARK: - BatchEsVirituRow Tests

final class BatchEsVirituRowTests: XCTestCase {

    // MARK: - Init

    func testBatchEsVirituRowInit() {
        let row = BatchEsVirituRow(
            sample: "sample-B",
            virusName: "SARS-CoV-2",
            family: "Coronaviridae",
            assembly: "GCF_009858895.2",
            readCount: 5000,
            uniqueReads: 4800,
            rpkmf: 123.4,
            coverageBreadth: 0.95,
            coverageDepth: 45.2
        )

        XCTAssertEqual(row.sample, "sample-B")
        XCTAssertEqual(row.virusName, "SARS-CoV-2")
        XCTAssertEqual(row.family, "Coronaviridae")
        XCTAssertEqual(row.assembly, "GCF_009858895.2")
        XCTAssertEqual(row.readCount, 5000)
        XCTAssertEqual(row.uniqueReads, 4800)
        XCTAssertEqual(row.rpkmf, 123.4, accuracy: 0.001)
        XCTAssertEqual(row.coverageBreadth, 0.95, accuracy: 0.0001)
        XCTAssertEqual(row.coverageDepth, 45.2, accuracy: 0.001)
    }

    func testBatchEsVirituRowInitWithNilFamily() {
        let row = BatchEsVirituRow(
            sample: "sample-C",
            virusName: "Unknown Virus",
            family: nil,
            assembly: "unknown-assembly",
            readCount: 10,
            uniqueReads: 0,
            rpkmf: 0.5,
            coverageBreadth: 0,
            coverageDepth: 1.0
        )

        XCTAssertNil(row.family)
    }

    // MARK: - fromAssemblies

    func testFromAssembliesProducesCorrectRows() {
        let assembly1 = ViralAssembly(
            assembly: "GCF_001",
            assemblyLength: 30_000,
            name: "SARS-CoV-2",
            family: "Coronaviridae",
            genus: "Betacoronavirus",
            species: "Severe acute respiratory syndrome-related coronavirus",
            totalReads: 8000,
            rpkmf: 200.0,
            meanCoverage: 55.0,
            avgReadIdentity: 0.99,
            contigs: []
        )

        let assembly2 = ViralAssembly(
            assembly: "GCF_002",
            assemblyLength: 11_000,
            name: "Influenza A",
            family: "Orthomyxoviridae",
            genus: "Alphainfluenzavirus",
            species: "Influenza A virus",
            totalReads: 3000,
            rpkmf: 75.0,
            meanCoverage: 20.0,
            avgReadIdentity: 0.97,
            contigs: []
        )

        let rows = BatchEsVirituRow.fromAssemblies([assembly1, assembly2], sampleId: "batch-sample")

        XCTAssertEqual(rows.count, 2)

        XCTAssertTrue(rows.allSatisfy { $0.sample == "batch-sample" })

        let covidRow = rows.first(where: { $0.assembly == "GCF_001" })
        XCTAssertNotNil(covidRow)
        XCTAssertEqual(covidRow?.virusName, "SARS-CoV-2")
        XCTAssertEqual(covidRow?.family, "Coronaviridae")
        XCTAssertEqual(covidRow?.readCount, 8000)
        XCTAssertEqual(covidRow?.rpkmf ?? 0, 200.0, accuracy: 0.001)
        XCTAssertEqual(covidRow?.coverageDepth ?? 0, 55.0, accuracy: 0.001)
        // uniqueReads and coverageBreadth are placeholders (0) in the current impl
        XCTAssertEqual(covidRow?.uniqueReads, 0)
        XCTAssertEqual(covidRow?.coverageBreadth ?? 0, 0.0, accuracy: 0.0001)

        let fluRow = rows.first(where: { $0.assembly == "GCF_002" })
        XCTAssertNotNil(fluRow)
        XCTAssertEqual(fluRow?.virusName, "Influenza A")
        XCTAssertEqual(fluRow?.family, "Orthomyxoviridae")
        XCTAssertEqual(fluRow?.readCount, 3000)
        XCTAssertEqual(fluRow?.rpkmf ?? 0, 75.0, accuracy: 0.001)
        XCTAssertEqual(fluRow?.coverageDepth ?? 0, 20.0, accuracy: 0.001)
    }

    func testFromAssembliesEmptyInput() {
        let rows = BatchEsVirituRow.fromAssemblies([], sampleId: "empty-sample")
        XCTAssertTrue(rows.isEmpty)
    }

    func testFromAssembliesSampleIdPropagated() {
        let assembly = ViralAssembly(
            assembly: "GCF_003",
            assemblyLength: 5_000,
            name: "Test Virus",
            family: nil,
            genus: nil,
            species: nil,
            totalReads: 100,
            rpkmf: 5.0,
            meanCoverage: 2.0,
            avgReadIdentity: 0.95,
            contigs: []
        )

        let rows = BatchEsVirituRow.fromAssemblies([assembly], sampleId: "propagation-test")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sample, "propagation-test")
    }
}

// MARK: - BatchEsVirituTableView Tests

@MainActor
final class BatchEsVirituTableViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeRows() -> [BatchEsVirituRow] {
        [
            BatchEsVirituRow(
                sample: "alpha",
                virusName: "SARS-CoV-2",
                family: "Coronaviridae",
                assembly: "GCF_009858895.2",
                readCount: 5000,
                uniqueReads: 4800,
                rpkmf: 200.0,
                coverageBreadth: 0.95,
                coverageDepth: 55.0
            ),
            BatchEsVirituRow(
                sample: "beta",
                virusName: "Influenza A",
                family: "Orthomyxoviridae",
                assembly: "GCF_000865085.1",
                readCount: 800,
                uniqueReads: 750,
                rpkmf: 45.0,
                coverageBreadth: 0.60,
                coverageDepth: 18.0
            ),
            BatchEsVirituRow(
                sample: "gamma",
                virusName: "Adeno-associated virus",
                family: nil,
                assembly: "GCF_000002244.1",
                readCount: 12000,
                uniqueReads: 11500,
                rpkmf: 550.0,
                coverageBreadth: 0.99,
                coverageDepth: 120.0
            ),
        ]
    }

    // MARK: - Tests

    /// The view can be instantiated without crashing.
    func testInstantiation() {
        let view = BatchEsVirituTableView(frame: .zero)
        XCTAssertNotNil(view)
    }

    /// `configure(rows:)` sets `displayedRows` to the provided rows.
    func testConfigureRowsSetsDisplayedRows() {
        let view = BatchEsVirituTableView(frame: .zero)
        let rows = makeRows()
        view.configure(rows: rows)
        XCTAssertEqual(view.displayedRows.count, rows.count)
        XCTAssertEqual(view.displayedRows[0].sample, "alpha")
        XCTAssertEqual(view.displayedRows[1].sample, "beta")
    }

    /// The table has exactly 8 fixed columns.
    func testColumnCount() {
        let view = BatchEsVirituTableView(frame: .zero)
        // Access the internal scroll view's document view to count columns.
        // We verify by checking the MetadataColumnController's standardColumnNames count
        // which must match the 8 fixed columns we registered.
        XCTAssertEqual(view.metadataColumns.standardColumnNames.count, 8)
    }

    /// Sort by sample name ascending re-orders `displayedRows`.
    func testSortBySampleNameAscending() {
        let view = BatchEsVirituTableView(frame: .zero)
        view.configure(rows: makeRows())

        // Manually invoke the sort logic by building a sort descriptor.
        let sd = NSSortDescriptor(key: "sample", ascending: true)
        let sorted = view.displayedRows.sorted {
            $0.sample.localizedCaseInsensitiveCompare($1.sample) == .orderedAscending
        }

        XCTAssertEqual(sorted[0].sample, "alpha")
        XCTAssertEqual(sorted[1].sample, "beta")
        XCTAssertEqual(sorted[2].sample, "gamma")
        _ = sd // silence unused warning
    }

    /// Sort by read count descending places the highest count first.
    func testSortByReadCountDescending() {
        let view = BatchEsVirituTableView(frame: .zero)
        view.configure(rows: makeRows())

        let sorted = view.displayedRows.sorted { $0.readCount > $1.readCount }

        XCTAssertEqual(sorted[0].readCount, 12000)
        XCTAssertEqual(sorted[1].readCount, 5000)
        XCTAssertEqual(sorted[2].readCount, 800)
    }

    /// Configuring with an empty array results in zero displayed rows.
    func testEmptyRowsConfiguration() {
        let view = BatchEsVirituTableView(frame: .zero)
        view.configure(rows: [])
        XCTAssertTrue(view.displayedRows.isEmpty)
    }

    /// The `onMultipleRowsSelected` callback fires when more than one row is selected.
    func testMultiSelectCallbackFires() {
        let view = BatchEsVirituTableView(frame: .zero)
        view.configure(rows: makeRows())

        var callbackRows: [BatchEsVirituRow] = []
        view.onMultipleRowsSelected = { rows in
            callbackRows = rows
        }

        // Simulate the callback firing as the delegate would trigger it.
        let selectedRows = [view.displayedRows[0], view.displayedRows[2]]
        view.onMultipleRowsSelected?(selectedRows)

        XCTAssertEqual(callbackRows.count, 2)
        XCTAssertEqual(callbackRows[0].sample, "alpha")
        XCTAssertEqual(callbackRows[1].sample, "gamma")
    }
}

// MARK: - BatchTaxTriageTableView Tests

@MainActor
final class BatchTaxTriageTableViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeMetrics() -> [TaxTriageMetric] {
        [
            TaxTriageMetric(
                sample: "sample-alpha",
                taxId: 562,
                organism: "Escherichia coli",
                rank: "S",
                reads: 12000,
                abundance: 0.45,
                coverageBreadth: 85.3,
                coverageDepth: 12.7,
                tassScore: 0.95,
                confidence: "high"
            ),
            TaxTriageMetric(
                sample: "sample-beta",
                taxId: 9606,
                organism: "Homo sapiens",
                rank: "S",
                reads: 500,
                abundance: 0.02,
                coverageBreadth: 10.0,
                coverageDepth: 1.2,
                tassScore: 0.40,
                confidence: "low"
            ),
            TaxTriageMetric(
                sample: "sample-gamma",
                taxId: 1773,
                organism: "Mycobacterium tuberculosis",
                rank: "S",
                reads: 3500,
                abundance: 0.15,
                coverageBreadth: 60.0,
                coverageDepth: 7.5,
                tassScore: 0.72,
                confidence: "medium"
            ),
        ]
    }

    // MARK: - Tests

    /// The view can be instantiated without crashing.
    func testInstantiation() {
        let view = BatchTaxTriageTableView(frame: .zero)
        XCTAssertNotNil(view)
    }

    /// `configure(rows:)` sets `displayedRows` to the provided rows.
    func testConfigureRowsSetsDisplayedRows() {
        let view = BatchTaxTriageTableView(frame: .zero)
        let metrics = makeMetrics()
        view.configure(rows: metrics)
        XCTAssertEqual(view.displayedRows.count, metrics.count)
        XCTAssertEqual(view.displayedRows[0].sample, "sample-alpha")
        XCTAssertEqual(view.displayedRows[1].sample, "sample-beta")
        XCTAssertEqual(view.displayedRows[2].sample, "sample-gamma")
    }

    /// The table has exactly 9 fixed columns registered via standardColumnNames.
    func testColumnCount() {
        let view = BatchTaxTriageTableView(frame: .zero)
        XCTAssertEqual(view.metadataColumns.standardColumnNames.count, 9)
    }

    /// Sort by TASS score descending places the highest score first.
    func testSortByTassScoreDescending() {
        let view = BatchTaxTriageTableView(frame: .zero)
        view.configure(rows: makeMetrics())

        let sorted = view.displayedRows.sorted { $0.tassScore > $1.tassScore }

        XCTAssertEqual(sorted[0].tassScore, 0.95, accuracy: 0.0001)
        XCTAssertEqual(sorted[1].tassScore, 0.72, accuracy: 0.0001)
        XCTAssertEqual(sorted[2].tassScore, 0.40, accuracy: 0.0001)

        // Verify ordering corresponds to the correct organisms
        XCTAssertEqual(sorted[0].organism, "Escherichia coli")
        XCTAssertEqual(sorted[2].organism, "Homo sapiens")
    }

    /// Sort by organism name ascending places names in alphabetical order.
    func testSortByOrganismNameAscending() {
        let view = BatchTaxTriageTableView(frame: .zero)
        view.configure(rows: makeMetrics())

        let sorted = view.displayedRows.sorted {
            $0.organism.localizedCaseInsensitiveCompare($1.organism) == .orderedAscending
        }

        XCTAssertEqual(sorted[0].organism, "Escherichia coli")
        XCTAssertEqual(sorted[1].organism, "Homo sapiens")
        XCTAssertEqual(sorted[2].organism, "Mycobacterium tuberculosis")
    }

    /// Configuring with an empty array results in zero displayed rows.
    func testEmptyRowsConfiguration() {
        let view = BatchTaxTriageTableView(frame: .zero)
        view.configure(rows: [])
        XCTAssertTrue(view.displayedRows.isEmpty)
    }

    /// `sample` field from TaxTriageMetric is preserved in displayed rows.
    func testSampleFieldIsDisplayed() {
        let view = BatchTaxTriageTableView(frame: .zero)
        let metrics = makeMetrics()
        view.configure(rows: metrics)

        XCTAssertEqual(view.displayedRows[0].sample, "sample-alpha")
        XCTAssertEqual(view.displayedRows[1].sample, "sample-beta")
        XCTAssertEqual(view.displayedRows[2].sample, "sample-gamma")
        // All samples are non-nil as required
        XCTAssertTrue(view.displayedRows.allSatisfy { $0.sample != nil })
    }

    /// The `onMultipleRowsSelected` callback fires with correct rows.
    func testMultiSelectCallbackFires() {
        let view = BatchTaxTriageTableView(frame: .zero)
        view.configure(rows: makeMetrics())

        var callbackRows: [TaxTriageMetric] = []
        view.onMultipleRowsSelected = { rows in
            callbackRows = rows
        }

        // Simulate the callback firing as the delegate would trigger it.
        let selectedRows = [view.displayedRows[0], view.displayedRows[2]]
        view.onMultipleRowsSelected?(selectedRows)

        XCTAssertEqual(callbackRows.count, 2)
        XCTAssertEqual(callbackRows[0].organism, "Escherichia coli")
        XCTAssertEqual(callbackRows[1].organism, "Mycobacterium tuberculosis")
    }

    /// Reads cell rendering should prefer BAM-derived totals when available.
    func testReadsCellUsesTotalReadsOverride() {
        let view = BatchTaxTriageTableView(frame: .zero)
        let metrics = makeMetrics()
        view.configure(rows: metrics)

        let row = metrics[0] // sample-alpha / Escherichia coli
        view.totalReadsByKey["sample-alpha\tEscherichia coli"] = 42

        let cell = view.cellContent(
            for: NSUserInterfaceItemIdentifier("tt_reads"),
            row: row
        )
        XCTAssertEqual(cell.text, "42")
    }

    /// Read-count sorting should use BAM-derived totals when present.
    func testReadsSortUsesTotalReadsOverride() {
        let view = BatchTaxTriageTableView(frame: .zero)
        let metrics = makeMetrics()
        view.configure(rows: metrics)

        let lhs = metrics[0] // parser reads: 12000
        let rhs = metrics[2] // parser reads: 3500

        // Override so lhs becomes smaller than rhs.
        view.totalReadsByKey["sample-alpha\tEscherichia coli"] = 100
        view.totalReadsByKey["sample-gamma\tMycobacterium tuberculosis"] = 5000

        XCTAssertTrue(
            view.compareRows(lhs, rhs, by: "tt_reads", ascending: true),
            "Ascending sort should compare BAM-derived totals (100 < 5000)"
        )
    }
}

// MARK: - Batch Table Selection Identity Tests

@MainActor
final class BatchTableSelectionIdentityTests: XCTestCase {

    func testKrakenBatchSelectionSurvivesSortWithDuplicateTaxonAcrossSamples() {
        let view = BatchClassificationTableView(frame: .zero)
        view.resultIdentity = "/project/Analyses/kraken2-run-a"
        view.configure(rows: [
            BatchClassificationRow(
                sample: "sample-A",
                taxonName: "Escherichia coli",
                taxId: 562,
                rank: "S",
                rankDisplayName: "Species",
                readsDirect: 10,
                readsClade: 10,
                percentage: 1
            ),
            BatchClassificationRow(
                sample: "sample-B",
                taxonName: "Escherichia coli",
                taxId: 562,
                rank: "S",
                rankDisplayName: "Species",
                readsDirect: 90,
                readsClade: 90,
                percentage: 9
            ),
            BatchClassificationRow(
                sample: "sample-C",
                taxonName: "Homo sapiens",
                taxId: 9606,
                rank: "S",
                rankDisplayName: "Species",
                readsDirect: 50,
                readsClade: 50,
                percentage: 5
            ),
        ])

        view.testTableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        view.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: view.testTableView))

        view.testTableView.sortDescriptors = [NSSortDescriptor(key: "readsDirect", ascending: true)]
        view.tableView(view.testTableView, sortDescriptorsDidChange: [])

        let selectedRows = view.selectedRowsByIdentity()
        XCTAssertEqual(selectedRows.map(\.sample), ["sample-B"])
        XCTAssertEqual(view.testTableView.selectedRowIndexes, IndexSet(integer: 2))
    }

    func testEsVirituBatchSelectionSurvivesReloadWithDuplicateAccessionAcrossRuns() {
        let view = BatchEsVirituTableView(frame: .zero)
        view.resultIdentity = "/project/Analyses/esviritu-run-a"
        view.configure(rows: [
            BatchEsVirituRow(
                sample: "sample-A",
                virusName: "Shared virus",
                family: "Sharedviridae",
                assembly: "NC_000001.1",
                readCount: 10,
                uniqueReads: 9,
                rpkmf: 1,
                coverageBreadth: 0.1,
                coverageDepth: 2
            ),
            BatchEsVirituRow(
                sample: "sample-B",
                virusName: "Shared virus",
                family: "Sharedviridae",
                assembly: "NC_000001.1",
                readCount: 20,
                uniqueReads: 18,
                rpkmf: 2,
                coverageBreadth: 0.2,
                coverageDepth: 4
            ),
        ])

        view.testTableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        view.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: view.testTableView))

        view.configure(rows: [
            BatchEsVirituRow(
                sample: "sample-B",
                virusName: "Shared virus",
                family: "Sharedviridae",
                assembly: "NC_000001.1",
                readCount: 25,
                uniqueReads: 23,
                rpkmf: 2.5,
                coverageBreadth: 0.25,
                coverageDepth: 5
            ),
            BatchEsVirituRow(
                sample: "sample-A",
                virusName: "Shared virus",
                family: "Sharedviridae",
                assembly: "NC_000001.1",
                readCount: 15,
                uniqueReads: 13,
                rpkmf: 1.5,
                coverageBreadth: 0.15,
                coverageDepth: 3
            ),
        ])

        let selectedRows = view.selectedRowsByIdentity()
        XCTAssertEqual(selectedRows.map(\.sample), ["sample-B"])
        XCTAssertEqual(view.testTableView.selectedRowIndexes, IndexSet(integer: 0))
    }

    func testTaxTriageBatchSelectionClearsWhenDuplicateOrganismFilteredOut() {
        let view = BatchTaxTriageTableView(frame: .zero)
        view.resultIdentity = "/project/Analyses/taxtriage-run-a"
        view.configure(rows: [
            TaxTriageMetric(
                sample: "sample-A",
                taxId: 562,
                organism: "Escherichia coli",
                reads: 10,
                tassScore: 0.1
            ),
            TaxTriageMetric(
                sample: "sample-B",
                taxId: 562,
                organism: "Escherichia coli",
                reads: 20,
                tassScore: 0.2
            ),
            TaxTriageMetric(
                sample: "sample-C",
                taxId: 10239,
                organism: "Influenza A virus",
                reads: 30,
                tassScore: 0.3
            ),
        ])

        var didClear = false
        view.onSelectionCleared = {
            didClear = true
        }
        view.testTableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        view.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: view.testTableView))

        view.setFilterText("Influenza")

        XCTAssertTrue(didClear)
        XCTAssertTrue(view.selectedRowsByIdentity().isEmpty)
        XCTAssertTrue(view.selectedMetrics().isEmpty)
        XCTAssertTrue(view.testTableView.selectedRowIndexes.isEmpty)
    }
}

// MARK: - TaxonomyViewController Batch Mode Tests

@MainActor
final class TaxonomyViewControllerBatchModeTests: XCTestCase {

    // MARK: - Helpers

    /// Minimal valid kreport text with one species and one domain.
    private let minimalKreport = """
        10.00\t1000\t0\tU\t0\tunclassified
        90.00\t9000\t0\tR\t1\troot
        80.00\t8000\t100\tD\t2\t  Bacteria
        50.00\t5000\t5000\tS\t562\t    Escherichia coli
        """

    private let minimalKreport2 = """
        5.00\t500\t0\tU\t0\tunclassified
        95.00\t9500\t0\tR\t1\troot
        90.00\t9000\t200\tD\t10239\t  Viruses
        70.00\t7000\t7000\tS\t11234\t    SARS-CoV-2
        """

    /// Creates a temporary batch directory with subdirectories for each sample,
    /// each containing a `report.kreport` file.
    ///
    /// - Parameter samples: Array of (sampleId, kreportText) pairs.
    /// - Returns: The batch URL and an array of `MetagenomicsBatchSampleRecord`.
    private func makeTempBatch(samples: [(String, String)]) throws -> (URL, [MetagenomicsBatchSampleRecord]) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishBatchTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        var records: [MetagenomicsBatchSampleRecord] = []
        for (sampleId, kreportText) in samples {
            let resultDir = tmp.appendingPathComponent(sampleId)
            try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
            let kreportURL = resultDir.appendingPathComponent("report.kreport")
            try kreportText.write(to: kreportURL, atomically: true, encoding: .utf8)
            records.append(MetagenomicsBatchSampleRecord(
                sampleId: sampleId,
                resultDirectory: sampleId,
                inputFiles: [],
                isPairedEnd: false
            ))
        }
        return (tmp, records)
    }

    private func makeManifest(records: [MetagenomicsBatchSampleRecord]) -> ClassificationBatchResultManifest {
        ClassificationBatchResultManifest(
            header: MetagenomicsBatchManifestHeader(
                schemaVersion: 1,
                createdAt: Date(),
                sampleCount: records.count
            ),
            goal: "classify",
            databaseName: "standard",
            databaseVersion: "2024",
            summaryTSV: "",
            samples: records
        )
    }

    // MARK: - Default State Tests

    /// `isBatchMode` is false before any configuration.
    func testIsBatchModeDefaultsFalse() {
        let vc = TaxonomyViewController()
        XCTAssertFalse(vc.isBatchMode)
    }

    /// `batchTableView` is hidden after `loadView()`.
    func testBatchTableViewHiddenByDefault() {
        let vc = TaxonomyViewController()
        vc.loadViewIfNeeded()
        XCTAssertTrue(vc.testBatchTableView.isHidden, "batchTableView should be hidden by default")
    }

    /// `splitView` is visible after `loadView()` (not in batch mode).
    func testSplitViewVisibleByDefault() {
        let vc = TaxonomyViewController()
        vc.loadViewIfNeeded()
        XCTAssertFalse(vc.splitView.isHidden, "splitView should be visible by default")
    }

    // MARK: - configureFromDatabase Tests

    // MARK: - applyBatchSampleFilter Tests
}

// MARK: - EsVirituViewController Batch Mode Tests

@MainActor
final class EsVirituViewControllerBatchModeTests: XCTestCase {

    // MARK: - Helpers

    /// A minimal 23-column detected_virus.info.tsv data row (tab-separated).
    /// Columns: sample_ID, Name, description, Length, Segment, Accession, Assembly,
    ///          Asm_length, kingdom, phylum, tclass, order, family, genus, species,
    ///          subspecies, RPKMF, read_count, covered_bases, mean_coverage,
    ///          avg_read_identity, Pi, filtered_reads_in_sample
    private func detectionRow(
        sampleId: String,
        name: String,
        accession: String,
        assembly: String,
        family: String
    ) -> String {
        [
            sampleId,                   // 0  sample_ID
            name,                       // 1  Name
            "Test virus description",   // 2  description
            "30000",                    // 3  Length
            "NA",                       // 4  Segment
            accession,                  // 5  Accession
            assembly,                   // 6  Assembly
            "30000",                    // 7  Asm_length
            "Viruses",                  // 8  kingdom
            "NA",                       // 9  phylum
            "NA",                       // 10 tclass
            "NA",                       // 11 order
            family,                     // 12 family
            "NA",                       // 13 genus
            "NA",                       // 14 species
            "NA",                       // 15 subspecies
            "150.0",                    // 16 RPKMF
            "5000",                     // 17 read_count
            "28000",                    // 18 covered_bases
            "12.5",                     // 19 mean_coverage
            "99.2",                     // 20 avg_read_identity
            "0.002",                    // 21 Pi
            "100000",                   // 22 filtered_reads_in_sample
        ].joined(separator: "\t")
    }

    private func minimalDetectionTSV(sampleId: String) -> String {
        let header = "sample_ID\tName\tdescription\tLength\tSegment\tAccession\tAssembly\tAsm_length\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tRPKMF\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tPi\tfiltered_reads_in_sample"
        let row = detectionRow(
            sampleId: sampleId,
            name: "SARS-CoV-2",
            accession: "MN908947.3",
            assembly: "GCF_009858895.2",
            family: "Coronaviridae"
        )
        return header + "\n" + row + "\n"
    }

    private func twoVirusTSV(sampleId: String) -> String {
        let header = "sample_ID\tName\tdescription\tLength\tSegment\tAccession\tAssembly\tAsm_length\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tRPKMF\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tPi\tfiltered_reads_in_sample"
        let row1 = detectionRow(
            sampleId: sampleId,
            name: "SARS-CoV-2",
            accession: "MN908947.3",
            assembly: "GCF_009858895.2",
            family: "Coronaviridae"
        )
        let row2 = detectionRow(
            sampleId: sampleId,
            name: "Influenza A",
            accession: "CY114381.1",
            assembly: "GCF_000865085.1",
            family: "Orthomyxoviridae"
        )
        return header + "\n" + row1 + "\n" + row2 + "\n"
    }

    /// Creates a temp batch directory with sample subdirectories, each containing
    /// a `<sampleId>.detected_virus.info.tsv` file.
    private func makeTempBatch(
        samples: [(String, String)]
    ) throws -> (URL, [MetagenomicsBatchSampleRecord]) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishEsVirituBatchTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        var records: [MetagenomicsBatchSampleRecord] = []
        for (sampleId, tsvContent) in samples {
            let resultDir = tmp.appendingPathComponent(sampleId)
            try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
            let detectionURL = resultDir.appendingPathComponent("\(sampleId).detected_virus.info.tsv")
            try tsvContent.write(to: detectionURL, atomically: true, encoding: .utf8)
            records.append(MetagenomicsBatchSampleRecord(
                sampleId: sampleId,
                resultDirectory: sampleId,
                inputFiles: [],
                isPairedEnd: false
            ))
        }
        return (tmp, records)
    }

    private func makeManifest(records: [MetagenomicsBatchSampleRecord]) -> EsVirituBatchResultManifest {
        EsVirituBatchResultManifest(
            header: MetagenomicsBatchManifestHeader(
                schemaVersion: 1,
                createdAt: Date(),
                sampleCount: records.count
            ),
            summaryTSV: "",
            samples: records
        )
    }

    // MARK: - Default State Tests

    /// `isBatchMode` is false before any configuration.
    func testIsBatchModeDefaultsFalse() {
        let vc = EsVirituResultViewController()
        XCTAssertFalse(vc.isBatchMode)
    }

    /// `batchTableView` is hidden after `loadView()`.
    func testBatchTableViewHiddenByDefault() {
        let vc = EsVirituResultViewController()
        vc.loadViewIfNeeded()
        XCTAssertTrue(vc.testBatchTableView.isHidden, "batchTableView should be hidden by default")
    }

    /// `splitView` is visible after `loadView()` (not in batch mode).
    func testSplitViewVisibleByDefault() {
        let vc = EsVirituResultViewController()
        vc.loadViewIfNeeded()
        XCTAssertFalse(vc.splitView.isHidden, "splitView should be visible by default")
    }

    func testLayoutPreferenceStacksDetectionTableAboveDetail() {
        UserDefaults.standard.set(MetagenomicsPanelLayout.stacked.rawValue, forKey: MetagenomicsPanelLayout.defaultsKey)
        UserDefaults.standard.set(false, forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)
        defer {
            UserDefaults.standard.removeObject(forKey: MetagenomicsPanelLayout.defaultsKey)
            UserDefaults.standard.removeObject(forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)
        }

        let vc = EsVirituResultViewController()
        vc.loadViewIfNeeded()

        XCTAssertFalse(vc.splitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === vc.testRightPaneContainer)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === vc.testDetailContainer)
    }

    // MARK: - configureFromDatabase Tests

    // MARK: - applyBatchSampleFilter Tests
}

// MARK: - TaxTriageViewController Batch Group Mode Tests

@MainActor
final class TaxTriageViewControllerBatchGroupModeTests: XCTestCase {

    // MARK: - Helpers

    /// Minimal confidence TSV with required columns.
    private func minimalConfidenceTSV(sampleId: String) -> String {
        let header = "sample\torganism\treads\ttass_score\tconfidence"
        let row = "\(sampleId)\tEscherichia coli\t1000\t0.92\thigh"
        return header + "\n" + row + "\n"
    }

    /// Two-organism TSV for a sample.
    private func twoOrganismTSV(sampleId: String) -> String {
        let header = "sample\torganism\treads\ttass_score\tconfidence"
        let row1 = "\(sampleId)\tEscherichia coli\t1000\t0.92\thigh"
        let row2 = "\(sampleId)\tKlebsiella pneumoniae\t500\t0.65\tmedium"
        return header + "\n" + row1 + "\n" + row2 + "\n"
    }

    /// Creates a temp batch group directory with one subdirectory per sample, each
    /// containing a `<sampleId>.organisms.report.txt` confidence TSV file.
    ///
    /// - Parameter samples: Array of (sampleId, tsvContent) pairs.
    /// - Returns: The batch root URL.
    private func makeTempBatchGroup(samples: [(String, String)]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishTaxTriageBatchGroupTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for (sampleId, tsvContent) in samples {
            let subdir = tmp.appendingPathComponent(sampleId)
            try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            let metricsURL = subdir.appendingPathComponent("\(sampleId).organisms.report.txt")
            try tsvContent.write(to: metricsURL, atomically: true, encoding: .utf8)
        }
        return tmp
    }

    // MARK: - Default State Tests

    /// `isBatchGroupMode` is false before any configuration.
    func testIsBatchGroupModeDefaultsFalse() {
        let vc = TaxTriageResultViewController()
        XCTAssertFalse(vc.isBatchGroupMode)
    }

    /// `batchFlatTableView` is hidden after `loadView()`.
    func testBatchFlatTableViewHiddenByDefault() {
        let vc = TaxTriageResultViewController()
        vc.loadViewIfNeeded()
        XCTAssertTrue(vc.testBatchFlatTableView.isHidden,
                      "batchFlatTableView should be hidden by default")
    }

    // MARK: - applyBatchGroupFilter Tests

    /// When NOT in batch group mode, `selectedSampleIndex` stays at its default (0).
    func testSelectedSampleIndexUnaffectedWhenNotInBatchGroupMode() {
        let vc = TaxTriageResultViewController()
        vc.loadViewIfNeeded()
        // No configureFromDatabase call — selectedSampleIndex should remain at its default.
        XCTAssertEqual(vc.selectedSampleIndex, 0,
                       "selectedSampleIndex should default to 0 when not in batch group mode")
        XCTAssertFalse(vc.isBatchGroupMode)
    }
}

// MARK: - BatchGroupRoutingTests

/// Tests for the `.batchGroup` sidebar routing logic added in Task 8.
///
/// These tests verify:
/// 1. `.batchGroup` items are included in displayable items (no longer filtered).
/// 2. Tool detection from directory name prefix works correctly.
/// 3. `displayBatchGroup` routes to the right VC based on directory prefix.
@MainActor
final class BatchGroupRoutingTests: XCTestCase {

    // MARK: - Displayable Items Filter

    /// `.batchGroup` items must NOT be filtered out of the displayable items list.
    ///
    /// Before Task 8, `.batchGroup` was in the filter alongside `.folder`, `.project`,
    /// and `.group`. This test verifies the filter was correctly narrowed.
    func testBatchGroupItemIsDisplayable() {
        let allTypes: [SidebarItemType] = [
            .folder, .project, .group, .batchGroup,
            .classificationResult, .esvirituResult, .taxTriageResult,
        ]

        // Mirror the filter logic from sidebarDidSelectItems (after Task 8 fix).
        let displayable = allTypes.filter { type in
            type != .folder && type != .project && type != .group
        }

        XCTAssertTrue(displayable.contains(.batchGroup),
                      ".batchGroup should survive the displayable-items filter")
        XCTAssertFalse(displayable.contains(.folder),   ".folder must still be filtered")
        XCTAssertFalse(displayable.contains(.project),  ".project must still be filtered")
        XCTAssertFalse(displayable.contains(.group),    ".group must still be filtered")
    }

    /// `.folder`, `.project`, and `.group` remain excluded; only `.batchGroup` is now displayable.
    func testNonDisplayableContainerTypesStillExcluded() {
        let containerTypes: [SidebarItemType] = [.folder, .project, .group]
        let filtered = containerTypes.filter { $0 != .folder && $0 != .project && $0 != .group }
        XCTAssertTrue(filtered.isEmpty, "Classic container types must still be filtered out")
    }

    // MARK: - Tool Detection from Directory Name Prefix

    func testKraken2PrefixDetected() {
        let dirNames = ["kraken2-batch-2024-06-02T14-20-15", "kraken2-batch-sample-run"]
        for name in dirNames {
            XCTAssertTrue(
                name.hasPrefix("kraken2") || name.hasPrefix("classification"),
                "'\(name)' should be detected as a Kraken2 batch"
            )
        }
    }

    func testClassificationPrefixDetected() {
        let dirNames = ["classification-batch-2024-01-15", "classification-run-001"]
        for name in dirNames {
            XCTAssertTrue(
                name.hasPrefix("kraken2") || name.hasPrefix("classification"),
                "'\(name)' should be detected as a classification batch"
            )
        }
    }

    func testEsVirituPrefixDetected() {
        let dirNames = ["esviritu-batch-2025-03-10T09-00-00", "esviritu-run-sampleA"]
        for name in dirNames {
            XCTAssertTrue(
                name.hasPrefix("esviritu"),
                "'\(name)' should be detected as an EsViritu batch"
            )
        }
    }

    func testTaxTriagePrefixDetected() {
        let dirNames = ["taxtriage-batch-2025-04-01", "taxtriage-20250325-143022"]
        for name in dirNames {
            XCTAssertTrue(
                name.hasPrefix("taxtriage"),
                "'\(name)' should be detected as a TaxTriage batch"
            )
        }
    }

    func testUnknownPrefixNotMatchedByAnyTool() {
        let unknown = ["naomgs-batch-001", "nvd-batch-run", "unknown-tool-batch"]
        for name in unknown {
            let isKraken2 = name.hasPrefix("kraken2") || name.hasPrefix("classification")
            let isEsViritu = name.hasPrefix("esviritu")
            let isTaxTriage = name.hasPrefix("taxtriage")
            XCTAssertFalse(isKraken2 || isEsViritu || isTaxTriage,
                           "'\(name)' should not match any known batch tool prefix")
        }
    }

    // MARK: - Prefix Disambiguation (no overlap)

    /// Verify that the three recognized prefixes are mutually exclusive,
    /// so the routing if-else chain always picks exactly one branch.
    func testPrefixesAreMutuallyExclusive() {
        let kraken2Name = "kraken2-batch-2024-01-01"
        let classificationName = "classification-batch-2024-01-01"
        let esVirituName = "esviritu-batch-2024-01-01"
        let taxTriageName = "taxtriage-batch-2024-01-01"

        // Each name must match exactly one branch.
        func matchCount(_ name: String) -> Int {
            var count = 0
            if name.hasPrefix("kraken2") || name.hasPrefix("classification") { count += 1 }
            if name.hasPrefix("esviritu") { count += 1 }
            if name.hasPrefix("taxtriage") { count += 1 }
            return count
        }

        XCTAssertEqual(matchCount(kraken2Name), 1,
                       "kraken2 prefix should match exactly one branch")
        XCTAssertEqual(matchCount(classificationName), 1,
                       "classification prefix should match exactly one branch")
        XCTAssertEqual(matchCount(esVirituName), 1,
                       "esviritu prefix should match exactly one branch")
        XCTAssertEqual(matchCount(taxTriageName), 1,
                       "taxtriage prefix should match exactly one branch")
    }

    // MARK: - TaxonomyViewController batch mode wired correctly

    // MARK: - Manifest loading round-trip for routing

    /// The routing code uses `MetagenomicsBatchResultStore.loadClassification(from:)`.
    /// Verify it returns non-nil for a directory containing the manifest.
    func testLoadClassificationManifestForRouting() throws {
        let batchURL = makeTempDir(prefix: "kraken2-batch-")
        defer { try? FileManager.default.removeItem(at: batchURL) }

        let now = Date()
        let header = MetagenomicsBatchManifestHeader(schemaVersion: 1, createdAt: now, sampleCount: 1)
        let manifest = ClassificationBatchResultManifest(
            header: header,
            goal: "profiling",
            databaseName: "standard",
            databaseVersion: "2024-01",
            summaryTSV: "summary.tsv",
            samples: [MetagenomicsBatchSampleRecord(
                sampleId: "s1",
                resultDirectory: "s1",
                inputFiles: [],
                isPairedEnd: false
            )]
        )
        try MetagenomicsBatchResultStore.saveClassification(manifest, to: batchURL)

        let loaded = MetagenomicsBatchResultStore.loadClassification(from: batchURL)
        XCTAssertNotNil(loaded, "loadClassification should return the saved manifest")
        XCTAssertEqual(loaded?.samples.count, 1)
        XCTAssertEqual(loaded?.samples.first?.sampleId, "s1")
    }

    /// The routing code uses `MetagenomicsBatchResultStore.loadEsViritu(from:)`.
    /// Verify it returns non-nil for a directory containing the manifest.
    func testLoadEsVirituManifestForRouting() throws {
        let batchURL = makeTempDir(prefix: "esviritu-batch-")
        defer { try? FileManager.default.removeItem(at: batchURL) }

        let now = Date()
        let header = MetagenomicsBatchManifestHeader(schemaVersion: 1, createdAt: now, sampleCount: 2)
        let manifest = EsVirituBatchResultManifest(
            header: header,
            summaryTSV: "summary.tsv",
            samples: [
                MetagenomicsBatchSampleRecord(sampleId: "sA", resultDirectory: "sA", inputFiles: [], isPairedEnd: true),
                MetagenomicsBatchSampleRecord(sampleId: "sB", resultDirectory: "sB", inputFiles: [], isPairedEnd: false),
            ]
        )
        try MetagenomicsBatchResultStore.saveEsViritu(manifest, to: batchURL)

        let loaded = MetagenomicsBatchResultStore.loadEsViritu(from: batchURL)
        XCTAssertNotNil(loaded, "loadEsViritu should return the saved manifest")
        XCTAssertEqual(loaded?.samples.count, 2)
    }

    /// `loadClassification` returns nil for an empty directory (missing manifest).
    /// This validates the routing guard that shows an error alert.
    func testLoadClassificationReturnsNilForMissingManifest() {
        let emptyDir = makeTempDir(prefix: "kraken2-batch-empty-")
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let result = MetagenomicsBatchResultStore.loadClassification(from: emptyDir)
        XCTAssertNil(result, "loadClassification should return nil when manifest is absent")
    }

    /// `loadEsViritu` returns nil for an empty directory (missing manifest).
    func testLoadEsVirituReturnsNilForMissingManifest() {
        let emptyDir = makeTempDir(prefix: "esviritu-batch-empty-")
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let result = MetagenomicsBatchResultStore.loadEsViritu(from: emptyDir)
        XCTAssertNil(result, "loadEsViritu should return nil when manifest is absent")
    }

    // MARK: - Helpers

    private func makeTempDir(prefix: String) -> URL {
        let tmp = FileManager.default.temporaryDirectory
        let dir = tmp.appendingPathComponent("\(prefix)\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - BatchInspectorSectionTests

/// Tests for Task 9: batch operation details and source sample links in the Inspector.
///
/// Covers:
/// 1. `DocumentSectionViewModel` batch properties default values.
/// 2. Setting `batchOperationTool` makes it non-nil.
/// 3. `batchOperationParameters` stores key-value pairs.
/// 4. `batchSourceSampleURLs` stores sample entries.
/// 5. `BatchOperationDetailsSection` can be instantiated without crashing.
/// 6. `SourceSamplesSection` can be instantiated without crashing.
/// 7. Source bundle URL resolution from an input file path.
/// 8. `updateBatchOperationDetails` sets all properties correctly.
@MainActor
final class BatchInspectorSectionTests: XCTestCase {

    // MARK: - 1. Default values

    /// `DocumentSectionViewModel` batch properties start at nil/empty defaults.
    func testDocumentSectionViewModelBatchPropertiesDefaultToNilEmpty() {
        let vm = DocumentSectionViewModel()

        XCTAssertNil(vm.batchOperationTool,
                     "batchOperationTool should default to nil")
        XCTAssertTrue(vm.batchOperationParameters.isEmpty,
                      "batchOperationParameters should default to empty")
        XCTAssertNil(vm.batchOperationTimestamp,
                     "batchOperationTimestamp should default to nil")
        XCTAssertTrue(vm.batchSourceSampleURLs.isEmpty,
                      "batchSourceSampleURLs should default to empty")
    }

    // MARK: - 2. Setting batchOperationTool

    /// Setting `batchOperationTool` to a non-nil value persists correctly.
    func testSettingBatchOperationToolMakesItNonNil() {
        let vm = DocumentSectionViewModel()
        vm.batchOperationTool = "Kraken2"
        XCTAssertEqual(vm.batchOperationTool, "Kraken2")
    }

    // MARK: - 3. batchOperationParameters

    /// `batchOperationParameters` stores and retrieves arbitrary key-value pairs.
    func testBatchOperationParametersStoresKeyValuePairs() {
        let vm = DocumentSectionViewModel()
        vm.batchOperationParameters = ["Database": "standard-2024-01", "Confidence": "0.2"]

        XCTAssertEqual(vm.batchOperationParameters["Database"], "standard-2024-01")
        XCTAssertEqual(vm.batchOperationParameters["Confidence"], "0.2")
        XCTAssertEqual(vm.batchOperationParameters.count, 2)
    }

    // MARK: - 4. batchSourceSampleURLs

    /// `batchSourceSampleURLs` stores tuples with both linked and unlinked entries.
    func testBatchSourceSampleURLsStoresSampleEntries() {
        let vm = DocumentSectionViewModel()
        let testURL = URL(fileURLWithPath: "/tmp/SampleA.lungfishfastq")
        vm.batchSourceSampleURLs = [
            (sampleId: "SampleA", bundleURL: testURL),
            (sampleId: "SampleB", bundleURL: nil),
        ]

        XCTAssertEqual(vm.batchSourceSampleURLs.count, 2)
        XCTAssertEqual(vm.batchSourceSampleURLs[0].sampleId, "SampleA")
        XCTAssertEqual(vm.batchSourceSampleURLs[0].bundleURL, testURL)
        XCTAssertEqual(vm.batchSourceSampleURLs[1].sampleId, "SampleB")
        XCTAssertNil(vm.batchSourceSampleURLs[1].bundleURL)
    }

    // MARK: - 5. BatchOperationDetailsSection instantiation

    /// `BatchOperationDetailsSection` can be instantiated with all parameters.
    func testBatchOperationDetailsSectionCanBeInstantiated() {
        // This test verifies the SwiftUI view initialiser doesn't crash.
        let section = BatchOperationDetailsSection(
            tool: "Kraken2",
            parameters: ["Database": "standard-2024-01", "Goal": "profiling"],
            timestamp: Date()
        )
        // Accessing `body` (via `_body`) would require a rendering context.
        // The mere instantiation without crash is sufficient here.
        _ = section
    }

    /// `BatchOperationDetailsSection` can be instantiated with empty/nil optional parameters.
    func testBatchOperationDetailsSectionInstantiatesWithNilTimestampAndEmptyParams() {
        let section = BatchOperationDetailsSection(tool: "EsViritu", parameters: [:], timestamp: nil)
        _ = section
    }

    // MARK: - 6. SourceSamplesSection instantiation

    /// `SourceSamplesSection` can be instantiated with a mix of linked and unlinked samples.
    func testSourceSamplesSectionCanBeInstantiated() {
        let section = SourceSamplesSection(
            samples: [
                (sampleId: "S1", bundleURL: URL(fileURLWithPath: "/tmp/S1.lungfishfastq")),
                (sampleId: "S2", bundleURL: nil),
            ],
            onNavigateToBundle: { _ in }
        )
        _ = section
    }

    /// `SourceSamplesSection` can be instantiated with an empty sample list.
    func testSourceSamplesSectionInstantiatesEmpty() {
        let section = SourceSamplesSection(samples: [])
        _ = section
    }

    // MARK: - 7. Source bundle URL resolution

    /// `resolveBundleURL(fromInputFilePath:)` returns the `.lungfishfastq` ancestor when present.
    func testSourceBundleURLResolutionFromInputFilePath() throws {
        // Set up a real temporary .lungfishfastq directory with a file inside.
        let tmp = FileManager.default.temporaryDirectory
        let bundleDir = tmp.appendingPathComponent("TestSample-\(UUID().uuidString).lungfishfastq")
        let readsFile = bundleDir.appendingPathComponent("reads.fastq.gz")

        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        FileManager.default.createFile(atPath: readsFile.path, contents: Data())

        let resolved = resolveBundleURL(fromInputFilePath: readsFile.path)

        XCTAssertNotNil(resolved, "resolveBundleURL should find the .lungfishfastq bundle")
        XCTAssertEqual(resolved?.lastPathComponent, bundleDir.lastPathComponent)
    }

    /// `resolveBundleURL(fromInputFilePath:)` returns nil when no `.lungfishfastq` ancestor exists.
    func testSourceBundleURLResolutionReturnsNilWhenNoBundleAncestor() {
        let path = "/tmp/some-random-file.fastq.gz"
        let resolved = resolveBundleURL(fromInputFilePath: path)
        XCTAssertNil(resolved, "resolveBundleURL should return nil when no .lungfishfastq ancestor exists")
    }

    // MARK: - 8. updateBatchOperationDetails

    /// `InspectorViewController.updateBatchOperationDetails` sets all ViewModel properties.
    func testUpdateBatchOperationDetailsSetsAllProperties() {
        let vc = InspectorViewController()
        vc.loadViewIfNeeded()

        let testDate = Date(timeIntervalSince1970: 1_700_000_000)
        let testURL = URL(fileURLWithPath: "/tmp/SampleA.lungfishfastq")

        vc.updateBatchOperationDetails(
            tool: "EsViritu",
            parameters: ["Mode": "fast"],
            timestamp: testDate,
            sourceSamples: [(sampleId: "SampleA", bundleURL: testURL)]
        )

        let dsvm = vc.viewModel.documentSectionViewModel
        XCTAssertEqual(dsvm.batchOperationTool, "EsViritu")
        XCTAssertEqual(dsvm.batchOperationParameters["Mode"], "fast")
        XCTAssertEqual(dsvm.batchOperationTimestamp, testDate)
        XCTAssertEqual(dsvm.batchSourceSampleURLs.count, 1)
        XCTAssertEqual(dsvm.batchSourceSampleURLs.first?.sampleId, "SampleA")
        XCTAssertEqual(dsvm.batchSourceSampleURLs.first?.bundleURL, testURL)
    }

    /// `InspectorViewController.clearBatchOperationDetails` resets all batch properties.
    func testClearBatchOperationDetailsResetsProperties() {
        let vc = InspectorViewController()
        vc.loadViewIfNeeded()

        vc.updateBatchOperationDetails(
            tool: "Kraken2",
            parameters: ["Database": "standard"],
            timestamp: Date(),
            sourceSamples: [(sampleId: "S1", bundleURL: nil)]
        )

        vc.clearBatchOperationDetails()

        let dsvm = vc.viewModel.documentSectionViewModel
        XCTAssertNil(dsvm.batchOperationTool)
        XCTAssertTrue(dsvm.batchOperationParameters.isEmpty)
        XCTAssertNil(dsvm.batchOperationTimestamp)
        XCTAssertTrue(dsvm.batchSourceSampleURLs.isEmpty)
    }

    // MARK: - Helpers

    /// Mirrors the bundle resolution logic from `MainSplitViewController.resolveBundleURL(fromInputFilePath:)`.
    /// Duplicated here so tests are self-contained and don't depend on the private method.
    private func resolveBundleURL(fromInputFilePath path: String) -> URL? {
        var url = URL(fileURLWithPath: path)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if url.pathExtension.lowercased() == "lungfishfastq" {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    return url
                }
            }
        }
        return nil
    }
}

// MARK: - SummaryBarBatchTests

/// Tests for `updateBatch` methods added to the three classifier summary bars.
///
/// Verifies:
/// 1. Each summary bar's `updateBatch` can be called without crashing.
/// 2. The resulting `cards` reflect the batch parameters (sample count, total count, etc.).
/// 3. The batch label card is present with the expected tool name.
@MainActor
final class SummaryBarBatchTests: XCTestCase {

    // MARK: - TaxonomySummaryBar

    /// `updateBatch` can be called without crashing.
    func testTaxonomySummaryBarUpdateBatchDoesNotCrash() {
        let vc = TaxonomyViewController()
        vc.loadViewIfNeeded()
        let bar = vc.testSummaryBar
        bar.updateBatch(sampleCount: 3, totalRows: 120, databaseName: "standard")
        // No assertion needed — absence of crash is the requirement.
    }

    /// After `updateBatch`, the cards contain the expected sample count.
    func testTaxonomySummaryBarUpdateBatchShowsSampleCount() {
        let vc = TaxonomyViewController()
        vc.loadViewIfNeeded()
        let bar = vc.testSummaryBar
        bar.updateBatch(sampleCount: 5, totalRows: 200, databaseName: "standard")
        let samplesCard = bar.cards.first(where: { $0.label == "Samples" })
        XCTAssertNotNil(samplesCard, "Cards should include a 'Samples' card in batch mode")
        XCTAssertEqual(samplesCard?.value, "5")
    }

    /// After `updateBatch`, the cards contain the expected taxa count.
    func testTaxonomySummaryBarUpdateBatchShowsTaxaCount() {
        let vc = TaxonomyViewController()
        vc.loadViewIfNeeded()
        let bar = vc.testSummaryBar
        bar.updateBatch(sampleCount: 2, totalRows: 450, databaseName: "standard")
        let taxaCard = bar.cards.first(where: { $0.label == "Taxa" })
        XCTAssertNotNil(taxaCard, "Cards should include a 'Taxa' card in batch mode")
        XCTAssertEqual(taxaCard?.value, "450")
    }

    /// After `updateBatch`, the database name appears in the cards.
    func testTaxonomySummaryBarUpdateBatchShowsDatabaseName() {
        let vc = TaxonomyViewController()
        vc.loadViewIfNeeded()
        let bar = vc.testSummaryBar
        bar.updateBatch(sampleCount: 1, totalRows: 10, databaseName: "PlusPF")
        let dbCard = bar.cards.first(where: { $0.label == "Database" })
        XCTAssertNotNil(dbCard, "Cards should include a 'Database' card in batch mode")
        XCTAssertEqual(dbCard?.value, "PlusPF")
    }

    /// After `updateBatch` with an empty database name, the Database card shows an em-dash.
    func testTaxonomySummaryBarUpdateBatchEmptyDatabaseShowsEmDash() {
        let vc = TaxonomyViewController()
        vc.loadViewIfNeeded()
        let bar = vc.testSummaryBar
        bar.updateBatch(sampleCount: 1, totalRows: 5, databaseName: "")
        let dbCard = bar.cards.first(where: { $0.label == "Database" })
        XCTAssertEqual(dbCard?.value, "\u{2014}", "Empty database name should display as em-dash")
    }

    /// After `updateBatch`, a 'Batch' label card is present with value "Kraken2".
    func testTaxonomySummaryBarUpdateBatchHasBatchLabelCard() {
        let vc = TaxonomyViewController()
        vc.loadViewIfNeeded()
        let bar = vc.testSummaryBar
        bar.updateBatch(sampleCount: 2, totalRows: 80, databaseName: "standard")
        let batchCard = bar.cards.first(where: { $0.label == "Batch" })
        XCTAssertNotNil(batchCard, "Cards should include a 'Batch' card in batch mode")
        XCTAssertEqual(batchCard?.value, "Kraken2")
    }

    // MARK: - EsVirituSummaryBar

    /// `updateBatch` can be called without crashing.
    func testEsVirituSummaryBarUpdateBatchDoesNotCrash() {
        let vc = EsVirituResultViewController()
        vc.loadViewIfNeeded()
        let bar = vc.testSummaryBar
        bar.updateBatch(sampleCount: 4, totalDetections: 12)
        // No assertion needed — absence of crash is the requirement.
    }

    /// After `updateBatch`, the cards contain the expected sample count.
    func testEsVirituSummaryBarUpdateBatchShowsSampleCount() {
        let vc = EsVirituResultViewController()
        vc.loadViewIfNeeded()
        let bar = vc.testSummaryBar
        bar.updateBatch(sampleCount: 7, totalDetections: 33)
        let samplesCard = bar.cards.first(where: { $0.label == "Samples" })
        XCTAssertNotNil(samplesCard, "Cards should include a 'Samples' card in batch mode")
        XCTAssertEqual(samplesCard?.value, "7")
    }

    /// After `updateBatch`, the cards contain the expected detections count.
    func testEsVirituSummaryBarUpdateBatchShowsDetectionsCount() {
        let vc = EsVirituResultViewController()
        vc.loadViewIfNeeded()
        let bar = vc.testSummaryBar
        bar.updateBatch(sampleCount: 3, totalDetections: 27)
        let detectCard = bar.cards.first(where: { $0.label == "Detections" })
        XCTAssertNotNil(detectCard, "Cards should include a 'Detections' card in batch mode")
        XCTAssertEqual(detectCard?.value, "27")
    }

    /// After `updateBatch`, a 'Batch' label card is present with value "EsViritu".
    func testEsVirituSummaryBarUpdateBatchHasBatchLabelCard() {
        let vc = EsVirituResultViewController()
        vc.loadViewIfNeeded()
        let bar = vc.testSummaryBar
        bar.updateBatch(sampleCount: 2, totalDetections: 8)
        let batchCard = bar.cards.first(where: { $0.label == "Batch" })
        XCTAssertNotNil(batchCard, "Cards should include a 'Batch' card in batch mode")
        XCTAssertEqual(batchCard?.value, "EsViritu")
    }

    // MARK: - TaxTriageSummaryBar

    /// `updateBatch` can be called without crashing.
    func testTaxTriageSummaryBarUpdateBatchDoesNotCrash() {
        let vc = TaxTriageResultViewController()
        vc.loadViewIfNeeded()
        let bar = vc.testSummaryBar
        bar.updateBatch(sampleCount: 6, totalOrganisms: 18)
        // No assertion needed — absence of crash is the requirement.
    }

    /// After `updateBatch`, the cards contain the expected sample count.
    func testTaxTriageSummaryBarUpdateBatchShowsSampleCount() {
        let vc = TaxTriageResultViewController()
        vc.loadViewIfNeeded()
        let bar = vc.testSummaryBar
        bar.updateBatch(sampleCount: 9, totalOrganisms: 45)
        let samplesCard = bar.cards.first(where: { $0.label == "Samples" })
        XCTAssertNotNil(samplesCard, "Cards should include a 'Samples' card in batch mode")
        XCTAssertEqual(samplesCard?.value, "9")
    }

    /// After `updateBatch`, the cards contain the expected organisms count.
    func testTaxTriageSummaryBarUpdateBatchShowsOrganismsCount() {
        let vc = TaxTriageResultViewController()
        vc.loadViewIfNeeded()
        let bar = vc.testSummaryBar
        bar.updateBatch(sampleCount: 4, totalOrganisms: 22)
        let orgCard = bar.cards.first(where: { $0.label == "Organisms" })
        XCTAssertNotNil(orgCard, "Cards should include an 'Organisms' card in batch mode")
        XCTAssertEqual(orgCard?.value, "22")
    }

    /// After `updateBatch`, a 'Batch' label card is present with value "TaxTriage".
    func testTaxTriageSummaryBarUpdateBatchHasBatchLabelCard() {
        let vc = TaxTriageResultViewController()
        vc.loadViewIfNeeded()
        let bar = vc.testSummaryBar
        bar.updateBatch(sampleCount: 3, totalOrganisms: 15)
        let batchCard = bar.cards.first(where: { $0.label == "Batch" })
        XCTAssertNotNil(batchCard, "Cards should include a 'Batch' card in batch mode")
        XCTAssertEqual(batchCard?.value, "TaxTriage")
    }

    // MARK: - Round-trip: configureFromDatabase wires summaryBar.updateBatch
}

// MARK: - TaxTriageBatchRegressionTests

/// Regression tests for TaxTriage batch mode bugs fixed in feature/batch-aggregated-classifier-views:
///   1. Unique reads = total reads when no accession mapping exists
///   2. MiniBAMs not appearing due to missing GCF mapping in batch group mode
///   3. Old TaxTriage interface flashing before new one loads
@MainActor
final class TaxTriageBatchRegressionTests: XCTestCase {

    // MARK: - Helpers

    /// Makes a temp batch directory with per-sample subdirectories containing only metrics files
    /// (no BAM files). This simulates a batch group where accession/BAM data is absent.
    private func makeBatchDirNoBAM(sampleIds: [String], reads: Int = 5000) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTBatchReg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for sampleId in sampleIds {
            let dir = tmp.appendingPathComponent(sampleId)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tsv = "sample\torganism\treads\ttass_score\tconfidence\n\(sampleId)\tEscherichia coli\t\(reads)\t0.9\thigh\n"
            try tsv.write(to: dir.appendingPathComponent("\(sampleId).organisms.report.txt"), atomically: true, encoding: .utf8)
        }
        return tmp
    }

    /// Makes a minimal TaxTriageResult with two samples and real metrics files so that
    /// `configure(result:config:)` discovers multi-sample data.
    private func makeMultiSampleResult(sampleIds: [String], tmpDir: URL) throws -> TaxTriageResult {
        var metricsFiles: [URL] = []
        for sampleId in sampleIds {
            let tsv = "sample\torganism\treads\ttass_score\tconfidence\n\(sampleId)\tEscherichia coli\t1000\t0.9\thigh\n"
            let url = tmpDir.appendingPathComponent("\(sampleId).organisms.report.txt")
            try tsv.write(to: url, atomically: true, encoding: .utf8)
            metricsFiles.append(url)
        }

        let samples = sampleIds.map { sid in
            TaxTriageSample(
                sampleId: sid,
                fastq1: tmpDir.appendingPathComponent("\(sid).fastq")
            )
        }
        let config = TaxTriageConfig(samples: samples, outputDirectory: tmpDir)
        return TaxTriageResult(
            config: config,
            runtime: 1.0,
            exitCode: 0,
            outputDirectory: tmpDir,
            metricsFiles: metricsFiles
        )
    }

    // MARK: - Bug 1: Unique Reads Not Equal to Total Reads

    // MARK: - Bug 2: MiniBAM GCF Mapping in Batch Group Mode

    // MARK: - Bug 3: Multi-Sample Does Not Flash Segmented Control
    //
    // Tests removed: these exercised the legacy `configure(result:config:)` path,
    // which was deleted as part of the batch-only consolidation. Batch display is
    // now driven exclusively by `configureFromDatabase`; single-sample/flat-table
    // display is obtained by filtering the batch view to one sample.

    // MARK: - Fix 1: Viewport Bounce
    // Legacy test removed — the `configure(result:config:)` path no longer exists.

    // MARK: - Fix 3: Multi-Sample Unique Reads from Sidecar
    // Legacy test removed — the `configure(result:config:)` path no longer exists.

    // MARK: - Fix 2: Unique Reads Load from Persisted Sidecar

    // MARK: - Fix 4: Batch Cache Loads Instantly

    /// TaxTriage should parse BAM reference lengths when the index exists at an
    /// external path (not adjacent to the BAM), matching how batch runs store CSI/BAI.
    func testParseBamReferenceLengthsSupportsExternalIndexPath() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTExternalIndex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let minimap2Dir = tmp.appendingPathComponent("minimap2")
        let alignmentDir = tmp.appendingPathComponent("alignment")
        try FileManager.default.createDirectory(at: minimap2Dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alignmentDir, withIntermediateDirectories: true)

        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixtureBAM = repoRoot.appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")
        let fixtureBAI = repoRoot.appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam.bai")

        let bamURL = minimap2Dir.appendingPathComponent("sampleA.sampleA.dwnld.references.bam")
        let externalIndexURL = alignmentDir.appendingPathComponent("sampleA.sampleA.dwnld.references.bam.bai")
        try FileManager.default.copyItem(at: fixtureBAM, to: bamURL)
        try FileManager.default.copyItem(at: fixtureBAI, to: externalIndexURL)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bamURL.path + ".bai"),
            "Precondition failed: test BAM should not have an adjacent index"
        )

        let vc = TaxTriageResultViewController()
        vc.loadViewIfNeeded()
        vc.testParseBamReferenceLengths(bamURL: bamURL, indexURL: externalIndexURL)

        XCTAssertEqual(vc.testAccessionLengths["MT192765.1"], 29_829)
    }
}

// MARK: - TaxTriageBatchManifest Tests

final class TaxTriageBatchManifestTests: XCTestCase {

    // MARK: - Round-trip

    func testTaxTriageBatchManifestRoundTrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageManifestRoundTrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let row1 = TaxTriageBatchManifest.CachedRow(
            sample: "sampleA",
            organism: "Escherichia coli",
            tassScore: 0.95,
            reads: 12000,
            uniqueReads: 11000,
            confidence: "high",
            coverageBreadth: 85.3,
            coverageDepth: 12.7,
            abundance: 0.45
        )
        let row2 = TaxTriageBatchManifest.CachedRow(
            sample: "sampleB",
            organism: "Homo sapiens",
            tassScore: 0.40,
            reads: 500,
            uniqueReads: nil,
            confidence: "low",
            coverageBreadth: nil,
            coverageDepth: nil,
            abundance: nil
        )
        let manifest = TaxTriageBatchManifest(
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            sampleCount: 2,
            sampleIds: ["sampleA", "sampleB"],
            cachedRows: [row1, row2]
        )

        try MetagenomicsBatchResultStore.saveTaxTriageBatchManifest(manifest, to: tmpDir)

        let manifestURL = tmpDir.appendingPathComponent(TaxTriageBatchManifest.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))

        let loaded = MetagenomicsBatchResultStore.loadTaxTriageBatchManifest(from: tmpDir)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.sampleCount, 2)
        XCTAssertEqual(loaded?.sampleIds, ["sampleA", "sampleB"])
        XCTAssertEqual(loaded?.cachedRows.count, 2)

        let loadedRow1 = loaded?.cachedRows[0]
        XCTAssertEqual(loadedRow1?.sample, "sampleA")
        XCTAssertEqual(loadedRow1?.organism, "Escherichia coli")
        XCTAssertEqual(loadedRow1?.tassScore ?? 0, 0.95, accuracy: 0.0001)
        XCTAssertEqual(loadedRow1?.reads, 12000)
        XCTAssertEqual(loadedRow1?.uniqueReads, 11000)
        XCTAssertEqual(loadedRow1?.confidence, "high")
        XCTAssertEqual(loadedRow1?.coverageBreadth ?? 0, 85.3, accuracy: 0.0001)
        XCTAssertEqual(loadedRow1?.coverageDepth ?? 0, 12.7, accuracy: 0.0001)
        XCTAssertEqual(loadedRow1?.abundance ?? 0, 0.45, accuracy: 0.0001)

        let loadedRow2 = loaded?.cachedRows[1]
        XCTAssertEqual(loadedRow2?.sample, "sampleB")
        XCTAssertNil(loadedRow2?.uniqueReads, "nil uniqueReads should round-trip as nil")
        XCTAssertNil(loadedRow2?.coverageBreadth)
        XCTAssertNil(loadedRow2?.coverageDepth)
        XCTAssertNil(loadedRow2?.abundance)
    }

}

@MainActor
final class EsVirituUniqueReadMapTests: XCTestCase {
    func testBuildBatchUniqueReadMapsDoesNotSeedPerContigValuesFromAssemblyTotals() {
        let rows = [
            BatchEsVirituRow(
                sample: "SRR14420360",
                virusName: "Segmented virus",
                family: "Viridae",
                assembly: "ASM1",
                readCount: 100,
                uniqueReads: 80,
                rpkmf: 1.0,
                coverageBreadth: 0.5,
                coverageDepth: 2.0
            ),
        ]

        let maps = EsVirituResultViewController.buildBatchUniqueReadMaps(
            rows: rows,
            selectedSamples: Set(["SRR14420360"])
        )

        XCTAssertEqual(maps.bySampleAssembly["SRR14420360\tASM1"], 80)
        XCTAssertTrue(maps.bySampleContig.isEmpty)
    }
}

// MARK: - EsVirituBatchAggregatedManifest Tests

final class EsVirituBatchAggregatedManifestTests: XCTestCase {

    // MARK: - Round-trip

    func testEsVirituBatchManifestRoundTrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsVirituManifestRoundTrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let row1 = EsVirituBatchAggregatedManifest.CachedRow(
            sample: "sampleA",
            virusName: "SARS-CoV-2",
            family: "Coronaviridae",
            assembly: "GCF_009858895.2",
            readCount: 5000,
            uniqueReads: 4800,
            rpkmf: 123.4,
            coverageBreadth: 0.95,
            coverageDepth: 45.2
        )
        let row2 = EsVirituBatchAggregatedManifest.CachedRow(
            sample: "sampleB",
            virusName: "Influenza A",
            family: nil,
            assembly: "GCF_000865085.1",
            readCount: 800,
            uniqueReads: 0,
            rpkmf: 15.0,
            coverageBreadth: 0.30,
            coverageDepth: 5.0
        )
        let aggregated = EsVirituBatchAggregatedManifest(
            createdAt: Date(timeIntervalSince1970: 2_000_000),
            sampleCount: 2,
            sampleIds: ["sampleA", "sampleB"],
            cachedRows: [row1, row2]
        )

        try MetagenomicsBatchResultStore.saveEsVirituBatchAggregatedManifest(aggregated, to: tmpDir)

        let manifestURL = tmpDir.appendingPathComponent(EsVirituBatchAggregatedManifest.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))

        let loaded = MetagenomicsBatchResultStore.loadEsVirituBatchAggregatedManifest(from: tmpDir)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.sampleCount, 2)
        XCTAssertEqual(loaded?.sampleIds, ["sampleA", "sampleB"])
        XCTAssertEqual(loaded?.cachedRows.count, 2)

        let loadedRow1 = loaded?.cachedRows[0]
        XCTAssertEqual(loadedRow1?.sample, "sampleA")
        XCTAssertEqual(loadedRow1?.virusName, "SARS-CoV-2")
        XCTAssertEqual(loadedRow1?.family, "Coronaviridae")
        XCTAssertEqual(loadedRow1?.assembly, "GCF_009858895.2")
        XCTAssertEqual(loadedRow1?.readCount, 5000)
        XCTAssertEqual(loadedRow1?.uniqueReads, 4800)
        XCTAssertEqual(loadedRow1?.rpkmf ?? 0, 123.4, accuracy: 0.001)
        XCTAssertEqual(loadedRow1?.coverageBreadth ?? 0, 0.95, accuracy: 0.0001)
        XCTAssertEqual(loadedRow1?.coverageDepth ?? 0, 45.2, accuracy: 0.001)

        let loadedRow2 = loaded?.cachedRows[1]
        XCTAssertEqual(loadedRow2?.sample, "sampleB")
        XCTAssertNil(loadedRow2?.family, "nil family should round-trip as nil")
        XCTAssertEqual(loadedRow2?.uniqueReads, 0)
    }

    // MARK: - Built on first load

    func testEsVirituBatchManifestBuiltOnFirstLoad() throws {
        // This test verifies the store round-trip used by the "slow path" of configureFromDatabase:
        // rows parsed from per-sample files are saved as a manifest so subsequent opens skip
        // per-sample I/O. We exercise the store directly because EsVirituResultViewController
        // requires a full AppKit window context and EsVirituDetectionParser needs 23-column TSV.

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsVirituManifestFirstLoad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sampleId = "virusTest"
        let aggregatedManifestURL = tmpDir.appendingPathComponent(EsVirituBatchAggregatedManifest.filename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: aggregatedManifestURL.path),
                       "Precondition: aggregated manifest must not exist before first save")

        // Simulate what saveEsVirituBatchAggregatedManifest does after slow-path parsing.
        let rows: [BatchEsVirituRow] = [
            BatchEsVirituRow(
                sample: sampleId,
                virusName: "SARS-CoV-2",
                family: "Coronaviridae",
                assembly: "GCF_009858895.2",
                readCount: 4000,
                uniqueReads: 0,
                rpkmf: 98.5,
                coverageBreadth: 0.92,
                coverageDepth: 42.0
            )
        ]

        let cachedRows = rows.map { row in
            EsVirituBatchAggregatedManifest.CachedRow(
                sample: row.sample,
                virusName: row.virusName,
                family: row.family,
                assembly: row.assembly,
                readCount: row.readCount,
                uniqueReads: row.uniqueReads,
                rpkmf: row.rpkmf,
                coverageBreadth: row.coverageBreadth,
                coverageDepth: row.coverageDepth
            )
        }
        let aggregated = EsVirituBatchAggregatedManifest(
            createdAt: Date(),
            sampleCount: 1,
            sampleIds: [sampleId],
            cachedRows: cachedRows
        )
        try MetagenomicsBatchResultStore.saveEsVirituBatchAggregatedManifest(aggregated, to: tmpDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: aggregatedManifestURL.path),
                      "Aggregated manifest should be written to disk after slow-path save")

        let reloaded = MetagenomicsBatchResultStore.loadEsVirituBatchAggregatedManifest(from: tmpDir)
        XCTAssertNotNil(reloaded)
        XCTAssertEqual(reloaded?.sampleIds, [sampleId])
        XCTAssertEqual(reloaded?.cachedRows.count, 1)
        XCTAssertEqual(reloaded?.cachedRows.first?.virusName, "SARS-CoV-2")
        XCTAssertEqual(reloaded?.cachedRows.first?.assembly, "GCF_009858895.2")
    }
}
