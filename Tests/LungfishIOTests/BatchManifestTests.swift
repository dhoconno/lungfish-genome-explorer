import XCTest
@testable import LungfishIO

final class BatchManifestTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - BatchManifest

    func testBatchManifestRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var manifest = BatchManifest(
            recipeName: "Illumina WGS Standard",
            recipeID: UUID(),
            batchName: "run-2024-01",
            barcodeCount: 12,
            stepCount: 3,
            barcodeLabels: ["bc01", "bc02"]
        )
        manifest.completedAt = Date()

        try manifest.save(to: dir)
        let loaded = BatchManifest.load(from: dir)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.recipeName, "Illumina WGS Standard")
        XCTAssertEqual(loaded?.batchName, "run-2024-01")
        XCTAssertEqual(loaded?.barcodeCount, 12)
        XCTAssertEqual(loaded?.stepCount, 3)
        XCTAssertNotNil(loaded?.completedAt)
    }

    func testBatchManifestLoadMissing() {
        let bogus = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        XCTAssertNil(BatchManifest.load(from: bogus))
    }

    // MARK: - BatchComparisonManifest

    func testComparisonManifestRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let comparison = BatchComparisonManifest(
            batchID: UUID(),
            recipeName: "Test",
            steps: [
                StepDefinition(index: 0, operationKind: "qualityTrim", shortLabel: "qtrim-Q20", displaySummary: "Quality trim Q20"),
            ],
            barcodes: [
                BarcodeSummary(
                    label: "bc01",
                    inputMetrics: StepMetrics(
                        readCount: 10000, baseCount: 1_000_000,
                        meanReadLength: 100, medianReadLength: 100, n50ReadLength: 100,
                        meanQuality: 30, q20Percentage: 95, q30Percentage: 90, gcContent: 0.45
                    ),
                    stepResults: [
                        StepResult(
                            stepIndex: 0,
                            status: .completed,
                            metrics: StepMetrics(
                                readCount: 9500, baseCount: 950_000,
                                meanReadLength: 100, medianReadLength: 100, n50ReadLength: 100,
                                meanQuality: 32, q20Percentage: 98, q30Percentage: 95, gcContent: 0.45,
                                readsRetainedPercent: 95.0, cumulativeRetainedPercent: 95.0
                            )
                        ),
                    ]
                ),
            ]
        )

        try comparison.save(to: dir)
        let loaded = BatchComparisonManifest.load(from: dir)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.steps.count, 1)
        XCTAssertEqual(loaded?.barcodes.count, 1)
        XCTAssertEqual(loaded?.barcodes.first?.label, "bc01")
    }

    // MARK: - BarcodeSummary

    func testFinalMetricsCompletedStep() {
        let summary = BarcodeSummary(
            label: "bc01",
            inputMetrics: StepMetrics(
                readCount: 1000, baseCount: 100_000,
                meanReadLength: 100, medianReadLength: 100, n50ReadLength: 100,
                meanQuality: 30, q20Percentage: 95, q30Percentage: 90, gcContent: 0.45
            ),
            stepResults: [
                StepResult(stepIndex: 0, status: .completed, metrics: StepMetrics(
                    readCount: 900, baseCount: 90_000,
                    meanReadLength: 100, medianReadLength: 100, n50ReadLength: 100,
                    meanQuality: 32, q20Percentage: 98, q30Percentage: 95, gcContent: 0.45
                )),
            ]
        )

        XCTAssertEqual(summary.finalMetrics.readCount, 900)
        XCTAssertEqual(summary.cumulativeRetention, 0.9, accuracy: 0.001)
    }

    func testFinalMetricsFallsBackToInput() {
        let summary = BarcodeSummary(
            label: "bc01",
            inputMetrics: StepMetrics(
                readCount: 1000, baseCount: 100_000,
                meanReadLength: 100, medianReadLength: 100, n50ReadLength: 100,
                meanQuality: 30, q20Percentage: 95, q30Percentage: 90, gcContent: 0.45
            ),
            stepResults: [
                StepResult(stepIndex: 0, status: .failed, metrics: .empty, errorMessage: "tool crashed"),
            ]
        )

        XCTAssertEqual(summary.finalMetrics.readCount, 1000)
        XCTAssertEqual(summary.cumulativeRetention, 1.0, accuracy: 0.001)
    }

    func testCumulativeRetentionZeroInput() {
        let summary = BarcodeSummary(
            label: "empty",
            inputMetrics: .empty,
            stepResults: []
        )
        XCTAssertEqual(summary.cumulativeRetention, 0)
    }

    // MARK: - StepMetrics from FASTQDatasetStatistics

    func testStepMetricsFromStatistics() {
        let stats = FASTQDatasetStatistics(
            readCount: 800, baseCount: 80_000,
            meanReadLength: 100, minReadLength: 50, maxReadLength: 150,
            medianReadLength: 100, n50ReadLength: 100,
            meanQuality: 32, q20Percentage: 98, q30Percentage: 95, gcContent: 0.45,
            readLengthHistogram: [:], qualityScoreHistogram: [:], perPositionQuality: []
        )

        let metrics = StepMetrics(from: stats, inputReadCount: 1000, rawInputReadCount: 2000)
        XCTAssertEqual(metrics.readCount, 800)
        XCTAssertEqual(metrics.readsRetainedPercent!, 80.0, accuracy: 0.001)
        XCTAssertEqual(metrics.cumulativeRetainedPercent!, 40.0, accuracy: 0.001)
    }

    func testStepMetricsWithoutInputCounts() {
        let stats = FASTQDatasetStatistics(
            readCount: 500, baseCount: 50_000,
            meanReadLength: 100, minReadLength: 50, maxReadLength: 150,
            medianReadLength: 100, n50ReadLength: 100,
            meanQuality: 30, q20Percentage: 90, q30Percentage: 85, gcContent: 0.50,
            readLengthHistogram: [:], qualityScoreHistogram: [:], perPositionQuality: []
        )

        let metrics = StepMetrics(from: stats)
        XCTAssertNil(metrics.readsRetainedPercent)
        XCTAssertNil(metrics.cumulativeRetainedPercent)
    }

    // MARK: - StepStatus

    func testStepStatusCases() {
        XCTAssertEqual(StepStatus.allCases.count, 4)
        XCTAssertEqual(StepStatus.completed.rawValue, "completed")
        XCTAssertEqual(StepStatus.failed.rawValue, "failed")
        XCTAssertEqual(StepStatus.cancelled.rawValue, "cancelled")
        XCTAssertEqual(StepStatus.skipped.rawValue, "skipped")
    }

    // MARK: - StepDefinition Identifiable

    func testStepDefinitionIdentifiable() {
        let def = StepDefinition(index: 3, operationKind: "qualityTrim", shortLabel: "qtrim", displaySummary: "Quality trim")
        XCTAssertEqual(def.id, 3)
    }
}
