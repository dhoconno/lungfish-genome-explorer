// CLIBundleBuildRunner.swift - Runs a lungfish-cli command that builds a new bundle through CLISubprocessTransport for the app's row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// Runs one `lungfish-cli` command that builds a new bundle (Phase 2.10 family L2, plan decision C5),
/// such as `extract sequence --bundle` for the viewer's region extraction (Phase 2.11 lane A48), for
/// the app's Operations row.
///
/// The command stages the bundle, publishes it under its final name with one rename and writes its
/// record, and the app writes nothing after it exits. `OperationCenterCLIBridge` shows the
/// command's events on the row. The caller completes or fails the row with today's words, from the
/// command's `complete` message or the error this throws, and then shows the bundle. A cancel goes
/// through the transport. The command gets SIGTERM and ``terminationGracePeriod`` to stop before it
/// publishes, record the run as cancelled and exit 125 before SIGKILL, inside the ten seconds
/// `OperationCenter` waits for a cancelling row, and the runner acknowledges the cancel on the row.
/// The command turns SIGTERM into a cancel, so a run that still exits 0 with its `complete` line had
/// published first, and the runner returns that result.
///
/// Make one runner for each run. The runner never starts a `Process` of its own.
struct CLIBundleBuildRunner: Sendable {
    /// The time the command has between SIGTERM and SIGKILL, the launcher's
    /// ``CLIProcessLauncher/operationGrace``.
    static let terminationGracePeriod = CLIProcessLauncher.operationGrace
    /// How long the run waits for a descendant that holds the command's output open after the
    /// command exited, the launcher's ``CLIProcessLauncher/operationDrain``.
    static let drainGracePeriod = CLIProcessLauncher.operationDrain

    private let transport: CLISubprocessTransport

    /// - Parameter cliURLOverride: The `lungfish-cli` to run, for a test. Nil finds the bundled one.
    init(cliURLOverride: URL? = nil) {
        transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
    }

    /// Stops the command, whether it is running or about to start. It returns at once and may be
    /// called from any thread.
    nonisolated func cancel() {
        transport.cancel()
    }

    /// Runs `arguments`, the argv after `lungfish-cli` that the row records, for the row
    /// `operationID`. It runs on the concurrent executor by declaration, whatever isolation the
    /// caller has.
    ///
    /// - Returns: The transport's result, whose `message` is the command's `complete` message and
    ///   whose `outputs` name the bundle it published.
    /// - Parameter environmentAdditions: Variables merged over the app's subprocess environment for
    ///   this run only, such as a test's stand-in conda root. The app passes none.
    /// - Throws: `CancellationError` once the row's cancel is acknowledged, else the transport's
    ///   `RunError`, whose description is the command's `failed` message.
    @concurrent
    func run(
        arguments: [String],
        operationID: UUID,
        environmentAdditions: [String: String] = [:]
    ) async throws -> CLISubprocessTransport.Result {
        do {
            return try await transport.run(
                arguments: arguments,
                terminationGracePeriod: Self.terminationGracePeriod,
                drainGracePeriod: Self.drainGracePeriod,
                environmentAdditions: environmentAdditions,
                completionOutlivesCancel: true,
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
        let runner = CLIBundleBuildRunner(cliURLOverride: cliURLOverride)
        OperationCenter.shared.setCancelCallback(for: operationID) { runner.cancel() }
        return try await runner.run(arguments: arguments, operationID: operationID)
    }
}
