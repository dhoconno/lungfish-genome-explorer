// NativeToolRunner+ToolProcess.swift - How NativeToolRunner hands its runs to ToolProcess
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The translation between NativeToolRunner's public API and ``ToolProcess``.
///
/// NativeToolRunner keeps its own result, error and event types. These helpers
/// map a `TimeInterval` timeout to ToolProcess's limit, ToolProcess's errors to
/// `NativeToolError` and `CancellationError`, its events to
/// `NativeProcessEvent`, and refuse a result whose output is incomplete.
enum NativeToolProcessAdapter {
    /// The ToolProcess limit for a NativeToolRunner timeout. An infinite
    /// timeout, which recipe workflows pass for data-dependent wall times,
    /// means no limit. A limit that is not positive has already run out.
    static func limit(_ seconds: TimeInterval, name: String) throws -> Duration? {
        guard seconds.isFinite else { return nil }
        guard seconds > 0 else { throw NativeToolError.timeout(name, seconds) }
        return .seconds(seconds)
    }

    /// The status `Process.terminationStatus` reported, which the runner has
    /// always returned: the exit code in 0...255, or the signal number.
    static func status(_ result: ToolProcessResult) -> Int32 {
        result.status
    }

    /// The error NativeToolRunner has always thrown for each way a run can
    /// fail to produce a result.
    static func nativeError(_ error: ToolProcessError, name: String, timeout: TimeInterval) -> Error {
        switch error {
        case .cancelled:
            return CancellationError()
        case .timedOut:
            return NativeToolError.timeout(name, timeout)
        case .invalidSpec, .launchFailed:
            return NativeToolError.executionFailed(name, -1, error.localizedDescription)
        }
    }

    /// Refuses a result whose output a lingering descendant cut short or a
    /// read error lost, because a truncated output must never pass as a
    /// complete one.
    static func requireCompleteOutput(_ result: ToolProcessResult, name: String) throws {
        if result.outputDrainTimedOut {
            throw NativeToolError.executionFailed(
                name, status(result),
                "\(name) output was incomplete: a child process kept its output open after it exited"
            )
        }
        if result.outputReadFailed {
            throw NativeToolError.executionFailed(
                name, status(result),
                "\(name) output was incomplete: reading it failed"
            )
        }
    }

    /// Forwards ToolProcess events as NativeProcessEvents, dropping empty
    /// lines as the runner always has.
    static func observer(
        _ onEvent: (@Sendable (NativeProcessEvent) -> Void)?
    ) -> (@Sendable (ToolProcessEvent) -> Void)? {
        guard let onEvent else { return nil }
        return { event in
            switch event {
            case .started(_, let argv):
                onEvent(.started(argv: argv))
            case .output(let stream, let line):
                guard !line.isEmpty else { return }
                onEvent(.output(stream: stream == .stdout ? .stdout : .stderr, line: line))
            }
        }
    }

    /// Runs one process and maps a run that produced no result.
    static func run(
        _ spec: ToolProcessSpec,
        timeout: TimeInterval,
        onEvent: (@Sendable (NativeProcessEvent) -> Void)?
    ) async throws -> ToolProcessResult {
        let result: ToolProcessResult
        do {
            result = try await ToolProcess.run(spec, onEvent: observer(onEvent))
        } catch {
            throw nativeError(error, name: spec.label, timeout: timeout)
        }
        try requireCompleteOutput(result, name: spec.label)
        return result
    }

    /// Runs a pipeline and maps a run that produced no result.
    ///
    /// Every stage runs to its own end, as the pipeline always has, so each
    /// stage reports its own exit code and stderr rather than the SIGTERM a
    /// stopped stage would report.
    static func runPipeline(
        _ specs: [ToolProcessSpec],
        name: String,
        timeout: TimeInterval
    ) async throws -> ToolPipelineResult {
        let limit = try limit(timeout, name: name)
        let result: ToolPipelineResult
        do {
            result = try await ToolProcess.runPipeline(specs, timeout: limit, failurePolicy: .runToCompletion)
        } catch {
            throw nativeError(error, name: name, timeout: timeout)
        }
        for stage in result.stages {
            try requireCompleteOutput(stage, name: name)
        }
        return result
    }

    /// Decodes captured bytes as NativeToolRunner always has.
    static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }
}
