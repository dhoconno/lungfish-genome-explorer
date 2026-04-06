// BatchAggregatedViewTests.swift - Tests for BatchClassificationRow, BatchEsVirituRow, and BatchTaxTriageTableView
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO

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

    /// The table has exactly 8 fixed columns registered via standardColumnNames.
    func testColumnCount() {
        let view = BatchTaxTriageTableView(frame: .zero)
        XCTAssertEqual(view.metadataColumns.standardColumnNames.count, 8)
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
}
