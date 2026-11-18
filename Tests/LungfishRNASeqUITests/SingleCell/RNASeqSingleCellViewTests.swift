// RNASeqSingleCellViewTests.swift - The single-cell view shows what cells.sqlite holds and writes nothing (lane RS-SC-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishRNASeqUI

final class RNASeqSingleCellViewTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-single-cell-view") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    /// Opens `url` in the view of the surface, as the viewer does, and waits for the cell summary.
    @MainActor
    private func open(_ url: URL) async throws -> (RNASeqResultSurface, RNASeqSingleCellViewController) {
        let surface = RNASeqResultSurface()
        surface.present(RNASeqResultSurface.read(url), bundleURL: url)
        let view = try XCTUnwrap(surface.controller.singleCell, "a single-cell result hosts the single-cell view")
        await view.loading?.value
        return (surface, view)
    }

    @MainActor
    func testTheSummaryIsTheSamplesRowTheOriginAndTheQualityAsWritten() async throws {
        let url = try RNASeqSingleCellFixtures.write(.cellRanger, into: root)
        let database = try RNASeqCellsDatabase(url: url.appendingPathComponent(RNASeqCellsDatabase.filename))
        let (_, view) = try await open(url)
        let summary = try XCTUnwrap(view.summary, view.failureWords ?? "no summary")
        XCTAssertEqual(summary.samples, try database.samples())
        XCTAssertEqual(summary.cellCount, try database.cellCount())
        let result = try RNASeqResultBundle.load(from: url)
        XCTAssertEqual(summary.tool, result.manifest.origin.tool)
        XCTAssertEqual(summary.toolVersion, "3.0.0", "Cell Ranger states its version on line 2 of its matrix")
        XCTAssertEqual(summary.quality, result.quality)
        let text = RNASeqSingleCellFixtures.texts(in: view.view)
        let sample = try XCTUnwrap(try database.samples().first)
        XCTAssertEqual([text["rnaseq-sc-samples-0-0"], text["rnaseq-sc-samples-0-1"], text["rnaseq-sc-samples-0-2"], text["rnaseq-sc-samples-0-3"]],
                       [sample.name, String(sample.cells), String(sample.features), String(sample.entries)])
        XCTAssertEqual(text["rnaseq-sc-tool"], result.manifest.origin.tool)
        XCTAssertEqual(text["rnaseq-sc-tool-version"], "3.0.0")
        let quality = try XCTUnwrap(result.quality, "the Cell Ranger import keeps metrics_summary.csv's numbers")
        for (column, value) in quality.rows[0].values.enumerated() {
            XCTAssertEqual(text["rnaseq-sc-quality-0-\(column + 1)"], value ?? "", quality.columns[column])
        }
        XCTAssertEqual(text["rnaseq-sc-rank-words"], RNASeqSingleCellWords.rankPlot)
        XCTAssertEqual(text["rnaseq-sc-no-not-host"], RNASeqSingleCellWords.noNotHost, "with no not-host table the third histogram says so")
        XCTAssertEqual(summary.notHost, [])
        let ids = Set(RNASeqSingleCellFixtures.allSubviews(of: view.view).map { $0.accessibilityIdentifier() })
        XCTAssertTrue(ids.isSuperset(of: ["rnaseq-sc-rank-plot", "rnaseq-sc-histogram-umis", "rnaseq-sc-histogram-genes", "rnaseq-sc-cells"]))
    }

    @MainActor
    func testTheFirstPageIsTheFirstPageOfTheCellsTable() async throws {
        let url = try RNASeqSingleCellFixtures.write(.starsolo, into: root)
        let database = try RNASeqCellsDatabase(url: url.appendingPathComponent(RNASeqCellsDatabase.filename))
        let (_, view) = try await open(url)
        let source = try XCTUnwrap(view.tableSource)
        let expected = try database.cells(offset: 0, limit: RNASeqSingleCellPages.pageSize)
        XCTAssertEqual(try source.pages.page(0).map(\.cell), expected)
        XCTAssertEqual(source.pages.count, try database.cellCount())
        XCTAssertEqual(view.cellsTable.numberOfRows, try database.cellCount())
        XCTAssertEqual(view.summary?.toolVersion, RNASeqResultBundle.notRecordedText, "STARsolo states no version")
        for (row, cell) in expected.prefix(20).enumerated() {
            XCTAssertEqual(["cell", "barcode", "umis", "genes"].map { source.text(row: row, column: $0) },
                           [String(cell.cell), cell.barcode, String(cell.umis), String(cell.genes)])
        }
        let last = source.pages.count - 1
        XCTAssertEqual(source.text(row: last, column: "barcode"), try database.cells(offset: last, limit: 1).first?.barcode)
        XCTAssertEqual(source.text(row: last + 1, column: "barcode"), "", "a row past the cells shows nothing")
    }

    func testRowsPastTheFirstPageAreTheRowsOfTheCellsTable() throws {
        // The fixtures hold 200 cells, one page, so this file of ten pages and 37 cells reaches the later pages.
        let url = root.appendingPathComponent(RNASeqCellsDatabase.filename)
        let writer = try RNASeqCellsDatabaseWriter(url: url)
        let count = RNASeqSingleCellPages.pageSize * 10 + 37
        try writer.addSample(1, name: "S1", matrix: "m", size: MatrixMarketSize(rows: 1, columns: count, entries: count))
        try writer.addCells(sample: 1, firstCell: 1, barcodes: (1...count).map { "BC\($0)" },
                            umis: (1...count).map { UInt64($0) }, genes: (1...count).map { UInt32($0 % 7) })
        try writer.finish()
        let pages = try RNASeqSingleCellPages(cellsURL: url)
        let database = try RNASeqCellsDatabase(url: url)
        XCTAssertEqual(pages.count, count)
        for row in [0, 199, 200, 201, 1999, 2000, count - 1] {
            XCTAssertEqual(pages.row(row)?.cell, try database.cells(offset: row, limit: 1).first, "row \(row)")
        }
        XCTAssertNil(pages.row(count))
        XCTAssertEqual(try pages.page(10).count, 37)
        XCTAssertEqual(try pages.page(11), [])
        pages.close()
        XCTAssertNil(pages.row(0), "a closed table reads nothing")
    }

    @MainActor
    func testTheFlagColumnReadsTheFlagWordsForAVirusAndABacterium() async throws {
        for (notHost, words, umis, masked, near) in [
            (RNASeqSingleCellFixtures.NotHost.virus, "viral RNA above ambient", "10", "0", "8 of 10"),
            (.bacterium, "bacterial RNA above ambient", "6", "3", "6 of 6"),
        ] {
            let url = try RNASeqSingleCellFixtures.write(.starsolo, into: root.appendingPathComponent("\(notHost)"), notHost: notHost)
            let (_, view) = try await open(url)
            let source = try XCTUnwrap(view.tableSource, view.failureWords ?? "")
            let extra = try XCTUnwrap(view.summary?.extras.first)
            let prefix = "not-host-\(extra.extra)"
            // The mask line shows the file's words, and a virus has no rRNA to mask, so its file holds none and the line says so.
            XCTAssertEqual(extra.maskWords.isEmpty, notHost == .virus)
            XCTAssertEqual(RNASeqSingleCellFixtures.texts(in: view.view)["rnaseq-sc-mask-words-\(extra.extra)"],
                           notHost == .virus ? "No rRNA mask, none needed" : extra.maskWords)
            XCTAssertEqual(source.text(row: 0, column: "\(prefix)-flag"), words)
            XCTAssertEqual(source.text(row: 0, column: "\(prefix)-umis"), umis)
            XCTAssertEqual(source.text(row: 0, column: "\(prefix)-masked"), masked)
            XCTAssertEqual(source.text(row: 0, column: "\(prefix)-nm01"), near)
            XCTAssertEqual(source.columns.map(\.title).last, "\(extra.name) flag")
            let calls = try RNASeqCellsDatabase(url: url.appendingPathComponent(RNASeqCellsDatabase.filename)).notHostCalls()
            for row in 0..<40 {
                let cell = row + 1
                XCTAssertEqual(source.text(row: row, column: "\(prefix)-flag"), calls.first { $0.cell == cell }?.flag ?? "", "cell \(cell)")
            }
            let histogram = try XCTUnwrap(view.summary?.notHost.first)
            XCTAssertEqual(histogram.bins, try RNASeqCellsDatabase.bins(of: .notHostUMIs(extra: extra.extra), inFileAt: url.appendingPathComponent(RNASeqCellsDatabase.filename)))
            XCTAssertNil(RNASeqSingleCellFixtures.texts(in: view.view)["rnaseq-sc-no-not-host"])
        }
    }

    @MainActor
    func testARowWithNullPAndQShowsTheTablesWords() async throws {
        // A bacterium with no rRNA mask gets no flag and the words that say why (BIO-NOTHOST-BARCODE item 6).
        let url = try RNASeqSingleCellFixtures.write(.starsolo, into: root, notHost: .unmaskedBacterium)
        let cells = url.appendingPathComponent(RNASeqCellsDatabase.filename)
        let calls = try RNASeqCellsDatabase(url: cells).notHostCalls()
        let (_, view) = try await open(url)
        let source = try XCTUnwrap(view.tableSource)
        let nulls = calls.filter { $0.p == nil && $0.q == nil }
        XCTAssertEqual(nulls.count, calls.count, "a bacterium with no mask gets no p or q in any cell")
        XCTAssertFalse(nulls.isEmpty)
        for call in nulls.prefix(10) {
            XCTAssertEqual(source.text(row: call.cell - 1, column: "not-host-\(call.extra)-flag"), "not computed: no rRNA mask for mtb-erdman")
        }
        XCTAssertEqual(source.text(row: 0, column: "not-host-1-umis"), "9", "the counts still show, all nine in the default column")
    }

    @MainActor
    func testEveryFileIsTheSameBeforeTheViewOpensAndAfterItClosesWithNoJournalLeft() async throws {
        let url = try RNASeqSingleCellFixtures.write(.starsolo, into: root, notHost: .virus)
        let before = try RNASeqSingleCellFixtures.snapshot(url)
        XCTAssertTrue(before.keys.contains("/\(RNASeqCellsDatabase.filename)"))
        do {
            let (surface, view) = try await open(url)
            let source = try XCTUnwrap(view.tableSource)
            for row in stride(from: 0, to: source.pages.count, by: 97) { _ = source.text(row: row, column: "not-host-1-flag") }
            view.close()
            surface.controller.show(.failed("closed"), bundleURL: url)
        }
        let after = try RNASeqSingleCellFixtures.snapshot(url)
        XCTAssertEqual(after, before, "the view changes no byte and adds no file")
        for name in ["-wal", "-shm", "-journal"] {
            XCTAssertNil(after["/\(RNASeqCellsDatabase.filename)\(name)"], name)
        }
    }

    @MainActor
    func testNoShownWordSaysInfectedAndNothingIsOfferedForEdit() async throws {
        let url = try RNASeqSingleCellFixtures.write(.starsolo, into: root, notHost: .virus)
        let (surface, view) = try await open(url)
        let source = try XCTUnwrap(view.tableSource)
        let views = RNASeqSingleCellFixtures.allSubviews(of: surface.viewController.view)
        var shown = views.compactMap { ($0 as? NSTextField)?.stringValue }
        shown += views.compactMap { $0.accessibilityLabel() } + views.compactMap { $0.accessibilityValue() as? String }
        shown += source.columns.map(\.title) + (0..<50).flatMap { row in source.columns.map { source.text(row: row, column: $0.id) } }
        shown += [RNASeqSingleCellWords.rankPlot, RNASeqSingleCellWords.noNotHost, RNASeqSingleCellWords.noCellsSummary,
                  RNASeqSingleCellWords.noQuality, RNASeqSingleCellWords.noCells]
        XCTAssertTrue(shown.contains("viral RNA above ambient"))
        XCTAssertFalse(shown.joined(separator: "\n").lowercased().contains("infected"))
        XCTAssertFalse(views.contains { $0 is NSButton }, "the view offers no button")
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.allSatisfy { !$0.isEditable }, "no field is editable")
        XCTAssertTrue(view.cellsTable.tableColumns.allSatisfy { !$0.isEditable })
        XCTAssertFalse(source.tableView(view.cellsTable, shouldEdit: view.cellsTable.tableColumns.first, row: 0))
    }

    @MainActor
    func testACellsFileOfANewerSchemaShowsTheManifestsWordsAndNoTable() async throws {
        let url = try RNASeqSingleCellFixtures.write(.starsolo, into: root)
        let result = try RNASeqResultBundle.load(from: url)
        // A copy of the file whose meta says schema 9 stands for the result's cells.sqlite.
        let copy = root.appendingPathComponent("newer.lungfishrnaseq", isDirectory: true)
        try FileManager.default.copyItem(at: url, to: copy)
        let cells = copy.appendingPathComponent(RNASeqCellsDatabase.filename)
        try RNASeqSingleCellFixtures.setSchema(9, of: cells)
        let words = "This RNA-seq result was written by a newer LGE (schema 9). Open it with that version or a later one."
        XCTAssertEqual(RNASeqSingleCellSummary.read(result, bundleURL: copy), .failed(words))
        let view = RNASeqSingleCellViewController(nibName: nil, bundle: nil)
        view.configure(result: result, bundleURL: copy)
        await view.loading?.value
        XCTAssertEqual(view.failureWords, words)
        XCTAssertNil(view.tableSource)
        XCTAssertEqual(view.cellsTable.numberOfRows, 0)
        XCTAssertEqual(RNASeqSingleCellFixtures.texts(in: view.view)["rnaseq-sc-failure"], words)
    }

    @MainActor
    func testTheQualityTableLiesInsideTheViewAtTheDefaultWidth() async throws {
        // Cell Ranger keeps 20 metrics, the longest "Reads Mapped Confidently to Intergenic Regions". The top pane does not
        // scroll sideways, so a table with one column for each metric runs past the edge and no one can read it.
        let url = try RNASeqSingleCellFixtures.write(.cellRanger, into: root)
        let (surface, view) = try await open(url)
        let host = surface.viewController.view
        host.setFrameSize(NSSize(width: 1100, height: 900))
        host.layoutSubtreeIfNeeded()
        let fields = RNASeqSingleCellFixtures.allSubviews(of: view.view).compactMap { $0 as? NSTextField }
            .filter { $0.accessibilityIdentifier().hasPrefix("rnaseq-sc-quality-") }
        XCTAssertGreaterThan(fields.count, 20, "twenty metrics and their values")
        for field in fields {
            XCTAssertLessThanOrEqual(field.convert(field.bounds, to: host).maxX, 1100, "\(field.accessibilityIdentifier()) lies past the right edge")
            XCTAssertGreaterThanOrEqual(field.frame.width, field.intrinsicContentSize.width - 1, "\(field.stringValue) is cut short")
        }
    }

    @MainActor
    func testEveryStateOfTheViewNamesTheNextStep() async throws {
        for words in [RNASeqSingleCellWords.noNotHost, RNASeqSingleCellWords.noCellsSummary, RNASeqSingleCellWords.noCells] {
            XCTAssertTrue(words.lowercased().contains("import"), words)
        }
        let url = try RNASeqSingleCellFixtures.write(.starsolo, into: root)
        let result = try RNASeqResultBundle.load(from: url)
        let copy = root.appendingPathComponent("broken.lungfishrnaseq", isDirectory: true)
        try FileManager.default.copyItem(at: url, to: copy)
        try Data("not a database".utf8).write(to: copy.appendingPathComponent(RNASeqCellsDatabase.filename))
        guard case .failed(let words) = RNASeqSingleCellSummary.read(result, bundleURL: copy) else { return XCTFail("a file that is not a database fails in words") }
        XCTAssertTrue(words.hasSuffix("Check that the result folder is whole, or import it again."), words)
    }
}
