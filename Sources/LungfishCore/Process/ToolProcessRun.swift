// ToolProcessRun.swift - The one handle on a running ToolProcess process, and runBlocking
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

extension ToolProcess {
    /// Starts one process on the calling thread and returns the handle on
    /// it without waiting for it to end. ``run(_:onEvent:onLaunch:)`` and
    /// ``runBlocking(_:cancellation:onEvent:onLaunch:)`` are this plus a wait.
    ///
    /// The spawn happens before this returns, so ``ToolProcessRun/pid`` is
    /// already set, and everything after it runs on GCD, so the run needs no
    /// Swift task to start, progress or finish. A spec whose stdout is
    /// ``ToolProcessOutput/stream`` is read through ``ToolProcessRun/stdout``.
    /// Every other disposition behaves as in `run`. A launch failure is not
    /// thrown here. The pid is then nil, and the failure is the error of
    /// ``ToolProcessRun/waitBlocking()`` and ``ToolProcessRun/result()``.
    ///
    /// - Parameters:
    ///   - spec: What to run and how.
    ///   - onEvent: Receives the launch and every captured output line, one
    ///     event at a time, before the run's result is available.
    ///   - onLaunch: Receives the pid synchronously, on the calling thread,
    ///     right after the spawn succeeds.
    /// - Throws: ``ToolProcessError/invalidSpec(_:)`` only. Nothing was launched.
    public static func start(
        _ spec: ToolProcessSpec,
        onEvent: (@Sendable (ToolProcessEvent) -> Void)? = nil,
        onLaunch: (@Sendable (Int32) -> Void)? = nil
    ) throws(ToolProcessError) -> ToolProcessRun {
        let run = ToolProcessRun(try singleExecution(spec, onEvent: onEvent, onLaunch: onLaunch))
        run.begin()
        return run
    }

    /// Runs one process and waits for it on the calling thread, for a
    /// synchronous caller.
    ///
    /// The spawn, the reads and the wait use posix_spawn and GCD only, never
    /// a Swift task, so the call completes even when every thread of the
    /// cooperative pool is blocked. The calling thread blocks until the run
    /// is over, so never call it on the main thread, and from async code
    /// call ``run(_:onEvent:onLaunch:)`` instead. Every guarantee of `run`
    /// holds, with `cancellation` in place of task cancellation.
    ///
    /// - Parameters:
    ///   - spec: What to run and how. Its stdout cannot be ``ToolProcessOutput/stream``.
    ///   - cancellation: Stops the run, as cancelling the task stops `run`.
    ///     When it is already cancelled, nothing launches.
    ///   - onEvent: As in ``run(_:onEvent:onLaunch:)``.
    ///   - onLaunch: As in ``run(_:onEvent:onLaunch:)``.
    /// - Throws: ``ToolProcessError``.
    public static func runBlocking(
        _ spec: ToolProcessSpec,
        cancellation: ToolProcessCancellation? = nil,
        onEvent: (@Sendable (ToolProcessEvent) -> Void)? = nil,
        onLaunch: (@Sendable (Int32) -> Void)? = nil
    ) throws(ToolProcessError) -> ToolProcessResult {
        try refuseStream(spec, in: "runBlocking")
        let run = ToolProcessRun(try singleExecution(spec, onEvent: onEvent, onLaunch: onLaunch))
        // Registered before the launch, so a cancellation that comes first
        // stops the run before anything is spawned.
        let token = cancellation?.register { run.cancel() }
        defer {
            if let token { cancellation?.unregister(token) }
        }
        run.begin()
        return try run.waitBlocking()
    }
}

/// The one handle on a process started by ``ToolProcess/start(_:onEvent:onLaunch:)``.
///
/// Start now, cancel from any thread, wait later, either suspending with
/// ``result()`` or blocking a thread with ``waitBlocking()``. The run keeps
/// itself alive until it is over, so dropping the handle neither stops the
/// process nor leaves it unreaped.
public final class ToolProcessRun: Sendable {
    /// Standard output when the spec sets ``ToolProcessOutput/stream``, and
    /// at end of file at once otherwise.
    public let stdout: ToolProcessOutputStream

    private let execution: ToolProcessExecution
    private let done = DispatchGroup()
    private let outcome = Mutex<Result<ToolProcessResult, ToolProcessError>?>(nil)

    init(_ execution: ToolProcessExecution) {
        self.execution = execution
        self.stdout = execution.stdoutStream
        done.enter()
    }

    /// The process ID, set before ``ToolProcess/start(_:onEvent:onLaunch:)``
    /// returns, or nil when the launch failed or a cancellation came first.
    public var pid: Int32? {
        execution.state.withLock { $0.stages[0].launched ? $0.stages[0].pid : nil }
    }

    func begin() {
        // The closure holds the run until the execution calls it at the end.
        execution.start { [self] in
            done.leave()
        }
    }

    /// Stops the run. ToolProcess terminates the process group and tree, a
    /// blocked reader of ``stdout`` reaches end of file, and the result is
    /// ``ToolProcessError/cancelled(results:)``. Does nothing once the run is over.
    public func cancel() {
        execution.requestStop(.cancelled)
    }

    /// Waits on the calling thread until the run is over, closes ``stdout``
    /// and returns the result. Never call it on the main thread, and read
    /// ``stdout`` to end of file or cancel the run first. Safe to call more
    /// than once.
    ///
    /// - Throws: ``ToolProcessError``.
    public func waitBlocking() throws(ToolProcessError) -> ToolProcessResult {
        done.wait()
        return try finish().get()
    }

    /// Suspends until the run is over, closes ``stdout`` and returns the
    /// result. Cancelling the waiting task cancels the run, as it does for
    /// ``ToolProcess/run(_:onEvent:onLaunch:)``. Read ``stdout`` to end of
    /// file or cancel the run first. Safe to call more than once.
    ///
    /// - Throws: ``ToolProcessError``.
    public func result() async throws(ToolProcessError) -> ToolProcessResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                done.notify(queue: execution.queue) {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
        return try finish().get()
    }

    private func finish() -> Result<ToolProcessResult, ToolProcessError> {
        outcome.withLock { cached in
            if let cached { return cached }
            let value: Result<ToolProcessResult, ToolProcessError>
            do throws(ToolProcessError) {
                let result = try execution.outcome().stages[0]
                value = .success(stdout.folded(into: result))
            } catch {
                value = .failure(error)
            }
            stdout.close()
            cached = value
            return value
        }
    }
}

/// Stops a ``ToolProcess/runBlocking(_:cancellation:onEvent:onLaunch:)``
/// run from another thread, the way task cancellation stops an async run.
///
/// One cancellation can serve several runs. Once cancelled, it stays
/// cancelled, and a run given it later launches nothing.
public final class ToolProcessCancellation: Sendable {
    private struct State {
        var cancelled = false
        var nextToken = 0
        var handlers: [Int: @Sendable () -> Void] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// True once ``cancel()`` has been called.
    public var isCancelled: Bool {
        state.withLock { $0.cancelled }
    }

    /// Stops every run registered now and every run given this cancellation
    /// later.
    public func cancel() {
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.cancelled else { return [] }
            state.cancelled = true
            defer { state.handlers = [:] }
            return Array(state.handlers.values)
        }
        handlers.forEach { $0() }
    }

    /// Calls `handler` on cancellation, or now when already cancelled, in
    /// which case it returns nil.
    func register(_ handler: @escaping @Sendable () -> Void) -> Int? {
        let token = state.withLock { state -> Int? in
            guard !state.cancelled else { return nil }
            state.nextToken += 1
            state.handlers[state.nextToken] = handler
            return state.nextToken
        }
        if token == nil {
            handler()
        }
        return token
    }

    func unregister(_ token: Int) {
        _ = state.withLock { $0.handlers.removeValue(forKey: token) }
    }
}
