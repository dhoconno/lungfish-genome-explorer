// DownloadCenterTests.swift - Unit tests for DownloadCenter
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
import Combine
@testable import LungfishApp
import LungfishKit

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
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        try await super.setUp()
        center = DownloadCenter()
        cancellables = []
    }

    override func tearDown() async throws {
        cancellables.removeAll()
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

    func testUpdateIgnoresCompletedOperation() {
        let id = center.start(title: "Test", detail: "Starting...")
        center.complete(id: id, detail: "Done")

        center.update(id: id, progress: 0.25, detail: "Late progress")

        let item = center.items.first
        XCTAssertEqual(item?.state, .completed)
        XCTAssertEqual(item?.progress ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(item?.detail, "Done")
    }

    func testUpdateWithLogDeduplicatesAdjacentProgressMessages() {
        let id = center.start(title: "Test", detail: "Starting...")

        center.updateWithLog(id: id, progress: 0.1, detail: "Parsing reads")
        center.updateWithLog(id: id, progress: 0.2, detail: "Parsing reads")
        center.updateWithLog(id: id, progress: 0.3, detail: "Writing bundle")

        let item = center.items.first
        XCTAssertEqual(item?.detail, "Writing bundle")
        XCTAssertEqual(item?.progress ?? -1, 0.3, accuracy: 0.001)
        XCTAssertEqual(item?.logEntries.map(\.message), ["Parsing reads", "Writing bundle"])
    }

    func testUpdateDoesNotAppendVolatileProgressDetailsToLogHistory() {
        let id = center.start(title: "Test", detail: "Starting...")
        center.log(id: id, level: .info, message: "Import started")

        center.update(id: id, progress: 0.1, detail: "Processed 10,000 variants · ETA 8m")
        center.update(id: id, progress: 0.2, detail: "Processed 20,000 variants · ETA 6m")

        let item = center.items.first
        XCTAssertEqual(item?.detail, "Processed 20,000 variants · ETA 6m")
        XCTAssertEqual(item?.progress ?? -1, 0.2, accuracy: 0.001)
        XCTAssertEqual(item?.logEntries.map(\.message), ["Import started"])
    }

    func testProgressUpdatesEmitRowLevelChange() {
        var changes: [OperationCenter.Change] = []
        center.changes.sink { changes.append($0) }.store(in: &cancellables)

        let id = center.start(title: "Test", detail: "Starting...")
        center.update(id: id, progress: 0.5, detail: "Halfway")

        XCTAssertEqual(changes, [
            .inserted(id: id, index: 0),
            .updated(id: id, index: 0),
        ])
    }

    func testLogUpdatesEmitRowLevelChange() {
        var changes: [OperationCenter.Change] = []
        center.changes.sink { changes.append($0) }.store(in: &cancellables)

        let id = center.start(title: "Test", detail: "Starting...")
        center.log(id: id, level: .info, message: "Import started")

        XCTAssertEqual(changes, [
            .inserted(id: id, index: 0),
            .updated(id: id, index: 0),
        ])
    }

    func testClearCompletedEmitsRemovedChange() {
        var changes: [OperationCenter.Change] = []
        center.changes.sink { changes.append($0) }.store(in: &cancellables)

        let runningID = center.start(title: "Running", detail: "")
        let doneID = center.start(title: "Done", detail: "")
        center.complete(id: doneID, detail: "Done")

        changes.removeAll()
        center.clearCompleted()

        XCTAssertEqual(center.items.map(\.id), [runningID])
        XCTAssertEqual(changes, [.removed(ids: [doneID])])
    }

    func testCompletingOlderRunningOperationEmitsReloadWhenItemOrderChanges() {
        var changes: [OperationCenter.Change] = []
        center.changes.sink { changes.append($0) }.store(in: &cancellables)

        let olderID = center.start(title: "Older", detail: "")
        let newerID = center.start(title: "Newer", detail: "")

        changes.removeAll()
        center.complete(id: newerID, detail: "Done")

        XCTAssertEqual(center.items.map(\.id), [olderID, newerID])
        XCTAssertEqual(changes, [.reloaded])
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
        XCTAssertEqual(DownloadCenter.Item.State.cancelling.rawValue, "cancelling")
        XCTAssertEqual(DownloadCenter.Item.State.completed.rawValue, "completed")
        XCTAssertEqual(DownloadCenter.Item.State.failed.rawValue, "failed")
        XCTAssertEqual(DownloadCenter.Item.State.cancelled.rawValue, "cancelled")
    }

    func testOperationTypesIncludeVariantCalling() {
        let allTypes: [OperationType] = [
            .download,
            .bamImport,
            .vcfImport,
            .bundleBuild,
            .export,
            .assembly,
            .ingestion,
            .fastqOperation,
            .qualityReport,
            .taxonomyExtraction,
            .classification,
            .blastVerification,
            .bamPrimerTrim,
            .applicationExportImport,
            .multipleSequenceAlignmentImport,
            .multipleSequenceAlignmentGeneration,
            .multipleSequenceAlignmentAction,
            .phylogeneticTreeImport,
            .phylogeneticTreeInference,
            .variantCalling,
            .viralRecon,
        ]

        XCTAssertEqual(allTypes.count, 21)
        XCTAssertEqual(OperationType.variantCalling.rawValue, "Variant Calling")
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

    func testCompleteWithOutputURLsStoresURLsWithoutImportingBundles() {
        var callbackFired = false
        center.onBundleReady = { _ in
            callbackFired = true
        }

        let id = center.start(title: "Export Alignment", detail: "Starting...")
        let urls = [URL(fileURLWithPath: "/project/exports/alignment.fasta")]

        center.complete(id: id, detail: "Exported alignment", outputURLs: urls)

        let item = center.items.first
        XCTAssertEqual(item?.state, .completed)
        XCTAssertEqual(item?.outputURLs.map(\.lastPathComponent), ["alignment.fasta"])
        XCTAssertEqual(item?.bundleURLs, [])
        XCTAssertFalse(callbackFired, "Plain file outputs should not be routed through bundle import callbacks")
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
        XCTAssertEqual(OperationType.applicationExportImport.rawValue, "Application Export")
        XCTAssertEqual(OperationType.multipleSequenceAlignmentImport.rawValue, "MSA Import")
        XCTAssertEqual(OperationType.multipleSequenceAlignmentGeneration.rawValue, "MSA Generation")
        XCTAssertEqual(OperationType.multipleSequenceAlignmentAction.rawValue, "MSA Action")
        XCTAssertEqual(OperationType.phylogeneticTreeImport.rawValue, "Tree Import")
        XCTAssertEqual(OperationType.phylogeneticTreeInference.rawValue, "Tree Inference")
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

    func testCancelSignalsCallbackAndWorkerAcknowledgesCancellation() async throws {
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        let id = center.start(
            title: "Import",
            detail: "...",
            operationType: .bamImport,
            onCancel: { cancelFlag.withLock { $0 = true } }
        )

        center.cancel(id: id)

        try await waitUntil(timeout: 2) {
            cancelFlag.withLock { $0 }
        }
        XCTAssertEqual(center.items.first(where: { $0.id == id })?.state, .cancelling)
        XCTAssertTrue(center.acknowledgeCancellation(id: id))
        let item = center.items.first { $0.id == id }
        XCTAssertEqual(item?.detail, "Cancelled by user")
        XCTAssertEqual(item?.displayStateLabel, "Cancelled")
    }

    func testCancelKeepsBundleLockUntilWorkerAcknowledgesDrain() async throws {
        let bundleURL = URL(fileURLWithPath: "/tmp/test.lungfishref")
        let callbackStarted = DispatchSemaphore(value: 0)
        let callbackMayReturn = DispatchSemaphore(value: 0)
        let callbackReturned = OSAllocatedUnfairLock(initialState: false)
        let id = center.start(
            title: "Import",
            detail: "...",
            operationType: .bamImport,
            targetBundleURL: bundleURL,
            onCancel: {
                callbackStarted.signal()
                callbackMayReturn.wait()
                callbackReturned.withLock { $0 = true }
            }
        )

        center.cancel(id: id)

        XCTAssertEqual(callbackStarted.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(center.canStartOperation(on: bundleURL))
        XCTAssertEqual(center.activeLockHolder(for: bundleURL)?.id, id)
        XCTAssertEqual(center.items.first(where: { $0.id == id })?.state, .cancelling)
        XCTAssertEqual(center.items.first(where: { $0.id == id })?.displayStateLabel, "Cancelling")

        callbackMayReturn.signal()
        try await waitUntil(timeout: 2) { callbackReturned.withLock { $0 } }
        XCTAssertFalse(center.canStartOperation(on: bundleURL))
        XCTAssertTrue(center.acknowledgeCancellation(id: id))
        XCTAssertTrue(center.canStartOperation(on: bundleURL))
        XCTAssertNil(center.activeLockHolder(for: bundleURL))
    }

    func testCancelWithoutCallbackLeavesOperationRunningAndLocked() {
        let bundleURL = URL(fileURLWithPath: "/tmp/test.lungfishref")
        let id = center.start(
            title: "Import",
            detail: "...",
            operationType: .bamImport,
            targetBundleURL: bundleURL
        )

        center.cancel(id: id)

        XCTAssertFalse(center.canStartOperation(on: bundleURL))
        XCTAssertEqual(center.activeLockHolder(for: bundleURL)?.id, id)
        XCTAssertEqual(center.items.first { $0.id == id }?.state, .running)
        XCTAssertEqual(center.items.first { $0.id == id }?.detail, "...")
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

    func testWorkerCompletionAcknowledgesCancellationWithoutPublishingLateSuccess() async throws {
        let callbackMayReturn = DispatchSemaphore(value: 0)
        let id = center.start(
            title: "BLAST",
            detail: "Running",
            operationType: .blastVerification,
            onCancel: {
                callbackMayReturn.wait()
            }
        )
        center.cancel(id: id)

        XCTAssertFalse(center.update(id: id, progress: 0.9, detail: "Late progress"))
        XCTAssertFalse(center.updateWithLog(id: id, progress: 0.95, detail: "Late logged progress"))
        XCTAssertFalse(center.complete(id: id, detail: "Late success"))
        XCTAssertFalse(center.completeWithWarning(id: id, detail: "Late warning"))
        XCTAssertFalse(center.fail(id: id, detail: "Late failure"))

        let item = center.items.first { $0.id == id }
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertEqual(item?.detail, "Cancelled by user")
        XCTAssertTrue(item?.bundleURLs.isEmpty ?? false)
        XCTAssertTrue(item?.outputURLs.isEmpty ?? false)
        XCTAssertTrue(item?.logEntries.isEmpty ?? false)

        callbackMayReturn.signal()
        try await waitUntil(timeout: 2) {
            self.center.items.first(where: { $0.id == id })?.state == .cancelled
        }
    }

    func testCancelAllCancelsAllRunning() async throws {
        let flag1 = OSAllocatedUnfairLock(initialState: false)
        let flag2 = OSAllocatedUnfairLock(initialState: false)
        let first = center.start(title: "A", detail: "", onCancel: { flag1.withLock { $0 = true } })
        let second = center.start(title: "B", detail: "", onCancel: { flag2.withLock { $0 = true } })

        center.cancelAll()

        try await waitUntil(timeout: 2) {
            flag1.withLock { $0 } && flag2.withLock { $0 }
        }
        XCTAssertEqual(center.activeCount, 2, "A signal callback is not worker drain")
        XCTAssertTrue(center.acknowledgeCancellation(id: first))
        XCTAssertTrue(center.acknowledgeCancellation(id: second))
        try await waitUntil(timeout: 2) {
            self.center.activeCount == 0
        }
    }

    func testCancelAllSkipsRunningRowsWithoutCancelCallbacks() async throws {
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        let cancellableID = center.start(title: "Cancellable", detail: "", onCancel: {
            cancelFlag.withLock { $0 = true }
        })
        let uncancellableID = center.start(title: "Uncancellable", detail: "")

        center.cancelAll()

        try await waitUntil(timeout: 2) {
            cancelFlag.withLock { $0 }
        }
        try await waitUntil(timeout: 2) {
            self.center.items.first(where: { $0.id == cancellableID })?.state == .cancelling
        }
        XCTAssertTrue(center.acknowledgeCancellation(id: cancellableID))
        XCTAssertEqual(center.items.first { $0.id == uncancellableID }?.state, .running)
        XCTAssertEqual(center.activeCount, 1)
    }

    func testCancelAllKeepsRowsCancellingUntilWorkerDrainAcknowledgments() async throws {
        let callbackCount = OSAllocatedUnfairLock(initialState: 0)
        let callbackMayReturn = DispatchSemaphore(value: 0)
        for index in 0..<3 {
            _ = center.start(title: "Slow \(index)", detail: "", onCancel: {
                callbackCount.withLock { $0 += 1 }
                callbackMayReturn.wait()
            })
        }

        let start = Date()
        center.cancelAll()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.2, "cancelAll should not wait for each operation's teardown callback")
        XCTAssertEqual(center.activeCount, 3)
        XCTAssertTrue(center.items.allSatisfy { $0.state == .cancelling })

        try await waitUntil(timeout: 2) {
            callbackCount.withLock { $0 } == 3
        }
        for _ in 0..<3 {
            callbackMayReturn.signal()
        }
        XCTAssertTrue(center.items.allSatisfy { $0.state == .cancelling })
        for id in center.items.map(\.id) { XCTAssertTrue(center.acknowledgeCancellation(id: id)) }
        try await waitUntil(timeout: 2) {
            self.center.activeCount == 0
        }
        XCTAssertTrue(center.items.allSatisfy { $0.state == .cancelled })
    }

    // MARK: - OperationCenter Typealias

    func testDownloadCenterTypealiasWorks() {
        let dc: DownloadCenter = center
        XCTAssertEqual(dc.activeCount, 0)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    // MARK: - All Operation Types

    func testAllOperationTypesExist() {
        let allTypes: [OperationType] = [
            .download, .bamImport, .vcfImport, .bundleBuild, .export,
            .assembly, .ingestion, .fastqOperation, .qualityReport,
            .taxonomyExtraction, .classification, .blastVerification, .bamPrimerTrim,
            .variantCalling, .viralRecon, .applicationExportImport,
            .multipleSequenceAlignmentImport, .multipleSequenceAlignmentGeneration,
            .multipleSequenceAlignmentAction, .phylogeneticTreeImport,
            .phylogeneticTreeInference,
        ]
        XCTAssertEqual(allTypes.count, 21, "Update this test when new OperationType cases are added")
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
        let cmd = "lungfish-cli conda classify --db standard --input /data/R1.fastq.gz"
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
            subcommand: "conda classify",
            args: ["--input", "/path with spaces/file.fastq.gz", "--db", "standard"]
        )
        XCTAssertTrue(cmd.hasPrefix("lungfish-cli conda classify"))
        XCTAssertTrue(cmd.contains("'/path with spaces/file.fastq.gz'"),
                      "Paths with spaces should be shell-quoted: \(cmd)")
    }

    func testBuildCLICommandSplitsNestedSubcommands() {
        let cmd = OperationCenter.buildCLICommand(
            subcommand: "fastq import-ont",
            args: ["/data/run", "--output", "/tmp/project"]
        )

        XCTAssertEqual(cmd, "lungfish-cli fastq import-ont /data/run --output /tmp/project")
        XCTAssertFalse(cmd.contains("'fastq import-ont'"))
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

    func testCompletedItemWithWarningLogsReportsCompletedWithWarnings() {
        let id = center.start(title: "TaxTriage", detail: "Running...")

        center.log(id: id, level: .warning, message: "21 samples failed in MINIMAP2_ALIGN and were ignored")
        center.complete(id: id, detail: "128 samples completed, 21 ignored failures")

        let item = center.items.first { $0.id == id }
        XCTAssertEqual(item?.state, .completed)
        XCTAssertTrue(item?.hasWarnings == true)
        XCTAssertEqual(item?.displayStateLabel, "Completed with Warnings")
    }

    func testRecordRetryMetadataSurfacesRetryStatusAndLog() {
        let id = center.start(title: "NCBI Fetch", detail: "Fetching...")

        center.recordRetry(
            id: id,
            attempt: 2,
            maxRetries: 5,
            statusCode: 429,
            delaySeconds: 10,
            message: "NCBI rate limit response"
        )

        let item = center.items.first { $0.id == id }
        XCTAssertEqual(item?.retryEvents.count, 1)
        XCTAssertEqual(item?.retryEvents.first?.attempt, 2)
        XCTAssertEqual(item?.retryEvents.first?.maxRetries, 5)
        XCTAssertEqual(item?.retryEvents.first?.statusCode, 429)
        XCTAssertEqual(item?.retryEvents.first?.delaySeconds, 10)
        XCTAssertEqual(item?.displayStateLabel, "Retrying")
        XCTAssertEqual(item?.detail, "Retrying after HTTP 429 (attempt 2/5, next in 10s)")
        XCTAssertTrue(item?.logEntries.contains {
            $0.level == .warning && $0.message.contains("NCBI rate limit response")
        } == true)
    }

    // MARK: - Failure Report Data Completeness

    func testFailedItemWithAllFieldsHasCompleteReportData() {
        let cmd = "lungfish-cli conda classify --db standard --input /data/R1.fastq.gz"
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
