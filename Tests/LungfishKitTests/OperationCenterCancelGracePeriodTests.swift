// OperationCenterCancelGracePeriodTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishKit

/// NEW-08: live GUI testing found a cancelled EsViritu operation stayed in
/// OperationCenter's active list indefinitely (40+ minutes, still shown as
/// running in the quit warning) even though its tool processes were gone.
///
/// The orchestrator's follow-up investigation (a `sample` of the live debug
/// build) found the real root cause: the worker was blocked inside a
/// pre-tool stage on an uninterruptible kernel call (a TCC-gated directory
/// open under `~/Desktop` that a mismatched ad-hoc code-signature never
/// resolves) that never observes `Task.isCancelled` and never returns. That
/// specific block is environmental/design (tracked separately as NEW-11) and
/// is not fixable here. What IS in scope, and what these tests cover: when a
/// worker never returns after `cancel(id:)` signals it, `OperationCenter`
/// itself must still move the operation to a terminal `.cancelled` state and
/// release its bundle lock within a bounded time, and a worker that only
/// returns later (or never) must not resurrect or double-complete the
/// operation.
@MainActor
final class OperationCenterCancelGracePeriodTests: XCTestCase {
    private var center: OperationCenter!

    override func setUp() {
        super.setUp()
        center = OperationCenter()
        // Tests use a short grace period so this suite stays fast; production
        // uses OperationCenter's own default.
        center.cancelGracePeriod = 0.1
    }

    override func tearDown() {
        center = nil
        super.tearDown()
    }

    /// Simulates a worker whose pre-tool stage blocks forever on a semaphore
    /// that is only signalled at test teardown -- standing in for the live
    /// bug's uninterruptible `openat` -- and asserts `cancel(id:)` still
    /// drives the operation to `.cancelled` (not left `.cancelling`/active)
    /// within a bounded time, well under the semaphore's release.
    func testCancelForcesTerminalStateWhenWorkerNeverReturns() async throws {
        let neverSignalled = DispatchSemaphore(value: 0)
        defer { neverSignalled.signal() } // release the parked thread so it can exit

        let id = center.start(
            title: "Stuck EsViritu op",
            detail: "Loading first 1,000 FASTQ reads as FASTA...",
            operationType: .classification,
            onCancel: {
                // Real cancel callbacks (task.cancel(), process-tree
                // termination) return promptly. This one models a worker
                // whose *cooperative* cancellation point is never reached
                // because it is parked in an uninterruptible system call --
                // it never calls back into OperationCenter at all.
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = neverSignalled.wait(timeout: .now() + 30)
                }
            }
        )

        center.cancel(id: id)
        XCTAssertEqual(center.items.first(where: { $0.id == id })?.state, .cancelling)

        let deadline = Date().addingTimeInterval(5)
        while center.items.first(where: { $0.id == id })?.state == .cancelling, Date() < deadline {
            let expectation = XCTestExpectation(description: "poll tick")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { expectation.fulfill() }
            await fulfillment(of: [expectation], timeout: 1)
        }

        let finalState = center.items.first(where: { $0.id == id })?.state
        XCTAssertEqual(finalState, .cancelled, "a worker that never returns must not leave the operation active forever")
        XCTAssertFalse(center.activeItems.contains { $0.id == id })
    }

    /// Same stuck-worker scenario, but the operation also holds a bundle
    /// lock. The forced cancellation must release it so a later operation on
    /// the same bundle is not refused forever because of a worker that will
    /// never call a terminal method.
    func testCancelReleasesBundleLockWhenWorkerNeverReturns() async throws {
        let neverSignalled = DispatchSemaphore(value: 0)
        defer { neverSignalled.signal() }

        let bundleURL = URL(fileURLWithPath: "/tmp/OperationCenterCancelGracePeriodTests-\(UUID().uuidString).lungfishfastq")

        guard case .started(let id) = center.begin(
            title: "Stuck EsViritu op",
            detail: "running",
            operationType: .classification,
            targetBundleURL: bundleURL,
            onCancel: {
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = neverSignalled.wait(timeout: .now() + 30)
                }
            }
        ) else {
            XCTFail("expected the first operation on an unlocked bundle to start")
            return
        }

        XCTAssertFalse(center.canStartOperation(on: bundleURL), "the bundle must be locked while the operation runs")

        center.cancel(id: id)

        let deadline = Date().addingTimeInterval(5)
        while !center.canStartOperation(on: bundleURL), Date() < deadline {
            let expectation = XCTestExpectation(description: "poll tick")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { expectation.fulfill() }
            await fulfillment(of: [expectation], timeout: 1)
        }

        XCTAssertTrue(center.canStartOperation(on: bundleURL), "a stuck worker must not hold the bundle lock forever")
        XCTAssertEqual(center.items.first(where: { $0.id == id })?.state, .cancelled)
    }

    /// A worker that does eventually return -- just after the grace period
    /// already forced the operation to `.cancelled` -- must not resurrect it
    /// or overwrite the cancelled outcome by completing/failing late.
    func testLateWorkerCompletionAfterForcedCancellationIsANoOp() async throws {
        let id = center.start(
            title: "Slow-to-return op",
            detail: "running",
            operationType: .classification,
            onCancel: { /* signals promptly, but the caller below simulates a slow return */ }
        )

        center.cancel(id: id)

        let deadline = Date().addingTimeInterval(5)
        while center.items.first(where: { $0.id == id })?.state != .cancelled, Date() < deadline {
            let expectation = XCTestExpectation(description: "poll tick")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { expectation.fulfill() }
            await fulfillment(of: [expectation], timeout: 1)
        }
        XCTAssertEqual(center.items.first(where: { $0.id == id })?.state, .cancelled)
        XCTAssertTrue(
            center.items.first(where: { $0.id == id })?.logEntries.contains {
                $0.message.contains("did not respond to cancellation")
            } ?? false,
            "the forced cancellation must be recorded in the operation's log history"
        )

        // The worker "returns late" here, well after the forced cancellation.
        let completedLate = center.complete(id: id, detail: "finished after all")
        XCTAssertFalse(completedLate, "a late completion must not resurrect an already-cancelled operation")
        XCTAssertEqual(center.items.first(where: { $0.id == id })?.state, .cancelled)
        XCTAssertEqual(center.items.first(where: { $0.id == id })?.detail, "Cancelled by user")

        let failedLate = center.fail(id: id, detail: "or maybe it failed late")
        XCTAssertFalse(failedLate, "a late failure must not overwrite an already-cancelled operation")
        XCTAssertEqual(center.items.first(where: { $0.id == id })?.state, .cancelled)
    }

    /// Sanity check on the non-stuck path: a worker that returns well within
    /// the grace period completes normally and the grace-period timer's
    /// later fire must be a no-op (it must not race a legitimately completed
    /// operation back into `.cancelled`).
    func testWorkerThatReturnsWithinGracePeriodCompletesNormally() async throws {
        center.cancelGracePeriod = 0.3
        let id = center.start(
            title: "Responsive op",
            detail: "running",
            operationType: .classification,
            onCancel: {}
        )

        center.cancel(id: id)
        // OperationCenter's pre-existing cancellation-wins rule in
        // finishWorker means a `complete` call after `cancel` still lands as
        // `.cancelled`, not `.completed` (the false return reflects that the
        // requested `.completed` state lost to the pending cancellation, not
        // that the call was rejected outright as it would be for a fully
        // terminal operation -- that no-op case is covered by the "late
        // worker" test above).
        XCTAssertFalse(center.complete(id: id, detail: "done"))
        XCTAssertEqual(center.items.first(where: { $0.id == id })?.state, .cancelled, "OperationCenter's existing cancellation-wins rule still applies")

        // Let the grace-period timer fire; it must not change anything further
        // (no double-log, no state flip) now that the operation is already terminal.
        let expectation = XCTestExpectation(description: "grace period elapses")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 2)

        XCTAssertEqual(center.items.first(where: { $0.id == id })?.state, .cancelled)
        XCTAssertEqual(center.items.first(where: { $0.id == id })?.detail, "Cancelled by user")
    }
}
