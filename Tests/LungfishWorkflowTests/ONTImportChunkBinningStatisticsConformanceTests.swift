// ONTImportChunkBinningStatisticsConformanceTests.swift - A binned chunked ONT import stores statistics of the chunks it keeps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import os
@testable import LungfishWorkflow

/// Phase 3.0 lane ONT, review fix BIO F2 (walk WF-8). The app's default ONT import stores chunks, bins each chunk
/// with BBTools `reformat.sh` and does not run Optimize Storage. The statistics in the bundle's sidecar must describe
/// the binned chunks the bundle stores, whatever the binning does to the scores. The test compares them with a fresh
/// pass over those chunks and pins no mean quality, so a ruling on the binning cannot break it.
///
/// A real-tool suite. Its name puts it in the conformance tier, and it skips when the managed `reformat.sh` is
/// missing, or fails under LUNGFISH_REQUIRE_TOOLS=1. `ONTImportStoredStatisticsTests` covers the same branch with no
/// tool.
final class ONTImportChunkBinningStatisticsConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ont-chunk-binning-statistics")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testTheSidecarDescribesTheBinnedChunksTheBundleStores() async throws {
        try await requireManagedTools([.reformat])
        let barcode85 = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ont/nrg1-run/fastq_pass/barcode85", isDirectory: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let progressLog = OSAllocatedUnfairLock<[String]>(initialState: [])

        let result = try await ONTImportWorkflow().importDirectory(
            config: ONTImportConfig(sourceDirectory: barcode85, outputDirectory: output, storageMode: .chunked),
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
            optimization: ONTImportWorkflow.OptimizationConfig(optimizeStorage: false, qualityBinning: .illumina4),
            progress: { _, message in progressLog.withLock { $0.append(message) } }
        )

        let bundle = try XCTUnwrap(result.importResult.bundleURLs.first)
        let stored = try XCTUnwrap(FASTQMetadataStore.load(for: bundle)?.computedStatistics)
        let chunks = try XCTUnwrap(FASTQBundle.resolveAllFASTQURLs(for: bundle))
        XCTAssertEqual(chunks.count, 2, "barcode85 holds two chunks")

        let collector = FASTQStatisticsCollector()
        let reader = FASTQReader(validateSequence: false)
        for chunk in chunks {
            for try await record in reader.records(from: chunk) {
                collector.process(record)
            }
        }
        XCTAssertEqual(stored, collector.finalize(), "the sidecar describes the chunks the bundle stores")
        XCTAssertEqual(stored.readCount, 1_000, "binning keeps every read")

        // The second measure parses every stored read again, so the row says so after the last binning line.
        let words = progressLog.withLock { $0 }
        let measuring = try XCTUnwrap(words.firstIndex(of: "barcode85: measuring reads"), "\(words)")
        let lastBinning = try XCTUnwrap(words.lastIndex { $0.contains("binning quality scores") }, "\(words)")
        XCTAssertGreaterThan(measuring, lastBinning, "\(words)")
    }

    // MARK: - Helpers

    private func requireManagedTools(_ tools: [NativeTool]) async throws {
        for tool in tools {
            guard (try? await NativeToolRunner.shared.toolPath(for: tool)) != nil else {
                try ToolAvailability.skipOrFail("Managed \(tool.rawValue) is not available")
            }
        }
    }
}
