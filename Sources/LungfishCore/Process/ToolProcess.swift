// ToolProcess.swift - The one way Lungfish runs an external process
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Runs external processes for every layer, from LungfishCore to the CLI.
///
/// Guarantees that every run keeps.
///
/// - Each process is spawned with posix_spawn as the leader of its own
///   process group, with only stdin, stdout and stderr open, default signal
///   dispositions (SIGPIPE included) and an empty signal mask.
/// - Both output pipes are read from launch until end of file, so a process
///   that writes more than the 64 KB pipe buffer never blocks on a full pipe.
///   The one exception is a ``ToolProcessOutput/stream`` stdout, which the
///   caller reads at its own pace through ``start(_:onEvent:onLaunch:)``.
/// - The engine runs on posix_spawn and GCD alone. ``start(_:onEvent:onLaunch:)``
///   and ``runBlocking(_:cancellation:onEvent:onLaunch:)`` start and finish a
///   run without a Swift task, so they complete even when every thread of the
///   cooperative pool is blocked.
/// - After the root process exits, captured streams get
///   ``ToolProcessSpec/drainGracePeriod`` to reach end of file, and a stage
///   that writes a file gets the same time for its process group to empty.
///   Descendants still running then get SIGTERM through the group and SIGKILL
///   after a short fixed grace, so the call cannot hang and nothing writes
///   after it returns. The result is then not a success and says so with
///   ``ToolProcessResult/outputDrainTimedOut`` and
///   ``ToolProcessResult/incompleteOutputReason``.
/// - Cancelling the calling task (or calling ``ToolProcessRun/cancel()``, or
///   the ``ToolProcessCancellation`` of a blocking run), or exceeding the wall-clock or idle limit,
///   sends SIGTERM to the process group and the descendant tree, then
///   SIGKILL after ``ToolProcessSpec/terminationGracePeriod``, so helper
///   processes such as a JVM under a wrapper script do not survive. The run
///   ends as soon as the group and tree are gone, so a tool that honours
///   SIGTERM does not wait out the grace, and no thread waits for it. The
///   limits run on the suspending clock, so time the Mac spends asleep does
///   not count.
/// - Every running process is registered with ``NativeProcessRegistry``, so
///   app quit reaches it.
/// - A nonzero exit status is a result, not an error. Only an invalid spec, a
///   launch failure, a timeout or a cancellation throws.
///
/// Known limits.
///
/// - Settlement watches the stage's process group, plus the descendant tree
///   while a termination runs. A descendant that leaves the group with
///   setsid or setpgid, and is no longer in the tree, can keep writing a
///   ``ToolProcessOutput/file(_:)`` output after the run returns, and the
///   result does not show it.
/// - A streamed stdout settles when the stage's group empties. A descendant
///   in the group that still writes it after the leader exits gets
///   ``ToolProcessSpec/drainGracePeriod``. A reader slower than that keeps it
///   blocked on the full pipe until the grace runs out, and it is then
///   killed and the output reported incomplete. Read a stream promptly, or
///   raise the grace for such a tool.
/// - Pipes are made with pipe() and marked close-on-exec with fcntl right
///   after. ToolProcess spawns with POSIX_SPAWN_CLOEXEC_DEFAULT and never
///   inherits them, but a Foundation `Process` launched elsewhere in the app
///   in that window can, and then holds the pipe open until it exits. The
///   window stays until the remaining Foundation `Process` spawns move to
///   ToolProcess, which scripts/ratchets/process-spawn.sh counts.
public enum ToolProcess {
    /// Runs one process and returns once it has exited and its captured
    /// output is drained.
    ///
    /// - Parameters:
    ///   - spec: What to run and how.
    ///   - onEvent: Receives the launch and every captured output line, one
    ///     event at a time, before this method returns or throws. Without it,
    ///     output is not framed into lines at all. A trailing closure binds here.
    ///   - onLaunch: Receives the pid synchronously, on the launching thread,
    ///     right after the spawn succeeds.
    /// - Throws: ``ToolProcessError``.
    public static func run(
        _ spec: ToolProcessSpec,
        onEvent: (@Sendable (ToolProcessEvent) -> Void)? = nil,
        onLaunch: (@Sendable (Int32) -> Void)? = nil
    ) async throws(ToolProcessError) -> ToolProcessResult {
        try refuseStream(spec, in: "run")
        let run = ToolProcessRun(try singleExecution(spec, onEvent: onEvent, onLaunch: onLaunch))
        if Task.isCancelled {
            throw .cancelled(results: [])
        }
        run.begin()
        // result() forwards the cancellation of this task to the run.
        return try await run.result()
    }

    /// Validates a single-process spec and builds the engine that runs it.
    static func singleExecution(
        _ spec: ToolProcessSpec,
        onEvent: (@Sendable (ToolProcessEvent) -> Void)?,
        onLaunch: (@Sendable (Int32) -> Void)?
    ) throws(ToolProcessError) -> ToolProcessExecution {
        try validate(spec)
        if let idle = spec.idleTimeout, !spec.stdout.isCaptured && spec.stdout != .stream && !spec.stderr.isCaptured {
            throw .invalidSpec("An idle timeout of \(idle) needs stdout or stderr captured, or stdout streamed, because no other output is observed.")
        }
        var stageHandler: (@Sendable (Int, ToolProcessEvent) -> Void)?
        if let onEvent {
            stageHandler = { _, event in onEvent(event) }
        }
        var launchHandler: (@Sendable (Int, Int32) -> Void)?
        if let onLaunch {
            launchHandler = { _, pid in onLaunch(pid) }
        }
        return ToolProcessExecution(
            specs: [spec],
            limits: .init(wallClock: spec.timeout, idle: spec.idleTimeout, drainGrace: spec.drainGracePeriod),
            observers: .init(failurePolicy: .runToCompletion, onLaunch: launchHandler, onEvent: stageHandler)
        )
    }

    /// A streamed stdout needs a reader, which only ``start(_:onEvent:onLaunch:)`` hands out.
    static func refuseStream(_ spec: ToolProcessSpec, in method: String) throws(ToolProcessError) {
        if spec.stdout == .stream {
            throw .invalidSpec("\(spec.label) streams stdout, which needs ToolProcess.start and a reader. \(method) has none.")
        }
    }

    /// Runs stages connected stdout to stdin, as a shell pipeline does, for
    /// example `samtools view | samtools sort`.
    ///
    /// The first stage reads its own ``ToolProcessSpec/stdin`` and the last
    /// stage writes its own ``ToolProcessSpec/stdout``. Every stage keeps its
    /// own stderr. The stdin of a later stage must stay `.null` and the stdout
    /// of an earlier stage must stay at its default, because the pipe replaces
    /// them. The limits cover the whole pipeline, so the stages' own
    /// `timeout` and `idleTimeout` must be nil. A cancellation or a limit
    /// terminates every running stage. Under the default
    /// ``ToolPipelineFailurePolicy/stopAllOnFailure`` a failing stage stops
    /// the others and the result is not a success. A stage that cannot launch
    /// stops the stages already running, and the error carries their results.
    ///
    /// - Parameters:
    ///   - stages: The stages in order. At least one.
    ///   - timeout: Wall-clock limit for the whole pipeline.
    ///   - idleTimeout: Limit on the time with no output on any captured
    ///     stream of any stage.
    ///   - failurePolicy: What a failing stage does to the others.
    ///   - onEvent: Receives each stage's index with its events, one event at
    ///     a time, before this method returns or throws. A trailing closure
    ///     binds here.
    ///   - onLaunch: Receives each stage's index and pid synchronously, right
    ///     after its spawn succeeds.
    /// - Throws: ``ToolProcessError``.
    public static func runPipeline(
        _ stages: [ToolProcessSpec],
        timeout: Duration? = nil,
        idleTimeout: Duration? = nil,
        failurePolicy: ToolPipelineFailurePolicy = .stopAllOnFailure,
        onEvent: (@Sendable (_ stage: Int, _ event: ToolProcessEvent) -> Void)? = nil,
        onLaunch: (@Sendable (_ stage: Int, _ pid: Int32) -> Void)? = nil
    ) async throws(ToolProcessError) -> ToolPipelineResult {
        guard !stages.isEmpty else {
            throw .invalidSpec("A pipeline needs at least one stage.")
        }
        for (index, stage) in stages.enumerated() {
            try validate(stage)
            try refuseStream(stage, in: "runPipeline")
            if stage.timeout != nil || stage.idleTimeout != nil {
                throw .invalidSpec("Stage \(index) (\(stage.label)) sets its own timeout. Pass the pipeline's limits to runPipeline instead.")
            }
            if index > 0 && stage.stdin != .null {
                throw .invalidSpec("Stage \(index) (\(stage.label)) reads the previous stage's stdout, so its stdin must stay .null.")
            }
            if index < stages.count - 1 && stage.stdout != .capture() {
                throw .invalidSpec("Stage \(index) (\(stage.label)) writes into the next stage, so its stdout must stay at the default.")
            }
        }
        try validate(limit: timeout, name: "pipeline timeout")
        try validate(limit: idleTimeout, name: "pipeline idle timeout")
        if let idleTimeout {
            let observed = stages.contains { $0.stderr.isCaptured } || stages[stages.count - 1].stdout.isCaptured
            if !observed {
                throw .invalidSpec("An idle timeout of \(idleTimeout) needs a captured stream, because no other output is observed.")
            }
        }
        let execution = ToolProcessExecution(
            specs: stages,
            limits: .init(
                wallClock: timeout,
                idle: idleTimeout,
                drainGrace: stages.map(\.drainGracePeriod).max() ?? ToolProcessSpec.defaultDrainGracePeriod
            ),
            observers: .init(failurePolicy: failurePolicy, onLaunch: onLaunch, onEvent: onEvent)
        )
        return try await execution.run()
    }

    private static func validate(_ spec: ToolProcessSpec) throws(ToolProcessError) {
        guard spec.executableURL.isFileURL else {
            throw .invalidSpec("\(spec.label) has an executable URL that is not a file URL.")
        }
        if spec.stderr == .stream {
            throw .invalidSpec("\(spec.label) streams stderr. Only stdout can stream.")
        }
        for output in [spec.stdout, spec.stderr] {
            if case .capture(let limit?) = output, limit < 0 {
                throw .invalidSpec("\(spec.label) has a negative capture limit.")
            }
        }
        if case .file(let stdoutURL) = spec.stdout, case .file(let stderrURL) = spec.stderr,
           stdoutURL.standardizedFileURL.path == stderrURL.standardizedFileURL.path {
            throw .invalidSpec("\(spec.label) writes stdout and stderr to the same file, and each would truncate and overwrite the other. Write one to a file and capture the other.")
        }
        try validate(limit: spec.timeout, name: "timeout of \(spec.label)")
        try validate(limit: spec.idleTimeout, name: "idle timeout of \(spec.label)")
        if spec.terminationGracePeriod < .zero || spec.drainGracePeriod < .zero {
            throw .invalidSpec("\(spec.label) has a negative grace period.")
        }
    }

    private static func validate(limit: Duration?, name: String) throws(ToolProcessError) {
        if let limit, limit <= .zero {
            throw .invalidSpec("The \(name) must be positive.")
        }
    }
}
