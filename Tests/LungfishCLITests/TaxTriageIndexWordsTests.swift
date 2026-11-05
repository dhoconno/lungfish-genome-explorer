// TaxTriageIndexWordsTests.swift - The words of a TaxTriage batch whose viewer index cannot be built
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane W1FIX, walk row W-36. The walk's CLI batch ended with `The viewer index could not be built (The
// operation couldn't be completed. (ArgumentParser.ValidationError error 1.)). LGE builds it when the result opens.`
// The index build failed because no sample folder held a taxonomy report, one sample having failed and the other
// having found no organism, and the sentence named the Swift type of the error in place of the error's message. These
// cases run the CLI's own index builder through the TaxTriage finalize, so the error is the real one.

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class TaxTriageIndexWordsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-index-words")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// A batch root as the walk's run left it, `Water` finished with a MultiQC folder and no taxonomy report and
    /// `Water_blank` stopped after its log.
    private func makeBatchWithoutAnyTaxonomyReport() throws -> URL {
        let batch = root.appendingPathComponent("taxtriage-batch", isDirectory: true)
        let finished = batch.appendingPathComponent("Water/report/multiqc_data", isDirectory: true)
        try FileManager.default.createDirectory(at: finished, withIntermediateDirectories: true)
        try "kraken".write(to: finished.appendingPathComponent("multiqc_kraken.txt"), atomically: true, encoding: .utf8)
        let stopped = batch.appendingPathComponent("Water_blank", isDirectory: true)
        try FileManager.default.createDirectory(at: stopped, withIntermediateDirectories: true)
        try "log".write(to: stopped.appendingPathComponent("nextflow.log"), atomically: true, encoding: .utf8)
        return batch
    }

    func testABatchWithNoTaxonomyReportWarnsInWordsAndNamesNoSwiftType() async throws {
        let batch = try makeBatchWithoutAnyTaxonomyReport()
        let sample = TaxTriageSample(sampleId: "Water", fastq1: root.appendingPathComponent("Water.fastq.gz"))
        let tool = TaxTriageAnalysisRunTool(
            request: TaxTriageRunRequest(settings: TaxTriageConfig(samples: [sample], outputDirectory: batch))
        )
        let context = AnalysisRunFinalizeContext(
            rootDirectory: batch,
            layout: .batchRoot,
            projectURL: nil,
            toolID: .taxtriage,
            indexing: TaxTriageCommand.RunSubcommand.resultIndexer(cancelRequested: { false })
        )

        let finalization = try await tool.finalize([], context: context)

        XCTAssertEqual(finalization.warnings.count, 1, "\(finalization.warnings)")
        let warning = try XCTUnwrap(finalization.warnings.first)
        XCTAssertTrue(warning.hasPrefix("The viewer index could not be built ("), warning)
        XCTAssertTrue(warning.hasSuffix(" LGE builds it when the result opens."), warning)
        XCTAssertTrue(
            warning.contains("No supported TaxTriage taxonomy report found"),
            "The sentence says what happened, and it read: \(warning)"
        )
        XCTAssertFalse(warning.contains("ValidationError"), "A Swift type is not words a person reads: \(warning)")
        XCTAssertFalse(warning.contains("ArgumentParser"), warning)
        XCTAssertFalse(warning.contains("The operation"), "Foundation's stand-in for a missing message: \(warning)")
    }
}
