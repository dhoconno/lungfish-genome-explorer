// CLIReadsRunner.swift - The L6 family's runner: map, assemble and the FASTQ ingest leaves on lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow

/// Runs one command of the L6 family (mapping, assembly and FASTQ ingest) for its row, the family
/// runner of decision C5 in Phase 2.10.
///
/// Each leaf of the family writes `CLIEvent` lines on standard output under `--format json` and
/// runs on ``CLISubprocessTransport`` through ``runEvents(arguments:operationID:startAsLog:)``. The runner gives
/// the command `operationGrace` between SIGTERM and SIGKILL and `operationDrain` for an output a
/// descendant still holds (decision P2), hands each event and each line of standard error to the
/// row through ``OperationCenterCLIBridge``, and stops on the nonisolated ``cancel()``. The runner
/// never starts a `Process` of its own. `map` was a result leaf with a second launch path here
/// until lane A46's M2 turned it into an events leaf.
///
/// Make one runner for each run. A cancel that comes between two runs stops the next one before
/// it launches (`CLIRunCancellation`), so a batch route stops its own loop, as `runManagedMapping`
/// does through `cancelBatch`, and gives each child a new runner. A run whose command exited 0
/// with its `complete` line returns its result even after a late cancel. `OperationCenter.complete`
/// ends the row cancelled, and the route keeps the result.
struct CLIReadsRunner: Sendable {
    private let transport: CLISubprocessTransport

    /// - Parameter cliURLOverride: The `lungfish-cli` to run, for a test. Nil finds the bundled one.
    init(cliURLOverride: URL? = nil) {
        self.transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
    }

    /// Runs an events leaf with `arguments`, the full argv after the binary, and returns what its
    /// `complete` event named. A `failed` event or a non-zero exit throws, and a cancel throws
    /// `CancellationError`.
    ///
    /// With `startAsLog` the command's `start` line reaches the row as an info log, so the row keeps
    /// the first detail its begin helper showed (`ADDING-AN-OPERATION.md`, title and first detail).
    /// Assembly passes it, since its in-process row never showed the `start` words (BIO's ruling D4
    /// on Phase 2.10 lane A46 M3).
    func runEvents(arguments: [String], operationID: UUID, startAsLog: Bool = false) async throws -> CLISubprocessTransport.Result {
        let toRow = OperationCenterCLIBridge.onEvent(operationID: operationID)
        return try await transport.run(
            arguments: arguments,
            terminationGracePeriod: CLIProcessLauncher.operationGrace,
            drainGracePeriod: CLIProcessLauncher.operationDrain,
            completionOutlivesCancel: true,
            isCancelled: { await OperationCenterCLIBridge.isOperationCancelled(operationID) },
            onEvent: { event in
                if startAsLog, case let .start(message) = event {
                    toRow(.log(level: .info, message: message))
                } else {
                    toRow(event)
                }
            }
        )
    }

    /// Stops the run, whether it is running or about to start. Safe from any thread, and it never
    /// waits for the command.
    nonisolated func cancel() {
        transport.cancel()
    }
}
