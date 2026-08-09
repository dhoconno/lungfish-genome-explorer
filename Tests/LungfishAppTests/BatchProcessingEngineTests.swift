// BatchProcessingEngineTests.swift - Tests for batch recipe execution across barcodes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO

final class BatchProcessingEngineTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchProcessingEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// R3-R3ML-20: executeBatch's task group previously let
    /// BatchProcessingError.barcodeNotFound (thrown directly by processSource for a
    /// source bundle simply missing on disk) propagate uncaught out of
    /// group.next(), discarding collectedResults entirely and aborting the whole
    /// executeBatch call before batchManifest.json/comparison.json were ever
    /// written -- even if other sources in the batch already completed
    /// successfully. Uses two sources whose bundleURL does not exist (the simplest
    /// reliable way to reach the barcodeNotFound throw without needing a full
    /// FASTQDerivativeService-processable fixture) and asserts executeBatch
    /// completes (does not throw) with both sources reflected as .failed in the
    /// result manifest, rather than the call throwing and no manifest being written.
    func testExecuteBatchDoesNotAbortWholeBatchWhenOneSourceIsMissing() async throws {
        let missingSourceA = BatchSource(
            bundleURL: tempDir.appendingPathComponent("does-not-exist-A.lungfishfastq", isDirectory: true),
            displayName: "barcode-A"
        )
        let missingSourceB = BatchSource(
            bundleURL: tempDir.appendingPathComponent("does-not-exist-B.lungfishfastq", isDirectory: true),
            displayName: "barcode-B"
        )
        let recipe = ProcessingRecipe(
            name: "Test Recipe",
            steps: [FASTQDerivativeOperation(kind: .lengthFilter, minLength: 50, maxLength: 500)]
        )
        let engine = BatchProcessingEngine(derivativeService: FASTQDerivativeService())

        let manifest = try await engine.executeBatch(
            sources: [missingSourceA, missingSourceB],
            recipe: recipe,
            batchName: "test-batch",
            outputDirectory: tempDir
        )

        XCTAssertEqual(manifest.barcodeCount, 2)
        XCTAssertNotNil(manifest.completedAt, "the batch must complete (not throw) even though every source is missing")

        let batchDir = tempDir
            .appendingPathComponent("batch-runs", isDirectory: true)
            .appendingPathComponent("test-batch", isDirectory: true)
        let comparisonURL = batchDir.appendingPathComponent("comparison.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: comparisonURL.path),
            "comparison.json must be written even when every source failed -- the batch must not abort before writing results"
        )

        let comparison = try XCTUnwrap(BatchComparisonManifest.load(from: batchDir))
        XCTAssertEqual(comparison.barcodes.count, 2, "both missing sources must be reflected in the batch results")
        for summary in comparison.barcodes {
            XCTAssertEqual(summary.stepResults.first?.status, .failed)
            XCTAssertTrue(
                summary.stepResults.first?.errorMessage?.contains("not found") ?? false,
                "expected a barcodeNotFound-flavored error message, got: \(String(describing: summary.stepResults.first?.errorMessage))"
            )
        }
    }
}
