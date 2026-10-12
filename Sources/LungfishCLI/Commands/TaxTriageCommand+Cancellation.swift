// TaxTriageCommand+Cancellation.swift - SIGTERM cancels `taxtriage run` and its pipeline
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation

extension TaxTriageCommand.RunSubcommand {
    /// Runs the command so that SIGTERM cancels the pipeline instead of ending this process.
    ///
    /// The window's Cancel sends SIGTERM to `lungfish-cli`. Without a listener the CLI ended by
    /// the signal, exit 143 in a shell. `CLITerminationSignals` stopped the engine's tree, but the
    /// pipeline's own cancel never ran, so the run left no `cancelled` record, no log and its
    /// scratch behind (SWIFT inventory E8, the R3 run of lane Q15).
    ///
    /// Cancelling the task reaches `TaxTriagePipeline.run`, the cancel the Tools menu route has had
    /// since Phase 2.8 lane S1. It stops the engine's process tree with TERM and then KILL after
    /// its grace, records `cancelled` with exit 125 and removes the launch scratch. This command
    /// then exits 125, `CLIExitCode.cancelled`, after it writes "TaxTriage cancelled" to stderr.
    ///
    /// Like `workflow run`, the command listens before the task starts, so a SIGTERM caught before
    /// then cancels the task as soon as it exists, and a second SIGTERM ends the command at once.
    /// The executor's own `cancelled` record belongs to the executor lane (S2), not to this scope.
    func runCancellingOnSIGTERM() async throws {
        let pendingCancel = PendingTaskCancel<(any Error)?>()
        let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
        defer { termination.end() }
        let task = Task { () -> (any Error)? in
            do {
                try await self.execute()
                return nil
            } catch {
                return error
            }
        }
        pendingCancel.attach(task)
        guard let error = await task.value else { return }
        guard error is CancellationError else { throw error }
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        if !globalOptions.quiet {
            // The progress line has no line break yet.
            print("")
        }
        FileHandle.standardError.write(Data((formatter.error("TaxTriage cancelled") + "\n").utf8))
        throw CLIExitCode.cancelled.exitCode
    }
}
