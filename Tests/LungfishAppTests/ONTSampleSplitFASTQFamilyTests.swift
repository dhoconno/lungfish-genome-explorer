// ONTSampleSplitFASTQFamilyTests.swift - The FASTQ operation family reads the event lines of the two ONT split commands
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

/// Phase 2.6 lane C6, review defect 2. `fastq ont-fluidigm-samples` and `fastq ont-pacbio-barcode-demux`
/// print version 2 event lines on standard error, and the FASTQ operation family reads them there
/// through `LungfishCLIProcessRunner`. Each test plays a checked-in run of one command through a
/// stand-in `lungfish-cli` and the family's own reader, and reads what the dialog is told. A `start`
/// line reaches the dialog as progress 0, each `progress` line as its own fraction and message, and
/// a `complete` line as nothing. A `failed` line is not shown, and its message becomes the failure
/// text that the runner throws, in place of the plain `Error:` line that follows it.
final class ONTSampleSplitFASTQFamilyTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "ont-split-fastq-family")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(folder)
    }

    // MARK: A run that completes

    func testTheDialogIsToldTheStartAtZeroThenEachProgressLineOfAFluidigmRun() async throws {
        let outcome = try await play("fastq-ont-fluidigm-samples", "complete", exitStatus: 0)

        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.result?.outputURLs, [], "The stand-in wrote no bundle for the family to discover")
        assertTold(outcome.told, [
            (0, "Starting the ONT Fluidigm sample split."),
            (0.02, "Preparing ONT Fluidigm sample split."),
            (0.08, "Found 1 ONT FASTQ chunk."),
            (0.1, "Scanning chunk 1/1: reads.fastq"),
            (0.8, "Scanned chunk 1/1: 2 reads."),
            (0.84, "Writing 1 sample bundle."),
            (0.92, "Writing ONT Fluidigm sample manifest."),
            (1.0, "ONT Fluidigm sample split complete."),
        ])
    }

    func testTheDialogIsToldTheStartAtZeroThenEachProgressLineOfAPacBioRun() async throws {
        let outcome = try await play("fastq-ont-pacbio-barcode-demux", "complete", exitStatus: 0)

        XCTAssertNil(outcome.error)
        assertTold(outcome.told, [
            (0, "Starting PacBio barcode demultiplexing."),
            (0.02, "Running exact PacBio barcode demultiplexing on 1 ONT FASTQ chunk(s)"),
            (0.02, "Starting exact barcode demultiplexing..."),
            (0.666, "Building results..."),
            (0.7, "Demultiplexing complete."),
            (0.72, "Materializing exact PacBio sample FASTQ bundles..."),
            (0.92, "Finalizing exact PacBio sample FASTQ bundles..."),
            (1.0, "PacBio barcode demultiplexing complete"),
        ])
    }

    // MARK: A run that fails

    /// The command prints its `failed` line and then ArgumentParser prints an `Error:` line, and
    /// the command exits 1. The runner's error carries the message of the `failed` line.
    func testAFailedFluidigmRunThrowsTheMessageOfItsFailedLine() async throws {
        let message = "Output directory already exists: /work/fluidigm. Use --force to replace it."
        let outcome = try await play(
            "fastq-ont-fluidigm-samples", "failed", plainStandardError: ["Error: \(message)"], exitStatus: 1
        )

        try assertFailure(outcome, status: 1, text: message)
        assertTold(outcome.told, [
            (0, "Starting the ONT Fluidigm sample split."),
            (0.02, "Preparing ONT Fluidigm sample split."),
        ])
    }

    func testAFailedPacBioRunThrowsTheMessageOfItsFailedLine() async throws {
        let message = "Output directory already exists: /work/pacbio. Use --force to replace it."
        let outcome = try await play(
            "fastq-ont-pacbio-barcode-demux", "failed", plainStandardError: ["Error: \(message)"], exitStatus: 1
        )

        try assertFailure(outcome, status: 1, text: message)
        assertTold(outcome.told, [(0, "Starting PacBio barcode demultiplexing.")])
    }

    // MARK: Playing a run

    private struct Outcome {
        let told: [(fraction: Double, message: String)]
        let result: FASTQCLIExecutionResult?
        let error: Error?
    }

    /// The checked-in run of `leaf`, printed on standard error by a stand-in CLI that then prints
    /// `plainStandardError` and exits with `exitStatus`, read by the family's own runner.
    private func play(
        _ leaf: String,
        _ name: String,
        plainStandardError: [String] = [],
        exitStatus: Int32
    ) async throws -> Outcome {
        let cli = try standInCLI(standardError: try transcript(leaf, name) + plainStandardError, exitStatus: exitStatus)
        let told = ToldProgress()
        do {
            let result = try await LungfishCLIProcessRunner(cliURLProvider: { cli }).run(
                invocation: FASTQCLIInvocation(subcommand: "fastq", arguments: [String(leaf.dropFirst("fastq-".count))]),
                outputDirectory: folder,
                progress: { told.append($0, $1) }
            )
            return Outcome(told: told.calls, result: result, error: nil)
        } catch {
            return Outcome(told: told.calls, result: nil, error: error)
        }
    }

    private func transcript(_ leaf: String, _ name: String) throws -> [String] {
        let url = ProvenanceCompatCorpus.repositoryRoot
            .appendingPathComponent("Tests/Fixtures/cli-events/commands/\(leaf)/\(name).ndjson")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// A shell script in place of `lungfish-cli` that prints `lines` on standard error and exits.
    private func standInCLI(standardError lines: [String], exitStatus: Int32) throws -> URL {
        let tag = UUID().uuidString
        let text = folder.appendingPathComponent("standard-error-\(tag).txt")
        try (lines.joined(separator: "\n") + "\n").write(to: text, atomically: true, encoding: .utf8)
        let url = folder.appendingPathComponent("lungfish-cli-\(tag)")
        try "#!/bin/sh\n/bin/cat '\(text.path)' >&2\nexit \(exitStatus)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: Assertions

    /// The calls in order. A materializer computes some fractions by arithmetic, so 0.8 can arrive as
    /// 0.7999999999999999, and a fraction matches within a billionth.
    private func assertTold(
        _ actual: [(fraction: Double, message: String)],
        _ expected: [(Double, String)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "\(actual)", file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            XCTAssertEqual(pair.0.message, pair.1.1, "call \(index + 1)", file: file, line: line)
            XCTAssertEqual(pair.0.fraction, pair.1.0, accuracy: 1e-9, "call \(index + 1)", file: file, line: line)
        }
    }

    private func assertFailure(
        _ outcome: Outcome,
        status: Int32,
        text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let error = try XCTUnwrap(outcome.error, "A run that exits \(status) must throw", file: file, line: line)
        guard case let LungfishCLIRunner.RunError.nonZeroExit(thrownStatus, stderr) = error else {
            return XCTFail("Expected a nonZeroExit error, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(thrownStatus, status, file: file, line: line)
        XCTAssertEqual(stderr, text, "The failure text is the message of the failed line, not the Error: line", file: file, line: line)
        XCTAssertEqual(error.localizedDescription, "lungfish-cli exited with status \(status): \(text)", file: file, line: line)
    }
}

/// What the dialog was told, in order. The runner calls it from a reader task.
private final class ToldProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(fraction: Double, message: String)] = []

    func append(_ fraction: Double, _ message: String) {
        lock.lock()
        stored.append((fraction, message))
        lock.unlock()
    }

    var calls: [(fraction: Double, message: String)] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
