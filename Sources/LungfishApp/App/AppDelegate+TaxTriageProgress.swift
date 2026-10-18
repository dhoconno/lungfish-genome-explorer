// AppDelegate+TaxTriageProgress.swift - The viewer's overlay of a TaxTriage row that is cancelling
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

extension AppDelegate {
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
}
