// FullLengthONTMHCCheckpointIntactTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

/// TTL-ONT-CHECKPOINT-REUSE: a sample checkpoint is reused only when every output it recorded is still the file it
/// recorded. Reuse used to check that the files existed, so a rerun under another signature that stopped midway left a
/// mixed sample, and a later run under the first signature reused it as complete.
final class FullLengthONTMHCCheckpointIntactTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-length-ont-mhc-checkpoint-intact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Fixture {
        let pipeline: FullLengthONTMHCGenotypingPipeline
        let request: FullLengthONTMHCGenotypingRunRequest
        let scheduled: FullLengthONTMHCScheduledSample
        let preparedFASTQ: URL
        let referenceFASTA: URL
        let execution: FullLengthONTMHCSampleExecutionConfiguration
        let result: FullLengthONTMHCSampleResult
        let clusters: URL
        let alignment: URL

        func saveCheckpoint() throws {
            _ = try pipeline.saveSampleCheckpoint(
                result: result, scheduled: scheduled, preparedFASTQ: preparedFASTQ, request: request,
                referenceFASTAURL: referenceFASTA, execution: execution
            )
        }

        func loadCheckpoint() throws -> (url: URL, result: FullLengthONTMHCSampleResult)? {
            try pipeline.loadCompatibleSampleCheckpoint(
                scheduled: scheduled, preparedFASTQ: preparedFASTQ, request: request,
                referenceFASTAURL: referenceFASTA, execution: execution
            )
        }
    }

    /// One finished sample, S1, with two outputs under `samples/S1/`.
    private func makeFixture() throws -> Fixture {
        let input = root.appendingPathComponent("S1.fastq")
        let reference = root.appendingPathComponent("reference.fasta")
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [input],
            referenceSourceURL: reference,
            outputDirectory: root.appendingPathComponent("genotype.lungfishgenotype", isDirectory: true),
            outputName: "full-length",
            threads: 2,
            minimumLength: 4,
            maximumLength: 12,
            reuseCompatibleCheckpoints: true
        )
        let sampleDirectory = request.outputDirectory.appendingPathComponent("samples/S1", isDirectory: true)
        try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)
        try "@r1\nACGTACGT\n+\nIIIIIIII\n".write(to: input, atomically: true, encoding: .utf8)
        try ">allele1\nACGTACGT\n".write(to: reference, atomically: true, encoding: .utf8)
        let prepared = sampleDirectory.appendingPathComponent("S1.prepared.fastq")
        let clusters = sampleDirectory.appendingPathComponent("clusters.fasta")
        let alignment = sampleDirectory.appendingPathComponent("clusters.sorted.bam")
        try "@r1\nACGTACGT\n+\nIIIIIIII\n".write(to: prepared, atomically: true, encoding: .utf8)
        try ">cluster1\nACGTACGT\n".write(to: clusters, atomically: true, encoding: .utf8)
        try Data(repeating: 0x41, count: 4_096).write(to: alignment)

        let now = Date()
        let step = FullLengthONTMHCProvenanceStep(
            toolName: "savont",
            toolVersion: "test",
            argv: ["savont"],
            inputs: [prepared],
            outputs: [clusters, alignment],
            exitStatus: 0,
            stderr: nil,
            startedAt: now,
            completedAt: now
        )
        let result = FullLengthONTMHCSampleResult(
            originalIndex: 0,
            processingRank: 0,
            sample: "S1",
            readCount: 1,
            clustersFASTAURL: clusters,
            clusterRecords: [],
            genotypeRows: [],
            sampleSummary: FullLengthONTMHCSampleSummary(
                sample: "S1", totalInputReads: 1, clusterCount: 0, clusteredReads: 0, assignedReads: 0,
                unmatchedClusters: 0, cdnaClusters: 0, savontPreset: "test", savontStatus: .called,
                savontFallbackReason: nil
            ),
            unmatchedClusters: [],
            cdnaMatchedClusters: [],
            closestMatches: [],
            steps: [step]
        )
        let scheduled = FullLengthONTMHCScheduledSample(
            originalIndex: 0,
            inputURL: request.inputFASTQURLs[0],
            sample: "S1",
            sampleDirectory: sampleDirectory,
            materializedFASTQURL: prepared,
            readCount: 1
        )
        return Fixture(
            pipeline: FullLengthONTMHCGenotypingPipeline(),
            request: request,
            scheduled: scheduled,
            preparedFASTQ: prepared,
            referenceFASTA: reference,
            execution: FullLengthONTMHCSampleExecutionConfiguration(workerThreads: 1, savontThreads: 1),
            result: result,
            clusters: clusters,
            alignment: alignment
        )
    }

    /// The control: the outputs are what the checkpoint recorded, so the sample is reused.
    func testAnIntactSampleIsReused() throws {
        let fixture = try makeFixture()
        try fixture.saveCheckpoint()

        let reused = try XCTUnwrap(try fixture.loadCheckpoint(), "outputs untouched since the save are reused")
        XCTAssertEqual(reused.result.sample, "S1")
    }

    /// Saved under signature A. A rerun under signature B that stopped midway has overwritten one output, with the
    /// same size and other bytes. The file exists, so the sample used to be reused as complete.
    func testASampleOutputOverwrittenByAStoppedRunIsNotReused() throws {
        let fixture = try makeFixture()
        try fixture.saveCheckpoint()

        try Data(repeating: 0x42, count: 4_096).write(to: fixture.alignment)

        XCTAssertNil(try fixture.loadCheckpoint(), "one output is another run's file, so the sample is mixed")
    }

    /// A stopped run can also leave a partial file.
    func testASampleOutputThatIsShorterNowIsNotReused() throws {
        let fixture = try makeFixture()
        try fixture.saveCheckpoint()

        try Data(repeating: 0x41, count: 1_024).write(to: fixture.clusters)

        XCTAssertNil(try fixture.loadCheckpoint(), "a truncated output is not the output the checkpoint recorded")
    }

    /// A checkpoint saved before outputs were fingerprinted records nothing to compare, so it is not reused.
    func testACheckpointOfTheEarlierSchemaIsNotReused() throws {
        XCTAssertNotEqual(
            FullLengthONTMHCSampleCheckpoint.schemaVersion,
            "full-length-ont-mhc-sample-checkpoint/3",
            "the version that did not fingerprint outputs is retired"
        )
        let fixture = try makeFixture()
        try fixture.saveCheckpoint()
        let checkpointURL = fixture.pipeline.sampleCheckpointURL(for: "S1", request: fixture.request)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: checkpointURL)) as? [String: Any]
        )
        object["schemaVersion"] = "full-length-ont-mhc-sample-checkpoint/3"
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: checkpointURL)

        XCTAssertNil(try fixture.loadCheckpoint(), "a checkpoint of the earlier version is not reused")
    }
}
