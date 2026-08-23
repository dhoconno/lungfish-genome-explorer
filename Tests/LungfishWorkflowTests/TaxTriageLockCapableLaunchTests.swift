// TaxTriageLockCapableLaunchTests.swift - Nextflow launch directory + failure diagnostics
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Regression coverage for a real failure on an exFAT volume (2026-08-23):
// Nextflow was launched with its working directory set to the project result
// directory. exFAT does not support POSIX file locks, so Nextflow aborted with
// "Can't open cache DB: <resultDir>/.nextflow/cache/... Nextflow needs to be
// executed in a shared file system that supports file locks." and exited 1.
// The surfaced Lungfish message was "TaxTriage pipeline failed with exit code
// 1: " because the actionable text arrived on stdout, not stderr.

import XCTest
@testable import LungfishWorkflow

final class TaxTriageLockCapableLaunchTests: XCTestCase {

    private func makeTempDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    // MARK: - Launch directory / work directory

    func testLocalLaunchScratchIsOutsideTheResultDirectory() throws {
        let pipeline = TaxTriagePipeline()
        let resultDirectory = try makeTempDirectory(prefix: "taxtriage-result")
        defer { try? FileManager.default.removeItem(at: resultDirectory) }

        let scratch = try pipeline.makeLocalLaunchScratch(contextURL: resultDirectory)
        defer { pipeline.cleanUpLaunchScratch(scratch) }

        XCTAssertFalse(
            scratch.launchDirectory.standardizedFileURL.path
                .hasPrefix(resultDirectory.standardizedFileURL.path),
            "The Nextflow launch directory (host of .nextflow/cache) must not live in the result directory"
        )
        XCTAssertTrue(
            scratch.workDirectory.standardizedFileURL.path
                .hasPrefix(scratch.launchDirectory.standardizedFileURL.path),
            "The work tree must live under the local scratch root"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: scratch.workDirectory.path),
            "The work directory must exist before Nextflow launches"
        )
    }

    func testLaunchScratchIsRemovedOnCleanup() throws {
        let pipeline = TaxTriagePipeline()
        let resultDirectory = try makeTempDirectory(prefix: "taxtriage-result")
        defer { try? FileManager.default.removeItem(at: resultDirectory) }

        let scratch = try pipeline.makeLocalLaunchScratch(contextURL: resultDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.launchDirectory.path))

        pipeline.cleanUpLaunchScratch(scratch)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: scratch.launchDirectory.path),
            "The scratch root (which can hold GBs of work/) must be removed after the run"
        )
    }

    func testNextflowArgumentsUseLocalWorkDirectoryAndProjectOutdir() throws {
        let pipeline = TaxTriagePipeline()
        let resultDirectory = URL(fileURLWithPath: "/Volumes/External/proj.lungfish/Analyses/taxtriage")
        let scratchWork = URL(fileURLWithPath: "/private/tmp/taxtriage-run-abc/work")

        let sample = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/reads.fq.gz"),
            platform: .illumina
        )
        let config = TaxTriageConfig(samples: [sample], outputDirectory: resultDirectory)

        let args = pipeline.buildNextflowArguments(
            config: config,
            pipelineLaunchTarget: TaxTriageConfig.pipelineRepository,
            pipelineRevision: config.revision,
            workDirectory: scratchWork
        )

        XCTAssertEqual(
            value(after: "-w", in: args),
            scratchWork.path,
            "Nextflow's work tree needs file locks, so -w must point at local scratch"
        )
        XCTAssertEqual(
            value(after: "--outdir", in: args),
            resultDirectory.path,
            "Published results must still land in the caller's result directory"
        )
    }

    func testNextflowArgumentsOmitWorkFlagWhenNoScratchGiven() {
        let pipeline = TaxTriagePipeline()
        let sample = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/reads.fq.gz"),
            platform: .illumina
        )
        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: URL(fileURLWithPath: "/output")
        )

        let args = pipeline.buildNextflowArguments(config: config)

        XCTAssertFalse(args.contains("-w"))
    }

    func testLaunchMetadataRecordsScratchLaunchAndWorkDirectories() throws {
        let pipeline = TaxTriagePipeline()
        let resultDirectory = try makeTempDirectory(prefix: "taxtriage-result")
        defer { try? FileManager.default.removeItem(at: resultDirectory) }

        let scratch = try pipeline.makeLocalLaunchScratch(contextURL: resultDirectory)
        defer { pipeline.cleanUpLaunchScratch(scratch) }

        let sample = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/reads.fq.gz"),
            platform: .illumina
        )
        let config = TaxTriageConfig(samples: [sample], outputDirectory: resultDirectory)
        let args = pipeline.buildNextflowLaunchArguments(
            config: config,
            runtimeConfigURL: resultDirectory.appendingPathComponent("lungfish.nextflow.config"),
            pipelineLaunchTarget: TaxTriageConfig.pipelineRepository,
            pipelineRevision: config.revision,
            workDirectory: scratch.workDirectory
        )

        let metadata = pipeline.buildLaunchMetadata(
            requestedConfig: config,
            effectiveConfig: config,
            nextflowArguments: args,
            launcherPath: "/usr/bin/micromamba",
            launcherArguments: args,
            workingDirectory: scratch.launchDirectory,
            environment: [:],
            nextflowWorkDirectory: scratch.workDirectory,
            workflowRevision: config.revision,
            workflowGithubReleaseVersion: nil
        )

        XCTAssertTrue(metadata.contains("working_directory: \(scratch.launchDirectory.path)"))
        XCTAssertTrue(metadata.contains("nextflow_work_directory: \(scratch.workDirectory.path)"))
        XCTAssertTrue(metadata.contains("effective_output_directory: \(resultDirectory.path)"))
    }

    // MARK: - Failure diagnostics

    func testEmptyStderrFallsBackToStdoutTail() {
        let stdout = """
        N E X T F L O W  ~  version 24.10.0
        Can't open cache DB: /Volumes/iWES/32539.lungfish/Analyses/tt/.nextflow/cache/abc/db

        Nextflow needs to be executed in a shared file system that supports file locks.
        """

        let diagnostics = taxTriageFailureDiagnostics(stderr: "", stdout: stdout)

        XCTAssertTrue(diagnostics.contains("Can't open cache DB"))
        XCTAssertTrue(diagnostics.contains("supports file locks"))
    }

    func testBlankStderrFallsBackToStdoutTail() {
        let diagnostics = taxTriageFailureDiagnostics(
            stderr: "   \n\n  ",
            stdout: "Can't open cache DB: /vol/.nextflow/cache/x"
        )

        XCTAssertTrue(diagnostics.contains("Can't open cache DB"))
    }

    func testNonEmptyStderrIsPreferredOverStdout() {
        let diagnostics = taxTriageFailureDiagnostics(
            stderr: "real stderr failure",
            stdout: "Can't open cache DB: /vol/.nextflow/cache/x"
        )

        XCTAssertEqual(diagnostics, "real stderr failure")
    }

    func testDiagnosticsAreCappedAtTheRequestedLimit() {
        let diagnostics = taxTriageFailureDiagnostics(
            stderr: "",
            stdout: String(repeating: "x", count: 5000)
        )

        XCTAssertEqual(diagnostics.count, 600)
    }

    func testPipelineFailedErrorSurfacesTheStdoutLockDiagnostic() {
        let stdout = """
        Can't open cache DB: /Volumes/iWES/32539.lungfish/Analyses/tt/.nextflow/cache/abc/db

        Nextflow needs to be executed in a shared file system that supports file locks.
        """
        let error = TaxTriagePipelineError.pipelineFailed(
            exitCode: 1,
            stderr: taxTriageFailureDiagnostics(stderr: "", stdout: stdout),
            logFile: nil
        )

        let message = try? XCTUnwrap(error.errorDescription)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("Can't open cache DB") == true, "Got: \(message ?? "nil")")
        XCTAssertTrue(message?.contains("exit code 1") == true)
    }

    func testPipelineFailedErrorNeverEndsWithABareColon() {
        let error = TaxTriagePipelineError.pipelineFailed(exitCode: 1, stderr: "", logFile: nil)

        let message = error.errorDescription ?? ""
        XCTAssertFalse(
            message.hasSuffix(": "),
            "An empty tool error must not surface as 'failed with exit code 1: '"
        )
        XCTAssertTrue(message.contains("no diagnostic output"))
    }

    // MARK: - Generic Nextflow runner

    func testNextflowRunnerFailureDiagnosticsFallBackToStdout() {
        let diagnostics = NextflowRunner.failureDiagnostics(
            stderr: "",
            stdout: "Nextflow needs to be executed in a shared file system that supports file locks."
        )

        XCTAssertTrue(diagnostics.contains("supports file locks"))
    }

    func testNextflowRunnerFailureDiagnosticsPreferStderr() {
        let diagnostics = NextflowRunner.failureDiagnostics(
            stderr: "boom",
            stdout: "ignored"
        )

        XCTAssertEqual(diagnostics, "boom")
    }
}
