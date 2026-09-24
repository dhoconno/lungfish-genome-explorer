// OperationCenterCLIBridge.swift — Maps CLIEvent onto an OperationCenter item.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// Bridges a ``CLISubprocessTransport`` run onto an `OperationCenter` item.
///
/// This is the one place that turns a decoded `CLIEvent` into
/// `OperationCenter.shared.update`/`.log` calls, replacing the per-runner
/// `handleLine`/`DispatchQueue.main.async { MainActor.assumeIsolated { ... } }`
/// switch that used to live in each of the nine `CLI*Runner` types (ARC-02).
///
/// `.complete` and `.failed` are intentionally not handled here: the
/// transport folds those into its return value / thrown error so the caller
/// (which knows what the outputs mean — a tree bundle, an import manifest,
/// …) records completion itself via `OperationCenter.shared.complete(...)`.
enum OperationCenterCLIBridge {
    /// Suitable as the `onEvent` closure passed to `CLISubprocessTransport.run`.
    static func onEvent(operationID: UUID) -> @Sendable (CLIEvent) -> Void {
        { event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch event {
                    case let .start(message):
                        OperationCenter.shared.log(id: operationID, level: .info, message: message)
                        _ = OperationCenter.shared.update(id: operationID, progress: 0, detail: message)
                    case let .progress(fraction, message):
                        _ = OperationCenter.shared.update(id: operationID, progress: fraction, detail: message)
                    case let .log(level, message):
                        OperationCenter.shared.log(id: operationID, level: level.operationLogLevel, message: message)
                    case .output:
                        break
                    case .complete, .failed:
                        // Handled by the transport's return value / thrown error.
                        break
                    }
                }
            }
        }
    }

    /// True when the operation's own row has moved to cancelling/cancelled,
    /// independent of whether `cancel()` was called directly on the runner —
    /// mirrors the previous per-runner `isOperationCancelled` check.
    @MainActor
    static func isOperationCancelled(_ id: UUID) -> Bool {
        let state = OperationCenter.shared.items.first { $0.id == id }?.state
        return state == .cancelling || state == .cancelled
    }

    @MainActor
    static func failOperation(_ id: UUID, detail: String?, fallbackMessage: String) {
        let message = detail ?? fallbackMessage
        guard OperationCenter.shared.items.first(where: { $0.id == id })?.state != .cancelled else {
            return
        }
        _ = OperationCenter.shared.fail(id: id, detail: message, errorMessage: message)
    }

    @MainActor
    static func acknowledgeCancellation(_ id: UUID) {
        OperationCenter.shared.acknowledgeCancellation(id: id)
    }

    /// Marks an operation complete with the given bundle output. Callers
    /// await this directly from a non-isolated async context; `@MainActor`
    /// isolation handles the actor hop without an explicit `MainActor.run`.
    @MainActor
    static func completeOperation(_ id: UUID, detail: String, bundleURLs: [URL]) {
        _ = OperationCenter.shared.complete(id: id, detail: detail, bundleURLs: bundleURLs)
    }

    /// Marks an operation complete with loose (non-bundle) output files.
    @MainActor
    static func completeOperation(_ id: UUID, detail: String, outputURLs: [URL]) {
        _ = OperationCenter.shared.complete(id: id, detail: detail, outputURLs: outputURLs)
    }
}

private extension CLIEventLogLevel {
    var operationLogLevel: OperationLogLevel {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }
}
