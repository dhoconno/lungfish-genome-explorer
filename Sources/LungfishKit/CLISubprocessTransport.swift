// CLISubprocessTransport.swift — One `Process()` implementation for streaming `lungfish-cli --json-events`.
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
/// launch/pipe-drain/cancel choreography (ARC-02, SIMP-04): `diff
/// CLITreeInferenceRunner.swift CLITreeTransformRunner.swift` showed only 36
/// changed lines out of 297. `CLISubprocessTransport` is that shared
/// implementation. A runner now supplies only argv, an `OperationType`, and
/// small `CLIEvent -> OperationCenter` glue (how to interpret `.complete`'s
/// outputs, what failure text to show).
///
/// Cancellation mirrors the pre-existing per-runner contract exercised by
/// `CLIEventRunnerCancellationTests`: `cancel()` is `nonisolated` and returns
/// immediately (it only signals `NativeProcessCancellationHandle`), never
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
    private let cancellationHandle = NativeProcessCancellationHandle()
    private let eventDecoder = CLIEventLineDecoder()

    public init(cliURLOverride: URL? = nil) {
        self.cliURLOverride = cliURLOverride
    }

    /// Signals process-tree termination. Safe to call from any thread; never
    /// blocks on `run`'s actor isolation.
    public nonisolated func cancel() {
        cancellationHandle.requestProcessTreeTermination(gracePeriod: 0)
    }

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

        let proc = Process()
        proc.environment = ManagedStorageConfigStore().subprocessEnvironment()
        proc.executableURL = binaryURL
        proc.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        cancellationHandle.store(proc)

        final class StreamState: @unchecked Sendable {
            var stdoutBuffer = Data()
            var stderrBuffer = Data()
            var outputs: [String] = []
            var completeMessage: String?
            var failed: (message: String, detail: String?)?
        }

        let state = OSAllocatedUnfairLock(initialState: StreamState())
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let stdoutHandlerGroup = DispatchGroup()
        let stderrHandlerGroup = DispatchGroup()
        let decoder = eventDecoder

        @Sendable func handleLine(_ data: Data) {
            guard let line = String(data: data, encoding: .utf8),
                  !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

        @Sendable func consumeStdout(_ data: Data) {
            guard !data.isEmpty else { return }
            let lines = state.withLock { current -> [Data] in
                current.stdoutBuffer.append(data)
                var parsed: [Data] = []
                while let newlineIndex = current.stdoutBuffer.firstIndex(of: 0x0A) {
                    let line = Data(current.stdoutBuffer.prefix(upTo: newlineIndex))
                    current.stdoutBuffer.removeSubrange(...newlineIndex)
                    parsed.append(line)
                }
                return parsed
            }
            for line in lines {
                handleLine(line)
            }
        }

        @Sendable func consumeStderr(_ data: Data) {
            guard !data.isEmpty else { return }
            state.withLock { $0.stderrBuffer.append(data) }
        }

        func drainStreamHandlers() {
            stdoutHandlerGroup.wait()
            stderrHandlerGroup.wait()
        }

        stdoutHandle.readabilityHandler = { handle in
            stdoutHandlerGroup.enter()
            defer { stdoutHandlerGroup.leave() }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            consumeStdout(chunk)
        }
        stderrHandle.readabilityHandler = { handle in
            stderrHandlerGroup.enter()
            defer { stderrHandlerGroup.leave() }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            consumeStderr(chunk)
        }

        do {
            try proc.run()
            cancellationHandle.terminateIfRequested()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            drainStreamHandlers()
            cancellationHandle.clear(proc)
            throw RunError.launchFailed(error.localizedDescription)
        }

        proc.waitUntilExit()
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        drainStreamHandlers()
        consumeStdout(stdoutHandle.readDataToEndOfFile())
        consumeStderr(stderrHandle.readDataToEndOfFile())
        drainStreamHandlers()
        if let trailing = state.withLock({ current -> Data? in
            guard !current.stdoutBuffer.isEmpty else { return nil }
            defer { current.stdoutBuffer.removeAll(keepingCapacity: false) }
            return current.stdoutBuffer
        }) {
            handleLine(trailing)
        }
        let processWasCancelled = cancellationHandle.isTerminationRequested
        cancellationHandle.clear(proc)

        let snapshot = state.withLock { current in
            (
                stderr: String(data: current.stderrBuffer, encoding: .utf8) ?? "",
                outputs: current.outputs,
                completeMessage: current.completeMessage,
                failed: current.failed
            )
        }

        let operationCancelled = await isCancelled()
        if processWasCancelled || operationCancelled {
            throw CancellationError()
        }
        if let failed = snapshot.failed {
            throw RunError.failedEvent(message: failed.message, detail: failed.detail)
        }
        if proc.terminationStatus != 0 {
            throw RunError.nonZeroExit(status: proc.terminationStatus, stderr: snapshot.stderr)
        }
        guard !snapshot.outputs.isEmpty else {
            throw RunError.missingCompletion
        }

        return Result(outputs: snapshot.outputs, message: snapshot.completeMessage)
    }
}
