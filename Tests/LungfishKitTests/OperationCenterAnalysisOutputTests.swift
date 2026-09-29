// OperationCenterAnalysisOutputTests.swift - Analysis results appear only after a successful run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishKit

@MainActor
final class OperationCenterAnalysisOutputTests: XCTestCase {
    private var root: URL!
    private var center: OperationCenter!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oc-analysis-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        center = OperationCenter()
        center.failureReportStore = OperationFailureReportStore(
            directory: root.appendingPathComponent("reports", isDirectory: true)
        )
    }

    override func tearDownWithError() throws {
        center = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func makeIncompleteRun(_ name: String = "taxtriage-batch-2026-09-28T10-00-00") throws -> URL {
        let dir = root.appendingPathComponent("Analyses/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AnalysisRunRecord.begin(AnalysisRunRecord(analysisName: "TaxTriage"), in: dir)
        return dir
    }

    func testCompletingTheOperationMarksTheRunComplete() throws {
        let dir = try makeIncompleteRun()
        let id = center.start(title: "TaxTriage", detail: "Running", cliCommand: "lungfish-cli taxtriage --input a.fastq")
        center.trackAnalysisOutput(dir, for: id)
        XCTAssertTrue(center.isTrackingAnalysisOutput(dir))
        XCTAssertEqual(AnalysisRunRecord.load(from: dir)?.command, "lungfish-cli taxtriage --input a.fastq")

        let notified = expectation(forNotification: .analysisRunOutputsCompleted, object: center) { note in
            let urls = note.userInfo?["directories"] as? [URL] ?? []
            return urls.map(\.standardizedFileURL) == [dir.standardizedFileURL]
        }
        XCTAssertTrue(center.complete(id: id, detail: "Done"))
        XCTAssertFalse(AnalysisRunRecord.isIncomplete(dir))
        XCTAssertFalse(center.isTrackingAnalysisOutput(dir))
        wait(for: [notified], timeout: 1)
    }

    func testCompletingWithWarningsIsASuccessfulRun() throws {
        let dir = try makeIncompleteRun()
        let id = center.start(title: "Viral Recon", detail: "Running")
        center.trackAnalysisOutput(dir, for: id)
        XCTAssertTrue(center.completeWithWarning(id: id, detail: "2 samples skipped"))
        XCTAssertFalse(AnalysisRunRecord.isIncomplete(dir))
    }

    func testCompletingWithWarningsAndOutputsIsASuccessfulRun() throws {
        let dir = try makeIncompleteRun()
        let id = center.start(title: "Viral Recon", detail: "Running")
        center.trackAnalysisOutput(dir, for: id)
        XCTAssertTrue(center.completeWithWarning(id: id, detail: "advisories", bundleURLs: [dir]))
        XCTAssertFalse(AnalysisRunRecord.isIncomplete(dir))
    }

    func testFailedRunStaysIncomplete() throws {
        let dir = try makeIncompleteRun()
        let id = center.start(title: "TaxTriage", detail: "Running")
        center.trackAnalysisOutput(dir, for: id)
        XCTAssertTrue(center.fail(id: id, detail: "Nextflow exited 1"))
        XCTAssertTrue(AnalysisRunRecord.isIncomplete(dir))
        XCTAssertFalse(center.isTrackingAnalysisOutput(dir))
    }

    func testCancelledRunStaysIncomplete() throws {
        let dir = try makeIncompleteRun()
        let id = center.start(title: "TaxTriage", detail: "Running")
        center.trackAnalysisOutput(dir, for: id)
        XCTAssertTrue(center.acknowledgeCancellation(id: id))
        XCTAssertTrue(AnalysisRunRecord.isIncomplete(dir))
    }

    func testTrackingASampleDirectoryResolvesItsIncompleteBatchRoot() throws {
        let batch = try makeIncompleteRun("spades-batch-2026-09-28T10-00-00")
        let sampleA = batch.appendingPathComponent("A", isDirectory: true)
        let sampleB = batch.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: sampleA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sampleB, withIntermediateDirectories: true)

        let first = center.start(title: "Assemble A", detail: "Running")
        let second = center.start(title: "Assemble B", detail: "Running")
        center.trackAnalysisOutput(sampleA, for: first)
        center.trackAnalysisOutput(sampleB, for: second)

        XCTAssertTrue(center.complete(id: first, detail: "Done"))
        XCTAssertTrue(AnalysisRunRecord.isIncomplete(batch), "the batch waits for every child")
        XCTAssertTrue(center.fail(id: second, detail: "SPAdes failed"))
        XCTAssertFalse(AnalysisRunRecord.isIncomplete(batch), "one successful child makes the batch a result")
    }

    func testEveryChildFailingKeepsTheBatchIncomplete() throws {
        let batch = try makeIncompleteRun("spades-batch-2026-09-28T10-00-00")
        let first = center.start(title: "Assemble A", detail: "Running")
        let second = center.start(title: "Assemble B", detail: "Running")
        center.trackAnalysisOutput(batch, for: first)
        center.trackAnalysisOutput(batch, for: second)
        center.fail(id: first, detail: "failed")
        center.fail(id: second, detail: "failed")
        XCTAssertTrue(AnalysisRunRecord.isIncomplete(batch))
    }

    func testHoldKeepsASequentialBatchHiddenUntilReleased() throws {
        let batch = try makeIncompleteRun("minimap2-batch-2026-09-28T10-00-00")
        let hold = center.holdAnalysisOutput(batch)
        let child = center.start(title: "Map A", detail: "Running")
        center.trackAnalysisOutput(batch, for: child)
        center.complete(id: child, detail: "Done")
        XCTAssertTrue(AnalysisRunRecord.isIncomplete(batch))
        XCTAssertTrue(center.isTrackingAnalysisOutput(batch))

        center.releaseAnalysisOutputHold(hold, succeeded: false)
        XCTAssertFalse(AnalysisRunRecord.isIncomplete(batch), "a completed child already counts as success")
    }

    func testTrackingAfterTheOperationCompletedMarksImmediately() throws {
        let dir = try makeIncompleteRun()
        let id = center.start(title: "Kraken2", detail: "Running")
        center.complete(id: id, detail: "Done")
        center.trackAnalysisOutput(dir, for: id)
        XCTAssertFalse(AnalysisRunRecord.isIncomplete(dir))
    }

    func testTrackingACompleteDirectoryIsANoOp() throws {
        let dir = root.appendingPathComponent("Analyses/legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = center.start(title: "Kraken2", detail: "Running")
        center.trackAnalysisOutput(dir, for: id)
        XCTAssertFalse(center.isTrackingAnalysisOutput(dir))
    }

    // MARK: - Interrupted runs

    func testInterruptedRunIsListedOnceWithItsDetails() throws {
        let dir = try makeIncompleteRun()
        var record = try XCTUnwrap(AnalysisRunRecord.load(from: dir))
        record.command = "lungfish-cli taxtriage --input a.fastq"
        let run = OperationCenter.InterruptedAnalysisRun(directory: dir, record: record, sizeOnDiskBytes: 2_048)

        let id = try XCTUnwrap(center.registerInterruptedAnalysisRun(run))
        XCTAssertNil(center.registerInterruptedAnalysisRun(run), "the same directory is listed once")

        let item = try XCTUnwrap(center.items.first { $0.id == id })
        XCTAssertEqual(item.state, .interrupted)
        XCTAssertFalse(item.state.isActive)
        XCTAssertEqual(item.displayStateLabel, "Interrupted")
        XCTAssertEqual(item.interruptedRunDirectory?.standardizedFileURL, dir.standardizedFileURL)
        XCTAssertEqual(item.cliCommand, "lungfish-cli taxtriage --input a.fastq")
        XCTAssertEqual(item.startedAt, record.startedAt)
        XCTAssertTrue(item.title.contains("TaxTriage"))
        XCTAssertTrue(item.detail.contains("2 KB"), item.detail)
        XCTAssertFalse(item.logEntries.isEmpty, "View Log has something to show")
        XCTAssertNil(item.failureReportURL)
        XCTAssertTrue(AnalysisRunRecord.isIncomplete(dir), "listing an interrupted run never touches it")
    }

    func testTrackedRunsAreNeverListedAsInterrupted() throws {
        let dir = try makeIncompleteRun()
        let id = center.start(title: "TaxTriage", detail: "Running")
        center.trackAnalysisOutput(dir, for: id)
        let run = OperationCenter.InterruptedAnalysisRun(
            directory: dir,
            record: AnalysisRunRecord.load(from: dir),
            sizeOnDiskBytes: 0
        )
        XCTAssertNil(center.registerInterruptedAnalysisRun(run))
    }

    // MARK: - Sequential batches

    /// The last child's completion must find its batch root already complete,
    /// so the caller that selects the result right after completing it
    /// finds it in the sidebar.
    func testSequentialBatchRootCompletesWhenItsLastChildCompletes() throws {
        let dir = try makeIncompleteRun("minimap2-batch-2026-09-28T10-00-00")
        let sample1 = dir.appendingPathComponent("S1", isDirectory: true)
        let sample2 = dir.appendingPathComponent("S2", isDirectory: true)
        let batch = SequentialAnalysisBatchHold(directory: dir, childCount: 2, center: center)

        let first = center.start(title: "S1", detail: "Running")
        center.trackAnalysisOutput(sample1, for: first)
        batch.didLaunchChild()
        XCTAssertTrue(center.complete(id: first, detail: "Done"))
        XCTAssertTrue(AnalysisRunRecord.isIncomplete(dir), "hidden between children")

        let second = center.start(title: "S2", detail: "Running")
        center.trackAnalysisOutput(sample2, for: second)
        batch.didLaunchChild()
        XCTAssertTrue(AnalysisRunRecord.isIncomplete(dir), "hidden while the last child runs")
        XCTAssertTrue(center.complete(id: second, detail: "Done"))
        XCTAssertFalse(AnalysisRunRecord.isIncomplete(dir), "complete as soon as the last child completes")

        batch.finish(succeeded: true)
        XCTAssertFalse(AnalysisRunRecord.isIncomplete(dir))
    }

    func testSequentialBatchWhoseLastChildFailsStillCompletesOnAnEarlierSuccess() throws {
        let dir = try makeIncompleteRun("spades-batch-2026-09-28T10-00-00")
        let batch = SequentialAnalysisBatchHold(directory: dir, childCount: 2, center: center)
        let first = center.start(title: "S1", detail: "Running")
        center.trackAnalysisOutput(dir.appendingPathComponent("S1"), for: first)
        batch.didLaunchChild()
        center.complete(id: first, detail: "Done")
        let second = center.start(title: "S2", detail: "Running")
        center.trackAnalysisOutput(dir.appendingPathComponent("S2"), for: second)
        batch.didLaunchChild()
        center.fail(id: second, detail: "boom")
        XCTAssertFalse(AnalysisRunRecord.isIncomplete(dir))
    }

    func testSequentialBatchCancelledBeforeItsLastChildStaysHidden() throws {
        let dir = try makeIncompleteRun("minimap2-batch-2026-09-28T11-00-00")
        let batch = SequentialAnalysisBatchHold(directory: dir, childCount: 3, center: center)
        let first = center.start(title: "S1", detail: "Running")
        center.trackAnalysisOutput(dir.appendingPathComponent("S1"), for: first)
        batch.didLaunchChild()
        center.cancel(id: first)
        center.acknowledgeCancellation(id: first)
        batch.finish(succeeded: false)
        XCTAssertTrue(AnalysisRunRecord.isIncomplete(dir))
        XCTAssertFalse(center.isTrackingAnalysisOutput(dir))
    }
}
