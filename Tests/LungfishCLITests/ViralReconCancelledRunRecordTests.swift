// ViralReconCancelledRunRecordTests.swift - workflow run records a Viral Recon run cancelled before Nextflow starts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A30 M3, fix 1 of the M2 review. A cancel during the Docker wait left the manifest `prepared` with no
// provenance, and a cancel during the read split left it `running`. Each now records the run as cancelled with the
// command's own exit code, 125, as a cancel of the engine does (SWIFT 3), before the scratch is left for the sweep.

import ArgumentParser
import Foundation
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class ViralReconCancelledRunRecordTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // The CLI standardizes every path it records (/var -> /private/var).
        root = try TestTempDirectory.make(prefix: "viralrecon-cancelled-record").resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// Cancels the run in its Docker wait and counts the launches of Nextflow, which a cancel before the launch never
    /// reaches.
    private final class CancellingNextflowRunner: NFCoreWorkflowProcessRunning, @unchecked Sendable {
        enum Cancel {
            /// The wait throws, as a cancelled wait does.
            case throwsFromTheWait
            /// The wait cancels the run's task and returns, so the cancel reaches the next step that checks it.
            case cancelsTheRunsTask
        }

        private let cancel: Cancel
        private let lock = NSLock()
        private var launchCount = 0

        init(_ cancel: Cancel) {
            self.cancel = cancel
        }

        var launches: Int {
            lock.withLock { launchCount }
        }

        func waitForDocker(profile: String) async throws {
            switch cancel {
            case .throwsFromTheWait:
                throw CancellationError()
            case .cancelsTheRunsTask:
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        func runNextflow(_ launch: NFCoreWorkflowLaunch) async throws -> NFCoreWorkflowProcessResult {
            lock.withLock { launchCount += 1 }
            return NFCoreWorkflowProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
    }

    /// A cancel during the Docker wait records the run as cancelled and launches nothing.
    func testACancelDuringTheDockerWaitRecordsACancelledRun() async throws {
        let runner = CancellingNextflowRunner(.throwsFromTheWait)
        let bundle = try await runCancelled(runner)
        try assertRecordedCancelled(bundle, runner: runner)
    }

    /// A cancel that reaches the split of interleaved reads into R1 and R2 records the run as cancelled and launches
    /// nothing.
    func testACancelDuringReadSplittingRecordsACancelledRun() async throws {
        let runner = CancellingNextflowRunner(.cancelsTheRunsTask)
        let bundle = try await runCancelled(runner)
        try assertRecordedCancelled(bundle, runner: runner)
        let decisions = try XCTUnwrap(ViralReconReadPairing.loadDecisions(
            from: bundle.appendingPathComponent("inputs/\(ViralReconReadPairing.decisionsFilename)")
        ))
        XCTAssertTrue(decisions.contains(where: \.needsSplit), "the run had reads to split: \(decisions)")
    }

    // MARK: - Helpers

    /// Runs `workflow run nf-core/viralrecon` on a samplesheet whose one Illumina sample is an interleaved file, which
    /// the run splits into R1 and R2, inside a project, so a scratch the cancel leaves for the sweep stays in the
    /// test's folder. Returns the run bundle once the command has exited 125.
    private func runCancelled(_ runner: CancellingNextflowRunner) async throws -> URL {
        let project = root.appendingPathComponent("Cancel.lungfish", isDirectory: true)
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let reads = project.appendingPathComponent("reads.fastq")
        try InterleavedFASTQFixture.write(pairCount: 4, naming: .casava, to: reads)
        let samplesheet = project.appendingPathComponent("samplesheet.csv")
        try "sample,fastq_1,fastq_2\nS1,\(reads.path),\n".write(to: samplesheet, atomically: true, encoding: .utf8)
        let bundle = analyses.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
        let results = analyses.appendingPathComponent("viralrecon-results", isDirectory: true)
        do {
            try await RunSubcommand.parse([
                "nf-core/viralrecon",
                "--executor", "docker",
                "--input", samplesheet.path,
                "--results-dir", results.path,
                "--expected-output", results.path,
                "--bundle-path", bundle.path,
                "--version", "3.0.0",
                "--param", "platform=illumina",
                "--param", "protocol=amplicon",
                "--quiet",
            ]).run(nfCoreRunner: runner)
            XCTFail("a cancelled run ended without an error")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit.rawValue, CLIExitCode.cancelled.rawValue, "a cancel exits 125")
        }
        return bundle
    }

    /// The manifest and then the provenance record the run as cancelled with the command's exit code, 125, and no
    /// Nextflow was launched.
    private func assertRecordedCancelled(
        _ bundle: URL,
        runner: CancellingNextflowRunner,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(runner.launches, 0, "a cancel before the launch starts no Nextflow", file: file, line: line)
        let manifest = try NFCoreRunBundleStore.read(from: bundle)
        XCTAssertEqual(manifest.executionStatus, .cancelled, file: file, line: line)
        XCTAssertEqual(manifest.exitCode, CLIExitCode.cancelled.rawValue, "the command's own exit code", file: file, line: line)
        XCTAssertNotNil(manifest.completedAt, file: file, line: line)
        let provenance = try XCTUnwrap(
            ProvenanceEnvelopeReader.loadCanonical(from: bundle),
            "no provenance for the cancelled run",
            file: file,
            line: line
        )
        XCTAssertEqual(provenance.status, .cancelled, file: file, line: line)
        XCTAssertEqual(provenance.steps.first?.exitStatus, Int(CLIExitCode.cancelled.rawValue), file: file, line: line)
    }
}
