// Kraken2AnalysisRunToolTests+ReadSetPlan.swift - Where a batch sample's record files its read-set plan
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

extension Kraken2AnalysisRunToolTests {
    /// Lane B33 of Phase 2.10 (2.7 row 444, B16). A batch sample of a mixed bundle keeps the pipeline's record
    /// in its folder. The pipeline writes the plan once, under the resolved defaults, the one home (E13), and
    /// the unit's convergence leaves it there. The plan is the same plan at both times.
    func testABatchSamplePipelineRecordFilesThePlanUnderResolvedDefaultsAndTheUnitLeavesItThere() async throws {
        let inputs = [fixtures.singleRoot.path, fixtures.mixedRoot.path]
        let pipeline = ClassificationPipeline(condaManager: kraken2.condaManager)
        let written = Kraken2Captured<(folder: String, record: ProvenanceEnvelope)>()
        let capturing: PipelineRun = { config, progress in
            let result = try await pipeline.classify(config: config, progress: progress)
            if let record = ProvenanceRecorder.loadEnvelope(from: config.outputDirectory) {
                written.append((config.outputDirectory.lastPathComponent, record))
            }
            return result
        }

        let run = await execute(
            request(inputs), .project(fixtures.projectURL), batch: true,
            argv: command(inputs + ["--batch", "--project", fixtures.projectURL.path]),
            indexing: StubKraken2Indexer(), runPipeline: capturing
        )

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        let batchRoot = try XCTUnwrap(run.report.analysisDirectory)
        let manifest = try XCTUnwrap(MetagenomicsBatchResultStore.loadClassification(from: batchRoot))
        let mixed = try XCTUnwrap(manifest.samples.first { $0.inputFiles == [fixtures.mixedRoot.standardizedFileURL.path] })
        let single = try XCTUnwrap(manifest.samples.first { $0.inputFiles == [fixtures.singleRoot.standardizedFileURL.path] })
        let producer = try XCTUnwrap(written.values.first { $0.folder == mixed.resultDirectory }?.record, "the pipeline wrote its record")
        let converged = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batchRoot.appendingPathComponent(mixed.resultDirectory)))

        XCTAssertEqual(producer.readSetPlan?.place, .resolvedDefaults, "the pipeline writes the plan once, in the one home (E13)")
        XCTAssertNil(producer.options.explicit[AnalysisRootRecordOptions.readSetPlanKey])
        XCTAssertEqual(converged.readSetPlan?.place, .resolvedDefaults)
        XCTAssertNil(converged.options.explicit[AnalysisRootRecordOptions.readSetPlanKey])
        XCTAssertNotNil(converged.readSetPlan?.fields["capability"])
        XCTAssertEqual(converged.readSetPlan?.fields, producer.readSetPlan?.fields, "the unit changes no plan field")
        let singleRecord = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batchRoot.appendingPathComponent(single.resultDirectory)))
        XCTAssertNil(singleRecord.readSetPlan, "a sample of single reads records no plan")
    }
}
