// KrakenSplitFailureRemovalTests.swift - A Kraken2 run that fails after its split records the removal of the halves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B34, row 268 of docs/plans/2026-10-11-phase-2-8.md. The split step names both halves of an
// interleaved input as outputs, and the run's `defer` removes their folder on every exit. A failure after the split
// and before kraken2 saved a record that named two files the run then deleted, with no step to say so.

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

final class KrakenSplitFailureRemovalTests: XCTestCase {

    /// The read-set plan of the run holds a step whose output file is not there, so recording the plan's steps
    /// throws once the split has made the halves (the `recordReadSetInputSteps` catch of `ClassificationPipeline`).
    func testARunThatFailsRecordingItsReadSetStepsRecordsTheRemovalOfTheHalves() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let readSets = try ReadSetFixtures(in: fixture.root)
        var config = try fixture.makeConfig()
        let reads = readSets.interleavedRoot.appendingPathComponent("reads.fastq").standardizedFileURL
        config.inputFiles = [reads]
        config.interleavedInput = true
        config.originalInputFiles = [readSets.interleavedRoot]
        config.readSetPlan = try await Self.planWithAStepThatCannotBeRecorded(
            bundle: readSets.interleavedRoot, reads: reads, root: fixture.root
        )

        do {
            _ = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)
            XCTFail("recording a step whose output is missing fails the run")
        } catch is ClassificationPipelineError {
            XCTFail("the failure comes from the read-set step, not from kraken2")
        } catch {}

        let splitFolder = config.outputDirectory.appendingPathComponent(ClassificationPipeline.interleavedSplitDirectoryName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: splitFolder.path), "the halves are scratch")
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertEqual(envelope.status, .failed)
        XCTAssertFalse(envelope.steps.contains { $0.toolName == "kraken2" }, "the run failed before kraken2")
        XCTAssertEqual(KrakenRecordRemoval.problems(in: envelope), [], "every half the record names is kept or removed by a step")
        let split = try KrakenRecordRemoval.step("Lungfish Classification Interleaved Split", in: envelope)
        let removal = try KrakenRecordRemoval.step(ClassificationPipeline.interleavedSplitRemovalToolName, in: envelope)
        XCTAssertEqual(split.outputs.count, 2)
        XCTAssertEqual(removal.dependsOn, [split.id], "the removal follows the step that made the halves")
        XCTAssertEqual(removal.inputs.map(\.path), split.outputs.map(\.path))
        XCTAssertEqual(removal.inputs.map(\.checksumSHA256), split.outputs.map(\.checksumSHA256), "the digests the split recorded")
    }

    /// The plan the planner makes for `bundle`, with one split step whose output file does not exist.
    private static func planWithAStepThatCannotBeRecorded(bundle: URL, reads: URL, root: URL) async throws -> ReadSetPlan {
        let plan = try await KrakenReadSetPlanner.plan(
            bundle: bundle, materializedInputs: [reads], materializationDirectory: root.appendingPathComponent("plan-inputs")
        )
        let missing = ReadSetStep(
            kind: .splitByName, inputURLs: [reads], outputURLs: [root.appendingPathComponent("no-such-mate.fastq")],
            pairCount: 2, singleReadCount: 0, startedAt: Date(), endedAt: Date()
        )
        return ReadSetPlan(
            inputURL: plan.inputURL, capability: plan.capability, sourceLayout: plan.sourceLayout,
            layoutReason: plan.layoutReason, sequencingPlatform: plan.sequencingPlatform,
            wasMaterialized: plan.wasMaterialized, sampleHoldsPairsAndSingleReads: plan.sampleHoldsPairsAndSingleReads,
            runs: plan.runs, steps: [missing], singleReadReason: plan.singleReadReason, composition: plan.composition
        )
    }
}
