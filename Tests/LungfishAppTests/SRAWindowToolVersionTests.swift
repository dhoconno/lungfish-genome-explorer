// SRAWindowToolVersionTests.swift - The sra-tools version the window's import records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

/// Phase 2.6 lane P5a. The window's import records the SRA Toolkit steps with the `sra-tools`
/// version the managed tool lock pins, as `fetch sra download` does. Reading the lock by tool id
/// instead of through the tools list must not change what the record holds.
final class SRAWindowToolVersionTests: XCTestCase {

    func testToolkitStepsRecordTheSRAToolsVersionTheLockPins() throws {
        let root = try TestTempDirectory.make(prefix: "sra-window-tool-version")
        defer { TestTempDirectory.cleanup(root) }
        let lockVersion = try XCTUnwrap(ManagedToolLock.loadFromBundle().tool(named: "sra-tools")?.version)

        let bundle = root.appendingPathComponent("SRR1.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = bundle.appendingPathComponent("reads.fastq.gz")
        try Data().write(to: fastq)
        let start = Date(timeIntervalSince1970: 1_000)
        func trace(_ tool: String, at offset: TimeInterval) -> SRAService.FASTQDownloadStepTrace {
            SRAService.FASTQDownloadStepTrace(
                toolName: tool,
                toolVersion: "sra-tools",
                command: [tool, "SRR1"],
                inputs: ["SRR1"],
                outputs: [],
                exitCode: 0,
                wallTime: 1,
                stderr: "",
                startedAt: start.addingTimeInterval(offset),
                completedAt: start.addingTimeInterval(offset + 1)
            )
        }
        try writeGUISRAFASTQImportProvenance(
            accession: "SRR1",
            readRecord: nil,
            downloadSource: SRAFASTQDownloadSource.sraToolkit.rawValue,
            preferredSource: .ncbi,
            enaDownloadSteps: [],
            toolkitDownloadTraces: [trace("prefetch", at: 0), trace("fasterq-dump", at: 5)],
            cliArguments: ["import", "fastq"],
            cliCommandLine: CLIImportRunner.commandLine(arguments: ["import", "fastq"]),
            cliStartedAt: Date(timeIntervalSince1970: 2_000),
            cliCompletedAt: Date(timeIntervalSince1970: 2_001),
            stagedFASTQFiles: [],
            finalFASTQURL: fastq,
            bundleURL: bundle,
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "none",
            optimizeStorage: false,
            compressionLevel: "fast",
            cliBinaryPath: { URL(fileURLWithPath: "/injected/lungfish-cli") }
        )

        let run = try XCTUnwrap(ProvenanceRecorder.load(from: bundle))
        let toolkit = run.steps.filter { ["prefetch", "fasterq-dump"].contains($0.toolName) }
        XCTAssertEqual(toolkit.map(\.toolName), ["prefetch", "fasterq-dump"])
        XCTAssertEqual(toolkit.map(\.toolVersion), Array(repeating: "sra-tools \(lockVersion)", count: 2))
    }
}
