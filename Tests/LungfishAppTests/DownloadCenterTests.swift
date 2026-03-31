// DownloadCenterTests.swift - Unit tests for DownloadCenter
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
@testable import LungfishApp

/// Unit tests for ``DownloadCenter``.
///
/// Tests cover:
/// - Starting downloads creates items
/// - Updating progress and detail
/// - Completing and failing items
/// - Trim keeps max 20 finished items
/// - clearCompleted removes non-running items
/// - Active count tracking
/// - Byte-level progress tracking
/// - Error message and failure report data
/// - CLI command storage
/// - Log entries
@MainActor
final class DownloadCenterTests: XCTestCase {

    private var center: DownloadCenter!

    override func setUp() async throws {
        try await super.setUp()
        center = DownloadCenter()
    }

    override func tearDown() async throws {
        center = nil
        try await super.tearDown()
    }

    // MARK: - Start

    func testStartCreatesRunningItem() {
        let id = center.start(title: "Test", detail: "Starting...")

        XCTAssertEqual(center.items.count, 1)
        let item = center.items.first
        XCTAssertEqual(item?.id, id)
        XCTAssertEqual(item?.title, "Test")
        XCTAssertEqual(item?.detail, "Starting...")
        XCTAssertEqual(item?.progress, 0)
        XCTAssertEqual(item?.state, .running)
        XCTAssertNil(item?.finishedAt)
    }

    func testStartInsertsAtFront() {
        let id1 = center.start(title: "First", detail: "")
        let id2 = center.start(title: "Second", detail: "")

        XCTAssertEqual(center.items.count, 2)
        XCTAssertEqual(center.items[0].id, id2)
        XCTAssertEqual(center.items[1].id, id1)
    }

    // MARK: - Update

    func testUpdateChangesProgressAndDetail() {
        let id = center.start(title: "Test", detail: "Starting...")

        center.update(id: id, progress: 0.5, detail: "Halfway")

        let item = center.items.first
        XCTAssertEqual(item?.progress ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(item?.detail, "Halfway")
        XCTAssertEqual(item?.state, .running)
    }

    func testUpdateClampsProgress() {
        let id = center.start(title: "Test", detail: "")

        center.update(id: id, progress: 1.5, detail: "Over")
        XCTAssertEqual(center.items.first?.progress ?? -1, 1.0, accuracy: 0.001)

        center.update(id: id, progress: -0.5, detail: "Under")
        XCTAssertEqual(center.items.first?.progress ?? -1, 0.0, accuracy: 0.001)
    }

    func testUpdateIgnoresUnknownId() {
        _ = center.start(title: "Test", detail: "Starting...")

        center.update(id: UUID(), progress: 0.9, detail: "Other")

        XCTAssertEqual(center.items.first?.detail, "Starting...")
    }

    // MARK: - Complete

    func testCompleteSetsStateAndFinishedAt() {
        let id = center.start(title: "Test", detail: "Starting...")

        center.complete(id: id, detail: "Done!")

        let item = center.items.first
        XCTAssertEqual(item?.state, .completed)
        XCTAssertEqual(item?.progress ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(item?.detail, "Done!")
        XCTAssertNotNil(item?.finishedAt)
    }

    // MARK: - Fail

    func testFailSetsStateAndFinishedAt() {
        let id = center.start(title: "Test", detail: "Starting...")

        center.fail(id: id, detail: "Network error")

        let item = center.items.first
        XCTAssertEqual(item?.state, .failed)
        XCTAssertEqual(item?.detail, "Network error")
        XCTAssertNotNil(item?.finishedAt)
    }

    // MARK: - Active Count

    func testActiveCountTracksRunningItems() {
        XCTAssertEqual(center.activeCount, 0)

        let id1 = center.start(title: "A", detail: "")
        _ = center.start(title: "B", detail: "")

        XCTAssertEqual(center.activeCount, 2)

        center.complete(id: id1, detail: "Done")
        XCTAssertEqual(center.activeCount, 1)
    }

    // MARK: - Clear Completed

    func testClearCompletedRemovesFinishedItems() {
        let id1 = center.start(title: "Running", detail: "")
        let id2 = center.start(title: "Done", detail: "")
        let id3 = center.start(title: "Failed", detail: "")

        center.complete(id: id2, detail: "Completed")
        center.fail(id: id3, detail: "Error")

        XCTAssertEqual(center.items.count, 3)

        center.clearCompleted()

        XCTAssertEqual(center.items.count, 1)
        XCTAssertEqual(center.items.first?.id, id1)
        XCTAssertEqual(center.items.first?.state, .running)
    }

    func testClearCompletedWithNoFinishedItemsIsNoOp() {
        _ = center.start(title: "Running", detail: "")
        XCTAssertEqual(center.items.count, 1)

        center.clearCompleted()
        XCTAssertEqual(center.items.count, 1)
    }

    // MARK: - Trim

    func testTrimKeepsMaxFinishedItems() {
        // Start and complete 25 items (exceeds the 20-item limit)
        for i in 0..<25 {
            let id = center.start(title: "Item \(i)", detail: "")
            center.complete(id: id, detail: "Done \(i)")
        }

        // All 25 are completed; trim should keep only 20
        XCTAssertLessThanOrEqual(center.items.count, 20)
    }

    func testTrimPreservesRunningItems() {
        // Start a running item
        _ = center.start(title: "Running", detail: "In progress")

        // Start and complete 25 items
        for i in 0..<25 {
            let id = center.start(title: "Item \(i)", detail: "")
            center.complete(id: id, detail: "Done \(i)")
        }

        // Running item must be preserved
        let runningItems = center.items.filter { $0.state == .running }
        XCTAssertEqual(runningItems.count, 1)
        XCTAssertEqual(runningItems.first?.title, "Running")
    }

    // MARK: - Item Identity

    func testItemIdentityByUUID() {
        let id1 = center.start(title: "A", detail: "")
        let id2 = center.start(title: "B", detail: "")

        XCTAssertNotEqual(id1, id2)
        XCTAssertEqual(center.items.count, 2)
    }

    // MARK: - Item State Enum

    func testItemStateRawValues() {
        XCTAssertEqual(DownloadCenter.Item.State.running.rawValue, "running")
        XCTAssertEqual(DownloadCenter.Item.State.completed.rawValue, "completed")
        XCTAssertEqual(DownloadCenter.Item.State.failed.rawValue, "failed")
    }

    // MARK: - Bundle URLs

    func testCompleteWithBundleURLsStoresURLs() {
        let id = center.start(title: "Test", detail: "Starting...")
        let urls = [URL(fileURLWithPath: "/tmp/test.lungfishref")]

        center.complete(id: id, detail: "Done!", bundleURLs: urls)

        let item = center.items.first
        XCTAssertEqual(item?.state, .completed)
        XCTAssertEqual(item?.bundleURLs.count, 1)
        XCTAssertEqual(item?.bundleURLs.first?.lastPathComponent, "test.lungfishref")
    }

    func testCompleteWithBundleURLsFiresOnBundleReady() {
        var receivedURLs: [URL]?
        center.onBundleReady = { urls in
            receivedURLs = urls
        }

        let id = center.start(title: "Test", detail: "Starting...")
        let urls = [URL(fileURLWithPath: "/tmp/a.lungfishref"), URL(fileURLWithPath: "/tmp/b.lungfishref")]

        center.complete(id: id, detail: "Done!", bundleURLs: urls)

        XCTAssertEqual(receivedURLs?.count, 2)
        XCTAssertEqual(receivedURLs?.first?.lastPathComponent, "a.lungfishref")
    }

    func testCompleteWithEmptyBundleURLsDoesNotFireCallback() {
        var callbackFired = false
        center.onBundleReady = { _ in
            callbackFired = true
        }

        let id = center.start(title: "Test", detail: "Starting...")
        center.complete(id: id, detail: "Done!", bundleURLs: [])

        XCTAssertFalse(callbackFired)
    }

    func testCompleteWithoutBundleURLsDoesNotFireCallback() {
        var callbackFired = false
        center.onBundleReady = { _ in
            callbackFired = true
        }

        let id = center.start(title: "Test", detail: "Starting...")
        center.complete(id: id, detail: "Done!")

        XCTAssertFalse(callbackFired)
    }

    func testStartItemHasEmptyBundleURLs() {
        let id = center.start(title: "Test", detail: "Starting...")
        let item = center.items.first { $0.id == id }
        XCTAssertEqual(item?.bundleURLs, [])
    }

    // MARK: - Operation Type

    func testDefaultOperationTypeIsDownload() {
        let id = center.start(title: "Test", detail: "Starting...")
        let item = center.items.first { $0.id == id }
        XCTAssertEqual(item?.operationType, .download)
    }

    func testStartWithOperationType() {
        let id = center.start(title: "BAM", detail: "Importing...", operationType: .bamImport)
        let item = center.items.first { $0.id == id }
        XCTAssertEqual(item?.operationType, .bamImport)
    }

    func testOperationTypeRawValues() {
        XCTAssertEqual(OperationType.download.rawValue, "Download")
        XCTAssertEqual(OperationType.bamImport.rawValue, "BAM Import")
        XCTAssertEqual(OperationType.vcfImport.rawValue, "VCF Import")
        XCTAssertEqual(OperationType.bundleBuild.rawValue, "Bundle Build")
        XCTAssertEqual(OperationType.export.rawValue, "Export")
    }

    // MARK: - Bundle Locking

    func testCanStartOperationWithNoBundleURL() {
        XCTAssertTrue(center.canStartOperation(on: nil))
    }

    func testCanStartOperationOnUnlockedBundle() {
        let bundleURL = URL(fileURLWithPath: "/tmp/test.lungfishref")
        XCTAssertTrue(center.canStartOperation(on: bundleURL))
    }

    func testCannotStartOperationOnLockedBundle() {
        let bundleURL = URL(fileURLWithPath: "/tmp/test.lungfishref")
        _ = center.start(
            title: "Import",
            detail: "...",
            operationType: .bamImport,
            targetBundleURL: bundleURL
        )

        XCTAssertFalse(center.canStartOperation(on: bundleURL))
    }

    func testCanStartOperationAfterComplete() {
        let bundleURL = URL(fileURLWithPath: "/tmp/test.lungfishref")
        let id = center.start(
            title: "Import",
            detail: "...",
            operationType: .bamImport,
            targetBundleURL: bundleURL
        )
        center.complete(id: id, detail: "Done")

        XCTAssertTrue(center.canStartOperation(on: bundleURL))
    }

    func testCanStartOperationAfterFail() {
        let bundleURL = URL(fileURLWithPath: "/tmp/test.lungfishref")
        let id = center.start(
            title: "Import",
            detail: "...",
            operationType: .bamImport,
            targetBundleURL: bundleURL
        )
        center.fail(id: id, detail: "Error")

        XCTAssertTrue(center.canStartOperation(on: bundleURL))
    }

    func testDifferentBundlesCanRunConcurrently() {
        let bundle1 = URL(fileURLWithPath: "/tmp/a.lungfishref")
        let bundle2 = URL(fileURLWithPath: "/tmp/b.lungfishref")

        _ = center.start(
            title: "Import A",
            detail: "...",
            operationType: .bamImport,
            targetBundleURL: bundle1
        )

        XCTAssertTrue(center.canStartOperation(on: bundle2))
    }

    func testActiveLockHolderReturnsRunningItem() {
        let bundleURL = URL(fileURLWithPath: "/tmp/test.lungfishref")
        let id = center.start(
            title: "Import",
            detail: "...",
            operationType: .bamImport,
            targetBundleURL: bundleURL
        )

        let holder = center.activeLockHolder(for: bundleURL)
        XCTAssertEqual(holder?.id, id)
    }

    func testActiveLockHolderNilForUnlockedBundle() {
        let bundleURL = URL(fileURLWithPath: "/tmp/test.lungfishref")
        XCTAssertNil(center.activeLockHolder(for: bundleURL))
    }

    func testActiveLockHolderNilAfterComplete() {
        let bundleURL = URL(fileURLWithPath: "/tmp/test.lungfishref")
        let id = center.start(
            title: "Import",
            detail: "...",
            operationType: .bamImport,
            targetBundleURL: bundleURL
        )
        center.complete(id: id, detail: "Done")

        XCTAssertNil(center.activeLockHolder(for: bundleURL))
    }

    func testActiveLockHolderNilForNilURL() {
        XCTAssertNil(center.activeLockHolder(for: nil))
    }

    // MARK: - Cancel

    func testCancelInvokesCallbackAndFails() {
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        let id = center.start(
            title: "Import",
            detail: "...",
            operationType: .bamImport,
            onCancel: { cancelFlag.withLock { $0 = true } }
        )

        center.cancel(id: id)

        XCTAssertTrue(cancelFlag.withLock { $0 })
        let item = center.items.first { $0.id == id }
        XCTAssertEqual(item?.state, .failed)
        XCTAssertEqual(item?.detail, "Cancelled by user")
    }

    func testCancelReleaseBundleLock() {
        let bundleURL = URL(fileURLWithPath: "/tmp/test.lungfishref")
        let id = center.start(
            title: "Import",
            detail: "...",
            operationType: .bamImport,
            targetBundleURL: bundleURL
        )

        center.cancel(id: id)

        XCTAssertTrue(center.canStartOperation(on: bundleURL))
    }

    func testCancelIgnoresCompletedItem() {
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        let id = center.start(
            title: "Import",
            detail: "...",
            onCancel: { cancelFlag.withLock { $0 = true } }
        )
        center.complete(id: id, detail: "Done")

        center.cancel(id: id)

        XCTAssertFalse(cancelFlag.withLock { $0 })
        let item = center.items.first { $0.id == id }
        XCTAssertEqual(item?.state, .completed)
    }

    func testCancelAllCancelsAllRunning() {
        let flag1 = OSAllocatedUnfairLock(initialState: false)
        let flag2 = OSAllocatedUnfairLock(initialState: false)
        _ = center.start(title: "A", detail: "", onCancel: { flag1.withLock { $0 = true } })
        _ = center.start(title: "B", detail: "", onCancel: { flag2.withLock { $0 = true } })

        center.cancelAll()

        XCTAssertTrue(flag1.withLock { $0 })
        XCTAssertTrue(flag2.withLock { $0 })
        XCTAssertEqual(center.activeCount, 0)
    }

    // MARK: - OperationCenter Typealias

    func testDownloadCenterTypealiasWorks() {
        let dc: DownloadCenter = center
        XCTAssertEqual(dc.activeCount, 0)
    }

    // MARK: - All Operation Types

    func testAllOperationTypesExist() {
        let allTypes: [OperationType] = [
            .download, .bamImport, .vcfImport, .bundleBuild, .export,
            .assembly, .ingestion, .fastqOperation, .qualityReport,
            .taxonomyExtraction, .classification, .blastVerification,
        ]
        XCTAssertEqual(allTypes.count, 12, "Update this test when new OperationType cases are added")
    }

    // MARK: - Byte-Level Progress Tracking

    func testItemHasTotalBytesFieldDefaultNil() {
        let id = center.start(title: "Download", detail: "Starting...")
        let item = center.items.first { $0.id == id }
        XCTAssertNil(item?.totalBytes, "totalBytes should default to nil")
    }

    func testItemHasBytesDownloadedFieldDefaultNil() {
        let id = center.start(title: "Download", detail: "Starting...")
        let item = center.items.first { $0.id == id }
        XCTAssertNil(item?.bytesDownloaded, "bytesDownloaded should default to nil")
    }

    func testUpdateBytesComputesProgressCorrectly() {
        let id = center.start(title: "Download", detail: "Starting...")

        center.updateBytes(id: id, bytesDownloaded: 500_000, totalBytes: 1_000_000)

        let item = center.items.first { $0.id == id }
        XCTAssertEqual(item?.progress ?? -1, 0.5, accuracy: 0.001,
                       "Progress should be bytesDownloaded / totalBytes")
        XCTAssertEqual(item?.bytesDownloaded, 500_000)
        XCTAssertEqual(item?.totalBytes, 1_000_000)
    }

    func testUpdateBytesFullDownloadSetsProgressToOne() {
        let id = center.start(title: "Download", detail: "Starting...")

        center.updateBytes(id: id, bytesDownloaded: 2_000_000, totalBytes: 2_000_000)

        let item = center.items.first { $0.id == id }
        XCTAssertEqual(item?.progress ?? -1, 1.0, accuracy: 0.001)
    }

    func testUpdateBytesPreservesTotalWhenNilPassed() {
        let id = center.start(title: "Download", detail: "Starting...")

        // First call sets totalBytes
        center.updateBytes(id: id, bytesDownloaded: 100_000, totalBytes: 500_000)
        // Second call with nil totalBytes should preserve previously known total
        center.updateBytes(id: id, bytesDownloaded: 250_000, totalBytes: nil)

        let item = center.items.first { $0.id == id }
        XCTAssertEqual(item?.totalBytes, 500_000, "Previously known totalBytes should be preserved")
        XCTAssertEqual(item?.progress ?? -1, 0.5, accuracy: 0.001)
    }

    func testUpdateBytesGeneratesDetailWithByteCounts() {
        let id = center.start(title: "Download", detail: "Starting...")

        center.updateBytes(id: id, bytesDownloaded: 50_000_000, totalBytes: 100_000_000)

        let item = center.items.first { $0.id == id }
        // Detail should contain byte count text (e.g. "50 MB / 100 MB")
        XCTAssertNotEqual(item?.detail, "Starting...", "Detail should be updated by updateBytes")
        XCTAssertTrue(item?.detail.contains("/") == true,
                      "Detail should contain 'downloaded / total' format: \(item?.detail ?? "")")
    }

    func testUpdateBytesWithoutTotalShowsOnlyDownloaded() {
        let id = center.start(title: "Download", detail: "Starting...")

        // When totalBytes is nil and no previous total is known
        center.updateBytes(id: id, bytesDownloaded: 10_000_000, totalBytes: nil)

        let item = center.items.first { $0.id == id }
        XCTAssertNotEqual(item?.detail, "Starting...",
                          "Detail should be updated even without totalBytes")
    }

    // MARK: - Error Message and Failure Report Data

    func testFailWithErrorMessageStoresFields() {
        let id = center.start(title: "Classify", detail: "Running...")

        center.fail(
            id: id,
            detail: "kraken2 exited with code 1",
            errorMessage: "Database not found",
            errorDetail: "stderr: /db/k2 does not exist"
        )

        let item = center.items.first { $0.id == id }
        XCTAssertEqual(item?.state, .failed)
        XCTAssertEqual(item?.errorMessage, "Database not found")
        XCTAssertEqual(item?.errorDetail, "stderr: /db/k2 does not exist")
        XCTAssertEqual(item?.detail, "kraken2 exited with code 1")
    }

    func testFailWithoutErrorMessageLeavesErrorMessageNil() {
        let id = center.start(title: "Download", detail: "Running...")

        center.fail(id: id, detail: "Network timeout")

        let item = center.items.first { $0.id == id }
        XCTAssertEqual(item?.state, .failed)
        XCTAssertNil(item?.errorMessage, "errorMessage should be nil when not provided")
        XCTAssertEqual(item?.detail, "Network timeout",
                       "detail should serve as fallback failure reason")
    }

    func testFailedItemWithoutErrorMessageHasDetailForReport() {
        // buildFailureReport uses `item.errorMessage ?? item.detail` as fallback.
        // This test verifies the data model supports that pattern.
        let id = center.start(title: "Import BAM", detail: "Importing...")

        center.fail(id: id, detail: "File not found: /data/sample.bam")

        let item = center.items.first { $0.id == id }!
        let errorText = item.errorMessage ?? item.detail
        XCTAssertEqual(errorText, "File not found: /data/sample.bam",
                       "Failure report should fall back to detail when errorMessage is nil")
    }

    // MARK: - CLI Command Storage

    func testCLICommandStoredOnStart() {
        let cmd = "lungfish classify --db standard --input /data/R1.fastq.gz"
        let id = center.start(title: "Classify", detail: "Running...", cliCommand: cmd)

        let item = center.items.first { $0.id == id }
        XCTAssertEqual(item?.cliCommand, cmd)
    }

    func testCLICommandDefaultsToNil() {
        let id = center.start(title: "Download", detail: "Starting...")

        let item = center.items.first { $0.id == id }
        XCTAssertNil(item?.cliCommand, "cliCommand should default to nil")
    }

    func testBuildCLICommandShellQuotes() {
        let cmd = OperationCenter.buildCLICommand(
            subcommand: "classify",
            args: ["--input", "/path with spaces/file.fastq.gz", "--db", "standard"]
        )
        XCTAssertTrue(cmd.hasPrefix("lungfish classify"))
        XCTAssertTrue(cmd.contains("'/path with spaces/file.fastq.gz'"),
                      "Paths with spaces should be shell-quoted: \(cmd)")
    }

    // MARK: - Log Entries

    func testLogEntriesAppendedToItem() {
        let id = center.start(title: "Pipeline", detail: "Running...")

        center.log(id: id, level: .info, message: "Step 1 complete")
        center.log(id: id, level: .warning, message: "Low memory")
        center.log(id: id, level: .error, message: "kraken2 failed")

        let item = center.items.first { $0.id == id }
        XCTAssertEqual(item?.logEntries.count, 3)
        XCTAssertEqual(item?.logEntries[0].message, "Step 1 complete")
        XCTAssertEqual(item?.logEntries[0].level, .info)
        XCTAssertEqual(item?.logEntries[2].level, .error)
    }

    // MARK: - Failure Report Data Completeness

    func testFailedItemWithAllFieldsHasCompleteReportData() {
        let cmd = "lungfish classify --db standard --input /data/R1.fastq.gz"
        let id = center.start(title: "Classify Reads", detail: "Starting...", cliCommand: cmd)

        center.log(id: id, level: .info, message: "Loading database")
        center.log(id: id, level: .error, message: "OOM killed")
        center.fail(
            id: id,
            detail: "Process exited with code 137",
            errorMessage: "Out of memory",
            errorDetail: "Signal 9 (SIGKILL) received"
        )

        let item = center.items.first { $0.id == id }!
        // Verify all fields needed by buildFailureReport are populated
        XCTAssertEqual(item.title, "Classify Reads")
        XCTAssertNotNil(item.cliCommand)
        XCTAssertNotNil(item.errorMessage)
        XCTAssertNotNil(item.errorDetail)
        XCTAssertFalse(item.logEntries.isEmpty)
        XCTAssertEqual(item.state, .failed)
    }
}
