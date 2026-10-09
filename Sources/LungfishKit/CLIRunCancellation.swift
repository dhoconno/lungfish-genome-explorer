// CLIRunCancellation.swift - Runs lungfish-cli on ToolProcess and lets any thread cancel the run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import Synchronization

/// Runs one `lungfish-cli` process on ``ToolProcess`` and lets a caller on any
/// thread cancel it, before the launch, during the run or never.
///
/// Every `CLI*Runner` of the app and ``CLISubprocessTransport`` have a
/// `nonisolated cancel()` that must return at once and must never wait behind
/// the actor that runs the process. This type is the shared half of that
/// contract. ``cancel()`` only records the request and acts on the task that
/// runs the process, and ToolProcess then stops the process group and its
/// descendants. A cancel that arrives before ``run(_:onEvent:)`` makes that
/// call cancel its task at once, so ToolProcess launches nothing.
///
/// With a `cleanupGrace`, a cancel during the run first sends SIGTERM to the
/// CLI and its descendants and gives the CLI that long to clean up and exit,
/// as `import fastq` does to remove its staging folders. Only a CLI still
/// running then is cancelled through ToolProcess, which kills the tree at
/// once. Descendants that ignored the SIGTERM and outlive the CLI are killed
/// when the run ends. A ToolProcess `terminationGracePeriod` could not do
/// this, because it would also delay the stop of a descendant that holds the
/// output open after the CLI has exited.
///
/// The request is cleared when ``run(_:onEvent:)`` returns, so one instance
/// serves one run at a time.
public final class CLIRunCancellation: Sendable {
    /// How a run ended, with whether a cancel was asked for during or before it.
    public struct Outcome: Sendable {
        /// The result of the process, or the reason ToolProcess produced none.
        public let result: Result<ToolProcessResult, ToolProcessError>
        /// True when ``CLIRunCancellation/cancel()`` was called, or the
        /// calling task was cancelled, since the last run ended.
        public let cancelRequested: Bool
    }

    private typealias RunTask = Task<Result<ToolProcessResult, ToolProcessError>, Never>

    private struct State {
        var requested = false
        var task: RunTask?
        var pid: Int32?
        /// Descendants that were sent SIGTERM and may have ignored it.
        var signaledDescendants: [Int32] = []
    }

    private let cleanupGrace: Duration
    private let state = Mutex(State())

    /// - Parameter cleanupGrace: How long a CLI that was sent SIGTERM has to
    ///   exit before the whole tree is killed. Zero kills it at once.
    public init(cleanupGrace: Duration = .zero) {
        self.cleanupGrace = cleanupGrace
    }

    /// Asks the running process tree to stop. Safe from any thread, any
    /// number of times, and never waits for the process.
    public func cancel() {
        enum Step {
            case nothingRunning
            case cancelNow(RunTask)
            case signalThenCancel(RunTask, pid: Int32)
        }
        let step = state.withLock { state -> Step in
            state.requested = true
            guard let task = state.task else { return .nothingRunning }
            guard cleanupGrace > .zero, let pid = state.pid else { return .cancelNow(task) }
            return .signalThenCancel(task, pid: pid)
        }
        switch step {
        case .nothingRunning:
            break
        case .cancelNow(let task):
            task.cancel()
        case .signalThenCancel(let task, let pid):
            let grace = cleanupGrace
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                // The tree is read before SIGTERM, because a CLI that exits at
                // once leaves its children to a new parent.
                let descendants = ProcessTreeTerminator.descendantProcessIDs(of: pid)
                state.withLock { $0.signaledDescendants = descendants }
                for descendant in descendants.reversed() {
                    kill(descendant, SIGTERM)
                }
                kill(pid, SIGTERM)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.interval(grace)) {
                    task.cancel()
                }
            }
        }
    }

    /// True while a cancel has been asked for and no run has ended since.
    public var isCancelled: Bool {
        state.withLock { $0.requested }
    }

    /// Runs `spec` and returns once the process has ended and its output is
    /// drained.
    ///
    /// Cancelling the calling task counts as ``cancel()``, so a caller that
    /// cancels its task stops the process tree too.
    ///
    /// - Parameters:
    ///   - spec: What to run. Its `terminationGracePeriod` applies only to a
    ///     stop ToolProcess makes itself, so a cancel with a `cleanupGrace`
    ///     leaves it at zero.
    ///   - onEvent: Receives each captured output line, one at a time, before
    ///     this method returns.
    public func run(
        _ spec: ToolProcessSpec,
        onEvent: (@Sendable (ToolProcessEvent) -> Void)? = nil
    ) async -> Outcome {
        let task = RunTask.detached(priority: Task.currentPriority) { [self] in
            do throws(ToolProcessError) {
                return .success(try await ToolProcess.run(spec, onEvent: onEvent, onLaunch: { pid in
                    self.state.withLock { $0.pid = pid }
                }))
            } catch {
                return .failure(error)
            }
        }
        let alreadyRequested = state.withLock { state -> Bool in
            state.task = task
            return state.requested
        }
        if alreadyRequested { task.cancel() }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            self.cancel()
        }
        let (requested, leftovers) = state.withLock { state -> (Bool, [Int32]) in
            defer {
                state.requested = false
                state.task = nil
                state.pid = nil
                state.signaledDescendants = []
            }
            return (state.requested, state.signaledDescendants)
        }
        // A descendant that ignored the SIGTERM would otherwise be left running.
        for pid in leftovers where kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
        return Outcome(result: result, cancelRequested: requested)
    }

    private static func interval(_ duration: Duration) -> DispatchTimeInterval {
        let parts = duration.components
        let milliseconds = parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
        return .milliseconds(Int(min(milliseconds, Int64(Int32.max))))
    }
}

extension ToolProcessError {
    /// Why the process could not run, for a "failed to launch" message.
    public var cliLaunchFailureReason: String {
        if case .launchFailed(_, let reason, _) = self { return reason }
        return localizedDescription
    }
}

extension ToolProcessResult {
    /// Says why this result's output cannot be trusted, or nil when it is
    /// complete. A run that ToolProcess stopped on purpose is cut short by
    /// design and reports nothing here.
    public var cliIncompleteOutputNote: String? {
        guard stop == nil else { return nil }
        if outputDrainTimedOut {
            return "The output of lungfish-cli is incomplete because a child process kept it open after lungfish-cli exited. The child process was stopped."
        }
        if outputReadFailed {
            return "The output of lungfish-cli is incomplete because reading it failed."
        }
        return nil
    }

    /// Standard error as the CLI runners have always decoded it.
    public var cliStderrText: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }

    /// Standard output as the CLI runners have always decoded it.
    public var cliStdoutText: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }
}
