// NextflowEngineHooks.swift - What a Nextflow engine calls while a run is live, progress and container cleanup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import Synchronization

/// What the engine calls while a run is live, always off the main actor.
package struct NextflowEngineHooks: Sendable {
    /// Receives each stdout line and each new trace reading (W1, W2).
    package var progress: (any NextflowProgressReporting)?
    /// Stops a cancelled run's task containers once the host tree is gone (N5).
    package var cleanup: (any NextflowContainerCleanup)?

    package init(progress: (any NextflowProgressReporting)? = nil, cleanup: (any NextflowContainerCleanup)? = nil) {
        self.progress = progress
        self.cleanup = cleanup
    }
}

/// Receives each stdout line once it has reached the log, and each new reading of `trace.txt`
/// (W1, W2). The engine calls it from its own tasks, one stdout line at a time and in order, and a
/// reading only when it differs from the one before. Both return promptly, since the engine reads no
/// output while a line is with the receiver.
package protocol NextflowProgressReporting: Sendable {
    func engineLine(_ line: String)
    func traceProgress(_ progress: NextflowTraceProgress)
}

/// The completed rows of `trace.txt` so far, with the last one's `name` column, `PROCESS (tag)`.
package struct NextflowTraceProgress: Sendable, Equatable {
    package let completedTasks: Int
    package let lastCompletedName: String?

    package init(completedTasks: Int, lastCompletedName: String?) {
        self.completedTasks = completedTasks
        self.lastCompletedName = lastCompletedName
    }

    /// The reading of the trace file at `url`, or nil when it cannot be read or has no header yet.
    package init?(traceFileAt url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(traceText: String(decoding: data, as: UTF8.self))
    }

    /// The reading of a trace file's text, by the columns its header names.
    ///
    /// Nextflow writes a row once a task ends. A row counts once its line has ended, so a row still
    /// being written waits for the next reading. COMPLETED and CACHED rows count and FAILED or ABORTED
    /// rows do not, so a task that failed and ran again counts once. Nil when the text has no ended
    /// header line with `name` and `status` columns.
    package init?(traceText text: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // The piece after the last line break is empty for a finished file, or a row being written.
        lines.removeLast()
        guard let header = lines.first else { return nil }
        let columns = header.split(separator: "\t", omittingEmptySubsequences: false)
        guard let nameColumn = columns.firstIndex(of: "name"),
              let statusColumn = columns.firstIndex(of: "status") else { return nil }
        var completedTasks = 0
        var lastCompletedName: String?
        for row in lines.dropFirst() {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.indices.contains(nameColumn), fields.indices.contains(statusColumn) else { continue }
            switch fields[statusColumn] {
            case "COMPLETED", "CACHED":
                completedTasks += 1
                lastCompletedName = String(fields[nameColumn])
            default:
                continue
            }
        }
        self.init(completedTasks: completedTasks, lastCompletedName: lastCompletedName)
    }
}

/// Stops a cancelled run's task containers after the host tree is gone, never past `bound` (N5).
/// ``NextflowDockerContainerCleanup`` implements it for a docker run, by the containers' mounts of its work folder.
package protocol NextflowContainerCleanup: Sendable {
    func stopContainers(boundTo workDirectory: URL, within bound: Duration) async
}

extension NextflowEngineProcess {
    /// Calls the cleanup and returns once it has ended or `bound` has passed, whichever is first (N5).
    ///
    /// The calling task is cancelled, and a cancelled task launches no process, so the cleanup runs in
    /// a new unstructured task, which starts uncancelled and keeps the caller's task-local values
    /// except the provenance observer, which it unbinds. A cleanup still running at the bound is
    /// cancelled and left to end on its own.
    static func stopContainers(
        with cleanup: any NextflowContainerCleanup,
        boundTo workDirectory: URL,
        within bound: Duration
    ) async {
        let ended = NextflowOneShotSignal()
        let work = Task {
            // A plain task starts uncancelled and keeps the caller's task-local seams, such as a test's
            // probe. Only the provenance observer is unbound, so no docker command becomes a step.
            await ToolProcessObservation.$observer.withValue(nil) {
                await cleanup.stopContainers(boundTo: workDirectory, within: bound)
            }
            ended.fire()
        }
        let timer = Task {
            try? await Task.sleep(for: bound)
            ended.fire()
        }
        await ended.wait()
        timer.cancel()
        work.cancel()
    }
}

/// A signal that fires once and wakes its one waiter, whether the waiter came first or not.
final class NextflowOneShotSignal: Sendable {
    private enum State {
        case waiting(CheckedContinuation<Void, Never>?)
        case fired
    }

    private let state = Mutex(State.waiting(nil))

    func fire() {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { state in
            guard case .waiting(let waiter) = state else { return nil }
            state = .fired
            return waiter
        }
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let firedAlready: Bool = state.withLock { state in
                guard case .waiting = state else { return true }
                state = .waiting(continuation)
                return false
            }
            if firedAlready {
                continuation.resume()
            }
        }
    }
}
