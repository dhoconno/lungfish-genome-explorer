// TaxTriageAnalysisRunToolReplayTests.swift - TaxTriage units on the analysis run executor, on the stand-in engine
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane A2 M2. `TaxTriageAnalysisRunTool` runs each unit through the pipeline body the app's
// route shares, with a recording that sends the record where the layout needs it. A plain `--output`
// is one launch in the result folder whose step the root record holds (ARCH 3). A `--batch` is one
// launch per sample folder, each keeping the sample's own record, with the database the batch used on
// the root (B12 row 256). The stand-in engine starts processes, so the class name ends in ReplayTests.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageAnalysisRunToolReplayTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-executor").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testAPlainOutputIsOneLaunchInTheResultFolderWhoseStepTheRootRecordHolds() async throws {
        let engine = try makeEngine()
        let reads = try writeReads("S1.fastq")
        let output = root.appendingPathComponent("out", isDirectory: true)

        let report = await execute(try makeTool(input: reads.path, sample: "S1", engine: engine), .directory(output), batch: false)

        XCTAssertEqual(report.status, .completed, report.message ?? "")
        XCTAssertEqual(report.exitCode, 0)
        let launches = try engine.launches()
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(
            launches.first.flatMap { $0.value(after: "--outdir") }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            output.resolvingSymlinksInPath().path,
            "the unit runs in the folder the executor made, never the destination as the plan knew it"
        )
        XCTAssertEqual(launches.first?.value(after: "-r"), try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin().revision)
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: output))
        XCTAssertEqual(record.workflowName, TaxTriageAnalysisRunTool.workflowName, "the root record replaced the pipeline's")
        XCTAssertEqual(record.steps.filter { $0.toolName == "taxtriage" }.count, 1, "the pipeline's step reached the root record once")
        XCTAssertEqual(
            record.steps.first { $0.toolName == "taxtriage" }?.resolvedOptions["sample"],
            .string("S1"),
            "the executor's step names the launch's one sample (B12, 2.8 row 256)"
        )
        XCTAssertEqual(record.options.resolvedDefaults["sample_count"], .integer(1))
        XCTAssertNil(record.options.explicit["sample_count"])
        XCTAssertEqual(record.options.resolvedDefaults["databaseIdentityStatus"], .string("unpinned"))
    }

    func testABatchIsOneLaunchPerSampleFolderAndEachSampleKeepsItsOwnRecord() async throws {
        let engine = try makeEngine()
        let folder = root.appendingPathComponent("reads", isDirectory: true)
        try writeReads("A.fastq", in: folder)
        try writeReads("B.fastq", in: folder)
        let output = root.appendingPathComponent("batch", isDirectory: true)

        let report = await execute(try makeTool(input: folder.path, sample: nil, engine: engine), .directory(output), batch: true)

        XCTAssertEqual(report.status, .completed, report.message ?? "")
        XCTAssertEqual(try engine.launches().count, 2, "one Nextflow per sample (2.8 T2)")
        for sample in ["A", "B"] {
            let sampleFolder = output.appendingPathComponent(sample, isDirectory: true)
            let sampleRecord = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: sampleFolder), sample)
            XCTAssertEqual(sampleRecord.workflowName, "TaxTriage", "\(sample) keeps the pipeline's own record")
            XCTAssertEqual(
                sampleRecord.steps.first { $0.toolName == "taxtriage" }?.resolvedOptions["sample"],
                .string(sample),
                "\(sample)'s step names its sample (B12)"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: sampleFolder.appendingPathComponent("taxtriage-result.json").path),
                sample
            )
        }
        let rootRecord = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: output))
        XCTAssertEqual(rootRecord.workflowName, TaxTriageAnalysisRunTool.workflowName)
        XCTAssertEqual(rootRecord.options.resolvedDefaults["databaseIdentityStatus"], .string("unpinned"), "the batch root names its database (B12)")
    }

    // MARK: - Helpers

    private func makeEngine() throws -> TaxTriageStandInEngine {
        let engine = try TaxTriageStandInEngine(root: root.appendingPathComponent("engine", isDirectory: true), maximumWait: .seconds(60))
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        return engine
    }

    private func makeTool(input: String, sample: String?, engine: TaxTriageStandInEngine) throws -> TaxTriageAnalysisRunTool {
        let database = root.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        return TaxTriageAnalysisRunTool(
            request: TaxTriageRunRequest(
                input: input,
                sampleID: sample,
                settings: TaxTriageConfig(
                    samples: [],
                    outputDirectory: root,
                    kraken2DatabasePath: database,
                    maxCpus: 2,
                    profile: TaxTriageStandInEngine.profile
                )
            ),
            services: TaxTriageRunServices(
                makePipeline: { engine.makePipeline() },
                expandInputs: { arguments, recursive in
                    try arguments.flatMap { argument -> [URL] in
                        let url = URL(fileURLWithPath: argument)
                        guard TaxTriageAnalysisRunTool.isFolder(url) else { return [url] }
                        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                            .filter { $0.pathExtension == "fastq" }
                            .sorted { $0.path < $1.path }
                    }
                },
                materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:])
            )
        )
    }

    private func execute(_ tool: TaxTriageAnalysisRunTool, _ destination: AnalysisRunDestination, batch: Bool) async -> AnalysisRunReport {
        await AnalysisRunExecutor(services: AnalysisRunServices()).execute(
            tool,
            AnalysisRunRequest(inputs: [], destination: destination, groupsSamples: batch, commandLine: ["lungfish-cli", "taxtriage", "run"]),
            events: .discarding
        )
    }

    @discardableResult
    private func writeReads(_ name: String, in folder: URL? = nil) throws -> URL {
        let directory = folder ?? root.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let text = (1...3).map { "@\(name)-read-\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
