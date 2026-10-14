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
/// runs on ``CLISubprocessTransport`` through ``runEvents(arguments:operationID:)``. The runner gives
/// the command `operationGrace` between SIGTERM and SIGKILL and `operationDrain` for an output a
/// descendant still holds (decision P2), hands each event and each line of standard error to the
/// row through ``OperationCenterCLIBridge``, and stops on the nonisolated ``cancel()``. The runner
/// never starts a `Process` of its own. `map` was a result leaf with a second launch path here
/// until lane A46's M2 turned it into an events leaf.
///
/// Make one runner for each run. A cancel that comes between two runs stops the next one before
/// it launches (`CLIRunCancellation`), so a batch route stops its own loop, as `runManagedMapping`
/// does through `cancelBatch`, and gives each child a new runner. A cancel the row takes after
/// the command exited 0 still throws `CancellationError`, as `CLISubprocessTransport` does, so a
/// route removes nothing the command finished before it reads the command's record.
struct CLIReadsRunner: Sendable {
    private let transport: CLISubprocessTransport

    /// - Parameter cliURLOverride: The `lungfish-cli` to run, for a test. Nil finds the bundled one.
    init(cliURLOverride: URL? = nil) {
        self.transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
    }

    /// Runs an events leaf with `arguments`, the full argv after the binary, and returns what its
    /// `complete` event named. A `failed` event or a non-zero exit throws, and a cancel throws
    /// `CancellationError`.
    func runEvents(arguments: [String], operationID: UUID) async throws -> CLISubprocessTransport.Result {
        try await transport.run(
            arguments: arguments,
            terminationGracePeriod: CLIProcessLauncher.operationGrace,
            drainGracePeriod: CLIProcessLauncher.operationDrain,
            isCancelled: { await OperationCenterCLIBridge.isOperationCancelled(operationID) },
            onEvent: OperationCenterCLIBridge.onEvent(operationID: operationID)
        )
    }

    /// Stops the run, whether it is running or about to start. Safe from any thread, and it never
    /// waits for the command.
    nonisolated func cancel() {
        transport.cancel()
    }
}
