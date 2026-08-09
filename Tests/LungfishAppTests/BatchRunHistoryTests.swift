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

    /// R3-R3ML-13: the load-mutate-save sequence (load full log -> mutate in memory ->
    /// write full log back) must be serialized so concurrent writers do not clobber
    /// each other's appended record via a read-modify-write race: if writer A reads
    /// the log, then writer B reads the same pre-mutation log, appends its own entry,
    /// and saves, then A's later save (built from A's earlier, now-stale read)
    /// overwrites B's file and silently drops B's entry even though B's write already
    /// "succeeded".
    ///
    /// recordRun's production entry point derives BatchRunRecord.runId from
    /// result.outputDirectory's last path component, so every call targeting one
    /// directory dedupes onto a single runId -- that makes the race hard to observe
    /// through the public API alone (concurrent calls mostly overwrite the *same*
    /// logical record, so lost writes aren't visible as lost *entries*). Uses the
    /// #if DEBUG testingRecordRaw hook to fire many concurrent writes with genuinely
    /// distinct runIds at the same directory (still going through the same locked
    /// load-mutate-save critical section recordRun uses), which is what actually
    /// exercises the read-modify-write race this lock closes.
    func testConcurrentDistinctRecordsToSameDirectoryDoNotLoseEntries() {
        let writerCount = 30
        let directory = tempDir!
        let records = (0..<writerCount).map { index in
            BatchRunRecord(
                runId: "run-\(index)",
                startedAt: Date(),
                completedAt: Date(),
                sampleIds: ["S\(index)"],
                negativeControlSampleIds: [],
                platform: "ILLUMINA",
                outputDirectory: directory.path,
                exitCode: 0,
                runtime: Double(index),
                parameters: BatchRunParameters(
                    classifiers: ["kraken2"],
                    k2Confidence: 0.1,
                    topHitsCount: 1,
                    skipAssembly: false,
                    kraken2DatabasePath: nil
                )
            )
        }

        DispatchQueue.concurrentPerform(iterations: writerCount) { index in
            BatchRunHistory.testingRecordRaw(records[index], to: directory)
        }

        let finalRecords = BatchRunHistory.loadRecords(from: directory)
        let finalRunIds = Set(finalRecords.map(\.runId))
        let expectedRunIds = Set((0..<writerCount).map { "run-\($0)" })

        XCTAssertEqual(finalRecords.count, writerCount, "expected exactly \(writerCount) records, no lost writes from concurrent recordRun calls")
        XCTAssertEqual(finalRunIds, expectedRunIds, "every concurrently-written distinct runId must be present in the final history log, lost: \(expectedRunIds.subtracting(finalRunIds))")
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
