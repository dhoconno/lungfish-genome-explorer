// RNASeqExportCellsIdentConformanceTests.swift - seurat.R run by R with Seurat on ids that Seurat's own name reading merges (Phase 5.5 lane CM-IDENT, row SC-TEMPLATE-IDENT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The test runs the exported seurat.R in the R of the Seurat environment (`LGE_RNASEQ_ENV_SEURAT`, else
// /Volumes/lge_scratch/lge/rnaseq/env-r-seurat) and then a probe in the same R session. The probe prints what the object holds, and
// each cell's row has to name its sample and its barcode as cells.sqlite holds them, whatever the collation of the session is. A missing
// tool is a skip, and a failure with LUNGFISH_REQUIRE_TOOLS=1. `RNASeqExportCellsIdentTests` checks the data that R reads with no tool.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class RNASeqExportCellsIdentConformanceTests: RNASeqExportTestCase {
    private var rscript: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["LGE_RNASEQ_ENV_SEURAT"] ?? "/Volumes/lge_scratch/lge/rnaseq/env-r-seurat", isDirectory: true)
            .appendingPathComponent("bin/Rscript")
    }

    /// The lines the probe prints, by their first word.
    private static let probe = #"""
    meta <- object[[]]; who <- Seurat::Idents(object)
    say <- function(...) cat(paste(c(...), collapse = "\t"), "\n", sep = "")
    say("collate", Sys.getlocale("LC_COLLATE"))
    say("levels", "orig.ident", levels(meta[["orig.ident"]]))
    say("levels", "Idents", levels(who))
    say("columns", names(meta))
    has <- "barcode" %in% names(meta)
    for (cell in rownames(meta)) say("row", cell, as.character(meta[cell, "orig.ident"]), as.character(who[[cell]]), as.character(meta[cell, "sample"]), if (has) as.character(meta[cell, "barcode"]) else "NA")
    """#

    private struct Seen {
        var collate = ""
        var levels: [String: [String]] = [:]
        var columns: [String] = []
        var rows: [String: [String]] = [:]

        init(_ output: String) {
            for line in output.split(separator: "\n") {
                let parts = line.components(separatedBy: "\t")
                switch parts.first {
                case "collate": collate = parts.dropFirst().joined()
                case "levels" where parts.count >= 2: levels[parts[1]] = Array(parts.dropFirst(2))
                case "columns": columns = Array(parts.dropFirst())
                case "row" where parts.count >= 2: rows[parts[1]] = Array(parts.dropFirst(2))
                default: break
                }
            }
        }
    }

    /// Runs `tool` in `folder` under the collation and returns the exit status and what it wrote. The wait ends at the lookup budget.
    private func run(_ tool: URL, _ arguments: [String], in folder: URL, collation: String) throws -> (status: Int32, output: String) {
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
        variables["LC_ALL"] = nil
        variables["LC_COLLATE"] = collation
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

    /// A single-cell result of the STARsolo cut once a sample id, in the order given.
    private func result(_ ids: [String]) throws -> URL {
        let folders = try ids.map { try RNASeqPseudobulkTests.starsoloCopy($0, in: root) }
        return try RNASeqPseudobulkTests.singleCellResult(folders, name: "ident", in: analyses)
    }

    /// Exports the result, runs seurat.R and the probe in R under the collation, and returns what the probe printed.
    private func seen(_ result: URL, collation: String) throws -> Seen {
        let out = try RNASeqExport.run(
            results: [result], sheet: nil, settings: RNASeqExportSettings(), output: root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true),
            argv: ["lungfish-cli", "rnaseq", "export"])
        try Data(Self.probe.utf8).write(to: out.appendingPathComponent("probe.R"))
        let ran = try run(rscript, ["--vanilla", "-e", #"source("seurat.R"); source("probe.R")"#], in: out, collation: collation)
        XCTAssertEqual(ran.status, 0, ran.output)
        return Seen(ran.output)
    }

    /// Each cell's row of the object, by its name, against the cells.sqlite rows, and the levels against the order of the result.
    private func check(_ seen: Seen, _ result: URL, collation: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let database = try RNASeqCellsDatabase(url: result.appendingPathComponent(RNASeqCellsDatabase.filename))
        let samples = try database.samples()
        let names = samples.map(\.name)
        XCTAssertEqual(seen.collate, collation, "R runs under the collation the test asked for", file: file, line: line)
        XCTAssertEqual(seen.levels["orig.ident"], names, "orig.ident has one level a sample in the order of the result under LC_COLLATE=\(collation)", file: file, line: line)
        XCTAssertEqual(seen.levels["Idents"], names, "Idents has one level a sample in the order of the result under LC_COLLATE=\(collation)", file: file, line: line)
        XCTAssertTrue(seen.columns.contains("barcode"), "meta.data holds the barcode, and it holds \(seen.columns)", file: file, line: line)
        let cells = try database.cells(offset: 0, limit: 100_000)
        XCTAssertEqual(seen.rows.count, cells.count, "the object holds the cells of cells.sqlite", file: file, line: line)
        var wrong: [String] = []
        for cell in cells {
            let name = samples.first { $0.sample == cell.sample }?.name ?? ""
            let key = "\(name)_\(cell.barcode)"
            if seen.rows[key] != [name, name, name, cell.barcode] { wrong.append("\(key) is \(seen.rows[key] ?? [])") }
        }
        XCTAssertEqual(wrong.count, 0, "each cell names its sample as orig.ident, Idents and sample, and its barcode, as cells.sqlite holds them. First: \(wrong.prefix(3))", file: file, line: line)
    }

    func testATwoSampleResultKeepsCov10AndCov11ApartAndKeepsEachBarcode() throws {
        let result = try self.result(["cov_10", "cov_11"])
        try check(try seen(result, collation: "C"), result, collation: "C")
    }

    func testTheLevelsFollowTheOrderOfTheResultUnderBothCollationsWhateverTheLocaleSorts() throws {
        let result = try self.result(RNASeqExportCellsIdentTests.ids)
        for collation in ["C", "en_US.UTF-8"] {
            try check(try seen(result, collation: collation), result, collation: collation)
        }
    }

    /// A result of one sample names its cells by barcode alone. Seurat's own reading then gave every cell the project name `lungfish`
    /// (measured at the base), so the object holds the sample id as orig.ident, Idents and sample, and the barcode in meta.data.
    func testAOneSampleResultHoldsItsSampleIdAsIdentityAndNamesItsCellsByBarcode() throws {
        let result = try self.result(["solo.1"])
        let object = try seen(result, collation: "C")
        let database = try RNASeqCellsDatabase(url: result.appendingPathComponent(RNASeqCellsDatabase.filename))
        let names = try database.samples().map(\.name)
        XCTAssertEqual(names.count, 1, "the result holds one sample")
        let name = try XCTUnwrap(names.first, "the result holds a sample")
        let cells = try database.cells(offset: 0, limit: 100_000)
        XCTAssertEqual(object.levels["orig.ident"], [name], "orig.ident has the sample id as its one level")
        XCTAssertEqual(object.levels["Idents"], [name], "Idents has the sample id as its one level")
        XCTAssertEqual(object.rows.count, cells.count, "the object holds the cells of cells.sqlite")
        let wrong = cells.filter { object.rows[$0.barcode] != [name, name, name, $0.barcode] }.map(\.barcode)
        XCTAssertEqual(wrong.count, 0, "each cell is named by its barcode and holds the sample id as orig.ident, Idents and sample. First: \(wrong.prefix(3))")
    }
}
