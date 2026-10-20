// ToolPipelineRun.swift - startPipeline and the one handle on a running pipeline
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ToolProcess {
    /// Starts stages connected stdout to stdin on the calling thread and
    /// returns the handle on them without waiting for them to end, as
    /// ``start(_:onEvent:onLaunch:)`` does for one process.
    ///
    /// The stage rules, the limits, the failure policy and every guarantee
    /// are those of ``runPipeline(_:timeout:idleTimeout:failurePolicy:onEvent:onLaunch:)``,
    /// so a cancel or a limit terminates every running stage, and under
    /// ``ToolPipelineFailurePolicy/stopAllOnFailure`` a failing stage stops
    /// the others. Two ends can stream here and nowhere else in a pipeline.
    /// The first stage's stdin can be ``ToolProcessInput/stream``, written
    /// through ``ToolPipelineRun/stdin``, and the last stage's stdout can be
    /// ``ToolProcessOutput/stream``, read raw through
    /// ``ToolPipelineRun/stdout``. Every stage is spawned before this
    /// returns, and everything after runs on GCD with no Swift task. A stage
    /// that cannot launch is not thrown here. It is the error of
    /// ``ToolPipelineRun/waitBlocking()`` and ``ToolPipelineRun/result()``.
    ///
    /// - Parameters:
    ///   - stages: The stages in order. At least one.
    ///   - timeout: Wall-clock limit for the whole pipeline.
    ///   - idleTimeout: Limit on the time with no output on any captured
    ///     stream of any stage and with no bytes taken by the reader of a
    ///     streamed last stdout.
    ///   - failurePolicy: What a failing stage does to the others.
    ///   - onEvent: Receives each stage's index with its events, one event at
    ///     a time, before the run's result is available.
    ///   - onLaunch: Receives each stage's index and pid synchronously, on
    ///     the calling thread, right after its spawn succeeds.
    /// - Throws: ``ToolProcessError/invalidSpec(_:)`` only. Nothing was launched.
    public static func startPipeline(
        _ stages: [ToolProcessSpec],
        timeout: Duration? = nil,
        idleTimeout: Duration? = nil,
        failurePolicy: ToolPipelineFailurePolicy = .stopAllOnFailure,
        onEvent: (@Sendable (_ stage: Int, _ event: ToolProcessEvent) -> Void)? = nil,
        onLaunch: (@Sendable (_ stage: Int, _ pid: Int32) -> Void)? = nil
    ) throws(ToolProcessError) -> ToolPipelineRun {
        let execution = try pipelineExecution(
            stages,
            limits: (timeout, idleTimeout),
            observers: .init(failurePolicy: failurePolicy, onLaunch: onLaunch, onEvent: onEvent),
            refusingStreamsIn: nil
        )
        let run = ToolPipelineRun(execution)
        run.begin()
        return run
    }
}

/// The one handle on a pipeline started by
/// ``ToolProcess/startPipeline(_:timeout:idleTimeout:failurePolicy:onEvent:onLaunch:)``.
///
/// It works as ``ToolProcessRun`` does for one process. Write the first
/// stage's stdin through ``stdin`` and close it, read the last stage's
/// stdout through ``stdout`` to end of file, cancel from any thread, and
/// wait with ``waitBlocking()`` or ``result()``. The engine keeps itself
/// alive until the run is over, so dropping the handle never leaves a stage
/// unreaped or registered. Once the handle and every reference to its
/// streams are gone, both close, so the first stage gets end of file and a
/// last stage still writing gets SIGPIPE.
public final class ToolPipelineRun: Sendable {
    /// The first stage's standard input when its spec sets
    /// ``ToolProcessInput/stream``, and closed from the start otherwise.
    public let stdin: ToolProcessInputStream
    /// The last stage's standard output when its spec sets
    /// ``ToolProcessOutput/stream``, and at end of file at once otherwise.
    public let stdout: ToolProcessOutputStream

    private let waiter: ToolProcessRunWaiter

    init(_ execution: ToolProcessExecution) {
        self.waiter = ToolProcessRunWaiter(execution)
        self.stdout = ToolProcessOutputStream(execution.stdoutChannel)
        self.stdin = ToolProcessInputStream(execution.stdinChannel)
    }

    /// Each stage's process ID in stage order, set before
    /// ``ToolProcess/startPipeline(_:timeout:idleTimeout:failurePolicy:onEvent:onLaunch:)``
    /// returns, and nil for a stage that did not launch.
    public var pids: [Int32?] {
        waiter.pids
    }

    func begin() {
        waiter.begin()
    }

    /// Stops the pipeline. ToolProcess terminates every stage's process
    /// group and tree, a blocked reader of ``stdout`` reaches end of file, a
    /// write to ``stdin`` still waiting returns, and the result is
    /// ``ToolProcessError/cancelled(results:)``. Does nothing once the run
    /// is over.
    public func cancel() {
        waiter.cancel()
    }

    /// Waits on the calling thread until every stage is over, closes
    /// ``stdout`` and returns the result. Never call it on the main thread,
    /// and read ``stdout`` to end of file and close ``stdin``, or cancel the
    /// run, first. Safe to call more than once.
    ///
    /// - Throws: ``ToolProcessError``.
    public func waitBlocking() throws(ToolProcessError) -> ToolPipelineResult {
        try waiter.waitBlocking(closing: stdout).get()
    }

    /// Suspends until every stage is over, closes ``stdout`` and returns the
    /// result. Cancelling the waiting task cancels the run, as it does for
    /// ``ToolProcess/runPipeline(_:timeout:idleTimeout:failurePolicy:onEvent:onLaunch:)``.
    /// Read ``stdout`` to end of file and close ``stdin``, or cancel the run,
    /// first. Safe to call more than once.
    ///
    /// - Throws: ``ToolProcessError``.
    public func result() async throws(ToolProcessError) -> ToolPipelineResult {
        try await waiter.result(closing: stdout).get()
    }
}
