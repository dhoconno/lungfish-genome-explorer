// RNASeqExportCellsConformanceTests.swift - seurat.R and scanpy.py run by the real R and Python (Phase 5.2 lane RS-SC-HANDOFF, slice B)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `RNASeqExportCellsTests` reads the text of the two scripts. This class runs them. `scanpy.py` runs with the Python of the RNA-seq
// environment (`LGE_RNASEQ_ENV`, else /Volumes/lge_scratch/lge/rnaseq/env) and `seurat.R` with the R of the Seurat environment
// (`LGE_RNASEQ_ENV_SEURAT`, else .../rnaseq/env-r-seurat). Each prints its cells, writes its table of cells, and that table has to
// equal the rows of `cells.sqlite` of the result. A missing tool is a skip, and a failure with LUNGFISH_REQUIRE_TOOLS=1.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class RNASeqExportCellsConformanceTests: RNASeqExportTestCase {
    private func environment(_ variable: String, _ fallback: String) -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment[variable] ?? fallback, isDirectory: true)
    }

    private var python: URL { environment("LGE_RNASEQ_ENV", "/Volumes/lge_scratch/lge/rnaseq/env").appendingPathComponent("bin/python") }
    private var rscript: URL { environment("LGE_RNASEQ_ENV_SEURAT", "/Volumes/lge_scratch/lge/rnaseq/env-r-seurat").appendingPathComponent("bin/Rscript") }

    /// Runs `tool` in `folder` and returns the exit status and what it wrote. The wait ends at the lookup budget, and the exit
    /// status then fails the test. A signal on the termination handler replaces a sleep.
    private func run(_ tool: URL, _ arguments: [String], in folder: URL) throws -> (status: Int32, output: String) {
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { try ToolAvailability.skipOrFail("No \(tool.path) to run the template.") }
        let log = root.appendingPathComponent("run-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = handle
        process.standardError = handle
        var variables = ProcessInfo.processInfo.environment
        variables["PATH"] = tool.deletingLastPathComponent().path + ":" + (variables["PATH"] ?? "/usr/bin:/bin")
        process.environment = variables
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + WaitBudget.lookup.seconds) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + WaitBudget.standard.seconds)
        }
        return (process.terminationStatus, try String(contentsOf: log, encoding: .utf8))
    }

    /// A result of the STARsolo cut once (plain) or twice (two samples, whose barcodes take the sample as a prefix), or the gzip Cell Ranger cut.
    private func result(_ kind: String) throws -> URL {
        switch kind {
        case "two": return try RNASeqPseudobulkTests.singleCellResult(
            [RNASeqPseudobulkTests.starsolo, try RNASeqPseudobulkTests.starsoloCopy("second", in: root)], name: "two", in: analyses)
        case "gzip": return try RNASeqPseudobulkTests.singleCellResult([RNASeqPseudobulkTests.cellRanger], name: "gzip", in: analyses)
        default: return try RNASeqPseudobulkTests.singleCellResult([RNASeqPseudobulkTests.starsolo], name: "one", in: analyses)
        }
    }

    private func export(_ result: URL) throws -> URL {
        try RNASeqExport.run(
            results: [result], sheet: nil, settings: RNASeqExportSettings(), output: root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true),
            argv: ["lungfish-cli", "rnaseq", "export"])
    }

    /// The rows `cells.sqlite` holds, as the tables of both scripts write them, with the sample as a prefix for two or more samples.
    private func expectedRows(_ result: URL) throws -> [String] {
        let database = try RNASeqCellsDatabase(url: result.appendingPathComponent(RNASeqCellsDatabase.filename))
        let samples = try database.samples()
        return try database.cells(offset: 0, limit: 100_000).map { cell in
            let name = samples.first { $0.sample == cell.sample }?.name ?? ""
            let id = samples.count > 1 ? "\(name)_\(cell.barcode)" : cell.barcode
            return [id, name, cell.barcode, "\(cell.umis)", "\(cell.genes)"].joined(separator: "\t")
        }
    }

    private func table(_ folder: URL, _ name: String) throws -> [String] {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// The lines both scripts print, from the samples `cells.sqlite` holds.
    private func expectedLines(_ result: URL) throws -> [String] {
        let samples = try RNASeqCellsDatabase(url: result.appendingPathComponent(RNASeqCellsDatabase.filename)).samples()
        return samples.map { "cells \($0.name) \($0.cells)" } + ["cells total \(samples.map(\.cells).reduce(0, +))", "not-host features 0"]
    }

    private func check(_ run: (status: Int32, output: String), _ result: URL, _ out: URL, table name: String, status: Int32 = 0) throws {
        XCTAssertEqual(run.status, status, run.output)
        let printed = Set(run.output.split(separator: "\n").map(String.init))
        for line in try expectedLines(result) { XCTAssertTrue(printed.contains(line), "\(line) is printed:\n\(run.output)") }
        let expected = ["cell\tsample\tbarcode\tumis\tgenes"] + (try expectedRows(result))
        XCTAssertEqual(try table(out, name), expected, "\(name) holds the rows of cells.sqlite")
    }

    func testScanpyPrintsTheCellsAndWritesTheRowsOfCellsSqlite() throws {
        for kind in ["one", "two", "gzip"] {
            let result = try self.result(kind)
            let out = try export(result)
            try check(try run(python, ["-I", "scanpy.py"], in: out), result, out, table: "scanpy-cells.tsv")
            if kind == "two" {
                // Without -I the folder of the script is on the search path, and a file named scanpy.py must not shadow the package.
                try FileManager.default.removeItem(at: out.appendingPathComponent("scanpy-cells.tsv"))
                try check(try run(python, ["scanpy.py"], in: out), result, out, table: "scanpy-cells.tsv")
            }
        }
    }

    func testSeuratPrintsTheCellsWritesTheRowsAndBuildsTheObject() throws {
        for kind in ["one", "two", "gzip"] {
            let result = try self.result(kind)
            let out = try export(result)
            let ran = try run(rscript, ["--vanilla", "seurat.R"], in: out)
            try check(ran, result, out, table: "seurat-cells.tsv")
            let total = try expectedRows(result).count
            XCTAssertTrue(ran.output.contains("across \(total) samples within 1 assay"), "the Seurat object holds \(total) cells:\n\(ran.output)")
        }
    }

    func testSeuratStopsInWordsWhenSeuratIsMissingAfterTheTableIsWritten() throws {
        let plainR = environment("LGE_RNASEQ_ENV", "/Volumes/lge_scratch/lge/rnaseq/env").appendingPathComponent("bin/Rscript")
        let result = try self.result("one")
        let out = try export(result)
        let ran = try run(plainR, ["--vanilla", "seurat.R"], in: out)
        try check(ran, result, out, table: "seurat-cells.tsv", status: 1)
        XCTAssertTrue(ran.output.contains("Seurat is not installed"), ran.output)
    }
}
