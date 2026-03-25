// BatchRunHistoryTests.swift - Tests for batch run history persistence
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class BatchRunHistoryTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchRunHistoryTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testRecordAndLoad() {
        let config = TaxTriageConfig(
            samples: [
                TaxTriageSample(sampleId: "S1", fastq1: URL(fileURLWithPath: "/data/R1.fq")),
                TaxTriageSample(sampleId: "S2", fastq1: URL(fileURLWithPath: "/data/R2.fq"), isNegativeControl: true),
            ],
            outputDirectory: tempDir
        )

        let result = TaxTriageResult(
            config: config,
            runtime: 99.5,
            exitCode: 0,
            outputDirectory: tempDir
        )

        BatchRunHistory.recordRun(result: result, config: config)

        let records = BatchRunHistory.loadRecords(from: tempDir)
        XCTAssertEqual(records.count, 1)

        let record = records[0]
        XCTAssertEqual(record.sampleIds, ["S1", "S2"])
        XCTAssertEqual(record.negativeControlSampleIds, ["S2"])
        XCTAssertEqual(record.exitCode, 0)
        XCTAssertTrue(record.isSuccess)
        XCTAssertEqual(record.runtime, 99.5, accuracy: 0.1)
    }

    func testDeduplicateByRunId() {
        let config = TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: "S1", fastq1: URL(fileURLWithPath: "/data/R1.fq"))],
            outputDirectory: tempDir
        )

        let result = TaxTriageResult(
            config: config,
            runtime: 50.0,
            exitCode: 0,
            outputDirectory: tempDir
        )

        // Record twice with the same runId
        BatchRunHistory.recordRun(result: result, config: config)
        BatchRunHistory.recordRun(result: result, config: config)

        let records = BatchRunHistory.loadRecords(from: tempDir)
        XCTAssertEqual(records.count, 1)
    }

    func testLoadFromEmptyDirectory() {
        let records = BatchRunHistory.loadRecords(from: tempDir)
        XCTAssertTrue(records.isEmpty)
    }

    func testLoadFromNonExistentDirectory() {
        let bogus = tempDir.appendingPathComponent("does-not-exist")
        let records = BatchRunHistory.loadRecords(from: bogus)
        XCTAssertTrue(records.isEmpty)
    }

    func testParametersPersisted() {
        let config = TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: "S1", fastq1: URL(fileURLWithPath: "/data/R1.fq"))],
            outputDirectory: tempDir,
            kraken2DatabasePath: URL(fileURLWithPath: "/db/k2standard"),
            topHitsCount: 5,
            k2Confidence: 0.3
        )

        let result = TaxTriageResult(
            config: config,
            runtime: 30.0,
            exitCode: 0,
            outputDirectory: tempDir
        )

        BatchRunHistory.recordRun(result: result, config: config)

        let records = BatchRunHistory.loadRecords(from: tempDir)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].parameters.k2Confidence, 0.3)
        XCTAssertEqual(records[0].parameters.topHitsCount, 5)
        XCTAssertEqual(records[0].parameters.kraken2DatabasePath, "/db/k2standard")
    }
}
