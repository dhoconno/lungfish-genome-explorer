// CLISubprocessTransport.swift — One ToolProcess implementation for streaming `lungfish-cli --json-events`.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow
import os.log

private let transportLogger = Logger(subsystem: LogSubsystem.app, category: "CLISubprocessTransport")

/// Runs `lungfish-cli` as a subprocess, decodes its `--json-events` stdout
/// stream line by line through ``CLIEventLine`` into ``CLIEvent`` values and
/// typed artifacts, and bridges them onto an ``OperationCenter`` item.
///
/// A line of any schema version decodes. A line whose event this reader does
/// not know is noted at debug level and skipped, and the run goes on.
/// `docs/formats/cli-events.md` has the wire format and the version rule.
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
        /// Every path the `complete` line named, in the order the command
        /// documents. This list is what a runner imports, and a runner that
        /// reads a file by its place reads it here.
        public let outputs: [String]
        public let message: String?
        /// The typed artifacts of the `complete` line, in the order the command
        /// wrote them, or empty when the CLI wrote none, as a version 1 CLI
        /// never does. They describe outputs beside `outputs` and never replace
        /// it as the input to bundle import. A kind stays the string the CLI
        /// wrote, and ``CLIEventArtifact/bundleKind`` reads a kind that names a
        /// registered bundle kind.
        public let artifacts: [CLIEventArtifact]
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

    /// Launches `lungfish-cli` with `arguments`, streams decoded `CLIEvent`s
    /// to `onEvent` as they arrive, and returns the `.complete` outputs and
    /// typed artifacts on success.
    ///
    /// - Parameters:
    ///   - arguments: Full CLI argv, e.g. `["tree", "infer", "iqtree", ...]`.
    ///   - isCancelled: Polled before launch and after exit to detect an
    ///     operation cancelled via its `OperationCenter` row rather than
    ///     `cancel()` directly (matches the previous per-runner
    ///     `isOperationCancelled` check).
    ///   - onEvent: Invoked off the main actor, one event at a time and in
    ///     order, for every decoded event except `.complete`, which is folded
    ///     into the return value. A `.failed` event is delivered and also
    ///     thrown, so callers cannot forget to check it. The bridge hops each
    ///     event to the main actor itself.
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
            var artifacts: [CLIEventArtifact] = []
            var failed: (message: String, detail: String?)?
        }

        let state = OSAllocatedUnfairLock(initialState: StreamState())
        let decoder = eventDecoder

        @Sendable func handleLine(_ line: String) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            let envelope: CLIEventLine?
            do {
                envelope = try decoder.decodeLine(line)
            } catch {
                transportLogger.warning("Failed to decode CLIEvent line: \(error.localizedDescription, privacy: .public)")
                return
            }
            // Nil for chatter that is not a JSON object. A line whose event this
            // reader does not know, such as one from a later CLI, has no event. The
            // decoder notes it at debug level, and the run goes on without it.
            guard let envelope, let event = envelope.event else { return }
            switch event {
            case let .complete(outputs, message):
                state.withLock {
                    $0.outputs = outputs
                    $0.completeMessage = message
                    $0.artifacts = envelope.artifacts
                }
            case let .failed(message, detail):
                state.withLock { $0.failed = (message, detail) }
                onEvent(event)
            default:
                onEvent(event)
            }
        }

        let outcome = await CLIProcessLauncher.run(
            CLIProcessLauncher.spec(executableURL: binaryURL, arguments: arguments),
            cancellation: cancellation,
            onStdoutLine: handleLine
        )

        let exit: CLIProcessExit
        switch outcome {
        case .exited(let finished):
            exit = finished
        case .cancelled:
            throw CancellationError()
        case .launchFailed(let reason):
            throw RunError.launchFailed(reason)
        }

        if await isCancelled() {
            throw CancellationError()
        }

        let snapshot = state.withLock { current in
            (
                outputs: current.outputs,
                completeMessage: current.completeMessage,
                artifacts: current.artifacts,
                failed: current.failed
            )
        }
        if let failed = snapshot.failed {
            throw RunError.failedEvent(message: failed.message, detail: failed.detail)
        }
        if !exit.succeeded {
            if let incomplete = exit.incompleteOutput {
                transportLogger.error("\(incomplete, privacy: .public)")
            }
            throw RunError.nonZeroExit(status: exit.status, stderr: exit.failureDetail)
        }
        // Artifacts never stand in for outputs, so a completion that names no
        // output fails even when it lists artifacts.
        guard !snapshot.outputs.isEmpty else {
            throw RunError.missingCompletion
        }

        return Result(outputs: snapshot.outputs, message: snapshot.completeMessage, artifacts: snapshot.artifacts)
    }
}
