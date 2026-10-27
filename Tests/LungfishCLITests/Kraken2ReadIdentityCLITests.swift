// Kraken2ReadIdentityCLITests.swift - blast verify and both extract commands refuse reads that changed after the run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane READ-IDENTITY (BIO-READ-IDENTITY 4.4 test 9). The reads a Kraken2 result names were trimmed again
// after the run and put back at the same place under the same names. `blast verify` sent them to BLAST and both
// extract commands wrote them as the taxon's reads. Each command now prints the refusal on stderr, exits non-zero
// and writes nothing. The BLAST stand-in origin is a closed local port, so nothing reaches NCBI in any case.

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class Kraken2ReadIdentityCLITests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var bundle: URL!
    private var resultFolder: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "kraken2-read-identity-cli")
        project = root.appendingPathComponent("P.lungfish", isDirectory: true)
        _ = try ProjectFile.create(at: project, name: "P")
        bundle = project.appendingPathComponent("Imports/s.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let payload = bundle.appendingPathComponent("reads.fastq")
        let names = ["r1", "r2", "r3", "r4"]
        try Self.fastq(names, length: 20).write(to: payload, atomically: true, encoding: .utf8)
        resultFolder = project.appendingPathComponent("Analyses/kraken2-s", isDirectory: true)
        try FileManager.default.createDirectory(at: resultFolder, withIntermediateDirectories: true)
        try "100.00\t4\t0\tR\t1\troot\n100.00\t4\t4\tS\t562\t  Escherichia coli\n"
            .write(to: report, atomically: true, encoding: .utf8)
        try names.map { "C\t\($0)\t562\t20\t562:16\n" }.joined().write(to: krakenOutput, atomically: true, encoding: .utf8)
        var config = ClassificationConfig(
            inputFiles: [payload], isPairedEnd: false, databaseName: "TestDB",
            databasePath: URL(fileURLWithPath: "/nonexistent/db", isDirectory: true), outputDirectory: resultFolder
        )
        config.originalInputFiles = [bundle]
        try ClassificationResult(
            config: config, tree: try KreportParser.parse(url: report), reportURL: report, outputURL: krakenOutput,
            brackenURL: nil, runtime: 1, toolVersion: "2.1.3", provenanceId: nil
        ).save(to: resultFolder)
        // fastp ran again and the trimmed reads were imported with Replace.
        try Self.fastq(names, length: 15).write(to: payload, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private var report: URL { resultFolder.appendingPathComponent("classification.kreport") }
    private var krakenOutput: URL { resultFolder.appendingPathComponent("classification.kraken") }

    func testBlastVerifyRefusesReadsThatChangedAndSendsNothing() throws {
        let result = try runCLI([
            "blast", "verify", "--kreport", report.path, "--kraken-output", krakenOutput.path,
            "--source", bundle.path, "--taxid", "562", "--reads", "4",
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stderr.contains("Lungfish sent nothing to BLAST"), result.stderr)
        XCTAssertTrue(result.stderr.contains("4 have another length"), result.stderr)
        XCTAssertFalse((result.stdout + result.stderr).contains("Submitting to NCBI BLAST"), "a request was made")
    }

    func testExtractReadsByClassifierRefusesReadsThatChanged() throws {
        let output = root.appendingPathComponent("out/taxon.fastq")
        let result = try runCLI([
            "extract", "reads", "--by-classifier", "--tool", "kraken2", "--result", resultFolder.path,
            "--taxon", "562", "-o", output.path,
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stderr.contains("Lungfish extracted nothing"), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a refused Extract writes no file")
    }

    func testExtractTaxaCollectionRefusesReadsThatChanged() throws {
        let output = root.appendingPathComponent("collection", isDirectory: true)
        let result = try runCLI([
            "extract", "taxa-collection", "--result", resultFolder.path, "--collection-id", "identity",
            "--collection-name", "Identity", "--target", "562,children,Escherichia coli", "--output-dir", output.path,
        ])

        XCTAssertNotEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stderr.contains("Lungfish extracted nothing"), result.stderr)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
        XCTAssertEqual(written.filter { $0.contains(".fastq") }, [], "a refused collection writes no FASTQ")
    }

    // MARK: - Helpers

    private nonisolated static func fastq(_ names: [String], length: Int) -> String {
        zip(names, ["A", "C", "G", "T"]).map { name, base in
            "@\(name)\n\(String(repeating: base, count: length))\n+\n\(String(repeating: "I", count: length))\n"
        }.joined()
    }

    /// Runs the built `lungfish-cli` with the BLAST stand-in at a closed local port and waits up to a minute.
    private func runCLI(_ arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let binary = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(
                buildProductsDirectory: Bundle(for: Kraken2ReadIdentityCLITests.self).bundleURL.deletingLastPathComponent()
            ),
            "Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle"
        )
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        // The storage root stays this Mac's, where the managed seqkit lives. A stand-in keeps its BLAST ledger in
        // memory, so the hourly budget is not touched.
        process.environment = CLISIGTERMHarness.childEnvironment(overriding: [
            "LUNGFISH_BLAST_STAND_IN_ORIGIN": "http://127.0.0.1:9",
        ])
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            if process.isRunning { process.terminate() }
        }
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, out, err)
    }
}
