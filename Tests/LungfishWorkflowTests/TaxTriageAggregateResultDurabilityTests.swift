// TaxTriageAggregateResultDurabilityTests.swift - The aggregate taxtriage-result.json of a TaxTriage batch root
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B30 M3 (decision T5, parity X3, SWIFT 4). The executor's finalize writes the aggregate result the
// app's serial batch writes at a batch root, from the samples' results in request order with no fact they lack,
// through `DurableReplace` before the root record. These cases read
// `TaxTriageAnalysisRunTool.aggregateResult(of:planned:root:)` and `publishAggregateResult(of:planned:root:)` alone,
// with no run, and two cases run `finalize(_:context:)` under a cancel, which leaves no aggregate (2.9 T10, B30 review
// fix 7). The name holds "Durability" so `scripts/testing/exfat-tests.sh --simulate` runs the class with the
// ExFAT fallbacks of every rename. `TaxTriageExecutorBatchTreeReplayTests` runs the command on the stand-in engine.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageAggregateResultDurabilityTests: XCTestCase {
    private var root: URL!
    private var batch: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-aggregate").resolvingSymlinksInPath()
        batch = root.appendingPathComponent("Project.lungfish/Analyses/taxtriage-batch-2026-10-13T10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Request order Zeta, Alpha, Mu, so the order is the request's and never the alphabet's. Alpha failed.
    private func units() -> [AnalysisUnitReport<TaxTriageUnitResult>] {
        [
            unit(0, "Zeta", runtime: 12.34),
            AnalysisUnitReport(
                index: 1, label: "Alpha", sampleName: "Alpha", directory: folder("Alpha"),
                outcome: .failed(reason: "TaxTriage pipeline failed with exit code 1: ERROR ~ KRAKEN2_KRAKEN2 (Alpha)")
            ),
            unit(2, "Mu", runtime: 1.0, platform: .oxford, isNegativeControl: true, ignored: true),
        ]
    }

    /// The samples the plan gave the three launches.
    private func planned() -> [TaxTriageSample] {
        ["Zeta", "Alpha", "Mu"].map { name in
            TaxTriageSample(
                sampleId: name,
                fastq1: root.appendingPathComponent("Project.lungfish/Imports/\(name).lungfishfastq", isDirectory: true),
                isNegativeControl: name == "Alpha"
            )
        }
    }

    func testTheAggregateHoldsEverySampleInRequestOrder() throws {
        let units = units()
        let results = units.compactMap { $0.outcome.result?.result }
        let planned = planned()

        let aggregate = try XCTUnwrap(TaxTriageAnalysisRunTool.aggregateResult(of: units, planned: planned, root: batch))

        XCTAssertEqual(aggregate.config.samples.map(\.sampleId), ["Zeta", "Alpha", "Mu"], "every sample, in request order")
        XCTAssertEqual(aggregate.config.samples[0], results[0].config.samples[0], "a completed sample as its result holds it")
        XCTAssertEqual(aggregate.config.samples[1], planned[1], "a failed sample as the plan gave it to its launch")
        XCTAssertEqual(aggregate.config.samples.map(\.isNegativeControl), [false, true, true], "every control mark (T4)")
        XCTAssertEqual(aggregate.config.samples[2].platform, .oxford, "each sample keeps the platform it ran on")
        XCTAssertEqual(aggregate.sampleFailures, [
            TaxTriageSampleFailure(
                sampleID: "Alpha",
                outputDirectory: folder("Alpha"),
                errorDescription: "TaxTriage pipeline failed with exit code 1: ERROR ~ KRAKEN2_KRAKEN2 (Alpha)"
            ),
        ])
        XCTAssertEqual(aggregate.config.outputDirectory, batch)
        XCTAssertEqual(aggregate.outputDirectory, batch)
        XCTAssertEqual(aggregate.config.k2Confidence, results[0].config.k2Confidence, "the settings every launch shared")
        XCTAssertEqual(aggregate.reportFiles, results.flatMap(\.reportFiles), "Zeta's report before Mu's")
        XCTAssertEqual(aggregate.allOutputFiles, results.flatMap(\.allOutputFiles) + [batch.appendingPathComponent("taxtriage-result.json")])
        XCTAssertEqual(aggregate.ignoredFailures, results[1].ignoredFailures)
        XCTAssertNil(aggregate.logFile, "no launch's log is the batch's")
        XCTAssertNil(aggregate.traceFile)
        XCTAssertEqual(aggregate.exitCode, 0)
        XCTAssertEqual(aggregate.runtime, 13.34, accuracy: 1e-9, "the sum of the samples' runtimes")
        XCTAssertEqual(
            aggregate.summary,
            "TaxTriage pipeline completed with warnings\nRuntime: 13.3s\nSamples: 3\nReports: 2\nMetrics: 0\n"
                + "Ignored task failures: 1 across 1 sample\nFailed samples: 1\nTotal output files: 5",
            "the words each completed sample's bundle entry carries"
        )
    }

    func testAFailedSampleThePlanNoLongerNamesIsOnlyAFailure() throws {
        var moved = planned()
        moved.swapAt(0, 1)

        for planned in [nil, moved] {
            let aggregate = try XCTUnwrap(TaxTriageAnalysisRunTool.aggregateResult(of: units(), planned: planned, root: batch))
            XCTAssertEqual(aggregate.config.samples.map(\.sampleId), ["Zeta", "Mu"], "\(String(describing: planned))")
            XCTAssertEqual(aggregate.sampleFailures.map(\.sampleID), ["Alpha"])
        }
    }

    func testABatchWithNoCompletedSampleHasNoAggregate() throws {
        let failed = units().filter { !$0.outcome.completed }

        XCTAssertNil(try TaxTriageAnalysisRunTool.publishAggregateResult(of: failed, planned: planned(), root: batch))
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.appendingPathComponent("taxtriage-result.json").path))
    }

    func testTheAggregateIsPublishedWholeAndReplacesAnEarlierOne() throws {
        let file = batch.appendingPathComponent("taxtriage-result.json")
        let first = try XCTUnwrap(TaxTriageAnalysisRunTool.publishAggregateResult(of: units(), planned: planned(), root: batch))
        XCTAssertEqual(try TaxTriageResult.load(from: batch).config.samples.map(\.sampleId), ["Zeta", "Alpha", "Mu"])
        let published = try Data(contentsOf: file)
        try first.save()
        XCTAssertEqual(try Data(contentsOf: file), published, "the bytes TaxTriageResult.save() writes")

        let second = try XCTUnwrap(
            TaxTriageAnalysisRunTool.publishAggregateResult(of: Array(units().prefix(1)), planned: nil, root: batch)
        )

        XCTAssertEqual(try TaxTriageResult.load(from: batch).config.samples.map(\.sampleId), ["Zeta"], "the new file replaced the old")
        XCTAssertEqual(second.sampleFailures, [])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: batch.path)
            .filter { $0.contains(".lungfish-stage-") || $0.contains(".lungfish-swap-") }
        XCTAssertEqual(leftovers, [], "no stage or tombstone stays beside the result")
    }

    // MARK: - A cancel (2.9 T10, B30 review fix 7)

    /// A cancelled batch keeps no aggregate result, as the app's serial batch writes none (2.9 T10), and the
    /// executor names none of the finalize's outputs then (E5). Here the cancel comes before the finalize.
    func testACancelledFinalizeLeavesNoAggregate() async throws {
        let tool = finalizeTool()
        let context = finalizeContext(indexing: nil)
        let units = units()

        let finalize = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await tool.finalize(units, context: context).outputs.map(\.url)
        }
        let outputs = try await finalize.value

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: batch.appendingPathComponent("taxtriage-result.json").path),
            "a cancelled batch keeps no aggregate result"
        )
        XCTAssertEqual(outputs, [], "the finalization names no aggregate")
    }

    /// As above, with the cancel during the viewer index, after the finalize published the aggregate. The
    /// catch of an index that could not be built takes the cancel's error too, so the finalize removes it.
    func testACancelDuringTheIndexRemovesTheAggregate() async throws {
        let tool = finalizeTool()
        let context = finalizeContext(indexing: CancellingIndexer())
        let units = units()

        let outputs = try await Task { try await tool.finalize(units, context: context).outputs.map(\.url) }.value

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: batch.appendingPathComponent("taxtriage-result.json").path),
            "a batch cancelled during its index keeps no aggregate result"
        )
        XCTAssertEqual(outputs, [], "the finalization names no aggregate")
    }

    // MARK: - Helpers

    /// The tool of a batch whose request plans no sample, so a failed unit keeps no planned sample.
    private func finalizeTool() -> TaxTriageAnalysisRunTool {
        TaxTriageAnalysisRunTool(request: TaxTriageRunRequest(settings: TaxTriageConfig(samples: [], outputDirectory: batch)))
    }

    /// The finalize context of the batch root, as `TaxTriageSourceRecordTests` builds one.
    private func finalizeContext(indexing: (any AnalysisResultIndexing)?) -> AnalysisRunFinalizeContext {
        AnalysisRunFinalizeContext(
            rootDirectory: batch,
            layout: .batchRoot,
            projectURL: root.appendingPathComponent("Project.lungfish", isDirectory: true),
            toolID: .taxtriage,
            indexing: indexing
        )
    }

    private func folder(_ sample: String) -> URL {
        batch.appendingPathComponent(sample, isDirectory: true)
    }

    /// A completed unit of one sample whose result names one report and one log under its folder.
    private func unit(
        _ index: Int,
        _ sample: String,
        runtime: TimeInterval,
        platform: TaxTriageConfig.Platform = .illumina,
        isNegativeControl: Bool = false,
        ignored: Bool = false
    ) -> AnalysisUnitReport<TaxTriageUnitResult> {
        let directory = folder(sample)
        let reads = root.appendingPathComponent("Project.lungfish/Imports/\(sample).lungfishfastq/\(sample).fastq")
        let config = TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: sample, fastq1: reads, platform: platform, isNegativeControl: isNegativeControl)],
            platform: platform,
            outputDirectory: directory
        )
        let report = directory.appendingPathComponent("report/\(sample).odr.txt")
        let failure = TaxTriageIgnoredFailure(
            processPath: "NFCORE_TAXTRIAGE:TAXTRIAGE:MINIMAP2_ALIGN",
            processName: "MINIMAP2_ALIGN",
            taskLabel: "\(sample).\(sample).dwnld.references",
            sampleID: sample,
            exitCode: 137
        )
        let result = TaxTriageResult(
            config: config,
            runtime: runtime,
            exitCode: 0,
            outputDirectory: directory,
            reportFiles: [report],
            logFile: directory.appendingPathComponent("nextflow.log"),
            traceFile: directory.appendingPathComponent("trace.txt"),
            allOutputFiles: [directory.appendingPathComponent("nextflow.log"), report],
            ignoredFailures: ignored ? [failure] : []
        )
        return AnalysisUnitReport(
            index: index, label: sample, sampleName: sample, directory: directory,
            outcome: ignored ? .completedWithWarning(TaxTriageUnitResult(result: result), reason: "ignored") : .completed(TaxTriageUnitResult(result: result))
        )
    }
}

/// An index builder that cancels the task it runs in and stops, as a cancel of the run during the finalize's
/// viewer index does.
private struct CancellingIndexer: AnalysisResultIndexing {
    func buildIndex(_ request: AnalysisResultIndexRequest) async throws -> AnalysisResultIndex {
        withUnsafeCurrentTask { $0?.cancel() }
        throw CancellationError()
    }
}
