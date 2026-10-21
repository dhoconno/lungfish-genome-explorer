// AssemblyRouteFreezeTests.swift - The command the Reassemble row records, frozen before its route moves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A46 M2, panel decisions C4 and C7 with QA's and BIO's additions. Reassemble runs
// ManagedAssemblyPipeline in the app today (census row p32) and records the `lungfish-cli assemble`
// command that `AssemblyRunner.cliCommandPreview` builds through the FASTQ operations dialog's
// builder. Its CLI route will run that argv, so each word is frozen here first: `--json-events`,
// the folder the pipeline writes, and the threads and memory the run uses (BIO). The preview fell
// back to a bare `assemble` when the builder threw, and no request reached that fallback, which the
// ruling on the reference bundle removed with `--reference-bundle`, the one word both Reassemble
// routes add. A command a row recorded keeps parsing once `assemble` moves to `--format json` (QA).

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishWorkflow

@MainActor
final class AssemblyRouteFreezeTests: XCTestCase {
    private static let output = URL(fileURLWithPath: "/tmp/lane a46/Assembly Output", isDirectory: true)
    private static let r1 = URL(fileURLWithPath: "/tmp/lane a46/Reads/Sample R1.fastq.gz")
    private static let r2 = URL(fileURLWithPath: "/tmp/lane a46/Reads/Sample R2.fastq.gz")

    /// A paired SPAdes run as the wizard hands it to `runValidated`, with memory, a minimum contig
    /// length, a profile and an extra argument.
    private static var pairedRequest: AssemblyRunRequest {
        AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [r1, r2],
            projectName: "Mito Assembly",
            outputDirectory: output,
            pairedEnd: true,
            threads: 4,
            memoryGB: 8,
            minContigLength: 500,
            selectedProfileID: "meta",
            extraArguments: ["--only-assembler"]
        ).normalizedForExecution()
    }

    /// The command `runValidated` records for `request`, the preview of the folder the pipeline writes.
    private static func recordedCommand(_ request: AssemblyRunRequest) -> String {
        AssemblyRunner.cliCommandPreview(
            request: request,
            outputDirectory: AssemblyRunner.executionRequest(for: request).outputDirectory
        )
    }

    /// The command the row of `pairedRequest` recorded at the base, `0e8ac3bd3` and every commit up
    /// to this pin.
    private static let recordedAtTheBase = """
        lungfish-cli assemble '/tmp/lane a46/Reads/Sample R1.fastq.gz' '/tmp/lane a46/Reads/Sample R2.fastq.gz' \
        --paired --json-events --assembler spades --read-type illumina-short-reads --project-name 'Mito Assembly' \
        --threads 4 --output '/tmp/lane a46/Assembly Output/Mito Assembly' --memory-gb 8 --min-contig-length 500 \
        --profile meta --extra-args --only-assembler
        """

    func testThePairedRowRecordsTheBuildersArgvWithTheRunsThreadsAndMemory() throws {
        let request = Self.pairedRequest
        let words = try RecordedCLICommand.arguments(of: Self.recordedCommand(request))
        // `--format json` closes the argv since `assemble` moved its events to standard output (C7).
        XCTAssertEqual(words, [
            "assemble", Self.r1.path, Self.r2.path, "--paired",
            "--assembler", "spades", "--read-type", "illumina-short-reads", "--project-name", "Mito Assembly",
            "--threads", "4", "--output", "/tmp/lane a46/Assembly Output/Mito Assembly",
            "--memory-gb", "8", "--min-contig-length", "500", "--profile", "meta", "--extra-args", "--only-assembler",
            "--reference-bundle", "--format", "json",
        ])
        // BIO. The recorded threads and memory are the ones the in-process pipeline runs with.
        let execution = AssemblyRunner.executionRequest(for: request)
        XCTAssertEqual(words[words.firstIndex(of: "--threads")! + 1], String(execution.threads))
        XCTAssertEqual(words[words.firstIndex(of: "--memory-gb")! + 1], execution.memoryGB.map(String.init))
    }

    func testASingleInterleavedFileRecordsItsLayout() throws {
        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [Self.r1],
            projectName: "Interleaved",
            outputDirectory: Self.output,
            threads: 2,
            inputLayout: .strictlyInterleaved
        ).normalizedForExecution()
        // The recorded command carries the thread count the run uses, and MEGAHIT gets one thread on Apple silicon
        // (AssemblyExecutionHost.megahitThreadCap, Phase 2.13 lane 13.19, O8).
        #if os(macOS) && arch(arm64)
        let recordedThreads = "1"
        #else
        let recordedThreads = "2"
        #endif
        XCTAssertEqual(try RecordedCLICommand.arguments(of: Self.recordedCommand(request)), [
            "assemble", Self.r1.path, "--read-layout", "interleaved",
            "--assembler", "megahit", "--read-type", "illumina-short-reads", "--project-name", "Interleaved",
            "--threads", recordedThreads, "--output", "/tmp/lane a46/Assembly Output/Interleaved",
            "--reference-bundle", "--format", "json",
        ])
    }

    /// No request reaches a bare `lungfish-cli assemble`. The preview had that fallback until the
    /// builder's `assemble` arm became a static that cannot throw, and every shape still records the
    /// whole command.
    func testNoRequestReachesTheBareFallback() throws {
        for tool in AssemblyTool.allCases {
            let readType = AssemblyCompatibility.defaultReadType(for: tool)
            let shapes: [(inputs: [URL], paired: Bool)] = [([Self.r1, Self.r2], true), ([Self.r1], false), ([Self.r1, Self.r2], false)]
            for shape in shapes {
                let request = AssemblyRunRequest(
                    tool: tool,
                    readType: readType,
                    inputURLs: shape.inputs,
                    projectName: "Shape",
                    outputDirectory: Self.output,
                    pairedEnd: shape.paired,
                    threads: 1
                ).normalizedForExecution()
                let words = try RecordedCLICommand.arguments(of: Self.recordedCommand(request))
                XCTAssertEqual(words.first, "assemble")
                XCTAssertTrue(words.contains("--output"), "\(tool) \(shape): \(words)")
            }
        }
    }

    /// QA's parse test of C7. The command a row recorded at the base, with `--json-events`, parses
    /// with the values the run used, and its hidden alias turns on the events on standard output.
    func testACommandRecordedAtTheBaseParses() throws {
        let command = try RecordedCLICommand.parse(Self.recordedAtTheBase, as: AssembleCommand.self)
        XCTAssertTrue(command.jsonEvents)
        XCTAssertTrue(command.eventsOn)
        XCTAssertEqual(CLIEventContractTable.entries["assemble"], .events(flag: "--format json", channel: .standardOutput))
        XCTAssertEqual(command.fastqFiles, [Self.r1.path, Self.r2.path])
        XCTAssertTrue(command.pairedEnd)
        XCTAssertEqual(command.assembler, "spades")
        XCTAssertEqual(command.outputDir, "/tmp/lane a46/Assembly Output/Mito Assembly")
        XCTAssertEqual(command.memoryGB, 8)
        XCTAssertEqual(command.minContigLength, 500)
    }
}
