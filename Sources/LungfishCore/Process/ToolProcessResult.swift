// ToolProcessResult.swift - Events, results and errors of ToolProcess runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One of a process's two output streams.
public enum ToolProcessStream: Sendable, Equatable {
    case stdout
    case stderr
}

/// Something a running process did, delivered while it runs.
///
/// Events of one run are delivered one at a time, in order, on a queue the run
/// owns, and every event is delivered before the run returns or throws. An
/// observer must return promptly, because output is not read while it runs.
public enum ToolProcessEvent: Sendable, Equatable {
    /// The process launched.
    case started(pid: Int32, argv: [String])
    /// One line of a captured stream, framed by ``ProcessOutputLineFramer``.
    /// LF, CRLF and a lone CR each end a line, and empty lines are delivered.
    case output(stream: ToolProcessStream, line: String)
}

/// How the root process ended.
public enum ToolProcessTermination: Sendable, Equatable {
    /// It called exit with this status.
    case exited(code: Int32)
    /// An uncaught signal with this number ended it.
    case signaled(signal: Int32)
}

/// Which limit a run exceeded.
public enum ToolProcessTimeout: Sendable, Equatable {
    /// The run lasted longer than this.
    case wallClock(Duration)
    /// No captured stream produced output for this long.
    case idle(Duration)
}

/// Why ToolProcess signaled a stage's process group and tree itself.
public enum ToolProcessStop: Sendable, Equatable {
    /// The calling task was cancelled.
    case cancelled
    /// The run exceeded a limit.
    case timedOut(ToolProcessTimeout)
    /// Another stage of the pipeline failed, or could not launch, under
    /// ``ToolPipelineFailurePolicy/stopAllOnFailure``.
    case pipelineStageFailed(stage: Int)
}

/// What a pipeline does when one of its stages fails.
public enum ToolPipelineFailurePolicy: Sendable, Equatable {
    /// Terminate the stages still running as soon as one stage exits nonzero
    /// or is killed by a signal, as `set -o pipefail` and an early exit would.
    /// A stage killed by SIGPIPE does not count when the stage it wrote to
    /// finished cleanly, so `yes | head -n 1` succeeds.
    case stopAllOnFailure
    /// Let every stage run to its end and report the failures afterwards.
    case runToCompletion
}

/// The outcome of one process, or of one stage of a pipeline.
public struct ToolProcessResult: Sendable {
    /// The spec's label.
    public let label: String
    /// The process ID the root process had.
    public let pid: Int32
    /// How the root process ended.
    public let termination: ToolProcessTermination
    /// Set when ToolProcess signaled this stage's process group and tree
    /// itself, whether the stage was still running or had exited and left
    /// descendants behind.
    public let stop: ToolProcessStop?
    /// Captured standard output, or empty when the stream was not captured.
    public let stdout: Data
    /// Captured standard error, or empty when the stream was not captured.
    public let stderr: Data
    /// True when the capture limit dropped earlier standard output bytes.
    public let stdoutTruncated: Bool
    /// True when the capture limit dropped earlier standard error bytes.
    public let stderrTruncated: Bool
    /// True when output may be incomplete because descendants outlived the
    /// root. Either a captured stream had not reached end of file, or a
    /// process of the stage's group was still running while an output went to
    /// a file, at the end of the drain grace period (or at a cancellation in
    /// that period). Those descendants were killed. The captured bytes are
    /// those read before then.
    public let outputDrainTimedOut: Bool
    /// True when reading a captured stream failed with an error other than
    /// EAGAIN or EINTR, so the bytes after the failure are missing.
    public let outputReadFailed: Bool
    /// Time from launch to the exit of the root process, on a monotonic clock.
    public let wallTime: Duration

    public init(
        label: String,
        pid: Int32,
        termination: ToolProcessTermination,
        stop: ToolProcessStop?,
        stdout: Data,
        stderr: Data,
        stdoutTruncated: Bool,
        stderrTruncated: Bool,
        outputDrainTimedOut: Bool,
        outputReadFailed: Bool = false,
        wallTime: Duration
    ) {
        self.label = label
        self.pid = pid
        self.termination = termination
        self.stop = stop
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.outputDrainTimedOut = outputDrainTimedOut
        self.outputReadFailed = outputReadFailed
        self.wallTime = wallTime
    }

    /// The raw status `Process.terminationStatus` reports, which is the exit
    /// code or the signal number.
    public var status: Int32 {
        switch termination {
        case .exited(let code): return code
        case .signaled(let signal): return signal
        }
    }

    /// True when no output was cut short or failed to read.
    public var outputComplete: Bool {
        !outputDrainTimedOut && !outputReadFailed
    }

    /// True when the process exited with status 0 and its output is complete.
    /// Data integrity comes first, so a clean exit whose output a lingering
    /// descendant kept open is not a success.
    public var isSuccess: Bool {
        termination == .exited(code: 0) && outputComplete
    }

    /// Standard output decoded as UTF-8, with invalid bytes replaced.
    public var stdoutText: String {
        String(decoding: stdout, as: UTF8.self)
    }

    /// Standard error decoded as UTF-8, with invalid bytes replaced.
    public var stderrText: String {
        String(decoding: stderr, as: UTF8.self)
    }
}

/// The outcome of a pipeline, one result per stage in stage order.
public struct ToolPipelineResult: Sendable {
    /// One result per stage.
    public let stages: [ToolProcessResult]
    /// Time from the first launch until every stage exited and its output
    /// was drained, on a monotonic clock.
    public let wallTime: Duration

    public init(stages: [ToolProcessResult], wallTime: Duration) {
        self.stages = stages
        self.wallTime = wallTime
    }

    /// The stages that failed on their own, in stage order. A stage killed
    /// by SIGPIPE is not listed when the stage after it finished cleanly,
    /// and a stage the failure policy stopped is not listed, because the
    /// stage that caused the stop is.
    public var failedStageIndices: [Int] {
        var clean = Array(repeating: false, count: stages.count)
        var failed: [Int] = []
        for index in stages.indices.reversed() {
            let stage = stages[index]
            guard stage.stop == nil else { continue }
            if stage.termination == .exited(code: 0) {
                clean[index] = true
            } else if stage.termination == .signaled(signal: SIGPIPE),
                      index + 1 < stages.count, clean[index + 1] {
                clean[index] = true
            } else {
                failed.append(index)
            }
        }
        return failed.reversed()
    }

    /// True when no stage failed or was stopped and every stage's output is
    /// complete.
    public var isSuccess: Bool {
        failedStageIndices.isEmpty && stages.allSatisfy { $0.stop == nil && $0.outputComplete }
    }
}

/// Why a ToolProcess run produced no normal result.
///
/// A process that exits with a nonzero status is not an error. Its result
/// carries the status.
public enum ToolProcessError: Error, Sendable, LocalizedError {
    /// The spec cannot run as written. Nothing was launched.
    case invalidSpec(String)
    /// The process could not be launched, or an input or output file could
    /// not be opened. Any stage of a pipeline already launched was terminated
    /// first, and its result is in `results`.
    case launchFailed(label: String, reason: String, results: [ToolProcessResult])
    /// A limit was exceeded and the process tree was terminated. The results
    /// hold what each stage wrote before then.
    case timedOut(ToolProcessTimeout, results: [ToolProcessResult])
    /// The calling task was cancelled and the process tree was terminated.
    /// The results hold what each stage wrote before then, and are empty when
    /// the task was cancelled before launch.
    case cancelled(results: [ToolProcessResult])

    public var errorDescription: String? {
        switch self {
        case .invalidSpec(let reason):
            return "Invalid process spec. \(reason)"
        case .launchFailed(let label, let reason, _):
            return "Could not launch '\(label)'. \(reason)"
        case .timedOut(.wallClock(let limit), let results):
            return "'\(Self.labels(results))' timed out after \(Self.seconds(limit)) seconds"
        case .timedOut(.idle(let limit), let results):
            return "'\(Self.labels(results))' wrote no output for \(Self.seconds(limit)) seconds"
        case .cancelled(let results):
            return results.isEmpty ? "The process run was cancelled" : "'\(Self.labels(results))' was cancelled"
        }
    }

    private static func labels(_ results: [ToolProcessResult]) -> String {
        results.map(\.label).joined(separator: " | ")
    }

    private static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
