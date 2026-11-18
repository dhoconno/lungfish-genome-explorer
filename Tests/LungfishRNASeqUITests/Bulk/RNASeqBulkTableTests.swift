// RNASeqBulkTableTests.swift - The count tables of the bulk view show the file as printed (5.4 RS-BULK-VIEW M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishRNASeqUI
@testable import LungfishWorkflow

final class RNASeqBulkTableTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rnaseq-bulk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func text(_ url: URL, _ path: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    @MainActor
    func testEveryCellOfTheSalmonC1GeneTableEqualsTheFileAsPrinted() async throws {
        let url = try RNASeqBulkFixtures.importSalmonC1(into: root)
        let controller = try await RNASeqBulkFixtures.show(url)
        let model = controller.model
        XCTAssertEqual(model.tables.map(\.path), ["counts/genes.counts.tsv", "counts/transcripts.counts.tsv"])
        let file = try text(url, "counts/genes.counts.tsv")
        XCTAssertEqual(RNASeqBulkFixtures.printed(model, table: 0), file, "every cell of the gene table reads as the file prints it")
        XCTAssertEqual(RNASeqBulkFixtures.printed(model, table: 1), try text(url, "counts/transcripts.counts.tsv"))
        XCTAssertTrue(file.split(separator: "\n").dropFirst().contains { $0.split(separator: "\t").dropFirst().contains { $0.contains(".") } },
                      "the table holds counts that are not whole, so the check reads more than integers")

        // The table on screen shows the model's cells: the id, the three columns of genes.tsv, then each count.
        let table = controller.countTables[0]
        XCTAssertEqual(controller.numberOfRows(in: table), model.tables[0].rowCount)
        XCTAssertEqual(table.tableColumns.map(\.title), ["Gene", "Name", "Biotype", "Not host"] + RNASeqFixtures.salmonRunIDs)
        let lines = file.split(separator: "\n").dropFirst().map { $0.split(separator: "\t").map(String.init) }
        for (row, cells) in lines.enumerated() {
            let shown = (0..<table.numberOfColumns).map { column -> String in
                let field = controller.tableView(table, viewFor: table.tableColumns[column], row: row) as? NSTextField
                return field?.stringValue ?? "<no field>"
            }
            XCTAssertEqual([shown[0]] + shown.dropFirst(4), cells, "row \(row + 2) of counts/genes.counts.tsv")
            XCTAssertEqual(Array(shown[1...3]), Array(repeating: "Not recorded", count: 3), "an import's genes.tsv holds ids only")
        }
    }

    @MainActor
    func testTheHeaderNamesTheUnitOfTheCountsEntry() async throws {
        let c1 = try await RNASeqBulkFixtures.show(try RNASeqBulkFixtures.importSalmonC1(into: root))
        XCTAssertEqual(c1.model.tables[0].unitWords, "estimated counts")
        XCTAssertEqual(c1.model.tables[0].caption, "Counts in estimated counts from counts/genes.counts.tsv, "
            + "\(c1.model.tables[0].rowCount) genes by 2 samples. Name, biotype and not host are as genes.tsv lists them.")
        let texts = Dictionary(uniqueKeysWithValues: RNASeqBulkFixtures.allSubviews(of: c1.view).compactMap { view -> (String, String)? in
            guard let field = view as? NSTextField, !field.accessibilityIdentifier().isEmpty else { return nil }
            return (field.accessibilityIdentifier(), field.stringValue)
        })
        XCTAssertEqual(texts["rnaseq-bulk-table-caption-0"], c1.model.tables[0].caption)
        XCTAssertEqual(c1.countTables[0].tableColumns[4].headerToolTip, "SRR896663, in estimated counts")

        let named = try await RNASeqBulkFixtures.show(try RNASeqBulkFixtures.writeNamed(into: root))
        XCTAssertEqual(named.model.tables.map(\.unitWords), ["reads", "reads"])
        XCTAssertTrue(named.model.tables[1].caption.hasPrefix("Masked counts in reads from counts/genes.masked.tsv"))
    }

    @MainActor
    func testTheGeneColumnsComeFromGenesTSVAndAnEmptyCellReadsNotRecorded() async throws {
        let url = try RNASeqBulkFixtures.writeNamed(into: root)
        let model = try await RNASeqBulkFixtures.show(url).model
        XCTAssertEqual(RNASeqBulkFixtures.printed(model, table: 0), try text(url, "counts/genes.counts.tsv"))
        XCTAssertEqual((0..<5).map { model.geneCells(table: 0, row: $0) }, [
            ["TP53", "protein_coding", "false"], ["GAPDH", "protein_coding", "false"], ["RNA5-8SN4", "rRNA", "false"],
            ["sars-cov-2", "virus", "true"], ["Not recorded", "Not recorded", "Not recorded"],
        ])
        XCTAssertEqual(model.shownCells(table: 0, row: 3), ["NC_045512.2", "sars-cov-2", "virus", "true", "7", "0", "1e-05"])
        XCTAssertEqual(model.shownCells(table: 0, row: 0), ["ENSG00000141510", "TP53", "protein_coding", "false", "120", "98.5", "0.25"])
    }

    @MainActor
    func testTheMaskedTableIsItsOwnTabAndNeverJoinedToTheDefault() async throws {
        let url = try RNASeqBulkFixtures.writeNamed(into: root)
        let controller = try await RNASeqBulkFixtures.show(url)
        let model = controller.model
        XCTAssertEqual(model.tables.map(\.title), ["Genes", "Genes, masked"])
        XCTAssertEqual(controller.tabView.tabViewItems.map(\.label), ["Genes", "Genes, masked", "Quality", "Correlation"])
        XCTAssertEqual(model.tables.map(\.sampleIDs), [["S1", "S2", "S3"], ["S1", "S2", "S3"]], "no column of one table joins the other")
        XCTAssertEqual(RNASeqBulkFixtures.printed(model, table: 1), try text(url, "counts/genes.masked.tsv"))
        XCTAssertEqual(controller.countTables.count, 2)
        XCTAssertEqual(controller.numberOfRows(in: controller.countTables[1]), 5)
    }

    @MainActor
    func testASearchForOneGeneIDOrOneNameKeepsOnlyItsRow() async throws {
        let c1 = try await RNASeqBulkFixtures.show(try RNASeqBulkFixtures.importSalmonC1(into: root))
        let ercc = "ERCC-00002"
        XCTAssertTrue(c1.model.tables[0].table.rows.contains { $0.id == ercc })
        c1.searchField.stringValue = ercc
        c1.searchField.sendAction(c1.searchField.action, to: c1.searchField.target)
        XCTAssertEqual(c1.model.searchText, ercc)
        XCTAssertEqual(c1.model.tables[0].visibleRows.map { c1.model.tables[0].table.rows[$0].id }, [ercc])
        XCTAssertEqual(c1.numberOfRows(in: c1.countTables[0]), 1)
        XCTAssertEqual(c1.shownText(tableTag: 0, column: 0, row: 0), ercc)

        let named = try await RNASeqBulkFixtures.show(try RNASeqBulkFixtures.writeNamed(into: root)).model
        named.search("tp53")
        XCTAssertEqual(named.tables.map { $0.visibleRows.map { named.tables[0].table.rows[$0].id } },
                       [["ENSG00000141510"], ["ENSG00000141510"]], "a name in any case keeps its row in each table")
        named.search("ENSG00000111640")
        XCTAssertEqual(named.tables[0].visibleRows, [1])
        named.search("no such gene")
        XCTAssertEqual(named.tables[0].visibleRows, [])
        named.search("")
        XCTAssertEqual(named.tables[0].visibleRows, [0, 1, 2, 3, 4])
    }

    @MainActor
    func testTheViewWritesNothingAndOffersOnlyTheSearchForEdit() async throws {
        let url = try RNASeqBulkFixtures.writeNamed(into: root)
        let before = try RNASeqBulkFixtures.snapshot(url)
        let controller = try await RNASeqBulkFixtures.show(url)
        controller.model.search("gapdh")
        controller.tabView.selectTabViewItem(at: 3)
        XCTAssertEqual(try RNASeqBulkFixtures.snapshot(url), before, "showing, searching and reading the quality change no file")
        let views = RNASeqBulkFixtures.allSubviews(of: controller.view) + controller.tabView.tabViewItems.compactMap(\.view)
            .flatMap { [$0] + RNASeqBulkFixtures.allSubviews(of: $0) }
        XCTAssertFalse(views.contains { $0 is NSButton }, "the view offers no button")
        let editable = views.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertEqual(editable.map { $0.accessibilityIdentifier() }, ["rnaseq-bulk-search"], "only the search field takes typing")
        XCTAssertTrue(controller.countTables.allSatisfy { $0.tableColumns.allSatisfy { !$0.isEditable } })
    }

    @MainActor
    func testEachRowHasAKeyboardAndVoiceOverRoute() async throws {
        let controller = try await RNASeqBulkFixtures.show(try RNASeqBulkFixtures.writeNamed(into: root))
        for table in controller.countTables + [controller.qualityTable] {
            XCTAssertTrue(table.acceptsFirstResponder, "a table takes the keys, so the arrow keys move between its rows")
            XCTAssertTrue(table.isAccessibilityElement())
            XCTAssertFalse(table.accessibilityLabel()?.isEmpty ?? true, "VoiceOver names the table")
        }
        XCTAssertEqual(controller.countTables[0].accessibilityLabel(), "Genes count table, reads")
        XCTAssertEqual(controller.searchField.accessibilityLabel(), "Search the count tables by feature id or gene name")
        XCTAssertEqual(controller.view.accessibilityIdentifier(), "rnaseq-bulk-view")
    }

    func testACountPrintsAsTheWriterPrintsIt() throws {
        let values: [Double] = [0, 3, 120, 98.5, 0.1 + 0.2, 5.7379999999999995, 1e-05, 123456789012345, 1e15, 2.5e15, -0.0]
        let table = RNASeqCountTable(sampleIDs: values.indices.map { "S\($0)" }, rows: [.init(id: "G", counts: values)])
        let line = String(decoding: try table.tsvData(), as: UTF8.self).split(separator: "\n")[1]
        XCTAssertEqual(line.split(separator: "\t").dropFirst().map(String.init), values.map(RNASeqBulkModel.countText))
    }
}
