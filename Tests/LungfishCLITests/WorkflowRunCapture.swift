// WorkflowRunCapture.swift - Runs workflow run in this process on stand-in runners and captures what it prints
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A30 M3 (ARCH's ruling on M3). Shared by WorkflowRunOutcomeLinesTests and WorkflowRunEventsTests.

import Foundation
@testable import LungfishCLI
@testable import LungfishWorkflow

/// Stands in for Nextflow on a Viral Recon run. Its Docker wait reports the engine's two lines, and its run writes the
/// iVar table of each `called` sample into the results folder and, when given, a trace into `pipeline_info`.
final class ViralReconStandInRunner: NFCoreWorkflowProcessRunning, @unchecked Sendable {
    let results: URL
    let called: [String]
    let trace: String?
    let exitCode: Int32
    let standardError: String

    init(results: URL, called: [String], trace: String? = nil, exitCode: Int32 = 0, standardError: String = "") {
        self.results = results
        self.called = called
        self.trace = trace
        self.exitCode = exitCode
        self.standardError = standardError
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
        return NFCoreWorkflowProcessResult(exitCode: exitCode, standardOutput: "", standardError: standardError)
    }
}

/// Stands in for a local workflow's engine. It makes the results folder and exits 0.
final class LocalWorkflowStandInRunner: LocalWorkflowProcessRunning, @unchecked Sendable {
    let results: URL

    init(results: URL) {
        self.results = results
    }

    func runtimeExecutableURL(named executableName: String) -> URL? {
        nil
    }

    func runWorkflow(executableName: String, arguments: [String], workingDirectory: URL) async throws -> LocalWorkflowProcessResult {
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        return LocalWorkflowProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    }
}

enum WorkflowRunCaptureSync {
    /// The text standard output held while `body` ran.
    static func standardOutput(in root: URL, _ body: () -> Void) throws -> String {
        let outURL = root.appendingPathComponent("captured-sync-stdout.txt")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        fflush(stdout)
        let savedOut = dup(STDOUT_FILENO)
        dup2(outHandle.fileDescriptor, STDOUT_FILENO)
        body()
        fflush(stdout)
        dup2(savedOut, STDOUT_FILENO)
        close(savedOut)
        try outHandle.close()
        defer { try? FileManager.default.removeItem(at: outURL) }
        return try String(contentsOf: outURL, encoding: .utf8)
    }
}

enum WorkflowRunCapture {
    /// The text standard output and standard error held while `body` ran, and the error it threw.
    struct Captured {
        let standardOutput: String
        let standardError: String
        let error: Error?
    }

    /// `workflow run nf-core/viralrecon` in `root` on a samplesheet of two paired samples, S1 and S2, which the run
    /// does not split. The FASTQ paths are under `root`, and nothing reads them.
    static func viralReconArguments(root: URL) throws -> [String] {
        let samplesheet = root.appendingPathComponent("samplesheet.csv")
        let reads = root.appendingPathComponent("reads", isDirectory: true).path
        try "sample,fastq_1,fastq_2\nS1,\(reads)/S1_R1.fastq.gz,\(reads)/S1_R2.fastq.gz\nS2,\(reads)/S2_R1.fastq.gz,\(reads)/S2_R2.fastq.gz\n"
            .write(to: samplesheet, atomically: true, encoding: .utf8)
        return [
            "nf-core/viralrecon",
            "--executor", "docker",
            "--input", samplesheet.path,
            "--results-dir", root.appendingPathComponent("results", isDirectory: true).path,
            "--expected-output", root.appendingPathComponent("results", isDirectory: true).path,
            "--bundle-path", root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true).path,
            "--version", "3.0.0",
            "--param", "platform=illumina",
            "--param", "protocol=amplicon",
        ]
    }

    /// Runs `body` with standard output and standard error in files under `root`, and returns both texts.
    static func run(in root: URL, _ body: () async throws -> Void) async throws -> Captured {
        let outURL = root.appendingPathComponent("captured-stdout.txt")
        let errURL = root.appendingPathComponent("captured-stderr.txt")
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
            try await body()
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
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        return Captured(
            standardOutput: try String(contentsOf: outURL, encoding: .utf8),
            standardError: try String(contentsOf: errURL, encoding: .utf8),
            error: thrown
        )
    }
}
