// RNASeqExportCellsIdentTests.swift - Which cell is which in a single-cell export (Phase 5.5 lane CM-IDENT, row SC-TEMPLATE-IDENT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// seurat.R gives each cell of its Seurat object the sample of samples.tsv and the barcode of its sample folder. R with Seurat runs in
// `RNASeqExportCellsIdentConformanceTests`. This class checks what R reads, by meaning and with no tool. The ids are the smallest set
// that broke the object. `cov_10` and `cov_11` share the part before their first "_", which Seurat reads as the identity of a cell
// named `cov_10_<barcode>`. `ax.1` holds a dot. `Bx` puts a capital beside `ax`, so C and en_US order the ids in two ways and neither
// is the order of the result.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class RNASeqExportCellsIdentTests: RNASeqExportTestCase {
    static let ids = ["cov_10", "cov_11", "ax.1", "Bx"]

    private func result(_ ids: [String] = ids) throws -> URL {
        let folders = try ids.map { try RNASeqPseudobulkTests.starsoloCopy($0, in: root) }
        return try RNASeqPseudobulkTests.singleCellResult(folders, name: "ident", in: analyses)
    }

    private func exported(_ result: URL) throws -> URL {
        try RNASeqExport.run(
            results: [result], sheet: nil, settings: RNASeqExportSettings(), output: root.appendingPathComponent("out", isDirectory: true),
            argv: ["lungfish-cli", "rnaseq", "export"])
    }

    private func table(_ url: URL) throws -> [[String]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { $0.components(separatedBy: "\t") }
    }

    private func database(_ result: URL) throws -> RNASeqCellsDatabase {
        try RNASeqCellsDatabase(url: result.appendingPathComponent(RNASeqCellsDatabase.filename))
    }

    func testTheIdsMergeUnderSeuratsNameReadingAndSortInTwoWaysNeitherTheOrderOfTheResult() {
        let firstFields = Set(Self.ids.map { $0.split(separator: "_", maxSplits: 1)[0] })
        XCTAssertEqual(firstFields.count, Self.ids.count - 1, "cov_10 and cov_11 give one identity under the default name reading")
        let byCodePoint = Self.ids.sorted()
        let byLocale = Self.ids.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        XCTAssertNotEqual(byCodePoint, byLocale, "the two sorts of the ids differ, so a level order that follows either one is a visible fault")
        XCTAssertNotEqual(Self.ids, byCodePoint)
        XCTAssertNotEqual(Self.ids, byLocale)
    }

    /// The levels of orig.ident and of Idents are built from the sample_id column, so the column keeps the order of the result.
    func testSamplesTsvListsTheSamplesInTheOrderCellsSqliteHoldsThem() throws {
        let result = try self.result()
        let out = try exported(result)
        let listed = try table(out.appendingPathComponent("samples.tsv")).dropFirst().map { $0[0] }
        let held = try database(result).samples().map(\.name)
        XCTAssertEqual(Array(listed), held, "samples.tsv follows cells.sqlite")
        XCTAssertEqual(held, Self.ids, "and both follow the order of the import")
    }

    /// The pair a cell has in the object is the pair of its sample folder, so each folder's barcodes are the ones cells.sqlite holds.
    func testEachSampleFolderHoldsTheBarcodesOfItsSampleAndNoNameRepeats() throws {
        let result = try self.result()
        let out = try exported(result)
        let db = try database(result)
        let names = Dictionary(uniqueKeysWithValues: try db.samples().map { ($0.sample, $0.name) })
        let held = try db.cells(offset: 0, limit: 100_000).map { "\(names[$0.sample] ?? "?")\t\($0.barcode)" }
        let rows = try table(out.appendingPathComponent("samples.tsv"))
        let sampleColumn = try XCTUnwrap(rows[0].firstIndex(of: "sample_id"))
        let folderColumn = try XCTUnwrap(rows[0].firstIndex(of: "folder"))
        var read: [String] = []
        for row in rows.dropFirst() {
            let barcodes = try String(contentsOf: out.appendingPathComponent("\(row[folderColumn])/barcodes.tsv"), encoding: .utf8).split(separator: "\n")
            read += barcodes.map { "\(row[sampleColumn])\t\($0)" }
        }
        XCTAssertEqual(read, held, "each sample folder lists the barcodes of its sample as cells.sqlite holds them")
        XCTAssertEqual(Set(read.map { $0.replacingOccurrences(of: "\t", with: "_") }).count, read.count, "<sample>_<barcode> names one cell")
    }
}
