// RNASeqBulkEvidenceTests.swift - The lane's evidence on C1 and C5 and the ordinary size (5.4 RS-BULK-VIEW M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Both tests read results that live outside the repository, so each runs only when its environment variable names the
// files, and a gate that sets neither runs nothing here and needs no external disk.
//
// LUNGFISH_RNASEQ_BULK_EVIDENCE names a folder with `cases.tsv`, one line a case: its name, the result folder, and the
// output of the built `lungfish-cli rnaseq quality <result> --format tsv` with `--table samples` and `--table correlation`.
// The test writes `<case>.compare.tsv` there with the cells read and the cells that differ in each check.
//
// LUNGFISH_RNASEQ_BULK_ORDINARY names a bulk result whose default table is repeated by columns into 96 samples, written by
// the one writer, then opened and searched. It writes `ordinary.txt` into the evidence folder when that is set too.

import AppKit
import LungfishCore
import LungfishIO
import XCTest
@testable import LungfishRNASeqUI
@testable import LungfishWorkflow

final class RNASeqBulkEvidenceTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func cells(_ text: String) -> [[String]] {
        text.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    /// The cells compared and those that differ, also for a table whose shape differs.
    private func compare(_ shown: [[String]], _ expected: [[String]]) -> (read: Int, differ: Int) {
        var read = 0
        var differ = 0
        for index in 0..<max(shown.count, expected.count) {
            let a = index < shown.count ? shown[index] : []
            let b = index < expected.count ? expected[index] : []
            for column in 0..<max(a.count, b.count) {
                read += 1
                if column >= a.count || column >= b.count || a[column] != b[column] { differ += 1 }
            }
        }
        return (read, differ)
    }

    @MainActor
    func testTheScreenOfEachKeptResultEqualsItsTableAndTheCLI() async throws {
        guard let folder = environment["LUNGFISH_RNASEQ_BULK_EVIDENCE"].map(URL.init(fileURLWithPath:)) else { return }
        let lines = cells(try String(contentsOf: folder.appendingPathComponent("cases.tsv"), encoding: .utf8))
        XCTAssertFalse(lines.isEmpty, "cases.tsv names no case")
        for line in lines where line.count == 4 {
            let (name, result) = (line[0], URL(fileURLWithPath: line[1]))
            let controller = try await RNASeqBulkFixtures.show(result)
            let model = controller.model
            guard case .loaded(let quality) = model.quality else { XCTFail("\(name): \(model.quality)"); continue }
            let table = try XCTUnwrap(model.tables.firstIndex { $0.path == "counts/genes.counts.tsv" }, name)
            let file = cells(try String(contentsOf: result.appendingPathComponent("counts/genes.counts.tsv"), encoding: .utf8))
            let shownTable = [["feature_id"] + model.tables[table].sampleIDs]
                + model.tables[table].visibleRows.map { model.countCells(table: table, row: $0) }
            let onScreenQuality = (0..<controller.numberOfRows(in: controller.qualityTable)).map { row in
                (0..<controller.qualityTable.numberOfColumns).map { controller.shownText(tableTag: RNASeqBulkViewController.qualityTag, column: $0, row: row) }
            }
            let checks: [(String, (read: Int, differ: Int))] = [
                ("table to counts/genes.counts.tsv", compare(shownTable, file)),
                ("quality to rnaseq quality --table samples",
                 compare([quality.samples.columns] + onScreenQuality, cells(try String(contentsOfFile: line[2], encoding: .utf8)))),
                ("correlation to rnaseq quality --table correlation",
                 compare([quality.correlationTable.columns] + quality.correlationTable.rows,
                         cells(try String(contentsOfFile: line[3], encoding: .utf8)))),
                ("plot to the correlation table",
                 compare(controller.correlationPlot.cells, quality.correlationTable.rows.map { Array($0.dropFirst()) })),
            ]
            let report = (["check\tcells read\tcells differ"] + checks.map { "\($0.0)\t\($0.1.read)\t\($0.1.differ)" })
                .joined(separator: "\n") + "\n"
            try report.write(to: folder.appendingPathComponent("\(name).compare.tsv"), atomically: true, encoding: .utf8)
            for (check, outcome) in checks { XCTAssertEqual(outcome.differ, 0, "\(name), \(check), \(outcome.read) cells read") }
        }
    }

    @MainActor
    func testA96SampleResultOf60371GenesOpensAndSearches() async throws {
        guard let source = environment["LUNGFISH_RNASEQ_BULK_ORDINARY"].map(URL.init(fileURLWithPath:)) else { return }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("rnaseq-bulk-96-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let url = try autoreleasepool { () throws -> URL in
            let original = try RNASeqResultBundle.load(from: source)
            let base = try XCTUnwrap(original.counts.first { $0.entry.rows == .gene && $0.entry.column == .default }).table
            let width = base.sampleIDs.count
            let ids = (0..<96).map { "\(base.sampleIDs[$0 % width])_\($0 / width + 1)" }
            let table = RNASeqCountTable(sampleIDs: ids, rows: base.rows.map { row in
                .init(id: row.id, counts: (0..<96).map { row.counts[$0 % width] })
            })
            let request = RNASeqResultWriter.Request(
                name: "Ordinary size", modality: .bulk, origin: original.manifest.origin, route: original.manifest.route,
                referenceSet: nil, samples: ids.map { RNASeqSampleRecord(id: $0, runs: [$0]) }, genes: .ids(table.rows.map(\.id)),
                counts: [.init(rows: .gene, column: .default, unit: .estimated, table: table)], sourceFiles: [], notHost: [])
            return try RNASeqBulkFixtures.write(request, to: work.appendingPathComponent("ordinary.lungfishrnaseq", isDirectory: true))
        }
        let before = ProcessMemoryShare.currentFootprint() ?? 0
        let clock = ContinuousClock()
        let opened = clock.now
        guard case .loaded(let result) = RNASeqResultSurface.read(url) else { return XCTFail("\(RNASeqResultSurface.read(url))") }
        let readWall = opened.duration(to: clock.now)
        let shown = clock.now
        let controller = RNASeqBulkViewController(model: RNASeqBulkModel())
        controller.configure(result: result, bundleURL: url)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let tableWall = shown.duration(to: clock.now)
        let checked = clock.now
        await controller.model.qualityRead()
        controller.reloadFromModel()
        let qualityWall = checked.duration(to: clock.now)
        let openWall = opened.duration(to: clock.now)
        let model = controller.model
        XCTAssertEqual(model.tables.first?.rowCount, 60371)
        XCTAssertEqual(model.tables.first?.sampleIDs.count, 96)
        guard case .loaded(let quality) = model.quality else { return XCTFail("\(model.quality)") }
        XCTAssertEqual(quality.summary.samples.count, 96)
        XCTAssertEqual(quality.correlation.samples.count, 96)
        let wanted = try XCTUnwrap(model.tables.first?.table.rows[30000].id)
        let searched = clock.now
        controller.searchField.stringValue = wanted
        controller.searchField.sendAction(controller.searchField.action, to: controller.searchField.target)
        let searchWall = searched.duration(to: clock.now)
        XCTAssertEqual(model.tables[0].visibleRows.map { model.tables[0].table.rows[$0].id }, [wanted])
        let after = ProcessMemoryShare.currentFootprint() ?? 0
        let words = "open \(openWall): the surface's read \(readWall), the table on screen \(tableWall), "
            + "the checks, quality and correlation of rnaseq quality \(qualityWall), then search \(searchWall), "
            + "footprint before \(before) bytes, after \(after) bytes, growth \(Int64(after) - Int64(before)) bytes"
        print("RNASeqBulkOrdinarySize: \(words)")
        if let folder = environment["LUNGFISH_RNASEQ_BULK_EVIDENCE"].map(URL.init(fileURLWithPath:)) {
            try (words + "\n").write(to: folder.appendingPathComponent("ordinary.txt"), atomically: true, encoding: .utf8)
        }
    }
}
