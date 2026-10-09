// CLISubprocessTransport.swift — One ToolProcess implementation for streaming `lungfish-cli --json-events`.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow
import os.log

private let transportLogger = Logger(subsystem: LogSubsystem.app, category: "CLISubprocessTransport")

/// Runs `lungfish-cli` as a subprocess, decodes its `--json-events` stdout
/// stream line by line into ``CLIEvent`` values, and bridges them onto an
/// ``OperationCenter`` item.
///
/// Before this type existed, nine `CLI*Runner` actors under
/// `Sources/LungfishApp/Services/` each hand-rolled this exact
/// launch/pipe-drain/cancel choreography: `diff
/// CLITreeInferenceRunner.swift CLITreeTransformRunner.swift` showed only 36
/// changed lines out of 297. `CLISubprocessTransport` is that shared
/// implementation. A runner now supplies only argv, an `OperationType`, and
/// small `CLIEvent -> OperationCenter` glue (how to interpret `.complete`'s
/// outputs, what failure text to show).
///
/// Cancellation mirrors the pre-existing per-runner contract exercised by
/// `CLIEventRunnerCancellationTests`: `cancel()` is `nonisolated` and returns
/// immediately (it only records the request in `CLIRunCancellation`, which
/// cancels the task that runs the ToolProcess), never
/// blocking on the actor's in-flight `run`.
public actor CLISubprocessTransport {
    public enum RunError: Error, LocalizedError, Sendable, Equatable {
        case cliNotFound
        case launchFailed(String)
        case nonZeroExit(status: Int32, stderr: String)
        case missingCompletion
        case failedEvent(message: String, detail: String?)

        public var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "The `lungfish-cli` binary could not be found in the app bundle or build products."
            case .launchFailed(let message):
                return "Failed to launch lungfish-cli: \(message)"
            case .nonZeroExit(let status, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? "lungfish-cli exited with status \(status)"
                    : "lungfish-cli exited with status \(status): \(trimmed)"
            case .missingCompletion:
                return "lungfish-cli finished without reporting completion."
            case .failedEvent(let message, let detail):
                if let detail, !detail.isEmpty {
                    return "\(message): \(detail)"
                }
                return message
            }
        }
    }

    /// The terminal outcome of a run, handed back to the caller so it can
    /// interpret `outputs` (a tree bundle URL, an import manifest, …) without
    /// this type knowing about any particular feature's result shape.
    public struct Result: Sendable, Equatable {
        public let outputs: [String]
        public let message: String?
    }

    private let cliURLOverride: URL?
    private let cancellation = CLIRunCancellation()
    private let eventDecoder = CLIEventLineDecoder()

    public init(cliURLOverride: URL? = nil) {
        self.cliURLOverride = cliURLOverride
    }

    /// Cancels the run, whether it is running or about to start. Safe to call
    /// from any thread; never blocks on `run`'s actor isolation. The process
    /// tree is stopped by ``ToolProcess`` once the run's task sees the cancel.
    public nonisolated func cancel() {
        cancellation.cancel()
    }

    /// The longest event line the transport decodes whole. ToolProcess cuts a
    /// longer line into pieces, and a `complete` event that lists thousands of
    /// outputs can pass the 64 KB default.
    private static let maxEventLineBytes = 16 * 1024 * 1024

    /// Launches `lungfish-cli` with `arguments`, streams decoded `CLIEvent`s
    /// to `onEvent` as they arrive (already hopped to the main actor — see
    /// below), and returns the `.complete` outputs on success.
    ///
    /// - Parameters:
    ///   - arguments: Full CLI argv, e.g. `["tree", "infer", "iqtree", ...]`.
    ///   - isCancelled: Polled before launch and after exit to detect an
    ///     operation cancelled via its `OperationCenter` row rather than
    ///     `cancel()` directly (matches the previous per-runner
    ///     `isOperationCancelled` check).
    ///   - onEvent: Invoked on the main actor for every decoded event except
    ///     `.complete`/`.failed`, which are folded into the return value /
    ///     thrown error instead so callers cannot forget to check them.
    public func run(
        arguments: [String],
        isCancelled: @Sendable () async -> Bool,
        onEvent: @escaping @Sendable (CLIEvent) -> Void
    ) async throws -> Result {
        if await isCancelled() {
            throw CancellationError()
        }
        guard let binaryURL = cliURLOverride ?? CLIBinaryLocator.cliBinaryPath() else {
            throw RunError.cliNotFound
        }

        final class StreamState: @unchecked Sendable {
            var outputs: [String] = []
            var completeMessage: String?
            var failed: (message: String, detail: String?)?
        }

        let state = OSAllocatedUnfairLock(initialState: StreamState())
        let decoder = eventDecoder

        @Sendable func handleLine(_ line: String) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            let event: CLIEvent?
            do {
                event = try decoder.decode(line: line)
            } catch {
                transportLogger.warning("Failed to decode CLIEvent line: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let event else { return }
            switch event {
            case let .complete(outputs, message):
                state.withLock {
                    $0.outputs = outputs
                    $0.completeMessage = message
                }
            case let .failed(message, detail):
                state.withLock { $0.failed = (message, detail) }
                onEvent(event)
            default:
                onEvent(event)
            }
        }

        let spec = ToolProcessSpec(
            executableURL: binaryURL,
            arguments: arguments,
            environment: ManagedStorageConfigStore().subprocessEnvironment(),
            stdout: .capture(limit: 0),
            stderr: .capture(),
            terminationGracePeriod: .zero,
            maxLineBytes: Self.maxEventLineBytes,
            label: "lungfish-cli"
        )
        let outcome = await cancellation.run(spec) { event in
            guard case .output(.stdout, let line) = event else { return }
            handleLine(line)
        }

        let result: ToolProcessResult
        switch outcome.result {
        case .success(let finished):
            result = finished
        case .failure(.cancelled):
            throw CancellationError()
        case .failure(let error):
            throw RunError.launchFailed(error.cliLaunchFailureReason)
        }

        let operationCancelled = await isCancelled()
        if outcome.cancelRequested || result.stop == .cancelled || operationCancelled {
            throw CancellationError()
        }

        let snapshot = state.withLock { current in
            (
                outputs: current.outputs,
                completeMessage: current.completeMessage,
                failed: current.failed
            )
        }
        if let failed = snapshot.failed {
            throw RunError.failedEvent(message: failed.message, detail: failed.detail)
        }
        if let incomplete = result.cliIncompleteOutputNote {
            transportLogger.error("\(incomplete, privacy: .public)")
            throw RunError.nonZeroExit(status: result.status, stderr: [result.cliStderrText, incomplete].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        if result.status != 0 {
            throw RunError.nonZeroExit(status: result.status, stderr: result.cliStderrText)
        }
        guard !snapshot.outputs.isEmpty else {
            throw RunError.missingCompletion
        }

        return Result(outputs: snapshot.outputs, message: snapshot.completeMessage)
    }
}
