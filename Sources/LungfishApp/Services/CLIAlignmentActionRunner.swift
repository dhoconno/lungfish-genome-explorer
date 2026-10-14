// CLIAlignmentActionRunner.swift - Runs the L3 alignment action leaves of lungfish-cli for the app
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow

/// The runner of the L3 alignment actions, family L3 of Phase 2.10 (lanes A51 and A54, decision C5).
///
/// It runs one `lungfish-cli` leaf, such as `bam remove-track`, on `CLISubprocessTransport` with
/// `CLIProcessLauncher.operationGrace` between SIGTERM and SIGKILL and `operationDrain` for the
/// output, so a leaf that turns SIGTERM into a cancel records it before it exits (P2). The leaf's
/// events reach the row through `OperationCenterCLIBridge` in the order they arrive. It starts no
/// process of its own and writes nothing, because the leaf wrote every file before it exited.
struct CLIAlignmentActionRunner: Sendable {
    /// What the leaf's `complete` line named.
    struct Completion: Sendable, Equatable {
        let outputs: [String]
        let message: String?
    }

    static let terminationGracePeriod = CLIProcessLauncher.operationGrace
    static let drainGracePeriod = CLIProcessLauncher.operationDrain

    private let transport: CLISubprocessTransport

    init(cliURLOverride: URL? = nil) {
        transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
    }

    /// Runs `arguments`, the argv after the binary, for the row `operationID`, in
    /// `workingDirectory` when one is given, where a relative `--output` resolves. It throws
    /// `CancellationError` when the row was cancelled and `CLISubprocessTransport.RunError` when the
    /// leaf failed, whose description is the leaf's own failure message.
    func run(arguments: [String], operationID: UUID, workingDirectory: URL? = nil) async throws -> Completion {
        let result = try await transport.run(
            arguments: arguments,
            terminationGracePeriod: Self.terminationGracePeriod,
            drainGracePeriod: Self.drainGracePeriod,
            isCancelled: { await OperationCenterCLIBridge.isOperationCancelled(operationID) },
            onEvent: OperationCenterCLIBridge.onEvent(operationID: operationID),
            workingDirectory: workingDirectory
        )
        return Completion(outputs: result.outputs, message: result.message)
    }

    /// Cancels the run from any thread. The leaf gets SIGTERM and the grace to record its cancel.
    nonisolated func cancel() {
        transport.cancel()
    }
}
