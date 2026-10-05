// CLIImportProcessBox.swift - The running lungfish-cli import process, its cancel and its exit
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import LungfishWorkflow

/// A thread-safe box holding the currently running CLI process.
///
/// `cancel()` must be able to terminate the process tree without waiting for
/// actor access on ``CLIImportRunner``. If cancellation went through the
/// actor, a synchronous, non-suspending wait for process exit inside `run()`
/// (see the historical `proc.waitUntilExit()` call) would occupy the actor's
/// executor for the process's entire lifetime, and `cancel()` could never
/// run concurrently — the actor would deadlock against itself. Termination
/// is therefore driven from this plain, lock-protected box instead.
///
/// The box also remembers a cancel that arrives before the process is
/// launched, so the process is then never launched.
final class CLIImportProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    /// Launches `process` unless a cancel came first.
    ///
    /// The cancel check and the launch happen under one lock, so a cancel
    /// either stops the launch or finds the process running and stops it.
    ///
    /// - Returns: `false` when a cancel came first and nothing was launched.
    func launch(_ process: Process) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        try process.run()
        self.process = process
        return true
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    /// Records the cancel and stops the running process tree, if any.
    /// Safe to call from any thread, any number of times. Returns at once.
    /// The stop runs on a background queue so the caller, often the main
    /// thread, never waits out the cleanup grace period.
    func cancel(cleanupGrace: TimeInterval) {
        lock.lock()
        cancelled = true
        let current = process
        lock.unlock()
        guard let current else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            Self.stop(current, cleanupGrace: cleanupGrace)
        }
    }

    /// Asks the tree to stop with SIGTERM, gives `lungfish-cli` up to
    /// `cleanupGrace` to remove its staging folders and exit, then kills
    /// whatever is left.
    ///
    /// `lungfish-cli import fastq` turns SIGTERM into a cancel that runs its
    /// cleanup. A tool that ignores SIGTERM and outlives the CLI is killed as
    /// soon as the CLI exits.
    private static func stop(_ process: Process, cleanupGrace: TimeInterval) {
        let rootPID = process.processIdentifier
        guard rootPID > 0, process.isRunning else { return }
        let descendants = ProcessTreeTerminator.descendantProcessIDs(of: rootPID)
        for pid in descendants.reversed() {
            kill(pid, SIGTERM)
        }
        kill(rootPID, SIGTERM)

        let deadline = Date().addingTimeInterval(cleanupGrace)
        while process.isRunning, Date() < deadline {
            usleep(25_000)
        }
        if process.isRunning {
            ProcessTreeTerminator.terminate(rootProcess: process, gracePeriod: 0.5)
        }
        // Tools that ignored SIGTERM are now orphans, so they are not in the
        // root's tree any more. Their PIDs are still theirs while they live.
        for pid in descendants where kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }
}

/// Resumes exactly once with the process's exit status, driven by
/// `Process.terminationHandler` rather than a blocking `waitUntilExit()`
/// call, so nothing that awaits it can occupy an actor's executor.
final class CLIImportExitCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Never>?
    private var exitStatus: Int32?

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                continuation.resume(returning: exitStatus)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func complete(exitStatus: Int32) {
        let continuationToResume: CheckedContinuation<Int32, Never>?
        lock.lock()
        if self.exitStatus != nil {
            continuationToResume = nil
        } else {
            self.exitStatus = exitStatus
            continuationToResume = continuation
            continuation = nil
        }
        lock.unlock()
        continuationToResume?.resume(returning: exitStatus)
    }
}
