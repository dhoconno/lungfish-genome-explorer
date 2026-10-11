// ImportFastqTextOutputPinTests.swift - What `import fastq` prints in text mode
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI

/// What `import fastq` prints without `--format json`. The lines were captured at base `247504866`,
/// before lane Q4 of Phase 2.7 retired the S1 stream, into `Tests/Fixtures/cli-events/import-fastq-runs`
/// as `text-<case>.stdout` and `text-<case>.stderr`. Standard output there leaves out the JSON lines
/// that text mode printed at the base. The runs need no external tool, and a duration reads `<t>`.
/// Set `LUNGFISH_RECAPTURE_IMPORT_TEXT=1` to write the files instead of comparing with them.
final class ImportFastqTextOutputPinTests: XCTestCase {
    /// A pair and the run's third file, which the check leaves out, so its sample is skipped.
    func testAPairWhoseThirdFileIsLeftOutPrintsTheBaseLines() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let files = try [
            scratch.write("download/SRR125_1.fastq", Self.records([("SRR125.1.1", 1), ("SRR125.2.1", 2)], bases: "ACGTACGT")),
            scratch.write("download/SRR125_2.fastq", Self.records([("SRR125.1.2", 1), ("SRR125.2.2", 2)], bases: "TTGGCCAA")),
            scratch.write("download/SRR125.fastq", Self.records([("SRR125.3.1", 3)], bases: "GATTACAG")),
        ]

        let output = try await Self.run(files.map(\.path) + ["--pairing", "paired"], in: scratch)

        XCTAssertNil(output.thrown)
        try assertPrints(output, "pair-with-skip")
    }

    /// A single-end file that the WGS recipe refuses, a failed sample.
    func testASampleTheRecipeRefusesPrintsTheBaseLines() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let file = try scratch.write("download/Solo.fastq", Self.records([("Solo.1", 1), ("Solo.2", 2)], bases: "ACGTACGT"))

        let output = try await Self.run([file.path, "--pairing", "single", "--recipe", "wgs"], in: scratch)

        XCTAssertNotNil(output.thrown, "a failed sample is a failed import")
        try assertPrints(output, "failed")
    }

    // MARK: Helpers

    private static func run(_ arguments: [String], in scratch: ImportStreamCapture.Scratch) async throws -> ImportStreamCapture.Output {
        let command = try ImportCommand.FastqSubcommand.parse(arguments + [
            "--project", scratch.project.path, "--platform", "illumina", "--quality-binning", "none",
            "--no-optimize-storage", "--no-color", "--threads", "2",
        ])
        return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
    }

    /// Compares what the run printed, without the JSON lines of standard output, with the base files.
    private func assertPrints(_ output: ImportStreamCapture.Output, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let folder = CLIEventContractCoverageTests.repositoryRoot
            .appendingPathComponent("Tests/Fixtures/cli-events/import-fastq-runs", isDirectory: true)
        let standardOutput = output.standardOutput.filter { !$0.hasPrefix("{") }.map(Self.withoutDurations)
        let standardError = output.standardError.map(Self.withoutDurations)
        let outputFile = folder.appendingPathComponent("text-\(name).stdout")
        let errorFile = folder.appendingPathComponent("text-\(name).stderr")
        if ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_IMPORT_TEXT"] == "1" {
            try (standardOutput.joined(separator: "\n") + "\n").write(to: outputFile, atomically: true, encoding: .utf8)
            try (standardError.map { $0 + "\n" }.joined()).write(to: errorFile, atomically: true, encoding: .utf8)
            return
        }
        func lines(_ url: URL) throws -> [String] {
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        XCTAssertEqual(standardOutput, try lines(outputFile), "standard output of the \(name) run", file: file, line: line)
        XCTAssertEqual(standardError, try lines(errorFile), "standard error of the \(name) run", file: file, line: line)
    }

    /// A duration such as `7.7s` or `(0s)` reads `<t>s`.
    private static func withoutDurations(_ line: String) -> String {
        line.replacingOccurrences(of: #"\d+(\.\d+)?s\b"#, with: "<t>s", options: .regularExpression)
    }

    /// Records named as fasterq-dump names them, `@<id> <spot> length=8`.
    private static func records(_ reads: [(id: String, spot: Int)], bases: String) -> String {
        reads.map { "@\($0.id) \($0.spot) length=\(bases.count)\n\(bases)\n+\n\(String(repeating: "I", count: bases.count))\n" }.joined()
    }
}
