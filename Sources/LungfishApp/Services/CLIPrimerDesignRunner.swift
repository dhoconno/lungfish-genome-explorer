// CLIPrimerDesignRunner.swift - Runs lungfish-cli primers design through CLISubprocessTransport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow

/// Runs the `lungfish-cli primers design <engine>` command the PCR Primer Design dialog builds, for Primer3,
/// PrimalScheme3 and varVAMP (Phase 2.12 lane 12.17 M2, Q-A7, rule 9 and the recipe of a CLI route in
/// `docs/contracts/ADDING-AN-OPERATION.md`). Olivar stays in process until its bundle replay (2.13 row A67-OLIVAR).
///
/// The runner starts no `Process`. It runs the command on `CLISubprocessTransport` with `--format json` and hands each
/// event to `OperationCenterCLIBridge`, so the row shows the command's progress messages, which are the words the
/// in-process row showed, and logs each line of the native tool at info. A cancel sends the command SIGTERM and gives
/// it ``terminationGracePeriod`` to stop its tool and exit 125 before SIGKILL. The command publishes the bundle and
/// every record of the run before it exits, so the app writes nothing after the exit.
struct CLIPrimerDesignRunner {
    /// The time the command has between SIGTERM and SIGKILL, the launcher's ``CLIProcessLauncher/operationGrace``.
    static let terminationGracePeriod = CLIProcessLauncher.operationGrace
    /// How long the run waits for a descendant that holds the command's output open after the command exited, the
    /// launcher's ``CLIProcessLauncher/operationDrain``.
    static let drainGracePeriod = CLIProcessLauncher.operationDrain

    private let transport: CLISubprocessTransport
    private let environment: [String: String]

    /// - Parameters:
    ///   - cliURLOverride: The CLI to run, nil for the app's own.
    ///   - environment: Variables merged over the app's subprocess environment, empty in the app.
    init(cliURLOverride: URL? = nil, environment: [String: String] = [:]) {
        self.transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
        self.environment = environment
    }

    /// The arguments the transport runs for `argv`, the recorded command's words with the executable name first. They
    /// are the words after the executable and then `--format json`, which the command leaves out of its own record.
    static func arguments(argv: [String]) -> [String] {
        Array(argv.dropFirst()) + ["--format", "json"]
    }

    /// Runs the command and returns the bundle its complete event names. The row of `operationID` takes the events.
    func run(arguments: [String], operationID: UUID) async throws -> URL {
        let result = try await transport.run(
            arguments: arguments,
            terminationGracePeriod: Self.terminationGracePeriod,
            drainGracePeriod: Self.drainGracePeriod,
            environmentAdditions: environment,
            isCancelled: { await OperationCenterCLIBridge.isOperationCancelled(operationID) },
            onEvent: OperationCenterCLIBridge.onEvent(operationID: operationID)
        )
        guard let path = result.outputs.first, !path.isEmpty else {
            throw CLISubprocessTransport.RunError.missingCompletion
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Stops the command, whether it is running or about to start. It returns at once, from any thread.
    nonisolated func cancel() {
        transport.cancel()
    }

    /// Whether `error` is the command's refusal of a destination that exists. The dialog refuses a name in use before
    /// Run, and the recorded command names `--project`, which writes the first free name (Phase 2.13 lane 13.43), so
    /// only a command that names `--output` can meet a bundle that appeared between that check and the launch. A
    /// refusal exits 3 with its failed event, and no other failure leaves a bundle at the destination. The alert words
    /// stay as the UX ruling on lane 12.17 set them.
    static func refusedAnExistingDestination(_ error: any Error, destination: URL) -> Bool {
        switch error as? CLISubprocessTransport.RunError {
        case .nonZeroExit(status: 3, _)?, .failedEvent?:
            return (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil
        default:
            return false
        }
    }
}
