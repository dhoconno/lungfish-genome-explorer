// CLIBundleEditRunner.swift - Runs a lungfish-cli edit of a bundle in place through CLISubprocessTransport for the app's row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// Runs one `lungfish-cli` command that edits a bundle in place (Phase 2.10 family L1, plan
/// decision C5), such as `sequence attach-track`, for the app's Operations row.
///
/// The command writes the bundle's files and their records, and the app writes nothing after it
/// exits. `OperationCenterCLIBridge` shows the command's events on the row. The caller completes
/// or fails the row with today's words, from the command's `complete` message or the error this
/// throws, and then reloads what it shows. A cancel goes through the transport. The command gets
/// SIGTERM and ``terminationGracePeriod`` to leave the bundle as it was before SIGKILL, inside
/// the ten seconds `OperationCenter` waits for a cancelling row, and the runner acknowledges the
/// cancel on the row.
struct CLIBundleEditRunner {
    /// The time the command has between SIGTERM and SIGKILL, the launcher's
    /// ``CLIProcessLauncher/operationGrace``.
    static let terminationGracePeriod = CLIProcessLauncher.operationGrace
    /// How long the run waits for a descendant that holds the command's output open after the
    /// command exited, the launcher's ``CLIProcessLauncher/operationDrain``.
    static let drainGracePeriod = CLIProcessLauncher.operationDrain

    private let transport: CLISubprocessTransport

    init(cliURLOverride: URL? = nil) {
        transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
    }

    /// Stops the command, whether it is running or about to start. It returns at once and may be
    /// called from any thread.
    func cancel() {
        transport.cancel()
    }

    /// Runs `arguments`, the argv after `lungfish-cli` that the row records, for the row
    /// `operationID`. It runs on the concurrent executor by declaration, whatever isolation the
    /// caller has.
    ///
    /// - Returns: The transport's result, whose `message` is the command's `complete` message.
    /// - Throws: `CancellationError` once the row's cancel is acknowledged, else the transport's
    ///   `RunError`, whose description is the command's `failed` message.
    @concurrent
    func run(arguments: [String], operationID: UUID) async throws -> CLISubprocessTransport.Result {
        do {
            return try await transport.run(
                arguments: arguments,
                terminationGracePeriod: Self.terminationGracePeriod,
                drainGracePeriod: Self.drainGracePeriod,
                isCancelled: { await OperationCenterCLIBridge.isOperationCancelled(operationID) },
                onEvent: OperationCenterCLIBridge.onEvent(operationID: operationID)
            )
        } catch is CancellationError {
            await OperationCenterCLIBridge.acknowledgeCancellation(operationID)
            throw CancellationError()
        }
    }

    /// Runs `arguments` for the row `operationID` with the row's Cancel wired to the run.
    @MainActor
    static func launch(
        arguments: [String],
        operationID: UUID,
        cliURLOverride: URL? = nil
    ) async throws -> CLISubprocessTransport.Result {
        let runner = CLIBundleEditRunner(cliURLOverride: cliURLOverride)
        OperationCenter.shared.setCancelCallback(for: operationID) { runner.cancel() }
        return try await runner.run(arguments: arguments, operationID: operationID)
    }
}
