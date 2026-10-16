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
///
/// A cancel sends SIGTERM to the CLI and SIGKILL after the run's
/// `terminationGracePeriod`. The default is zero, which kills the CLI right
/// after the signal, so a command that cleans up on SIGTERM
/// (`SIGTERMCancellation` in `LungfishCLI`) gets no time to do it. A runner
/// whose command cleans up or writes a cancelled record passes a real grace.
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
        /// wrote them. Empty when the CLI wrote none, and always empty for a
        /// version 1 CLI. They describe outputs beside `outputs` and never
        /// replace it as the input to bundle import. A kind stays the string the
        /// CLI wrote, and ``CLIEventArtifact/bundleKind`` reads a kind that names
        /// a registered bundle kind.
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
    /// The CLI and its descendants get SIGTERM at once, and whatever is left
    /// gets SIGKILL after the `terminationGracePeriod` that `run` was given.
    public nonisolated func cancel() {
        cancellation.cancel()
    }

    /// Launches `lungfish-cli` with `arguments`, streams decoded `CLIEvent`s
    /// to `onEvent` as they arrive, and returns the `.complete` outputs and
    /// typed artifacts on success.
    ///
    /// - Parameters:
    ///   - arguments: Full CLI argv, e.g. `["tree", "infer", "iqtree", ...]`.
    ///   - terminationGracePeriod: How long the CLI's process tree has between
    ///     SIGTERM and SIGKILL when the run is cancelled. A tree that exits
    ///     sooner ends the wait at once, so the grace costs nothing when the
    ///     CLI cleans up and exits quickly. The default is zero, which sends
    ///     SIGKILL right after SIGTERM and gives the CLI's own cleanup no time.
    ///     Keep a real value at 8 seconds or less, because SIGKILL can take
    ///     another second to settle and `OperationCenter` marks a cancelling
    ///     row cancelled after 10 seconds.
    ///   - drainGracePeriod: How long to wait for a descendant that holds the
    ///     CLI's output open after the CLI has exited. Nil keeps the
    ///     ``ToolProcess`` default of five seconds.
    ///   - environmentAdditions: Variables merged over the app's subprocess
    ///     environment for this run only, such as the NCBI key as
    ///     `NCBI_API_KEY`, so a secret never travels in `arguments`.
    ///   - completionOutlivesCancel: For a leaf that converts SIGTERM. A run
    ///     that still exits 0 with `complete` finished first and returns its
    ///     result.
    ///   - isCancelled: Polled before launch and after exit to detect an
    ///     operation cancelled via its `OperationCenter` row rather than
    ///     `cancel()` directly (matches the previous per-runner
    ///     `isOperationCancelled` check).
    ///   - onEvent: Invoked off the main actor, one event at a time and in
    ///     order, for every decoded event except `.complete`, which is folded
    ///     into the return value. A `.failed` event is delivered and also
    ///     thrown, so callers cannot forget to check it. Each line of plain
    ///     standard error that is not blank arrives as an info `.log` event,
    ///     so the operation log keeps it at info level. The bridge hops each
    ///     event to the main actor itself.
    ///   - signalsCommandFirst: Whether a cancel sends SIGTERM to the CLI alone and leaves its
    ///     children to it until SIGKILL after `terminationGracePeriod`
    ///     (`ToolProcessSpec.signalsProcessFirst`), for a command whose cancel runs a cleanup tool.
    ///   - workingDirectory: The folder the CLI runs in, where a relative path in
    ///     `arguments` resolves, such as the `--output` name of a clipboard or
    ///     share destination. Nil keeps the app's own folder.
    public func run(
        arguments: [String],
        terminationGracePeriod: Duration = .zero,
        signalsCommandFirst: Bool = false,
        drainGracePeriod: Duration? = nil,
        environmentAdditions: [String: String] = [:],
        completionOutlivesCancel: Bool = false,
        isCancelled: @Sendable () async -> Bool,
        onEvent: @escaping @Sendable (CLIEvent) -> Void,
        workingDirectory: URL? = nil
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

        // Standard error carries human text, never events (S15). Each line that is
        // not blank reaches the caller as an info log line, so it stays in the
        // operation log at info level and never makes a run Completed with
        // Warnings, whatever it says (decision S16 of Phase 2.6).
        @Sendable func handleStandardErrorLine(_ line: String) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            onEvent(.log(level: .info, message: line))
        }

        var spec = CLIProcessLauncher.spec(
            executableURL: binaryURL,
            arguments: arguments,
            terminationGracePeriod: terminationGracePeriod,
            drainGracePeriod: drainGracePeriod,
            environmentAdditions: environmentAdditions,
            workingDirectory: workingDirectory
        )
        spec.signalsProcessFirst = signalsCommandFirst
        let outcome = await CLIProcessLauncher.run(
            spec,
            cancellation: cancellation,
            onStdoutLine: handleLine,
            onStderrLine: handleStandardErrorLine
        )

        let snapshot = state.withLock { current in
            (
                outputs: current.outputs,
                completeMessage: current.completeMessage,
                artifacts: current.artifacts,
                failed: current.failed
            )
        }
        let finishedFirst = { (exit: CLIProcessExit) in
            completionOutlivesCancel && exit.succeeded && snapshot.failed == nil && !snapshot.outputs.isEmpty
        }
        let exit: CLIProcessExit
        switch outcome {
        case .exited(let finished): exit = finished
        case .cancelled(let finished?) where finishedFirst(finished): exit = finished
        case .cancelled: throw CancellationError()
        case .launchFailed(let reason): throw RunError.launchFailed(reason)
        }
        if !finishedFirst(exit), await isCancelled() { throw CancellationError() }

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
