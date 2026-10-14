// CLIManagedToolsRunner.swift - Runs the managed tools and packs commands through CLISubprocessTransport for the app's row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// Runs one `lungfish-cli` command that changes the managed tools, packs or databases (Phase 2.10
/// family L10, panel decisions C10 and C5), for the app's Operations row: `tools update --apply
/// --only`, `conda install --pack [--reinstall]` and `conda db update`.
///
/// The command writes the environments, the registry and their records, and the app writes
/// nothing after it exits. `OperationCenterCLIBridge` shows the command's events on the row. The
/// caller completes or fails the row from the command's `complete` message or the error this
/// throws, and then reloads what it shows. A cancel goes through the transport. The command gets
/// SIGTERM and ``terminationGracePeriod`` to put back what it moved aside and leave the installed
/// copy whole, before SIGKILL, inside the ten seconds `OperationCenter` waits for a cancelling
/// row, and the runner acknowledges the cancel on the row.
struct CLIManagedToolsRunner {
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

    // MARK: - The commands

    /// One command of the family. The row records ``recordedCommand`` and the runner runs
    /// ``argv``, so the two cannot drift apart.
    struct Invocation: Sendable, Equatable {
        /// The words after `lungfish-cli` that name the command, such as `conda db update`.
        let subcommand: String
        let arguments: [String]

        var argv: [String] { subcommand.split(separator: " ").map(String.init) + arguments }
        var recordedCommand: String { OperationCenter.buildCLICommand(subcommand: subcommand, args: arguments) }
    }

    /// `tools update --apply --yes --only <id>...`. The storage root reaches the command through the
    /// transport's environment, as for every route.
    static func updateTools(ids: [String]) -> Invocation {
        Invocation(
            subcommand: "tools update",
            arguments: ["--apply", "--yes"] + ids.flatMap { ["--only", $0] } + ["--format", "json"]
        )
    }

    /// `conda install --pack <id> [--reinstall]`.
    static func installPack(packID: String, reinstall: Bool) -> Invocation {
        Invocation(
            subcommand: "conda install",
            arguments: ["--pack", packID] + (reinstall ? ["--reinstall"] : []) + ["--format", "json"]
        )
    }

    /// `conda db update <catalog id> --yes`.
    static func updateDatabase(catalogID: String) -> Invocation {
        Invocation(subcommand: "conda db update", arguments: [catalogID, "--yes", "--format", "json"])
    }

    /// The items an Update Tools selection names: its environments, its databases and, when
    /// removals are on, the retired environments of the plan, the ids `tools update --only` takes.
    static func itemIDs(of selection: PlanSelection, in plan: ReconciliationPlan) -> [String] {
        var ids = selection.environments.union(selection.databases)
        if selection.includeRemovals { ids.formUnion(plan.removeEnvironments) }
        return ids.sorted()
    }

    // MARK: - Running

    /// Runs `invocation` for the row `operationID`. It runs on the concurrent executor by
    /// declaration, whatever isolation the caller has.
    ///
    /// - Parameters:
    ///   - overlay: Called on the main actor with each progress message the row takes.
    ///   - progress: Called with the fraction and message of each `progress` event, for a caller
    ///     that shows them beside the row.
    /// - Returns: The transport's result, whose `message` is the command's `complete` message.
    /// - Throws: `CancellationError` once the row's cancel is acknowledged, else the transport's
    ///   `RunError`, whose description is the command's `failed` message.
    @concurrent
    func run(
        _ invocation: Invocation,
        operationID: UUID,
        overlay: (@MainActor @Sendable (String) -> Void)? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> CLISubprocessTransport.Result {
        let bridge = OperationCenterCLIBridge.onEvent(operationID: operationID, overlay: overlay)
        do {
            return try await transport.run(
                arguments: invocation.argv,
                terminationGracePeriod: Self.terminationGracePeriod,
                drainGracePeriod: Self.drainGracePeriod,
                isCancelled: { await OperationCenterCLIBridge.isOperationCancelled(operationID) },
                onEvent: { event in
                    bridge(event)
                    if case .progress(let fraction, let message) = event { progress?(fraction, message) }
                }
            )
        } catch is CancellationError {
            await OperationCenterCLIBridge.acknowledgeCancellation(operationID)
            throw CancellationError()
        }
    }

    /// Runs `invocation` for the row `operationID` with the row's Cancel wired to the run.
    @MainActor
    static func launch(
        _ invocation: Invocation,
        operationID: UUID,
        overlay: (@MainActor @Sendable (String) -> Void)? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil,
        cliURLOverride: URL? = nil
    ) async throws -> CLISubprocessTransport.Result {
        let runner = CLIManagedToolsRunner(cliURLOverride: cliURLOverride)
        OperationCenter.shared.setCancelCallback(for: operationID) { runner.cancel() }
        return try await runner.run(invocation, operationID: operationID, overlay: overlay, progress: progress)
    }
}
