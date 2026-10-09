// CLIRunCancellation.swift - Runs lungfish-cli on ToolProcess and lets any thread cancel the run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import Synchronization

/// Runs one `lungfish-cli` process on ``ToolProcess`` and lets a caller on any
/// thread cancel it, before the launch, during the run or never.
///
/// Every `CLI*Runner` of the app and ``CLISubprocessTransport`` have a
/// `nonisolated cancel()` that must return at once and must never wait behind
/// the actor that runs the process. This type is the shared half of that
/// contract. It keeps the ``ToolProcessRun`` handle of the running CLI, and
/// ``cancel()`` only records the request and calls ``ToolProcessRun/cancel()``,
/// so ToolProcess stops the process group and its descendants. The spec's
/// `terminationGracePeriod` sets how long the CLI has between SIGTERM and
/// SIGKILL for its own cleanup. A cancel that arrives before
/// ``run(_:onEvent:)`` makes that call launch nothing.
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

    private struct State {
        var requested = false
        var run: ToolProcessRun?
    }

    private let state = Mutex(State())

    public init() {}

    /// Asks the running process tree to stop. Safe from any thread, any
    /// number of times, and never waits for the process.
    public func cancel() {
        let run = state.withLock { state -> ToolProcessRun? in
            state.requested = true
            return state.run
        }
        run?.cancel()
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
    ///   - spec: What to run.
    ///   - onEvent: Receives each captured output line, one at a time, before
    ///     this method returns.
    public func run(
        _ spec: ToolProcessSpec,
        onEvent: (@Sendable (ToolProcessEvent) -> Void)? = nil
    ) async -> Outcome {
        defer {
            state.withLock { state in
                state.requested = false
                state.run = nil
            }
        }
        if Task.isCancelled {
            state.withLock { $0.requested = true }
        }
        if state.withLock({ $0.requested }) {
            return Outcome(result: .failure(.cancelled(results: [])), cancelRequested: true)
        }

        let run: ToolProcessRun
        do throws(ToolProcessError) {
            run = try ToolProcess.start(spec, onEvent: onEvent)
        } catch {
            return Outcome(result: .failure(error), cancelRequested: isCancelled)
        }
        // A cancel that came between the check above and this point found no
        // run to stop, so it is acted on here.
        let cancelledMeanwhile = state.withLock { state -> Bool in
            state.run = run
            return state.requested
        }
        if cancelledMeanwhile { run.cancel() }

        let result: Result<ToolProcessResult, ToolProcessError> = await withTaskCancellationHandler {
            do throws(ToolProcessError) {
                return .success(try await run.result())
            } catch {
                return .failure(error)
            }
        } onCancel: {
            self.cancel()
        }
        return Outcome(result: result, cancelRequested: isCancelled)
    }
}
