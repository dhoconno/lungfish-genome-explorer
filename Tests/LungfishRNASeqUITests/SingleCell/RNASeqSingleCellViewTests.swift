// RNASeqSingleCellViewTests.swift - The single-cell view shows what cells.sqlite holds and writes nothing (lane RS-SC-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
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
        // One row for each metric: the metric's name is column 0 and the first sample's value is column 1.
        for (metric, value) in quality.rows[0].values.enumerated() {
            XCTAssertEqual(text["rnaseq-sc-quality-\(metric)-0"], quality.columns[metric])
            XCTAssertEqual(text["rnaseq-sc-quality-\(metric)-1"], value ?? RNASeqResultBundle.notRecordedText, quality.columns[metric])
        }
        XCTAssertNil(text["rnaseq-sc-rank-words"], "the rank plot's words left the view for its info button")
        XCTAssertEqual(text["rnaseq-sc-cell-map-words"], RNASeqSingleCellWords.cellMap)
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

    /// 5.6 Q1 and UX 5. The accessibility elements of the whole view in the order VoiceOver reaches them, from the summary
    /// down to the cells table. The first commit of lane TV-SCVIEW pinned this order at the base. Since then the cell map
    /// line is followed by its info button, and the rank plot's words are replaced, at their own place, by the plot's.
    @MainActor
    func testTheSummaryKeepsItsAccessibilityOrderWithoutANotHostTable() async throws {
        let url = try RNASeqSingleCellFixtures.write(.cellRanger, into: root)
        let (_, view) = try await open(url)
        XCTAssertEqual(SCViewAXPin.elements(in: view.view), [
            "text:Cell summary", "rnaseq-sc-samples",
            "text:Tool", "rnaseq-sc-tool", "text:Version", "rnaseq-sc-tool-version", "text:Cells", "rnaseq-sc-cell-count",
            "rnaseq-sc-cell-map-words", "info-rnaseq.singleCell.cellMapRoutes",
            "text:Quality", "rnaseq-sc-quality",
            "text:Barcode rank", "info-rnaseq.singleCell.rankPlot", "rnaseq-sc-rank-plot",
            "text:UMIs per cell", "rnaseq-sc-histogram-umis",
            "text:Genes per cell", "rnaseq-sc-histogram-genes",
            "text:Not-host UMIs per cell", "rnaseq-sc-no-not-host",
            "rnaseq-sc-cells",
        ])
    }

    /// Hosts `content` in a window, as the viewer does, so that layout runs and a popover has a window to show from.
    @MainActor
    private func host(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        content.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            RNASeqSingleCellFixtures.allSubviews(of: content).compactMap { $0 as? LungfishInfoButton }.forEach { $0.closePopover() }
            window.orderOut(nil)
        }
        return window
    }

    /// A placement test checks that the view shows (QA 2): not hidden, and every point of it inside the visible rect once
    /// its scroll view has scrolled to it.
    @MainActor
    private func assertShown(_ view: NSView, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor, "\(name) is hidden", file: file, line: line)
        view.scrollToVisible(view.bounds)
        let clip = view.enclosingScrollView?.contentView
        let visible = clip?.bounds ?? view.window?.contentView?.bounds ?? .zero
        let frame = view.convert(view.bounds, to: clip)
        XCTAssertGreaterThan(frame.width, 0, "\(name) has no width", file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, "\(name) has no height", file: file, line: line)
        XCTAssertTrue(visible.contains(frame), "\(name) at \(frame) is outside the visible \(visible)", file: file, line: line)
    }

    /// 5.6 U2, U3 and the BIO condition. The general words sit one press behind an info button that VoiceOver and the
    /// keyboard reach, and the line that names the route to an embedding stays in view.
    @MainActor
    func testTheRankPlotAndCellMapWordsSitBehindInfoButtonsAndThePointerStaysInView() async throws {
        let url = try RNASeqSingleCellFixtures.write(.cellRanger, into: root)
        let (surface, _) = try await open(url)
        _ = host(surface.viewController.view)
        let subviews = RNASeqSingleCellFixtures.allSubviews(of: surface.viewController.view)
        let pointer = try XCTUnwrap(subviews.first { $0.accessibilityIdentifier() == "rnaseq-sc-cell-map-words" } as? NSTextField)
        XCTAssertEqual(pointer.stringValue, "To see these cells on an embedding, use Import Embedding\u{2026}")
        assertShown(pointer, "the cell map line")
        XCTAssertNil(subviews.first { $0.accessibilityIdentifier() == "rnaseq-sc-rank-words" }, "the rank plot's words left the view")
        let expected: [(id: String, label: String, help: String, popover: String)] = [
            ("info-rnaseq.singleCell.rankPlot", "About the rank plot",
             "The plot ranks the cells of cells.sqlite by UMIs, most first.",
             "The plot ranks the cells of cells.sqlite by UMIs, most first. "
                + "The result keeps no raw barcode list, so barcodes outside the cells are not in the plot."),
            ("info-rnaseq.singleCell.cellMapRoutes", "About importing an embedding",
             "Either writes a new cell map result and leaves this one as it is.",
             "Or run lungfish-cli rnaseq cell-map import or lungfish-cli rnaseq cell-map compute on this result. "
                + "Either writes a new cell map result and leaves this one as it is."),
        ]
        for item in expected {
            let button = try XCTUnwrap(subviews.compactMap { $0 as? LungfishInfoButton }.first { $0.accessibilityIdentifier() == item.id }, item.id)
            assertShown(button, item.id)
            XCTAssertEqual(button.accessibilityLabel(), item.label)
            XCTAssertEqual(button.accessibilityHelp(), item.help)
            XCTAssertFalse(button.refusesFirstResponder, "\(item.id) takes keyboard focus")
            _ = button.accessibilityPerformPress()
            XCTAssertTrue(button.isPopoverShown, "\(item.id) opens its popover")
            XCTAssertEqual(button.popoverController.text, item.popover)
            button.closePopover()
        }
    }

    func testTheViewsHelpItemsPassTheCatalogCheck() {
        XCTAssertEqual(LungfishHelpContent.catalogFaults(in: RNASeqSingleCellHelp.items), [])
    }

    /// BIO ANSWER 9 and the lane's finding 1. VoiceOver names the rank plot as the section heading above it names it, and no
    /// heading calls the ranked items barcodes. The label is read from the plot and the headings, not from the source (QA 2).
    @MainActor
    func testTheRankPlotIsNamedForVoiceOverAsItsHeadingNamesItAndNoHeadingCallsACellABarcode() async throws {
        let url = try RNASeqSingleCellFixtures.write(.cellRanger, into: root)
        let (_, view) = try await open(url)
        let subviews = RNASeqSingleCellFixtures.allSubviews(of: view.view)
        let plot = try XCTUnwrap(subviews.first { $0.accessibilityIdentifier() == "rnaseq-sc-rank-plot" })
        let headings = subviews.compactMap { $0 as? NSTextField }.filter { $0.accessibilityIdentifier().isEmpty }.map(\.stringValue)
        XCTAssertTrue(headings.contains("Cells ranked by UMIs"), "the heading above the plot reads Cells ranked by UMIs")
        XCTAssertEqual(plot.accessibilityLabel(), "Cells ranked by UMIs", "VoiceOver names the plot as its heading does")
        XCTAssertEqual(plot.accessibilityRole(), NSAccessibility.Role.image)
        XCTAssertFalse(headings.joined(separator: "\n").lowercased().contains("barcode"), "no heading calls the ranked items barcodes")
        let steps = try XCTUnwrap(view.summary?.rankSteps)
        let first = try XCTUnwrap(steps.first)
        let last = try XCTUnwrap(steps.last)
        XCTAssertEqual(plot.accessibilityValue() as? String,
                       "Rank \(first.firstRank) holds \(first.umis) UMIs, rank \(last.lastRank) holds \(last.umis) UMIs",
                       "the value keeps reading the plot's numbers")
    }

    @MainActor
    func testTheSummaryKeepsItsAccessibilityOrderWithANotHostTable() async throws {
        let url = try RNASeqSingleCellFixtures.write(.starsolo, into: root, notHost: .virus)
        let (_, view) = try await open(url)
        let extra = try XCTUnwrap(view.summary?.extras.first)
        XCTAssertEqual(SCViewAXPin.elements(in: view.view), [
            "text:Cell summary", "rnaseq-sc-samples",
            "text:Tool", "rnaseq-sc-tool", "text:Version", "rnaseq-sc-tool-version", "text:Cells", "rnaseq-sc-cell-count",
            "rnaseq-sc-cell-map-words", "info-rnaseq.singleCell.cellMapRoutes",
            "text:Quality", "rnaseq-sc-quality",
            "text:Barcode rank", "info-rnaseq.singleCell.rankPlot", "rnaseq-sc-rank-plot",
            "text:UMIs per cell", "rnaseq-sc-histogram-umis",
            "text:Genes per cell", "rnaseq-sc-histogram-genes",
            "text:Not-host UMIs per cell, \(extra.name), default column", "rnaseq-sc-histogram-not-host-\(extra.extra)",
            "text:\(extra.name) masked column", "rnaseq-sc-mask-words-\(extra.extra)",
            "rnaseq-sc-cells",
        ])
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
        XCTAssertTrue(views.compactMap { $0 as? NSButton }.allSatisfy { $0 is LungfishInfoButton }, "the only buttons are info buttons")
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
