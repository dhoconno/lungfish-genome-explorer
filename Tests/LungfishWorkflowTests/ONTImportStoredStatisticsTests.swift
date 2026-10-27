// ONTImportStoredStatisticsTests.swift - An ONT import's statistics describe the reads it stored
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane ONT (walk WF-8, BIO). The importer measures the reads it reads, and Optimize Storage or chunk
// binning then rewrites their quality scores. The statistics in the bundle's sidecar must describe the stored
// reads, so the walk's bundle, binned with illumina4, shows the mean Q of its binned reads. A stand-in optimizer
// rewrites every score, so the case needs no BBTools.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class ONTImportStoredStatisticsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-stored-statistics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheStatisticsDescribeTheReadsTheOptimizerStored() async throws {
        let source = root.appendingPathComponent("run/fastq_pass", isDirectory: true)
        let barcode = source.appendingPathComponent("barcode01", isDirectory: true)
        try FileManager.default.createDirectory(at: barcode, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n@r2\nACGGCC\n+\nIIIIII\n"
            .write(to: barcode.appendingPathComponent("chunk_0.fastq"), atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("out", isDirectory: true)

        // Stands in for binning: the stored reads keep their bases and every score becomes `+`, Q10.
        let workflow = ONTImportWorkflow(optimizationRunner: { bundleURL, _, _ in
            guard let payload = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) else { return [] }
            try "@r1\nACGT\n+\n++++\n@r2\nACGGCC\n+\n++++++\n".write(to: payload, atomically: true, encoding: .utf8)
            return []
        })
        let result = try await workflow.importDirectory(
            config: ONTImportConfig(sourceDirectory: source, outputDirectory: output, storageMode: .flattened),
            context: ONTImportWorkflow.CommandContext(
                caller: .cli,
                workflowName: "lungfish fastq import-ont",
                workflowVersion: "test",
                toolName: "lungfish fastq import-ont",
                toolVersion: "test",
                argv: ["lungfish-cli", "fastq", "import-ont"],
                reproducibleCommand: "lungfish-cli fastq import-ont",
                explicitOptions: [:],
                defaultOptions: [:],
                resolvedOptions: [:]
            ),
            optimization: ONTImportWorkflow.OptimizationConfig(optimizeStorage: true, qualityBinning: .illumina4),
            progress: { _, _ in }
        )

        let bundle = try XCTUnwrap(result.importResult.bundleURLs.first)
        let statistics = try XCTUnwrap(FASTQMetadataStore.load(for: bundle)?.computedStatistics)
        XCTAssertEqual(statistics.readCount, 2)
        XCTAssertEqual(statistics.baseCount, 10)
        XCTAssertEqual(statistics.minReadLength, 4)
        XCTAssertEqual(statistics.maxReadLength, 6)
        XCTAssertEqual(statistics.gcContent, 0.7, accuracy: 0.0001)
        XCTAssertEqual(statistics.meanQuality, 10, accuracy: 0.01, "the stored reads hold Q10, not the run's Q40")
        XCTAssertEqual(statistics.qualityScoreHistogram, [10: 10])
    }
}
