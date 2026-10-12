// TaxTriageRunCommandReplayTests.swift - `taxtriage run` on the analysis run executor, on the stand-in Nextflow
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane A2, milestone 2. The command runs `TaxTriageAnalysisRunTool` through the executor.
// A plain `--output` keeps one Nextflow run of every sample (2.8 T2), `--project` and `--batch` run
// one Nextflow per sample (T5, 2.8 T2 and T4), `--format json` prints the executor's version 2
// events, and the flags that name the result's place are refused before any folder exists. Each
// case runs the command in this process with its pipeline seam bound to `TaxTriageStandInEngine`.
//
// `LUNGFISH_RECAPTURE_CLI_EVENTS=1` writes the events of the plain `--output` case, its folder
// rewritten to `/work`, as the transcript of the `taxtriage run` events leaf
// (`Tests/Fixtures/cli-events/commands/taxtriage-run/complete.ndjson`). The engine starts processes,
// so the class name ends in ReplayTests, which sends it to the serial replay tier.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageRunCommandReplayTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-run-command").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testAPlainOutputOfTwoSamplesIsOneNextflowRunThatPrintsVersion2Events() async throws {
        let engine = try makeEngine()
        let folder = try writeTwoSamples()
        let output = root.appendingPathComponent("out", isDirectory: true)

        let (code, lines) = try await run(["--input", folder.path, "--output", output.path, "--format", "json"], engine: engine)

        XCTAssertEqual(code, 0, lines.joined(separator: "\n"))
        let launches = try engine.launches()
        XCTAssertEqual(launches.count, 1, "a plain --output runs every sample in one Nextflow run (2.8 T2)")
        XCTAssertEqual(
            launches.first.map { String(decoding: $0.samplesheet, as: UTF8.self).split(separator: "\n").count },
            3,
            "the one samplesheet holds both samples"
        )
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: output))
        XCTAssertEqual(record.workflowName, TaxTriageAnalysisRunTool.workflowName, "the executor's root record")
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.steps.filter { $0.toolName == "taxtriage" }.count, 1)
        XCTAssertNil(
            record.steps.first { $0.toolName == "taxtriage" }?.resolvedOptions["sample"],
            "a pooled launch of two samples names no one sample on its step (B12)"
        )

        let events = try lines.map { try XCTUnwrap(try CLIEventLineDecoder().decode(line: $0), $0) }
        guard case .start? = events.first, case .complete(let outputs, _)? = events.last else {
            return XCTFail("the events do not run from start to complete: \(lines)")
        }
        XCTAssertEqual(outputs, [output.path])
        XCTAssertTrue(
            events.contains { event in
                if case .output(let path, let role) = event {
                    return path == output.path && role == CLIEventArtifact.Role.analysisDirectory
                }
                return false
            },
            "the early output line names the result folder"
        )
        try recaptureTranscriptIfAsked(lines)
    }

    /// BIO ruling X3 (SCR reviews, ruling-B12-homes.md). A pooled run that fails as a whole ends with the
    /// executor's workflow error, 64, which its root record states as its exit status, and the record's
    /// taxtriage step keeps Nextflow's own exit status, 1, so the tool's exit stays traceable behind the 64.
    func testAFailedPooledRunRecordsTheWorkflowError64AndItsStepKeepsNextflowsExit1() async throws {
        let engine = try makeEngine(.failsSamples(["B"]))
        let folder = try writeTwoSamples()
        let output = root.appendingPathComponent("out", isDirectory: true)

        let (code, lines) = try await run(["--input", folder.path, "--output", output.path, "--format", "json"], engine: engine)

        XCTAssertEqual(code, AnalysisRunExitCode.workflowError, lines.joined(separator: "\n"))
        XCTAssertEqual(try engine.launches().count, 1, "one Nextflow run of both samples (2.8 T2)")
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: output))
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.exitStatus, 64, "the executor's workflow error (ruling X1)")
        let step = try XCTUnwrap(record.steps.first { $0.toolName == "taxtriage" }, "\(record.steps.map(\.toolName))")
        XCTAssertEqual(step.exitStatus, 1, "Nextflow's exit status on the taxtriage step (ruling X3)")
    }

    func testAProjectOfTwoSamplesRunsEachSampleAloneInOneBatchFolder() async throws {
        let engine = try makeEngine()
        let folder = try writeTwoSamples()
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let (code, lines) = try await run(["--input", folder.path, "--project", project.path, "--format", "json"], engine: engine)

        XCTAssertEqual(code, 0, lines.joined(separator: "\n"))
        XCTAssertEqual(try engine.launches().count, 2, "--project runs one Nextflow per sample (2.8 T2)")
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        let batches = try FileManager.default.contentsOfDirectory(atPath: analyses.path).filter { $0.hasPrefix("taxtriage-batch-") }
        XCTAssertEqual(batches.count, 1, "one batch folder in the project")
        let batch = analyses.appendingPathComponent(try XCTUnwrap(batches.first), isDirectory: true)
        XCTAssertEqual(try ProvenanceEnvelopeReader.load(from: batch)?.workflowName, TaxTriageAnalysisRunTool.workflowName)
        for sample in ["A", "B"] {
            let sampleFolder = batch.appendingPathComponent(sample, isDirectory: true)
            XCTAssertEqual(try ProvenanceEnvelopeReader.load(from: sampleFolder)?.workflowName, "TaxTriage", "\(sample) keeps its own record")
        }
    }

    func testAOneSampleProjectRunWritesIntoItsBatchFolderItself() async throws {
        let engine = try makeEngine()
        let reads = try writeReads("S1.fastq", in: root.appendingPathComponent("loose", isDirectory: true))
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let (code, lines) = try await run(["--input", reads.path, "--sample", "S1", "--project", project.path], engine: engine)

        XCTAssertEqual(code, 0, lines.joined(separator: "\n"))
        let launches = try engine.launches()
        XCTAssertEqual(launches.count, 1)
        let outdir = try XCTUnwrap(launches.first?.value(after: "--outdir"))
        XCTAssertTrue(
            URL(fileURLWithPath: outdir).lastPathComponent.hasPrefix("taxtriage-batch-"),
            "one sample runs in the batch folder itself, as the app's run does (2.8 T4): \(outdir)"
        )
        XCTAssertEqual(
            try ProvenanceEnvelopeReader.load(from: URL(fileURLWithPath: outdir, isDirectory: true))?.workflowName,
            TaxTriageAnalysisRunTool.workflowName,
            "the root record replaced the pipeline's"
        )
    }

    func testBatchRunsEachSampleOfAPlainOutputAlone() async throws {
        let engine = try makeEngine()
        let folder = try writeTwoSamples()
        let output = root.appendingPathComponent("batch", isDirectory: true)

        let (code, lines) = try await run(["--input", folder.path, "--output", output.path, "--batch"], engine: engine)

        XCTAssertEqual(code, 0, lines.joined(separator: "\n"))
        XCTAssertEqual(try engine.launches().count, 2, "--batch runs one Nextflow per sample (T5)")
        for sample in ["A", "B"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: output.appendingPathComponent("\(sample)/taxtriage-result.json").path),
                sample
            )
        }
    }

    func testTheFlagsThatNameTheResultsPlaceAreRefusedBeforeAnyFolder() async throws {
        let engine = try makeEngine()
        let reads = try writeReads("S1.fastq", in: root.appendingPathComponent("loose", isDirectory: true))
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let cases: [(arguments: [String], words: String)] = [
            (["--project", project.path, "--output", output.path], "--project makes the result folder in the project, so it takes no --output."),
            ([], "Give --output or --project to name where the result goes."),
            (["--project", root.appendingPathComponent("Missing.lungfish").path], "Project not found: \(root.appendingPathComponent("Missing.lungfish").path)"),
        ]
        for refused in cases {
            let (code, lines) = try await run(
                ["--input", reads.path, "--sample", "S1", "--format", "json"] + refused.arguments,
                engine: engine
            )
            XCTAssertEqual(code, 3, "\(refused.arguments)")
            let last = try XCTUnwrap(lines.last.flatMap { try CLIEventLineDecoder().decode(line: $0) })
            guard case .failed(let message, _) = last else {
                XCTFail("\(refused.arguments) ends with \(last)")
                continue
            }
            XCTAssertEqual(message, refused.words)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a refused run makes no folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Analyses").path))
        XCTAssertEqual(try engine.launches().count, 0)
    }

    // MARK: - Helpers

    private func makeEngine(_ behaviour: TaxTriageStandInEngine.Behaviour = .completes) throws -> TaxTriageStandInEngine {
        let engine = try TaxTriageStandInEngine(
            root: root.appendingPathComponent("engine", isDirectory: true), behaviour: behaviour, maximumWait: .seconds(60)
        )
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        return engine
    }

    /// Runs `taxtriage run` with `arguments`, the stand-in's database, profile and CPU count, and
    /// the pipeline seam bound to `engine`, and returns its exit code and the JSON event lines.
    private func run(_ arguments: [String], engine: TaxTriageStandInEngine) async throws -> (Int32, [String]) {
        let database = root.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let command = try TaxTriageCommand.RunSubcommand.parse(
            ["run"] + arguments + ["--db", database.path, "--nf-profile", TaxTriageStandInEngine.profile, "--max-cpus", "2", "--quiet"]
        )
        let sink = EventLineSink()
        do {
            try await TaxTriageCommand.RunSubcommand.$makePipeline.withValue({ engine.makePipeline() }) {
                try await command.execute(events: .jsonLines { sink.append($0) })
            }
            return (0, sink.lines)
        } catch let exit as ExitCode {
            return (exit.rawValue, sink.lines)
        }
    }

    /// A folder of two single-read samples, `A.fastq` and `B.fastq`, whose names make no pair.
    private func writeTwoSamples() throws -> URL {
        let folder = root.appendingPathComponent("reads", isDirectory: true)
        try writeReads("A.fastq", in: folder)
        try writeReads("B.fastq", in: folder)
        return folder
    }

    @discardableResult
    private func writeReads(_ name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let text = (1...3).map { "@\(name)-read-\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Writes `lines`, with this case's folder rewritten to `/work`, as the transcript of the
    /// `taxtriage run` events leaf when `LUNGFISH_RECAPTURE_CLI_EVENTS=1`.
    private func recaptureTranscriptIfAsked(_ lines: [String]) throws {
        guard ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_CLI_EVENTS"] == "1" else { return }
        let escapedRoot = root.path.replacingOccurrences(of: "/", with: "\\/")
        let normalized = lines.map {
            $0.replacingOccurrences(of: escapedRoot, with: "\\/work").replacingOccurrences(of: root.path, with: "/work")
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let transcript = repository.appendingPathComponent("Tests/Fixtures/cli-events/commands/taxtriage-run/complete.ndjson")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (normalized.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
    }
}

/// The event lines of one run, collected under a lock, since the executor delivers from its task.
private final class EventLineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    func append(_ line: String) {
        lock.lock()
        collected.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}
