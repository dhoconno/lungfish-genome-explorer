// WorkflowRunLiveOutputTests.swift - workflow run writes each stdout line to a pipe as it prints it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
@testable import LungfishCLI
import XCTest

/// The app runs `lungfish-cli workflow run nf-core/viralrecon` with stdout on
/// a pipe and logs each line to the Operations Panel as it arrives. On a pipe
/// print held every line in a block buffer until the command exited, so the
/// Preparing, Read pairing and Created run bundle lines, and the progress of
/// a split that can take minutes, reached the panel only when the whole run
/// ended. The command now line-buffers stdout, so each line is on the pipe
/// as soon as it is printed.
final class WorkflowRunLiveOutputTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "workflow-run-live-output")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// Reads what the command has written to the pipe by the time Nextflow
    /// would be running.
    private final class PipeReadingNextflowRunner: NFCoreWorkflowProcessRunning, @unchecked Sendable {
        let readDescriptor: Int32
        private(set) var outputSeenWhileRunning: String?

        init(readDescriptor: Int32) {
            self.readDescriptor = readDescriptor
        }

        func runNextflow(arguments: [String], workingDirectory: URL, environment: [String: String]) async throws -> NFCoreWorkflowProcessResult {
            outputSeenWhileRunning = Self.drain(readDescriptor)
            if let index = arguments.firstIndex(of: "--outdir"), index + 1 < arguments.count {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: arguments[index + 1]),
                    withIntermediateDirectories: true
                )
            }
            return NFCoreWorkflowProcessResult(exitCode: 0, standardOutput: "done\n", standardError: "")
        }

        /// Everything already on the non-blocking pipe, without waiting for more.
        private static func drain(_ descriptor: Int32) -> String {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer[0..<count])
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    func testLinesPrintedBeforeTheEngineStartsAreOnThePipeWhileItRuns() async throws {
        let fastq = root.appendingPathComponent("reads.fastq")
        try InterleavedFASTQFixture.write(pairCount: 4, naming: .casava, to: fastq)
        let samplesheet = root.appendingPathComponent("samplesheet.csv")
        try "sample,fastq_1,fastq_2\nS1,\(fastq.path),\n".write(to: samplesheet, atomically: true, encoding: .utf8)
        let results = root.appendingPathComponent("results", isDirectory: true)

        let pipe = Pipe()
        let readDescriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(readDescriptor, F_SETFL, fcntl(readDescriptor, F_GETFL) | O_NONBLOCK)
        let runner = PipeReadingNextflowRunner(readDescriptor: readDescriptor)
        let originalRunner = RunSubcommand.nfCoreWorkflowProcessRunner
        RunSubcommand.nfCoreWorkflowProcessRunner = runner
        defer { RunSubcommand.nfCoreWorkflowProcessRunner = originalRunner }

        // stdout on the app's pipe starts with a block buffer, so this run does too.
        fflush(stdout)
        setvbuf(stdout, nil, _IOFBF, 0)
        let savedStdout = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        defer {
            fflush(stdout)
            dup2(savedStdout, STDOUT_FILENO)
            close(savedStdout)
            // Leave stdout with the buffering stdio gives the real stdout.
            setvbuf(stdout, nil, isatty(STDOUT_FILENO) != 0 ? _IOLBF : _IOFBF, 0)
        }

        try await RunSubcommand.parse([
            "nf-core/viralrecon",
            "--input", samplesheet.path,
            "--results-dir", results.path,
            "--expected-output", results.path,
            "--bundle-path", root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true).path,
            "--param", "platform=illumina",
        ]).run()

        let seen = try XCTUnwrap(runner.outputSeenWhileRunning, "the run never reached the engine")
        for line in [
            "Preparing workflow: nf-core/viralrecon",
            "Read pairing: S1",
            "Created run bundle: ",
            "Splitting interleaved pairs of S1 into R1/R2",
        ] {
            XCTAssertTrue(seen.contains(line), "\"\(line)\" was still buffered while the engine ran. The pipe held:\n\(seen)")
        }
    }
}
