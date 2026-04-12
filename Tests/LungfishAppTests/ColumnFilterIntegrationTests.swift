// ColumnFilterIntegrationTests.swift - Integration tests for per-column filtering
// and metadata joins across Kraken2 and EsViritu taxonomy views.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Testing
import AppKit
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

// MARK: - Shared Test Helpers

@MainActor
private func makeMetadataStore(
    samples: [String],
    columns: [String],
    values: [[String]]
) throws -> SampleMetadataStore {
    var lines = [(["sample_id"] + columns).joined(separator: "\t")]
    for (i, sample) in samples.enumerated() {
        let row = [sample] + (i < values.count ? values[i] : Array(repeating: "", count: columns.count))
        lines.append(row.joined(separator: "\t"))
    }
    let tsv = lines.joined(separator: "\n") + "\n"
    return try SampleMetadataStore(csvData: Data(tsv.utf8), knownSampleIds: Set(samples))
}

// MARK: - ColumnFilter Application Tests

@Suite("ColumnFilter — Filtering Taxonomy Rows")
@MainActor
struct ColumnFilterApplicationTests {

    // MARK: - Kraken2 TaxonNode Filtering

    @Test("Numeric filter ≥ on clade reads filters TaxonNode children")
    func numericFilterOnCladeReads() {
        let parent = TaxonNode(
            taxId: 1, name: "root", rank: .root, depth: 0,
            readsDirect: 0, readsClade: 1000, fractionClade: 1.0, fractionDirect: 0.0, parentTaxId: nil
        )
        let child1 = TaxonNode(
            taxId: 2, name: "Bacteria", rank: .domain, depth: 1,
            readsDirect: 50, readsClade: 800, fractionClade: 0.8, fractionDirect: 0.05, parentTaxId: 1
        )
        let child2 = TaxonNode(
            taxId: 3, name: "Archaea", rank: .domain, depth: 1,
            readsDirect: 10, readsClade: 200, fractionClade: 0.2, fractionDirect: 0.01, parentTaxId: 1
        )
        parent.children = [child1, child2]

        let filter = ColumnFilter(columnId: "reads", op: .greaterOrEqual, value: "500")

        // Reads column shows clade counts in Kraken2
        let filtered = parent.children.filter { filter.matchesNumeric(Double($0.readsClade)) }
        #expect(filtered.count == 1)
        #expect(filtered[0].name == "Bacteria")
    }

    @Test("Text contains filter on taxon name")
    func textContainsFilterOnName() {
        let nodes = [
            ("Bacteria", 800), ("Archaea", 200), ("Bacteroides", 100),
        ].map { name, reads in
            TaxonNode(
                taxId: Int.random(in: 1...99999), name: name, rank: .domain, depth: 1,
                readsDirect: 0, readsClade: reads, fractionClade: 0.0, fractionDirect: 0.0, parentTaxId: nil
            )
        }

        let filter = ColumnFilter(columnId: "name", op: .contains, value: "bacter")
        let filtered = nodes.filter { filter.matchesString($0.name) }
        #expect(filtered.count == 2)
        #expect(Set(filtered.map(\.name)) == Set(["Bacteria", "Bacteroides"]))
    }

    @Test("Multiple filters compose as AND")
    func multipleFiltersComposeAsAnd() {
        let nodes = [
            ("Bacteria", 800), ("Archaea", 200), ("Viruses", 600),
        ].map { name, reads in
            TaxonNode(
                taxId: Int.random(in: 1...99999), name: name, rank: .domain, depth: 1,
                readsDirect: 0, readsClade: reads, fractionClade: 0.0, fractionDirect: 0.0, parentTaxId: nil
            )
        }

        let filters: [ColumnFilter] = [
            ColumnFilter(columnId: "reads", op: .greaterOrEqual, value: "500"),
            ColumnFilter(columnId: "name", op: .contains, value: "irus"),
        ]

        let filtered = nodes.filter { node in
            filters.allSatisfy { filter in
                switch filter.columnId {
                case "reads": return filter.matchesNumeric(Double(node.readsClade))
                case "name": return filter.matchesString(node.name)
                default: return true
                }
            }
        }

        // Only Viruses (600, contains "irus") passes both — Bacteria has 800 reads but no "irus"
        #expect(filtered.count == 1)
        #expect(filtered[0].name == "Viruses")
    }

    @Test("Clear filter restores all rows")
    func clearFilterRestoresAll() {
        let values = [100.0, 200.0, 300.0]
        let filter = ColumnFilter(columnId: "reads", op: .greaterOrEqual, value: "250")

        let filtered = values.filter { filter.matchesNumeric($0) }
        #expect(filtered.count == 1)

        let cleared = ColumnFilter(columnId: "reads", op: .greaterOrEqual, value: "")
        let restored = values.filter { cleared.matchesNumeric($0) }
        #expect(restored.count == 3)
    }

    // MARK: - Kraken2 Batch Row Filtering

    @Test("BatchClassificationRow filtered by numeric column")
    func batchClassificationNumericFilter() {
        let rows = [
            BatchClassificationRow(sample: "S1", taxonName: "E. coli", taxId: 562, rank: "S", rankDisplayName: "Species", readsDirect: 100, readsClade: 500, percentage: 5.0),
            BatchClassificationRow(sample: "S1", taxonName: "K. pneumoniae", taxId: 573, rank: "S", rankDisplayName: "Species", readsDirect: 50, readsClade: 200, percentage: 2.0),
            BatchClassificationRow(sample: "S2", taxonName: "E. coli", taxId: 562, rank: "S", rankDisplayName: "Species", readsDirect: 300, readsClade: 1000, percentage: 10.0),
        ]

        let filter = ColumnFilter(columnId: "readsClade", op: .greaterOrEqual, value: "400")
        let filtered = rows.filter { filter.matchesNumeric(Double($0.readsClade)) }
        #expect(filtered.count == 2)
        #expect(filtered.allSatisfy { $0.readsClade >= 400 })
    }

    @Test("BatchClassificationRow filtered by text sample column")
    func batchClassificationTextFilter() {
        let rows = [
            BatchClassificationRow(sample: "SRR001", taxonName: "E. coli", taxId: 562, rank: "S", rankDisplayName: "Species", readsDirect: 100, readsClade: 500, percentage: 5.0),
            BatchClassificationRow(sample: "SRR002", taxonName: "E. coli", taxId: 562, rank: "S", rankDisplayName: "Species", readsDirect: 200, readsClade: 800, percentage: 8.0),
        ]

        let filter = ColumnFilter(columnId: "sample", op: .equal, value: "SRR001")
        let filtered = rows.filter { filter.matchesString($0.sample) }
        #expect(filtered.count == 1)
        #expect(filtered[0].sample == "SRR001")
    }
}

// MARK: - Metadata Join Tests

@Suite("Metadata Join — Column Values")
@MainActor
struct MetadataJoinTests {

    @Test("MetadataColumnController returns correct value for per-row sample ID")
    func perRowMetadataLookup() throws {
        let store = try makeMetadataStore(
            samples: ["S1", "S2", "S3"],
            columns: ["organism", "read_count"],
            values: [
                ["Homo sapiens", "12500000"],
                ["Mus musculus", "9800000"],
                ["Homo sapiens", "15200000"],
            ]
        )

        let controller = MetadataColumnController()
        let table = NSTableView()
        controller.install(on: table)
        controller.update(store: store, sampleId: nil)
        controller.visibleColumns = Set(["organism", "read_count"])

        let orgColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("metadata_organism"))
        let readColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("metadata_read_count"))

        // Per-row lookup with different sample IDs
        let s1Cell = controller.cellForColumn(orgColumn, sampleId: "S1") as? NSTableCellView
        #expect(s1Cell?.textField?.stringValue == "Homo sapiens")

        let s2Cell = controller.cellForColumn(orgColumn, sampleId: "S2") as? NSTableCellView
        #expect(s2Cell?.textField?.stringValue == "Mus musculus")

        let s2ReadCell = controller.cellForColumn(readColumn, sampleId: "S2") as? NSTableCellView
        #expect(s2ReadCell?.textField?.stringValue == "9800000")
    }

    @Test("Metadata value missing for unknown sample shows em-dash")
    func metadataMissingValueShowsDash() throws {
        let store = try makeMetadataStore(
            samples: ["S1"],
            columns: ["location"],
            values: [["Boston"]]
        )

        let controller = MetadataColumnController()
        let table = NSTableView()
        controller.install(on: table)
        controller.update(store: store, sampleId: nil)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("metadata_location"))
        let cell = controller.cellForColumn(column, sampleId: "UNKNOWN") as? NSTableCellView
        #expect(cell?.textField?.stringValue == "\u{2014}")  // em dash
    }

    @Test("Metadata filter on numeric metadata column")
    func metadataNumericFilter() throws {
        let store = try makeMetadataStore(
            samples: ["S1", "S2", "S3"],
            columns: ["read_count"],
            values: [["12500000"], ["9800000"], ["15200000"]]
        )

        let filter = ColumnFilter(columnId: "metadata_read_count", op: .greaterOrEqual, value: "10M")

        // Simulate per-row metadata filter application
        let samples = ["S1", "S2", "S3"]
        let filtered = samples.filter { sample in
            guard let value = store.records[sample]?["read_count"],
                  let num = Double(value) else { return false }
            return filter.matchesNumeric(num)
        }

        #expect(filtered.count == 2)
        #expect(Set(filtered) == Set(["S1", "S3"]))  // 12.5M and 15.2M pass, 9.8M fails
    }

    @Test("Metadata filter on text metadata column")
    func metadataTextFilter() throws {
        let store = try makeMetadataStore(
            samples: ["S1", "S2", "S3"],
            columns: ["organism"],
            values: [["Homo sapiens"], ["Mus musculus"], ["Homo sapiens"]]
        )

        let filter = ColumnFilter(columnId: "metadata_organism", op: .contains, value: "Homo")

        let samples = ["S1", "S2", "S3"]
        let filtered = samples.filter { sample in
            guard let value = store.records[sample]?["organism"] else { return false }
            return filter.matchesString(value)
        }

        #expect(filtered.count == 2)
        #expect(Set(filtered) == Set(["S1", "S3"]))
    }

    @Test("SampleMetadataStore CSV round-trip preserves data")
    func csvRoundTrip() throws {
        let csv = """
        sample_id,organism,read_count,platform
        S1,Homo sapiens,12500000,NovaSeq
        S2,Mus musculus,9800000,NextSeq
        """
        let store = try SampleMetadataStore(
            csvData: Data(csv.utf8),
            knownSampleIds: Set(["S1", "S2"])
        )

        #expect(store.columnNames == ["organism", "read_count", "platform"])
        #expect(store.matchedSampleIds == Set(["S1", "S2"]))
        #expect(store.records["S1"]?["organism"] == "Homo sapiens")
        #expect(store.records["S1"]?["read_count"] == "12500000")
        #expect(store.records["S2"]?["platform"] == "NextSeq")
        #expect(store.unmatchedRecords.isEmpty)
    }

    @Test("SampleMetadataStore case-insensitive sample matching")
    func caseInsensitiveMatching() throws {
        let csv = "sample_id\tvalue\nsrr001\tA\nSRR002\tB\n"
        let store = try SampleMetadataStore(
            csvData: Data(csv.utf8),
            knownSampleIds: Set(["SRR001", "SRR002"])
        )

        // srr001 in CSV should match SRR001 in knownSampleIds
        #expect(store.matchedSampleIds.count == 2)
        #expect(store.records["SRR001"]?["value"] == "A")
        #expect(store.records["SRR002"]?["value"] == "B")
    }
}

// MARK: - Column Title Indicator Tests

@Suite("ColumnFilter — Title Indicators")
@MainActor
struct ColumnTitleIndicatorTests {

    @Test("Active filter adds diamond indicator to column title")
    func activeFilterAddsDiamond() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hits"))
        column.title = "Hits"

        var originals: [String: String] = [:]
        let filters: [String: ColumnFilter] = [
            "hits": ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "100"),
        ]

        ColumnFilter.updateColumnTitleIndicators(columns: [column], filters: filters, originalTitles: &originals)
        #expect(column.title.contains("◆"))
        #expect(column.title.hasPrefix("Hits"))
    }

    @Test("Clearing filter removes diamond indicator")
    func clearFilterRemovesDiamond() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hits"))
        column.title = "Hits"

        var originals: [String: String] = [:]

        // Apply filter
        let active: [String: ColumnFilter] = [
            "hits": ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "100"),
        ]
        ColumnFilter.updateColumnTitleIndicators(columns: [column], filters: active, originalTitles: &originals)
        #expect(column.title.contains("◆"))

        // Clear filter
        let empty: [String: ColumnFilter] = [:]
        ColumnFilter.updateColumnTitleIndicators(columns: [column], filters: empty, originalTitles: &originals)
        #expect(column.title == "Hits")
        #expect(!column.title.contains("◆"))
    }

    @Test("Multiple columns show indicators independently")
    func multipleColumnsIndependent() {
        let col1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hits"))
        col1.title = "Hits"
        let col2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col2.title = "Taxon"

        var originals: [String: String] = [:]
        let filters: [String: ColumnFilter] = [
            "hits": ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "100"),
        ]

        ColumnFilter.updateColumnTitleIndicators(columns: [col1, col2], filters: filters, originalTitles: &originals)
        #expect(col1.title.contains("◆"))
        #expect(!col2.title.contains("◆"))
        #expect(col2.title == "Taxon")
    }
}

// MARK: - EsViritu Batch Row Filtering

@Suite("EsViritu Batch — Column Filtering")
@MainActor
struct EsVirituBatchFilterTests {

    @Test("BatchEsVirituRow filtered by reads column")
    func filterByReads() {
        let rows = [
            BatchEsVirituRow(sample: "S1", virusName: "Norovirus GII", family: "Caliciviridae", assembly: "GCF_001", readCount: 500, uniqueReads: 400, rpkmf: 12.5, coverageBreadth: 0.85, coverageDepth: 3.0),
            BatchEsVirituRow(sample: "S1", virusName: "Rotavirus A", family: "Reoviridae", assembly: "GCF_002", readCount: 50, uniqueReads: 40, rpkmf: 1.2, coverageBreadth: 0.15, coverageDepth: 0.5),
            BatchEsVirituRow(sample: "S2", virusName: "Norovirus GII", family: "Caliciviridae", assembly: "GCF_001", readCount: 300, uniqueReads: 250, rpkmf: 8.0, coverageBreadth: 0.65, coverageDepth: 2.0),
        ]

        let filter = ColumnFilter(columnId: "reads", op: .greaterOrEqual, value: "200")
        let filtered = rows.filter { filter.matchesNumeric(Double($0.readCount)) }
        #expect(filtered.count == 2)
        #expect(filtered.allSatisfy { $0.readCount >= 200 })
    }

    @Test("BatchEsVirituRow filtered by family column")
    func filterByFamily() {
        let rows = [
            BatchEsVirituRow(sample: "S1", virusName: "Norovirus GII", family: "Caliciviridae", assembly: "GCF_001", readCount: 500, uniqueReads: 400, rpkmf: 12.5, coverageBreadth: 0.85, coverageDepth: 3.0),
            BatchEsVirituRow(sample: "S1", virusName: "Rotavirus A", family: "Reoviridae", assembly: "GCF_002", readCount: 50, uniqueReads: 40, rpkmf: 1.2, coverageBreadth: 0.15, coverageDepth: 0.5),
        ]

        let filter = ColumnFilter(columnId: "family", op: .contains, value: "Calici")
        let filtered = rows.filter { filter.matchesString($0.family ?? "") }
        #expect(filtered.count == 1)
        #expect(filtered[0].virusName == "Norovirus GII")
    }

    @Test("BatchEsVirituRow filtered by coverage with between operator")
    func filterByCoverageBetween() {
        let rows = [
            BatchEsVirituRow(sample: "S1", virusName: "A", family: nil, assembly: "G1", readCount: 100, uniqueReads: 80, rpkmf: 5.0, coverageBreadth: 0.10, coverageDepth: 1.0),
            BatchEsVirituRow(sample: "S1", virusName: "B", family: nil, assembly: "G2", readCount: 200, uniqueReads: 150, rpkmf: 8.0, coverageBreadth: 0.50, coverageDepth: 2.0),
            BatchEsVirituRow(sample: "S1", virusName: "C", family: nil, assembly: "G3", readCount: 300, uniqueReads: 250, rpkmf: 12.0, coverageBreadth: 0.90, coverageDepth: 4.0),
        ]

        // Coverage is displayed as percentage (breadth * 100)
        let filter = ColumnFilter(columnId: "coverage", op: .between, value: "20", value2: "60")
        let filtered = rows.filter { filter.matchesNumeric($0.coverageBreadth * 100.0) }
        #expect(filtered.count == 1)
        #expect(filtered[0].virusName == "B")  // 50% is between 20 and 60
    }

    @Test("EsViritu columnTypeHints declares correct types")
    func columnTypeHintsCorrect() {
        let table = BatchEsVirituTableView()
        let hints = table.columnTypeHints
        #expect(hints["reads"] == true)
        #expect(hints["uniqueReads"] == true)
        #expect(hints["rpkmf"] == true)
        #expect(hints["coverage"] == true)
        #expect(hints["sample"] == false)
        #expect(hints["name"] == false)
        #expect(hints["family"] == false)
    }
}

// MARK: - Kraken2 Batch Column Type Hints

@Suite("Kraken2 Batch — Column Type Hints")
@MainActor
struct Kraken2BatchColumnTypeTests {

    @Test("BatchClassificationTableView declares correct column types")
    func columnTypeHintsCorrect() {
        let table = BatchClassificationTableView()
        let hints = table.columnTypeHints
        #expect(hints["readsDirect"] == true)
        #expect(hints["readsClade"] == true)
        #expect(hints["percent"] == true)
        #expect(hints["sample"] == false)
        #expect(hints["name"] == false)
        #expect(hints["rank"] == false)
    }
}

// MARK: - TaxTriage Batch Column Filtering

@Suite("TaxTriage Batch — Column Filtering")
@MainActor
struct TaxTriageBatchFilterTests {

    private func makeRow(
        sample: String = "S1",
        organism: String = "Virus A",
        tassScore: Double = 0.8,
        reads: Int = 100,
        confidence: String = "high",
        coverageBreadth: Double = 50.0,
        coverageDepth: Double = 3.0,
        abundance: Double = 0.05
    ) -> TaxTriageMetric {
        TaxTriageMetric(
            sample: sample, taxId: nil, organism: organism, rank: "S",
            reads: reads, abundance: abundance,
            coverageBreadth: coverageBreadth, coverageDepth: coverageDepth,
            tassScore: tassScore, confidence: confidence,
            additionalFields: [:], sourceLineNumber: nil
        )
    }

    @Test("Filter by TASS score numeric column")
    func filterByTassScore() {
        let rows = [
            makeRow(organism: "Norovirus", tassScore: 0.95),
            makeRow(organism: "Rotavirus", tassScore: 0.45),
            makeRow(organism: "Astrovirus", tassScore: 0.72),
        ]

        let filter = ColumnFilter(columnId: "tassScore", op: .greaterOrEqual, value: "0.7")
        let filtered = rows.filter { filter.matchesNumeric($0.tassScore) }
        #expect(filtered.count == 2)
        #expect(Set(filtered.map(\.organism)) == Set(["Norovirus", "Astrovirus"]))
    }

    @Test("Filter by organism text column")
    func filterByOrganism() {
        let rows = [
            makeRow(organism: "Norovirus GII"),
            makeRow(organism: "Rotavirus A"),
            makeRow(organism: "Norovirus GI"),
        ]

        let filter = ColumnFilter(columnId: "organism", op: .contains, value: "Norovirus")
        let filtered = rows.filter { filter.matchesString($0.organism) }
        #expect(filtered.count == 2)
    }

    @Test("Filter by reads with K suffix")
    func filterByReadsKSuffix() {
        let rows = [
            makeRow(organism: "A", reads: 500),
            makeRow(organism: "B", reads: 1500),
            makeRow(organism: "C", reads: 3000),
        ]

        let filter = ColumnFilter(columnId: "reads", op: .greaterOrEqual, value: "1K")
        let filtered = rows.filter { filter.matchesNumeric(Double($0.reads)) }
        #expect(filtered.count == 2)
        #expect(filtered.allSatisfy { $0.reads >= 1000 })
    }

    @Test("Filter by confidence text column")
    func filterByConfidence() {
        let rows = [
            makeRow(organism: "A", confidence: "high"),
            makeRow(organism: "B", confidence: "medium"),
            makeRow(organism: "C", confidence: "low"),
            makeRow(organism: "D", confidence: "high"),
        ]

        let filter = ColumnFilter(columnId: "confidence", op: .equal, value: "high")
        let filtered = rows.filter { filter.matchesString($0.confidence ?? "") }
        #expect(filtered.count == 2)
    }

    @Test("Filter by coverage breadth between")
    func filterByCoverageBetween() {
        let rows = [
            makeRow(organism: "A", coverageBreadth: 10.0),
            makeRow(organism: "B", coverageBreadth: 45.0),
            makeRow(organism: "C", coverageBreadth: 80.0),
        ]

        let filter = ColumnFilter(columnId: "coverageBreadth", op: .between, value: "30", value2: "60")
        let filtered = rows.filter { filter.matchesNumeric($0.coverageBreadth ?? 0) }
        #expect(filtered.count == 1)
        #expect(filtered[0].organism == "B")
    }

    @Test("BatchTaxTriageTableView declares correct column types")
    func columnTypeHintsCorrect() {
        let table = BatchTaxTriageTableView()
        let hints = table.columnTypeHints
        #expect(hints["tassScore"] == true)
        #expect(hints["reads"] == true)
        #expect(hints["uniqueReads"] == true)
        #expect(hints["coverageBreadth"] == true)
        #expect(hints["coverageDepth"] == true)
        #expect(hints["abundance"] == true)
        #expect(hints["sample"] == false)
        #expect(hints["organism"] == false)
        #expect(hints["confidence"] == false)
    }

    @Test("Metadata filter on TaxTriage rows via sample ID join")
    func metadataFilterOnTaxTriageRows() throws {
        let store = try makeMetadataStore(
            samples: ["S1", "S2"],
            columns: ["organism", "read_count"],
            values: [["Homo sapiens", "12000000"], ["Mus musculus", "8000000"]]
        )

        let rows = [
            makeRow(sample: "S1", organism: "Norovirus"),
            makeRow(sample: "S2", organism: "Rotavirus"),
            makeRow(sample: "S1", organism: "Astrovirus"),
        ]

        // Filter metadata column: read_count >= 10M
        let filter = ColumnFilter(columnId: "metadata_read_count", op: .greaterOrEqual, value: "10M")
        let filtered = rows.filter { row in
            guard let sid = row.sample,
                  let value = store.records[sid]?["read_count"],
                  let num = Double(value) else { return false }
            return filter.matchesNumeric(num)
        }

        // Only S1 rows pass (12M >= 10M), S2 fails (8M < 10M)
        #expect(filtered.count == 2)
        #expect(filtered.allSatisfy { $0.sample == "S1" })
    }
}
