// CLITreeRunner.swift — Runs `lungfish-cli tree infer`/`tree reroot`/etc. through CLISubprocessTransport.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow

/// Replaces `CLITreeInferenceRunner` and `CLITreeTransformRunner`, which were
/// 297-line files differing only in six string literals
/// (`diff` showed 36 changed lines out of 297). Both launched IQ-TREE
/// inference or a tree transform (reroot / extract-subtree / relabel) as a
/// `lungfish-cli tree ...` subprocess and hand-rolled their own `Process`,
/// pipe draining, and event parsing.
///
/// `CLITreeRunner` keeps exactly the same call-site contract (`run(arguments:operationID:)`,
/// `cancel()`) so `ViewerViewController` needs only a rename, but delegates
/// all subprocess/event plumbing to `CLISubprocessTransport` (LungfishKit)
/// decoding the shared `CLIEvent` schema (LungfishWorkflow) instead of a
/// private per-runner JSON shape.
struct CLITreeRunner {
    enum RunError: Error, LocalizedError, Equatable {
        case underlying(String)

        var errorDescription: String? { message }

        private var message: String {
            switch self {
            case let .underlying(message): return message
            }
        }
    }

    struct Result: Sendable, Equatable {
        let bundleURL: URL
    }

    /// Human-readable label used only for the fallback failure message when
    /// the CLI process exits without a `.failed` event (e.g. a crash).
    let label: String
    private let transport: CLISubprocessTransport

    /// The time the command has between SIGTERM and SIGKILL to stop IQ-TREE, remove its staging folder
    /// and record its run as cancelled, the launcher's ``CLIProcessLauncher/operationGrace`` (Phase 2.11
    /// lane S61). Tree inference and the three tree transforms all convert SIGTERM into a cancel.
    static let terminationGracePeriod = CLIProcessLauncher.operationGrace
    /// How long the run waits for a descendant that holds the command's output open after the
    /// command exited, the launcher's ``CLIProcessLauncher/operationDrain``.
    static let drainGracePeriod = CLIProcessLauncher.operationDrain

    init(label: String, cliURLOverride: URL? = nil) {
        self.label = label
        self.transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
    }

    func run(arguments: [String], operationID: UUID) async throws -> Result {
        do {
            let result = try await transport.run(
                arguments: arguments,
                terminationGracePeriod: Self.terminationGracePeriod,
                drainGracePeriod: Self.drainGracePeriod,
                isCancelled: { await OperationCenterCLIBridge.isOperationCancelled(operationID) },
                onEvent: OperationCenterCLIBridge.onEvent(operationID: operationID)
            )
            guard let outputPath = result.outputs.first,
                  !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                let message = "lungfish-cli finished without reporting a \(label) bundle."
                await OperationCenterCLIBridge.failOperation(operationID, detail: message, fallbackMessage: message)
                throw RunError.underlying(message)
            }
            let bundleURL = URL(fileURLWithPath: outputPath, isDirectory: true)
            await OperationCenterCLIBridge.completeOperation(
                operationID,
                detail: "\(label.capitalizedFirstLetter) complete",
                bundleURLs: [bundleURL]
            )
            return Result(bundleURL: bundleURL)
        } catch is CancellationError {
            await OperationCenterCLIBridge.acknowledgeCancellation(operationID)
            throw CancellationError()
        } catch let error as CLISubprocessTransport.RunError {
            let message = error.errorDescription ?? "\(label.capitalizedFirstLetter) failed"
            await OperationCenterCLIBridge.failOperation(operationID, detail: message, fallbackMessage: message)
            throw RunError.underlying(message)
        }
    }

    /// Stops the command, whether it is running or about to start. It returns at once, from any thread.
    nonisolated func cancel() {
        transport.cancel()
    }
}

private extension String {
    var capitalizedFirstLetter: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
