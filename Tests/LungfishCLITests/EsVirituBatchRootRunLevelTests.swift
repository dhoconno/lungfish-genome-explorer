// EsVirituBatchRootRunLevelTests.swift - The batch root names each kept file as the run left it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A39 M3 (2.8 row 269, 2.9 R7, the B3 ruling). The root record of an EsViritu batch takes
// the steps of its index build, whose markdup rewrites each BAM in place and whose removal step names the
// bytes that went. As the Kraken2 batch root names each kept staged file with the digest of the step that
// wrote it and reads nothing again, the root's run level names each kept file only as the run left it,
// with no step of its own.

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class EsVirituBatchRootRunLevelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "esviritu-batch-root-run-level")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// A `--project` EsViritu run of one sample through the executor, whose index build moves a BAM into
    /// `bams/`, reads it, marks duplicates in place and names the old bytes in a removal step, as
    /// `build-db esviritu` does. The root record keeps those steps, and its run level names the BAM only
    /// with the digest of the file there.
    func testTheBatchRootNamesNoBytesItsIndexBuildReplaced() async throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let shapes = try BundleShapeFixtures(in: project.appendingPathComponent("Imports", isDirectory: true))
        let tables = BuildDbStreamCapture.fixturesFolder.appendingPathComponent("esviritu-mini/SRR35517705/SRR35517705")
        let esviritu = try StandInEsViritu(root: root.appendingPathComponent("tool"), tables: tables)
        let tool = EsVirituAnalysisRunTool(
            options: EsVirituAnalysisRunOptions(sampleName: "S1", readFormat: .unpaired, databasePath: esviritu.databaseURL, threads: 2),
            groupsSamples: false,
            pipeline: EsVirituPipeline(condaManager: esviritu.condaManager),
            materializer: FASTQCLIMaterializer(runner: .shared),
            installedDatabase: { [databaseURL = esviritu.databaseURL] in databaseURL }
        )
        let request = AnalysisRunRequest(
            inputs: [shapes.single],
            destination: .project(project),
            commandLine: ["lungfish-cli", "esviritu", "detect"]
        )

        let report = await AnalysisRunExecutor(services: AnalysisRunServices(indexing: MarkdupLikeIndexing()))
            .execute(tool, request, events: AnalysisRunEvents { _ in })

        XCTAssertEqual(report.status, .completed, report.message)
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(report.recordURL)))
        let bam = try XCTUnwrap(report.analysisDirectory).appendingPathComponent(MarkdupLikeIndexing.bamPath)
        let before = try MarkdupLikeIndexing.digest(of: MarkdupLikeIndexing.before)
        let after = try XCTUnwrap(ProvenanceRecorder.sha256(of: bam))
        XCTAssertTrue(
            record.steps.contains { $0.inputs.contains { $0.checksumSHA256 == before } },
            "a step of the index build keeps the bytes it read"
        )
        let runLevel = record.files + record.outputs + [record.output].compactMap { $0 }
        let named = runLevel.filter { EsVirituRunLevel.resolved($0.path) == EsVirituRunLevel.resolved(bam.path) }
        XCTAssertTrue(record.outputs.contains { EsVirituRunLevel.resolved($0.path) == EsVirituRunLevel.resolved(bam.path) }, "the root names the kept BAM")
        XCTAssertEqual(Set(named.map(\.checksumSHA256)), [after], "the root names the BAM only as the markdup left it")
    }
}

/// An index build that does to a BAM what `build-db esviritu` does, with placeholder bytes and no samtools.
/// It puts a BAM in `bams/`, reads it, rewrites it in place, names the old bytes in a removal step and lists
/// the BAM and a database as outputs of its own step, each step handed to the root record as it ends.
private struct MarkdupLikeIndexing: AnalysisResultIndexing {
    static let bamPath = "bams/S1.third.filt.sorted.bam"
    static let before = Data("BAM before markdup\n".utf8)
    static let after = Data("BAM after markdup\n".utf8)

    static func digest(of data: Data) throws -> String {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("markdup-like-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try data.write(to: scratch)
        return try XCTUnwrap(ProvenanceRecorder.sha256(of: scratch))
    }

    func buildIndex(_ request: AnalysisResultIndexRequest) async throws -> AnalysisResultIndex {
        let bam = request.resultDirectory.appendingPathComponent(Self.bamPath)
        try FileManager.default.createDirectory(at: bam.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.before.write(to: bam)
        let clock = ProvenanceRunClock()
        let read = try ProvenanceFileDescriptor.file(url: bam, format: .bam, role: .input)
        let move = step("Lungfish EsViritu BAM Relocation", outputs: [try .file(url: bam, format: .bam, role: .output)], clock)
        let header = step("samtools", inputs: [read], clock)
        try Self.after.write(to: bam)
        let replacement = try XCTUnwrap(RecordedRemovalStep.step(
            toolName: "Lungfish Markdup Replacement", api: "FileManager.replaceItemAt(_:withItemAt:)", removing: [read], clock: clock
        ))
        let database = request.resultDirectory.appendingPathComponent("esviritu.sqlite")
        try Data("stand-in database\n".utf8).write(to: database)
        let build = step("lungfish build-db esviritu", outputs: [
            try .file(url: database, role: .output), try .file(url: bam, format: .bam, role: .output),
        ], clock)
        let steps = [move, header, replacement, build]
        steps.forEach(request.recordStep)
        return AnalysisResultIndex(outputs: [AnalysisRunOutput(url: database, format: .sqlite)], steps: steps)
    }

    private func step(
        _ toolName: String, inputs: [ProvenanceFileDescriptor] = [], outputs: [ProvenanceFileDescriptor] = [], _ clock: ProvenanceRunClock
    ) -> ProvenanceStep {
        ProvenanceStep(
            toolName: toolName, toolVersion: "stand-in", argv: [toolName], inputs: inputs, outputs: outputs,
            exitStatus: 0, wallTimeSeconds: 0, stderr: nil, startedAt: clock.startedAt, completedAt: clock.now
        )
    }
}
