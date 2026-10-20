// OperationCenterCLIBridge.swift — Maps CLIEvent onto an OperationCenter item.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// Bridges a ``CLISubprocessTransport`` run onto an `OperationCenter` item.
///
/// This is the one place that turns a decoded `CLIEvent` into
/// `OperationCenter.shared.update`/`.log` calls, replacing the per-runner
/// `handleLine`/`DispatchQueue.main.async { MainActor.assumeIsolated { ... } }`
/// switch that used to live in each of the nine `CLI*Runner` types.
///
/// `.complete` and `.failed` are intentionally not handled here: the
/// transport folds those into its return value / thrown error so the caller
/// (which knows what the outputs mean — a tree bundle, an import manifest,
/// …) records completion itself via `OperationCenter.shared.complete(...)`.
/// The caller completes with paths from `outputs` only. Typed artifacts
/// describe them and are never imported on their own.
///
/// ## The row rule (Phase 2.10 decision W2)
///
/// Every route that runs `lungfish-cli` reads its events through this one rule, so a
/// row behaves alike on all of them. `docs/contracts/ADDING-AN-OPERATION.md` states it
/// in "What a CLI route's row shows".
///
/// - A `progress` event sets the row's detail to its message. The bar is held. It moves
///   to the event's fraction only when that is higher than the bar, so a lower fraction
///   after a higher one leaves the bar alone. A `start` event holds the bar the same way.
///   The bar is the row's `progress` value. The panel does not draw it, since it draws a bar only for progress evidence.
///   An empty message changes the bar only.
/// - A progress message is logged at info once. It is not logged when the row's log
///   already ends with it at info, so a command that repeats a line, or a reader that
///   sends one line for each reading of a file, adds one entry. A route that sends a
///   step as a progress event and then as a log event with the same words gets one
///   entry for the pair. The log keeps a message that arrives once the row no longer
///   runs, as the row refuses its bar and detail.
/// - The optional `overlay` closure gets each non-empty progress message the row takes,
///   on the main actor and only while the row runs. A route that shows the message in
///   the viewer's progress overlay passes one. A message that arrives once a cancel has
///   moved the row to Cancelling reaches neither the row nor the overlay.
/// - A log event is logged at its own level. Plain standard error stays in the
///   operation log at info level. The transport hands each line over as an info
///   `.log` event, so text such as "warning: ..." on standard error never makes a run
///   Completed with Warnings. Under today's rules only a `log` event at level
///   `warning` or a producer's `completeWithWarning` does (S16).
///   `OperationCenterCLIBridgeTests` holds one test for each label a run can end on.
///
/// Each event takes one hop to the main queue, in the order the transport delivers it,
/// and the bridge reads and writes the bar, the detail and the log inside that hop. The
/// state of a run lives in one main-actor object, so no event reads a bar that another
/// event can change before it writes.
public enum OperationCenterCLIBridge {
    /// Suitable as the `onEvent` closure passed to `CLISubprocessTransport.run`.
    ///
    /// - Parameter overlay: Called on the main actor with each non-empty progress message the
    ///   row takes, in arrival order, only while the row runs. Nil for a route with no overlay.
    public static func onEvent(
        operationID: UUID,
        overlay: (@MainActor @Sendable (String) -> Void)? = nil
    ) -> @Sendable (CLIEvent) -> Void {
        let run = RowEvents(operationID: operationID, overlay: overlay)
        return { event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    run.apply(event)
                }
            }
        }
    }

    /// True when the operation's own row has moved to cancelling/cancelled,
    /// independent of whether `cancel()` was called directly on the runner —
    /// mirrors the previous per-runner `isOperationCancelled` check.
    @MainActor
    public static func isOperationCancelled(_ id: UUID) -> Bool {
        let state = OperationCenter.shared.items.first { $0.id == id }?.state
        return state == .cancelling || state == .cancelled
    }

    @MainActor
    public static func failOperation(_ id: UUID, detail: String?, fallbackMessage: String) {
        let message = detail ?? fallbackMessage
        guard OperationCenter.shared.items.first(where: { $0.id == id })?.state != .cancelled else {
            return
        }
        _ = OperationCenter.shared.fail(id: id, detail: message, errorMessage: message)
    }

    @MainActor
    public static func acknowledgeCancellation(_ id: UUID) {
        OperationCenter.shared.acknowledgeCancellation(id: id)
    }

    /// Marks an operation complete with the given bundle output. Callers
    /// await this directly from a non-isolated async context; `@MainActor`
    /// isolation handles the actor hop without an explicit `MainActor.run`.
    @MainActor
    public static func completeOperation(_ id: UUID, detail: String, bundleURLs: [URL]) {
        _ = OperationCenter.shared.complete(id: id, detail: detail, bundleURLs: bundleURLs)
    }

    /// Marks an operation complete with loose (non-bundle) output files. Only ``CLIViewerExportRunner`` passes
    /// `committed`, once its leaf exited 0 with file and record written, so a Cancel that reached the row after that
    /// commit settles it Completed with its links and the detail `Finished before Cancel took effect` (Phase 2.13
    /// M842). Every other caller keeps the rule that a cancelling row settles Cancelled by user.
    @MainActor
    public static func completeOperation(_ id: UUID, detail: String, outputURLs: [URL], committed: Bool = false) {
        _ = OperationCenter.shared.complete(id: id, detail: detail, outputURLs: outputURLs, committed: committed)
    }
}

/// What the bridge does to one row for the events of one run, in one isolation domain.
@MainActor
private final class RowEvents {
    private let operationID: UUID
    private let overlay: (@MainActor @Sendable (String) -> Void)?
    /// The progress message the previous event logged, while no other event has come since. A
    /// log event with the same words right after it is the same step, which the log already holds.
    private var loggedProgressLine: String?

    nonisolated init(operationID: UUID, overlay: (@MainActor @Sendable (String) -> Void)?) {
        self.operationID = operationID
        self.overlay = overlay
    }

    func apply(_ event: CLIEvent) {
        let justLogged = loggedProgressLine
        loggedProgressLine = nil
        switch event {
        case let .start(message):
            guard !message.isEmpty else { return }
            OperationCenter.shared.log(id: operationID, level: .info, message: message)
            _ = showProgress(fraction: 0, message: message)
        case let .progress(fraction, message):
            let tookIt = showProgress(fraction: fraction, message: message)
            guard !message.isEmpty else { return }
            if tookIt { overlay?(message) }
            logProgress(message)
        case let .log(level, message):
            // The same step as the progress event before it, which logged these words already.
            if level == .info, message == justLogged { return }
            OperationCenter.shared.log(id: operationID, level: level.operationLogLevel, message: message)
        case .output:
            break
        case .complete, .failed:
            // Handled by the transport's return value / thrown error.
            break
        }
    }

    /// Sets the row's detail to `message`, or leaves it alone for an empty one, and moves the bar to
    /// `fraction` only when that is higher than the bar. Returns whether the row took the update, which
    /// it does only while it runs.
    private func showProgress(fraction: Double, message: String) -> Bool {
        guard let row = OperationCenter.shared.items.first(where: { $0.id == operationID }) else { return false }
        let held = max(row.progress, min(max(fraction, 0), 1))
        return OperationCenter.shared.update(
            id: operationID,
            progress: held,
            detail: message.isEmpty ? row.detail : message
        )
    }

    /// Logs a progress message at info unless the row's log already ends with it. The log keeps a
    /// message the row refused because it no longer runs.
    private func logProgress(_ message: String) {
        let last = OperationCenter.shared.items.first { $0.id == operationID }?.logEntries.last
        guard last?.message != message || last?.level != .info else { return }
        OperationCenter.shared.log(id: operationID, level: .info, message: message)
        loggedProgressLine = message
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
