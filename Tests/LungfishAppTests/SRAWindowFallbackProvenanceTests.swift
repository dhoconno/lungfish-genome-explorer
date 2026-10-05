// SRAWindowFallbackProvenanceTests.swift - The window's provenance of a run that fell back to the other archive
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

/// Review finding S3-4: when Prefer NCBI's toolkit failed and ENA served the
/// run, the window's provenance listed ENA's transfers before the earlier
/// toolkit steps, and the import step depended on the failed toolkit steps.
/// The steps now run in time order, the failed attempt stays recorded and
/// marked failed, the import depends only on the transfers that served the
/// run, and the record names the requested and selected strategies and the
/// fallback line as `fetch sra download` does.
final class SRAWindowFallbackProvenanceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sra-window-fallback-provenance")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testAToolkitFailureThenENARecordsTheStepsInOrderAndTheImportDependsOnENAOnly() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let enaStep = StepExecution(
            toolName: "https-download", toolVersion: "URLSession", command: ["curl"],
            inputs: [], exitCode: 0, startTime: start.addingTimeInterval(10), endTime: start.addingTimeInterval(11)
        )
        let run = try record(
            preference: .ncbi,
            source: .enaAfterFailedToolkit,
            fallbackMessage: "The SRA Toolkit failed for SRR1, so ENA serves it instead. disk full",
            enaSteps: [enaStep],
            toolkitTraces: [
                trace("prefetch", exitCode: 0, at: start),
                trace("fasterq-dump", exitCode: 3, at: start.addingTimeInterval(5)),
            ]
        )

        XCTAssertEqual(run.steps.map(\.toolName), ["prefetch", "fasterq-dump", "https-download", "lungfish-cli"])
        let failed = run.steps.filter { $0.resolvedOptions?["attempt"] == .string("failed") }
        XCTAssertEqual(failed.map(\.toolName), ["prefetch", "fasterq-dump"], "the failed toolkit attempt stays recorded, marked failed")
        XCTAssertEqual(run.steps.last?.dependsOn, [enaStep.id], "the import depends only on the transfers that served the run")
        XCTAssertEqual(run.parameters["requestedStrategy"], .string("sra-toolkit-first"))
        XCTAssertEqual(run.parameters["selectedStrategy"], .string("ena-fallback"))
        XCTAssertEqual(run.parameters["fallbackMessage"], .string("The SRA Toolkit failed for SRR1, so ENA serves it instead. disk full"))
    }

    func testAToolkitSuccessUnderPreferNCBIDependsOnTheToolkitSteps() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let run = try record(
            preference: .ncbi,
            source: .sraToolkit,
            fallbackMessage: nil,
            enaSteps: [],
            toolkitTraces: [trace("prefetch", exitCode: 0, at: start), trace("fasterq-dump", exitCode: 0, at: start.addingTimeInterval(5))]
        )
        XCTAssertEqual(run.steps.last?.dependsOn, Array(run.steps.dropLast().map(\.id)))
        XCTAssertTrue(run.steps.allSatisfy { $0.resolvedOptions?["attempt"] == nil })
        XCTAssertEqual(run.parameters["requestedStrategy"], .string("sra-toolkit-first"))
        XCTAssertEqual(run.parameters["selectedStrategy"], .string("sra-toolkit"))
        XCTAssertEqual(run.parameters["fallbackMessage"], .null)
    }

    func testPreferENARecordsTheCLIStrategyNames() throws {
        let direct = try record(preference: .ena, source: .ena, fallbackMessage: nil, enaSteps: [], toolkitTraces: [])
        XCTAssertEqual(direct.parameters["requestedStrategy"], .string("ena-direct"))
        XCTAssertEqual(direct.parameters["selectedStrategy"], .string("ena-direct"))

        let fallback = try record(
            preference: .ena, source: .sraToolkitAfterFailedTransfer,
            fallbackMessage: "ENA transfer failed for SRR1; using SRA Toolkit...", enaSteps: [], toolkitTraces: []
        )
        XCTAssertEqual(fallback.parameters["requestedStrategy"], .string("ena-direct"))
        XCTAssertEqual(fallback.parameters["selectedStrategy"], .string("sra-toolkit-fallback"))
        XCTAssertEqual(fallback.parameters["fallbackMessage"], .string("ENA transfer failed for SRR1; using SRA Toolkit..."))
    }

    // MARK: - Helpers

    private func trace(_ tool: String, exitCode: Int32, at start: Date) -> SRAService.FASTQDownloadStepTrace {
        SRAService.FASTQDownloadStepTrace(
            toolName: tool,
            toolVersion: "sra-tools",
            command: [tool, "SRR1"],
            inputs: ["SRR1"],
            outputs: [],
            exitCode: exitCode,
            wallTime: 1,
            stderr: exitCode == 0 ? "" : "disk full",
            startedAt: start,
            completedAt: start.addingTimeInterval(1)
        )
    }

    private func record(
        preference: SRADownloadSourcePreference,
        source: SRAFASTQDownloadSource,
        fallbackMessage: String?,
        enaSteps: [StepExecution],
        toolkitTraces: [SRAService.FASTQDownloadStepTrace]
    ) throws -> WorkflowRun {
        let bundle = root.appendingPathComponent("SRR1-\(UUID().uuidString).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = bundle.appendingPathComponent("reads.fastq.gz")
        try Data().write(to: fastq)
        try writeGUISRAFASTQImportProvenance(
            accession: "SRR1",
            readRecord: nil,
            downloadSource: source.rawValue,
            preferredSource: preference,
            fallbackMessage: fallbackMessage,
            enaDownloadSteps: enaSteps,
            toolkitDownloadTraces: toolkitTraces,
            cliArguments: ["import", "fastq"],
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
        return try XCTUnwrap(ProvenanceRecorder.load(from: bundle))
    }
}
