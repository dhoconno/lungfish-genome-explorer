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
}
