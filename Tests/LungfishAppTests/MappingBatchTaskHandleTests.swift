// MappingBatchTaskHandleTests.swift - Deterministic cancel/assign ordering coverage (C2 fix round 2, NEW-1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

/// Covers `MappingBatchTaskHandle`'s `cancelRequested` flag, added because
/// the production `assign(_:)`/`cancel()` entry points are both
/// `nonisolated` and hop onto the actor via their own unordered
/// `Task { await ... }` -- with no `cancelRequested` flag, a `cancel()`
/// that wins that race while `assign(_:)`'s hop is still pending would find
/// `task == nil` and silently do nothing: the `OperationCenter` row would
/// show "Cancelled by user" while the mapper kept running underneath.
///
/// These tests drive the actor-isolated `setTask`/`cancelStoredTask`
/// methods directly with plain sequential `await`s (NOT the racy
/// `nonisolated assign`/`cancel` wrappers), so the cancel-before-assign
/// ordering is deterministic rather than dependent on which of two
/// independently-scheduled `Task { await ... }` hops happens to run first.
final class MappingBatchTaskHandleTests: XCTestCase {
    /// Tiny actor to observe a `Task<Void, Never>`'s cancellation state
    /// from inside its own body without capturing a non-Sendable mutable
    /// local across the closure boundary.
    private actor CancellationObserver {
        private(set) var wasCancelled = false
        func markObserved(_ cancelled: Bool) { wasCancelled = cancelled }
    }

    func testCancelBeforeAssignCancelsTheTaskImmediatelyOnAssignment() async {
        let handle = MappingBatchTaskHandle()
        let observer = CancellationObserver()

        // Cancel arrives FIRST, while no task has been assigned yet -- the
        // exact race the reviewer flagged (opID/cancel button wired before
        // the batch Task literal finishes constructing and being assigned).
        await handle.cancelStoredTask()
        let cancelRequestedBeforeAssign = await handle.currentlyHasCancelRequested()
        XCTAssertTrue(cancelRequestedBeforeAssign)

        let task = Task<Void, Never> {
            // Give the runtime a chance to observe cancellation if it were
            // (incorrectly) never requested.
            try? await Task.sleep(nanoseconds: 1_000_000)
            await observer.markObserved(Task.isCancelled)
        }

        // assign() lands AFTER cancel() -- setTask must see cancelRequested
        // already true and cancel the incoming task immediately rather than
        // silently storing an un-cancelled task.
        await handle.setTask(task)

        _ = await task.value
        let sawCancellation = await observer.wasCancelled
        XCTAssertTrue(sawCancellation, "Task assigned after cancel() must be cancelled immediately, not silently kept running")
        XCTAssertTrue(task.isCancelled)

        // setTask's early-return path cancels the incoming task without
        // storing it (there is nothing further to cancel later, since it's
        // already cancelled) -- `task` itself is the source of truth here.
        let stored = await handle.currentlyAssignedTask()
        XCTAssertNil(stored, "setTask's cancelRequested fast path returns before storing self.task")
    }

    func testAssignBeforeCancelCancelsTheStoredTask() async {
        let handle = MappingBatchTaskHandle()
        let observer = CancellationObserver()

        let task = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000)
            await observer.markObserved(Task.isCancelled)
        }

        // Normal ordering: assign lands first, cancel second.
        await handle.setTask(task)
        XCTAssertFalse(task.isCancelled)

        await handle.cancelStoredTask()

        _ = await task.value
        let sawCancellation = await observer.wasCancelled
        XCTAssertTrue(sawCancellation)
        XCTAssertTrue(task.isCancelled)
    }

    func testCancelRequestedFlagPersistsAcrossMultipleAssignments() async {
        let handle = MappingBatchTaskHandle()

        await handle.cancelStoredTask()

        // Simulates the sequential-loop shape in runManagedMapping: each
        // bundle's request re-registers a cancel callback against the SAME
        // handle. Once cancelRequested is true, every subsequent
        // assignment must be cancelled immediately too -- the flag is not
        // a one-shot latch that only catches the first race.
        for _ in 0..<3 {
            let task = Task<Void, Never> {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            await handle.setTask(task)
            XCTAssertTrue(task.isCancelled)
            _ = await task.value
        }
    }

    func testNoCancelRequestedLeavesFreshTaskUncancelled() async {
        let handle = MappingBatchTaskHandle()

        let task = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await handle.setTask(task)

        XCTAssertFalse(task.isCancelled)
        let cancelRequested = await handle.currentlyHasCancelRequested()
        XCTAssertFalse(cancelRequested)

        task.cancel()
        _ = await task.value
    }

    /// End-to-end via the PRODUCTION (racy) `nonisolated` entry points,
    /// run enough times to make an ordering bug flaky-visible even though
    /// a single run can't guarantee which hop lands first. The
    /// deterministic tests above are the actual regression coverage; this
    /// is a best-effort smoke check that `assign`/`cancel` compose
    /// correctly with the actor-isolated methods they wrap.
    func testProductionAssignAndCancelEntryPointsAgreeRegardlessOfCallOrder() async {
        for _ in 0..<20 {
            let handle = MappingBatchTaskHandle()
            let observer = CancellationObserver()
            let task = Task<Void, Never> {
                try? await Task.sleep(nanoseconds: 2_000_000)
                await observer.markObserved(Task.isCancelled)
            }

            handle.cancel()
            handle.assign(task)

            _ = await task.value
            // Poll briefly for the actor hops to settle before asserting --
            // both nonisolated calls fire their own detached Task{}, so
            // there's no synchronous guarantee they've landed the instant
            // `assign`/`cancel` return.
            var cancelled = task.isCancelled
            for _ in 0..<10_000 where !cancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
                cancelled = task.isCancelled
            }
            XCTAssertTrue(cancelled, "cancel() called before assign() must still cancel the task once assigned")
        }
    }
}
