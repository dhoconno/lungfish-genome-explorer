// RouteParityHarness+Cancel.swift - A cancel through the real transport, checked with S30's assertions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q30 M2, panel decision G1 and QA 4. The app's Cancel reaches a CLI route through
// `CLIRunCancellation`, so ToolProcess sends SIGTERM to the command's process group and tree and
// SIGKILL after `CLIProcessLauncher.operationGrace`. A case that cancels gives the harness a
// `RouteParityCancel`. `runCLI` cancels a run that way once the point is reached, and reads first
// every process the test process started since the run began. Side C' is cancelled at the same
// point as side C, and `assertCancelled` checks each cancelled side with lane S30's assertions in
// `CLISIGTERMHarness`. The command exits 125 inside the grace, its record reads cancelled and no
// process of its tree is left.

import Foundation
import LungfishCore
import LungfishKit
import LungfishTestSupport
import Synchronization
import XCTest

/// Where a case's CLI runs are cancelled, and how the record of a cancelled run is read.
public struct RouteParityCancel: Sendable {
    /// Whether the run in a side's root has reached the point to cancel at, such as a stand-in
    /// tool having written its process ID.
    public let isReached: @Sendable (URL) -> Bool
    /// The status the record of the run in a side's root holds, which S30's check reads as
    /// `cancelled`.
    public let recordStatus: @Sendable (URL) throws -> String?

    public init(
        when isReached: @escaping @Sendable (URL) -> Bool,
        record recordStatus: @escaping @Sendable (URL) throws -> String?
    ) {
        self.isReached = isReached
        self.recordStatus = recordStatus
    }
}

/// What a cancel through the real transport observed, for S30's assertions.
public struct RouteParityCancelObservation: Sendable, Equatable {
    /// The exit status, or the signal number when a signal ended the CLI, nil when nothing ran.
    public let status: Int32?
    /// The time from the cancel to the end of the run, its output drained.
    public let elapsed: Duration
    /// Every process the test process had started since the run began, read just before the
    /// cancel. That is the CLI and its tree.
    public let tree: [Int32]
}

extension RouteParityHarness {
    /// When a watch sent its cancel, and the processes it read just before.
    struct CancelSent: Sendable {
        let tree: [Int32]
        let sent: ContinuousClock.Instant
    }

    /// Whether a run has ended, set once by the task that awaited it.
    final class RunEnd: Sendable {
        private let state = Mutex(false)

        func set() { state.withLock { $0 = true } }

        var isSet: Bool { state.withLock { $0 } }
    }

    /// Cancels through `cancellation` once `isReached` holds, unless `ended` is set first or 30
    /// seconds pass, and returns the processes this test process had started since the call.
    static func cancelOnce(
        _ cancellation: CLIRunCancellation,
        when isReached: @escaping @Sendable () -> Bool,
        unless ended: RunEnd
    ) -> Task<CancelSent?, Never> {
        let before = Set(ProcessTreeTerminator.descendantProcessIDs(of: getpid()))
        return Task {
            let reached = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)) {
                ended.isSet || isReached()
            }
            guard reached, !ended.isSet else { return nil }
            let tree = ProcessTreeTerminator.descendantProcessIDs(of: getpid()).filter { !before.contains($0) }
            let sent = ContinuousClock.now
            cancellation.cancel()
            return CancelSent(tree: tree, sent: sent)
        }
    }

    /// S30's check of a side whose CLI run was cancelled through the real transport. It exited 125
    /// inside `CLIProcessLauncher.operationGrace` after the cancel, `cancel` reads its record as
    /// cancelled, and no process of its tree is left (QC-2). The end alone is not enough, since a
    /// run stopped by a signal ends Cancelled too.
    public static func assertCancelled(
        _ run: RouteParitySideRun,
        _ cancel: RouteParityCancel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard let observed = run.outcome.cancel else {
            XCTFail(
                "side \(run.side) was not cancelled through the transport, it ended \(run.outcome.end): \(run.outcome.detail)",
                file: file, line: line
            )
            return
        }
        CLISIGTERMHarness.assertCancelledExit(
            status: observed.status,
            elapsed: observed.elapsed,
            within: CLIProcessLauncher.operationGrace,
            detail: " Side \(run.side): \(run.outcome.detail)",
            file: file, line: line
        )
        CLISIGTERMHarness.assertRecordCancelled({ try cancel.recordStatus(run.root) }, file: file, line: line)
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree, file: file, line: line)
    }
}
