// AppDelegate+TaxTriageProgress.swift - How the TaxTriage row logs what the engine's reader reports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

extension AppDelegate {
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
