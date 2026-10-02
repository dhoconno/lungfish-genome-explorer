// AnnotationTableDrawerView+OperationBegin.swift - Operations panel registration for stored variant edits
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

/// The begin helper for the drawer's stored variant edits (finding R4), kept
/// out of the baselined AnnotationTableDrawerView.swift so that file does not
/// grow (scripts/ratchets/file-size.sh). It registers the row through
/// `OperationReporting` and calls `launch` only when the row started, so a
/// test can check the row, its lock and its command without touching
/// `OperationCenter.shared`.
extension AnnotationTableDrawerView {
    /// Registers the stored variant edit row and, only when it starts, calls
    /// `launch` with the operation ID. The row locks `bundleURL` and records
    /// no command. `title` names the edit, for example "Variant deletion".
    ///
    /// CLI parity gap. No lungfish-cli command edits the variants stored in a
    /// bundle, whether it deletes them or imports sample metadata for them.
    /// The closest is `variants query`, which only reads them. The row keeps
    /// recording no command until an edit command exists.
    @discardableResult
    static func beginVariantStorageMutationOperation(
        title: String,
        bundleURL: URL,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: title,
            detail: "Updating stored data and provenance",
            operationType: .workflow,
            targetBundleURL: bundleURL,
            cliCommand: nil,
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }
}
