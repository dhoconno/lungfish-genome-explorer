// RNASeqQualitySubcommandTests.swift - `lungfish-cli rnaseq quality` (5.4 lane RS-BULK-VIEW M1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The leaf writes nothing, so its family's cases are the argv round trip, the two refusals in their words and a run that
// leaves the result's files as they were. The numbers themselves are `RNASeqQualitySummaryTests` in Workflow.

import ArgumentParser
import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RNASeqQualitySubcommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-quality-cli") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    private func bulk() throws -> URL { try RNASeqExportCommandTests.makeResult("bulk", samples: ["S1", "S2", "S3"], in: root) }

    /// Every file of the folder with its bytes, to show a run wrote nothing.
    private func files(_ folder: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            out[String(url.path.dropFirst(folder.path.count))] = try Data(contentsOf: url)
        }
        return out
    }

    func testTheArgvRoundTripsAndEachTablePrintsTheWorkflowCells() async throws {
        let result = try bulk()
        for table in ["samples", "correlation"] {
            let command = try RNASeqQualitySubcommand.parse([result.path, "--table", table, "--format", "json"])
            let argv = command.canonicalArgv()
            XCTAssertEqual(Array(argv.prefix(3)), ["lungfish-cli", "rnaseq", "quality"])
            let reparsed = try RNASeqQualitySubcommand.parse(Array(argv.dropFirst(3)))
            XCTAssertEqual(reparsed.canonicalArgv(), argv, table)
            let document = try JSONDecoder().decode(RNASeqQualityDocument.self, from: Data(try command.render().utf8))
            let expected = table == "samples"
                ? try RNASeqQualitySummary.read(resultAt: result).document() : try RNASeqSampleCorrelation.read(resultAt: result).document()
            XCTAssertEqual(document, expected, table)
            XCTAssertEqual(document.table, table)
        }
        let tsv = try RNASeqQualitySubcommand.parse([result.path, "--format", "tsv"]).render()
        XCTAssertEqual(tsv.split(separator: "\n").first.map(String.init), RNASeqQualitySummary.columns.joined(separator: "\t"))
        XCTAssertEqual(tsv.split(separator: "\n").count, 4, "a header and one line for each of three samples")
        let text = try RNASeqQualitySubcommand.parse([result.path, "--table", "correlation"]).render()
        XCTAssertTrue(text.hasPrefix("Sample correlation of bulk: Pearson r of log2(CPM + 1) over 3 host genes"), text)
    }

    func testARunWritesNothingIntoTheResult() async throws {
        let result = try bulk()
        let before = try files(root)
        try await RNASeqQualitySubcommand.parse([result.path, "--table", "correlation", "--format", "tsv"]).run()
        try await RNASeqQualitySubcommand.parse([result.path]).run()
        XCTAssertEqual(try files(root), before)
    }

    func testASingleCellResultIsRefusedInWordsThatNameCellsSqlite() async throws {
        let result = try RNASeqPseudobulkCommandTests.makeSingleCellResult(in: root)
        XCTAssertThrowsError(try RNASeqQualitySubcommand.parse([result.path]).render()) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "cells.lungfishrnaseq is a single-cell result, whose numbers for each cell are in its cells.sqlite. "
                    + "rnaseq quality reads the count table of a bulk result. Run rnaseq pseudobulk to sum its cells into one.")
        }
        do {
            try await RNASeqQualitySubcommand.parse([result.path]).run()
            XCTFail("a single-cell result was read")
        } catch let code as ExitCode {
            XCTAssertEqual(code, CLIExitCode.inputError.exitCode)
        }
    }

    func testAResultWhoseFileDiffersFromTheManifestIsRefusedInWordsThatNameTheFile() async throws {
        let result = try bulk()
        let counts = result.appendingPathComponent("counts/genes.counts.tsv")
        let handle = try FileHandle(forWritingTo: counts)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("G4\t1\t2\t3\n".utf8))
        try handle.close()
        XCTAssertThrowsError(try RNASeqQualitySubcommand.parse([result.path, "--table", "correlation"]).render()) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "The RNA-seq result bulk.lungfishrnaseq changed after LGE wrote it. Its file counts/genes.counts.tsv no longer matches "
                    + "the sha256 the result lists, so its numbers are not the ones LGE recorded. "
                    + "Restore the file from a copy, or import or count the data again.")
        }
        do {
            try await RNASeqQualitySubcommand.parse([result.path]).run()
            XCTFail("a changed result was read")
        } catch let code as ExitCode {
            XCTAssertEqual(code, CLIExitCode.inputError.exitCode)
        }
    }
}
