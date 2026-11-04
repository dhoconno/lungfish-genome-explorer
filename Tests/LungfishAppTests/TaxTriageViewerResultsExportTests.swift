// TaxTriageViewerResultsExportTests.swift - The viewer's TaxTriage results export writes Reads and Unique Reads as the table shows them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane ESVUNIQUE, owner direction O144 ("when the results table for TaxTriage is exported, it should include
// the Unique read count and Reads count"). `TaxTriageResultsExport.buildDelimitedExport` writes both columns right after
// TASS Score. This test proves the viewer's own Export route does too, on a result whose database stores unique counts.
// The view is configured as the app's route configures it, the export is the invocation the view builds
// (`resultsExportInvocation`) run through the leaf `taxtriage export results`, and each file cell is compared with the
// cell the table shows for the same row. A count the table shows as a dash (never stored) is an empty cell in the file.
// The invocation carries the rows (samples, search, filters, sort) and the shown metadata columns and never a hidden
// standard column, so hiding Reads and Unique Reads in the table leaves them in the file. It is a pin, with no code
// change behind it.

import AppKit
import XCTest
@testable import LungfishCLI
@testable import LungfishTaxTriageUI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class TaxTriageViewerResultsExportTests: XCTestCase {
    private var root: URL!
    private var layouts: TestDefaultsSuite!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-viewer-results-export")
        layouts = TestDefaultsSuite(prefix: "TaxTriageViewerResultsExportTests")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// The Reads and Unique Reads of one row, as the table shows them or the file writes them. The table's dash is the
    /// file's empty cell.
    private struct Cells: Equatable {
        let key: String
        let reads: String
        let unique: String
    }

    private func tableCells(_ table: BatchTaxTriageTableView) -> [Cells] {
        table.displayedRows.map { row in
            let unique = table.cellContent(for: NSUserInterfaceItemIdentifier("tt_uniqueReads"), row: row).text
            return Cells(
                key: "\(row.sample ?? "")\t\(row.organism)",
                reads: table.cellContent(for: NSUserInterfaceItemIdentifier("tt_reads"), row: row).text,
                unique: unique == "\u{2014}" ? "" : unique
            )
        }.sorted { $0.key < $1.key }
    }

    /// The viewer's Export as TSV: the invocation the view builds, run through the leaf in this process.
    private func exportedCells(_ view: TaxTriageResultViewController, name: String) throws -> [Cells] {
        let output = root.appendingPathComponent(name)
        let invocation = try XCTUnwrap(view.resultsExportInvocation(format: .tsv, outputURL: output))
        _ = try TaxTriageCommand.ExportResultsSubcommand.parse(
            Array(invocation.arguments().dropFirst(invocation.commandPath.count))
        ).export()
        let lines = try String(contentsOf: output, encoding: .utf8)
            .split(separator: "\n").map { $0.components(separatedBy: "\t") }
        let header = try XCTUnwrap(lines.first)
        let sample = try XCTUnwrap(header.firstIndex(of: "Sample"))
        let organism = try XCTUnwrap(header.firstIndex(of: "Organism"))
        let reads = try XCTUnwrap(header.firstIndex(of: "Reads"), "the file holds Reads")
        let unique = try XCTUnwrap(header.firstIndex(of: "Unique Reads"), "the file holds Unique Reads")
        XCTAssertEqual(unique, reads + 1, "Unique Reads sits right after Reads")
        return lines.dropFirst().map {
            Cells(key: "\($0[sample])\t\($0[organism])", reads: $0[reads], unique: $0[unique])
        }.sorted { $0.key < $1.key }
    }

    func testViewerResultsExportWritesReadsAndUniqueReadsAsTheTableShows() async throws {
        try TaxTriageExportCLIGUIParityReplayTests.makeResult(root)
        let view = try await TaxTriageExportCLIGUIParityReplayTests.configuredView(root, defaults: layouts.defaults)
        let table = view.testBatchFlatTableView

        // Every row, with a stored count on four rows and none on the Delta row.
        let shown = tableCells(table)
        XCTAssertEqual(shown.count, 5)
        XCTAssertEqual(shown.first { $0.key == "sample-1\tAlpha virus" }, Cells(key: "sample-1\tAlpha virus", reads: "42", unique: "21"))
        XCTAssertEqual(
            shown.first { $0.key == "sample-1\tDelta, \"quoted\" virus" }?.unique, "",
            "the table shows a dash for a count never stored"
        )
        let all = try exportedCells(view, name: "all.tsv")
        XCTAssertEqual(all, shown, "the file holds the Reads and Unique Reads the table shows, an empty cell for the dash")

        // Hiding both columns in the table leaves them in the file, since the invocation carries no hidden column.
        for identifier in ["tt_reads", "tt_uniqueReads"] {
            let column = try XCTUnwrap(table.tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier)))
            column.isHidden = true
            XCTAssertTrue(column.isHidden)
        }
        XCTAssertEqual(try exportedCells(view, name: "hidden.tsv"), all, "a hidden column is still written")

        // A column filter drops the row of 3 reads and a sort reorders. Neither drops a column.
        let filtered = try await TaxTriageExportCLIGUIParityReplayTests.configuredView(
            root, defaults: layouts.defaults, sortKey: "tt_reads",
            filter: ColumnFilter(columnId: "tt_reads", op: .greaterOrEqual, value: "5")
        )
        let filteredShown = tableCells(filtered.testBatchFlatTableView)
        XCTAssertEqual(filteredShown.count, 4)
        XCTAssertEqual(try exportedCells(filtered, name: "filtered.tsv"), filteredShown)
    }
}
