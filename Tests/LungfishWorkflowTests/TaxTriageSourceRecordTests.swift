// TaxTriageSourceRecordTests.swift - Which samples of a TaxTriage result record the run in their source bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B30 M1 (parity X4, panel R1). The executor's finalize gives each completed sample of a `--project`
// result one `analyses-manifest.json` entry in its source bundle, as Kraken2's finalize records a result in a project,
// so the GUI's own manifest writer can go when its route moves onto the command (U30). A plain `--output` result
// records nothing, in the project's `Analyses/` folder too (B30 ruling Q2). These cases read
// `TaxTriageAnalysisRunTool.sourceRecords(for:context:destinationIsProject:)` alone, with no run.
// `TaxTriageExecutorBatchTreeReplayTests` runs the command on the stand-in engine.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageSourceRecordTests: XCTestCase {
    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-source-records").resolvingSymlinksInPath()
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testEachCompletedSampleWithABundleRecordsTheRunAndAFailedOneNothing() throws {
        let batch = try analysisFolder("taxtriage-batch-2026-10-13T10-00-00")
        let units = [
            try report(0, sample: "A", reads: bundleReads("A"), completed: true),
            try report(1, sample: "B", reads: bundleReads("B"), completed: false),
            try report(2, sample: "C", reads: looseReads("C"), completed: true),
            try report(3, sample: "D", reads: bundleReads("D"), completed: true),
        ]

        let records = TaxTriageAnalysisRunTool.sourceRecords(
            for: units,
            context: context(root: batch, layout: .batchRoot),
            destinationIsProject: true
        )

        let entries = records.compactMap { $0 as? AnalysisManifestSourceRecord }
        XCTAssertEqual(entries.count, records.count, "every record is an analyses-manifest.json entry")
        XCTAssertEqual(
            entries.map { $0.bundleURL.lastPathComponent },
            ["A.lungfishfastq", "D.lungfishfastq"],
            "the completed samples with a bundle, in request order. B failed and C's reads belong to no bundle"
        )
        for entry in entries {
            XCTAssertEqual(entry.displayName, "TaxTriage Classification", "the app's route's name for the run")
            XCTAssertEqual(entry.parameters["k2Confidence"], .double(0.2))
            XCTAssertEqual(entry.parameters["platform"], .string(TaxTriageConfig.Platform.illumina.rawValue))
        }
    }

    func testOneSampleInItsSharedBatchRootRecordsTheRun() throws {
        let batch = try analysisFolder("taxtriage-batch-2026-10-13T10-00-00")
        let units = [try report(0, sample: "A", reads: bundleReads("A"), completed: true, directory: batch)]

        let records = TaxTriageAnalysisRunTool.sourceRecords(
            for: units,
            context: context(root: batch, layout: .sharedBatchRoot),
            destinationIsProject: true
        )

        XCTAssertEqual(records.compactMap { ($0 as? AnalysisManifestSourceRecord)?.bundleURL.lastPathComponent }, ["A.lungfishfastq"])
    }

    func testAResultOutsideItsProjectsAnalysesFolderRecordsNothing() throws {
        let elsewhere = root.appendingPathComponent("out", isDirectory: true)
        let inProject = project.appendingPathComponent("Exports/run", isDirectory: true)
        let units = [try report(0, sample: "A", reads: bundleReads("A"), completed: true)]

        XCTAssertTrue(
            TaxTriageAnalysisRunTool.sourceRecords(
                for: units,
                context: context(root: elsewhere, layout: .batchRoot, project: nil),
                destinationIsProject: true
            ).isEmpty,
            "a result in no project is no entry of any bundle"
        )
        XCTAssertTrue(
            TaxTriageAnalysisRunTool.sourceRecords(
                for: units,
                context: context(root: inProject, layout: .batchRoot),
                destinationIsProject: true
            ).isEmpty,
            "an entry names its folder below the project's Analyses folder, so a result elsewhere in the project records nothing"
        )
    }

    func testAnOutputResultInTheAnalysesFolderRecordsNothing() throws {
        let batch = try analysisFolder("cli-batch")
        let units = [
            try report(0, sample: "A", reads: bundleReads("A"), completed: true),
            try report(1, sample: "B", reads: bundleReads("B"), completed: true),
        ]

        let records = TaxTriageAnalysisRunTool.sourceRecords(
            for: units,
            context: context(root: batch, layout: .batchRoot),
            destinationIsProject: false
        )

        XCTAssertTrue(records.isEmpty, "a plain --output result records nothing in its inputs' bundles, as Kraken2's (B30 ruling Q2)")
    }

    func testTheSummaryIsTheResultsSummaryWithoutTheMeasuredRuntime() throws {
        let unit = try report(0, sample: "A", reads: bundleReads("A"), completed: true)
        let result = try XCTUnwrap(unit.outcome.result?.result)

        let summary = TaxTriageAnalysisRunTool.manifestSummary(of: result)

        XCTAssertTrue(result.summary.contains("Runtime: 12.3s"), result.summary)
        XCTAssertEqual(
            summary,
            result.summary.components(separatedBy: "\n").filter { $0 != "Runtime: 12.3s" }.joined(separator: "\n"),
            "every line of the app's summary but the runtime, which the sample's record holds"
        )
        XCTAssertTrue(summary.hasPrefix("TaxTriage pipeline completed successfully\nSamples: 1\nReports: 1"), summary)
    }

    // MARK: - Helpers

    private func analysisFolder(_ name: String) throws -> URL {
        let folder = project.appendingPathComponent("Analyses/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// One file of reads in `Imports/<sample>.lungfishfastq`.
    private func bundleReads(_ sample: String) throws -> URL {
        let bundle = project.appendingPathComponent("Imports/\(sample).lungfishfastq", isDirectory: true)
        return try writeReads(sample, in: bundle)
    }

    /// One file of reads in a folder that is no bundle.
    private func looseReads(_ sample: String) throws -> URL {
        try writeReads(sample, in: root.appendingPathComponent("loose", isDirectory: true))
    }

    private func writeReads(_ sample: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let reads = folder.appendingPathComponent("\(sample).fastq")
        try "@\(sample)-1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        return reads
    }

    /// A unit of one sample whose result, when it completed, names `reads` as the sample's file.
    private func report(
        _ index: Int,
        sample: String,
        reads: URL,
        completed: Bool,
        directory: URL? = nil
    ) throws -> AnalysisUnitReport<TaxTriageUnitResult> {
        let folder = directory ?? root.appendingPathComponent("units/\(sample)", isDirectory: true)
        let config = TaxTriageConfig(samples: [TaxTriageSample(sampleId: sample, fastq1: reads)], outputDirectory: folder)
        let result = TaxTriageResult(
            config: config,
            runtime: 12.34,
            exitCode: 0,
            outputDirectory: folder,
            reportFiles: [folder.appendingPathComponent("report/\(sample).odr.txt")]
        )
        return AnalysisUnitReport(
            index: index,
            label: sample,
            sampleName: sample,
            directory: folder,
            outcome: completed ? .completed(TaxTriageUnitResult(result: result)) : .failed(reason: "Nextflow exited 1")
        )
    }

    private func context(root folder: URL, layout: AnalysisRunLayout, project: URL? = nil) -> AnalysisRunFinalizeContext {
        AnalysisRunFinalizeContext(
            rootDirectory: folder,
            layout: layout,
            projectURL: project ?? (folder.path.hasPrefix(self.project.path) ? self.project : nil),
            toolID: .taxtriage,
            indexing: nil
        )
    }
}
