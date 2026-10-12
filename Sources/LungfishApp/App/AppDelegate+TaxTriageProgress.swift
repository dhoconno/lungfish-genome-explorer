// AppDelegate+TaxTriageProgress.swift - How the TaxTriage row and the viewer's overlay show what the engine reports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

extension AppDelegate {
    /// Shows a progress message of a TaxTriage run in its row, shows it on the viewer's overlay only
    /// when the row takes it, and logs it once.
    ///
    /// The row takes a message only while it runs, so a message that arrives once the row is
    /// cancelling, such as an engine line or a reading of `trace.txt` inside the grace of a cancel,
    /// leaves the bar, the detail and the overlay as they are (Phase 2.9 UX inventory T2). The log
    /// keeps it, as ``logTaxTriageProgress(_:for:)`` says.
    static func showTaxTriageProgress(
        _ progress: Double,
        _ message: String,
        for operationID: UUID,
        on viewer: ViewerViewController
    ) {
        if OperationCenter.shared.update(id: operationID, progress: max(0, min(1, progress)), detail: message) {
            viewer.showProgress(message)
        }
        logTaxTriageProgress(message, for: operationID)
    }

    /// Shows the row's own `Cancelling...` on the viewer's overlay once a cancel has moved the row
    /// there, so the overlay reads what the row reads through the grace of the cancel (UX 4).
    ///
    /// The row's cancel callback calls it off the main actor before it cancels the run's task, so
    /// the overlay changes before any message the cancel causes. It shows nothing when the row has
    /// already left Cancelling, because the run's end has then hidden the overlay.
    nonisolated static func showTaxTriageCancelling(for operationID: UUID, on viewer: ViewerViewController) {
        Task { @MainActor in
            guard let row = OperationCenter.shared.items.first(where: { $0.id == operationID }),
                  row.state == .cancelling else { return }
            viewer.showProgress(row.detail)
        }
    }

    /// Logs a progress message of a TaxTriage run unless the row's log already ends with it.
    ///
    /// The engine's reader words each task line `Running <process> (<tag>)` (Phase 2.9 decision W1)
    /// and reports each reading of `trace.txt` that moves the bar with the task line the row already
    /// shows (W2), so a run sends one message several times in a row. The log keeps it once. A message
    /// that differs from the last entry is logged as before, also once the row has stopped running.
    static func logTaxTriageProgress(_ message: String, for operationID: UUID) {
        let last = OperationCenter.shared.items.first { $0.id == operationID }?.logEntries.last
        guard last?.message != message || last?.level != .info else { return }
        OperationCenter.shared.log(id: operationID, level: .info, message: message)
    }
}
