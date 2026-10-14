// WorkflowRunOutcomeLinesTests.swift - workflow run prints a Viral Recon run's outcome lines and its Docker wait
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A30 M3, ARCH's ruling on M3 (commit 4, decision N5). After a run that exits 0 the command reads the
// run's own trace for ignored tasks and its results for failed samples, and prints one warning line for each kind on
// standard error with UX's words, even under --quiet. The Docker wait's two lines reach standard output through the
// runner's progress closure. Each case runs the command in this process on a stand-in runner that writes what a run
// of nf-core/viralrecon 3.0.0 leaves in its results folder.

import ArgumentParser
import Foundation
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class WorkflowRunOutcomeLinesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // The CLI standardizes every path it records (/var -> /private/var).
        root = try TestTempDirectory.make(prefix: "workflow-run-outcome").resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// Stands in for Nextflow. Its Docker wait reports the engine's two lines, and its run writes `called` samples'
    /// iVar tables into the results folder and, when given, a trace into `pipeline_info`, and exits 0.
    private final class StandInRunner: NFCoreWorkflowProcessRunning, @unchecked Sendable {
        let results: URL
        let called: [String]
        let trace: String?

        init(results: URL, called: [String], trace: String? = nil) {
            self.results = results
            self.called = called
            self.trace = trace
        }

        func waitForDocker(profile: String, progress: (@Sendable (Double, String) -> Void)?) async throws {
            progress?(0.01, "Docker daemon unavailable. Launching Docker Desktop...")
            progress?(0.02, "Docker daemon ready")
        }

        func runNextflow(_ launch: NFCoreWorkflowLaunch) async throws -> NFCoreWorkflowProcessResult {
            let ivar = results.appendingPathComponent("variants/ivar", isDirectory: true)
            try FileManager.default.createDirectory(at: ivar, withIntermediateDirectories: true)
            for sample in called {
                try "REGION\tPOS\tREF\tALT\n".write(to: ivar.appendingPathComponent("\(sample).tsv"), atomically: true, encoding: .utf8)
            }
            if let trace {
                let folder = results.appendingPathComponent("pipeline_info", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try trace.write(to: folder.appendingPathComponent("execution_trace_2026-10-14_01-00-00.txt"), atomically: true, encoding: .utf8)
            }
            return NFCoreWorkflowProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
    }

    private var results: URL { root.appendingPathComponent("results", isDirectory: true) }

    /// A stand-in run in which S2 never reached iVar and Pangolin's task of S1 failed with no retry left.
    func testAStandInRunMissingOneSamplesOutputPrintsTheFailedSampleLine() async throws {
        let trace = "task_id\thash\tname\tstatus\texit\n"
            + "1\taa/000001\tNFCORE_VIRALRECON:VIRALRECON:VARIANTS_IVAR:IVAR_VARIANTS (S1)\tCOMPLETED\t0\n"
            + "2\taa/000002\tNFCORE_VIRALRECON:VIRALRECON:CONSENSUS_BCFTOOLS:CONSENSUS_QC:PANGOLIN_RUN (S1)\tFAILED\t1\n"
        let runner = StandInRunner(results: results, called: ["S1"], trace: trace)

        let output = try await runCapturing(arguments(), runner: runner)

        XCTAssertTrue(
            output.standardError.contains("⚠ Some Viral Recon tasks failed: PANGOLIN_RUN (S1). Their outputs are missing.\n"),
            output.standardError
        )
        XCTAssertTrue(
            output.standardError.contains(
                "⚠ 1 failed sample: S2. Too few reads were left after trimming or mapping to call variants.\n"
            ),
            output.standardError
        )
        XCTAssertEqual(output.standardOutput.split(separator: "\n").last.map(String.init), bundle.path, "the bundle path stays the last line")
    }

    /// Under --quiet the outcome lines still print, as a read pairing warning does, and the wait's lines do not.
    func testTheOutcomeLinesPrintUnderQuietAndTheWaitLinesPrintWithoutIt() async throws {
        let quiet = try await runCapturing(arguments() + ["--quiet"], runner: StandInRunner(results: results, called: ["S1"]))
        XCTAssertTrue(quiet.standardError.contains("⚠ 1 failed sample: S2."), quiet.standardError)
        XCTAssertFalse(quiet.standardOutput.contains("Docker daemon"), quiet.standardOutput)

        TestTempDirectory.cleanup(root)
        root = try TestTempDirectory.make(prefix: "workflow-run-outcome").resolvingSymlinksInPath()
        let loud = try await runCapturing(arguments(), runner: StandInRunner(results: results, called: ["S1", "S2"]))
        XCTAssertTrue(loud.standardOutput.contains("ℹ Docker daemon unavailable. Launching Docker Desktop...\nℹ Docker daemon ready\n"), loud.standardOutput)
    }

    /// A run whose samples all reached the caller and whose trace holds no ignored task prints no outcome line.
    func testACleanRunPrintsNoOutcomeLine() async throws {
        let output = try await runCapturing(arguments(), runner: StandInRunner(results: results, called: ["S1", "S2"]))
        XCTAssertFalse(output.standardError.contains("⚠"), output.standardError)
    }

    // MARK: - Helpers

    private var bundle: URL { root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true) }

    /// `workflow run nf-core/viralrecon` on a samplesheet of two paired samples, S1 and S2, which the run does not split.
    private func arguments() throws -> [String] {
        let samplesheet = root.appendingPathComponent("samplesheet.csv")
        try "sample,fastq_1,fastq_2\nS1,/tmp/S1_R1.fastq.gz,/tmp/S1_R2.fastq.gz\nS2,/tmp/S2_R1.fastq.gz,/tmp/S2_R2.fastq.gz\n"
            .write(to: samplesheet, atomically: true, encoding: .utf8)
        return [
            "nf-core/viralrecon",
            "--executor", "docker",
            "--input", samplesheet.path,
            "--results-dir", results.path,
            "--expected-output", results.path,
            "--bundle-path", bundle.path,
            "--version", "3.0.0",
            "--param", "platform=illumina",
            "--param", "protocol=amplicon",
        ]
    }

    /// Runs the command with standard output and standard error in files, and returns both texts.
    private func runCapturing(
        _ arguments: [String],
        runner: any NFCoreWorkflowProcessRunning
    ) async throws -> (standardOutput: String, standardError: String) {
        let outURL = root.appendingPathComponent("stdout.txt")
        let errURL = root.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        fflush(stdout)
        fflush(stderr)
        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)
        dup2(outHandle.fileDescriptor, STDOUT_FILENO)
        dup2(errHandle.fileDescriptor, STDERR_FILENO)
        var thrown: Error?
        do {
            try await RunSubcommand.parse(arguments).run(nfCoreRunner: runner)
        } catch {
            thrown = error
        }
        fflush(stdout)
        fflush(stderr)
        dup2(savedOut, STDOUT_FILENO)
        dup2(savedErr, STDERR_FILENO)
        close(savedOut)
        close(savedErr)
        // Leave stdout with the buffering stdio gives the real stdout, since the command sets line buffering.
        setvbuf(stdout, nil, isatty(STDOUT_FILENO) != 0 ? _IOLBF : _IOFBF, 0)
        try outHandle.close()
        try errHandle.close()
        if let thrown { throw thrown }
        return (try String(contentsOf: outURL, encoding: .utf8), try String(contentsOf: errURL, encoding: .utf8))
    }
}
