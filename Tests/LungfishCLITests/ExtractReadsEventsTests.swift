// ExtractReadsEventsTests.swift - extract reads speaks events under --format json
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A51 M3. The viewer's three read rows launch `extract reads` on the L3 runner, which
// reads the command's `CLIEvent` lines (ADDING-AN-OPERATION.md, the recipe of a new CLI route). With
// `--format json` standard output holds only events, a start, then a complete that names what the run
// wrote or a failed that names the fix, and the human text goes to standard error. The runs use
// samtools on the sarscov2 BAM.

import ArgumentParser
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class ExtractReadsEventsTests: XCTestCase {
    private static let bam = ProvenanceCompatCorpus.repositoryRoot
        .appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")

    private func run(_ arguments: [String], in scratch: ImportStreamCapture.Scratch) async throws -> (events: [CLIEvent], output: ImportStreamCapture.Output) {
        let command = try ExtractReadsSubcommand.parse(arguments)
        let output = try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
        let decoder = CLIEventLineDecoder()
        var events: [CLIEvent] = []
        for line in output.standardOutput where !line.isEmpty {
            events.append(try XCTUnwrap(try? decoder.decodeLine(line)?.event, "standard output holds a line that is no event: \(line)"))
        }
        return (events, output)
    }

    func testWithFormatJSONStandardOutputHoldsOnlyEventsThatNameTheReadsWritten() async throws {
        guard SamtoolsLocator.locate() != nil else { throw XCTSkip("The managed samtools is not installed.") }
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let fastq = scratch.root.appendingPathComponent("orf1a.fastq")

        let (events, output) = try await run([
            "--by-region", "--bam", Self.bam.path, "--region", "MT192765.1:1-3000", "-o", fastq.path, "--format", "json",
        ], in: scratch)

        XCTAssertNil(output.thrown)
        XCTAssertEqual(events.first, .start(message: "Extracting reads…"))
        guard case .complete(let outputs, let message)? = events.last else {
            return XCTFail("the last event is no complete: \(events)")
        }
        XCTAssertEqual(outputs, ["/work/orf1a.fastq"])
        let count = try String(contentsOf: fastq, encoding: .utf8).split(separator: "\n").count / 4
        XCTAssertEqual(message, "Extracted \(count) reads")
        XCTAssertTrue(output.standardError.contains { $0.contains("Extraction complete") }, "the text goes to standard error")
    }

    /// TTL2-BIO SF2. The record a run writes holds the limit it was given with `--time-limit`, and none without it.
    func testTheRecordOfARunHoldsTheTimeLimitOnlyWhenOneWasSet() async throws {
        guard SamtoolsLocator.locate() != nil else { throw XCTSkip("The managed samtools is not installed.") }
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }

        func recordedLimit(_ extra: [String], folder: String) async throws -> ParameterValue? {
            let directory = scratch.root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let (_, output) = try await run([
                "--by-region", "--bam", Self.bam.path, "--region", "MT192765.1:1-3000",
                "-o", directory.appendingPathComponent("orf1a.fastq").path, "--format", "json",
            ] + extra, in: scratch)
            XCTAssertNil(output.thrown)
            let sidecar = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
            return try envelope.legacyWorkflowRun().parameters[AnalysisTimeLimit.recordKey]
        }

        let limited = try await recordedLimit(["--time-limit", "20"], folder: "limited")
        XCTAssertEqual(limited, .integer(20), "the written record names the limit the run was given")
        let plain = try await recordedLimit([], folder: "plain")
        XCTAssertNil(plain, "a run with no limit records none")
    }

    func testARefusalEndsInAFailedEventThatNamesTheFixAndExits3() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let missing = scratch.root.appendingPathComponent("missing.bam")

        let (events, output) = try await run([
            "--by-region", "--bam", missing.path, "--region", "MT192765.1:1-3000",
            "-o", scratch.root.appendingPathComponent("out.fastq").path, "--format", "json",
        ], in: scratch)

        XCTAssertEqual((output.thrown as? ExitCode)?.rawValue, 3)
        XCTAssertEqual(events.first, .start(message: "Extracting reads…"))
        XCTAssertEqual(events.last, .failed(message: "BAM file not found: /work/missing.bam", detail: nil))
    }
}
