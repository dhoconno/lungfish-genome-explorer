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
/// An events leaf, one that writes `CLIEvent` lines on standard output under `--format json`, runs
/// on ``CLISubprocessTransport`` through ``runEvents(arguments:operationID:)``. A result leaf, which
/// prints one JSON report and no events, as `map --format json` does, runs on `CLIProcessLauncher`
/// with its standard output kept through ``runResult(arguments:operationID:)``, and the route reads
/// what it shows back from disk. Both give the command `operationGrace` between SIGTERM and
/// SIGKILL and `operationDrain` for an output a descendant still holds (decision P2), hand each line
/// of standard error to the row's log at info through ``OperationCenterCLIBridge``, and stop on the
/// nonisolated ``cancel()``. The runner never starts a `Process` of its own.
///
/// Make one runner for each run. A cancel that comes between two runs stops the next one before
/// it launches (`CLIRunCancellation`), so a batch route stops its own loop, as `runManagedMapping`
/// does through `cancelBatch`, and gives each child a new runner. A cancel the row takes after
/// the command exited 0 still throws `CancellationError`, as `CLISubprocessTransport` does, so a
/// route removes nothing the command finished before it reads the command's record.
struct CLIReadsRunner: Sendable {
    enum RunError: Error, LocalizedError, Equatable {
        case cliNotFound
        case launchFailed(String)
        case failed(status: Int32, detail: String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return CLISubprocessTransport.RunError.cliNotFound.errorDescription
            case .launchFailed(let reason):
                return CLISubprocessTransport.RunError.launchFailed(reason).errorDescription
            case .failed(let status, let detail):
                return CLISubprocessTransport.RunError.nonZeroExit(status: status, stderr: detail).errorDescription
            }
        }
    }

    private let cliURLOverride: URL?
    private let transport: CLISubprocessTransport
    private let cancellation = CLIRunCancellation()

    /// - Parameter cliURLOverride: The `lungfish-cli` to run, for a test. Nil finds the bundled one.
    init(cliURLOverride: URL? = nil) {
        self.cliURLOverride = cliURLOverride
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

    /// Runs a result leaf with `arguments`, the full argv after the binary, and returns its standard
    /// output once it exits 0. A cancel, including exit 125, throws `CancellationError`, and any
    /// other end throws ``RunError`` with the end of the command's standard error.
    func runResult(arguments: [String], operationID: UUID) async throws -> String {
        if await OperationCenterCLIBridge.isOperationCancelled(operationID) {
            throw CancellationError()
        }
        guard let binaryURL = cliURLOverride ?? CLIBinaryLocator.cliBinaryPath() else {
            throw RunError.cliNotFound
        }
        let onEvent = OperationCenterCLIBridge.onEvent(operationID: operationID)
        let outcome = await CLIProcessLauncher.run(
            CLIProcessLauncher.spec(
                executableURL: binaryURL,
                arguments: arguments,
                standardOutput: .captured,
                terminationGracePeriod: CLIProcessLauncher.operationGrace,
                drainGracePeriod: CLIProcessLauncher.operationDrain
            ),
            cancellation: cancellation,
            onStderrLine: { line in
                // Standard error is human text, logged at info and never a warning (2.6 S16).
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                onEvent(.log(level: .info, message: line))
            }
        )
        switch outcome {
        case .cancelled:
            throw CancellationError()
        case .launchFailed(let reason):
            throw RunError.launchFailed(reason)
        case .exited(let exit):
            // 125 is `CLIExitCode.cancelled`, the exit of a command that converted SIGTERM (2.7 E5).
            let rowCancelled = await OperationCenterCLIBridge.isOperationCancelled(operationID)
            if exit.status == 125 || rowCancelled {
                throw CancellationError()
            }
            guard exit.succeeded else {
                throw RunError.failed(status: exit.status, detail: exit.failureDetail)
            }
            return exit.stdout
        }
    }

    /// Stops the run, whether it is running or about to start. Safe from any thread, and it never
    /// waits for the command.
    nonisolated func cancel() {
        transport.cancel()
        cancellation.cancel()
    }
}
