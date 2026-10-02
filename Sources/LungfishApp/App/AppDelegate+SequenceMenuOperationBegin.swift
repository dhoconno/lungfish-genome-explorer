// AppDelegate+SequenceMenuOperationBegin.swift - Operations panel registration for Sequence menu launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

/// The begin helpers for the Sequence menu's annotation launches (finding R4).
/// They live here, not beside their launch sites, so the baselined
/// AppDelegate+SequenceMenu.swift does not grow (scripts/ratchets/file-size.sh).
/// Each helper registers its row through `OperationReporting` and calls
/// `launch` only when the row started, so a test can check the row, its lock
/// and its command without touching `OperationCenter.shared`.
extension AppDelegate {
    /// Registers the manual annotation row and, only when it starts, awaits
    /// `launch` with the operation ID. The launch is `async` because the
    /// caller awaits the bundle write inside it. The row locks no bundle and
    /// records no command.
    ///
    /// The write adds an annotation to a reference bundle without declaring a
    /// bundle lock. That is how the site behaved before this migration, and
    /// the helper keeps it. Adding a lock target is a separate decision (Rule 3
    /// in docs/contracts/ADDING-AN-OPERATION.md).
    ///
    /// CLI parity gap. No lungfish-cli command adds an annotation to a
    /// bundle. The closest is `sequence update-annotation`, which edits an
    /// existing row. The row keeps recording no command until an add command
    /// exists.
    @discardableResult
    static func beginManualReferenceAnnotationOperation(
        annotationName: String,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) async -> Void
    ) async -> OperationStartResult {
        let result = reporter.begin(
            title: "Add Annotation",
            detail: "Adding \(annotationName)...",
            operationType: .bundleBuild,
            cliCommand: nil,
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            await launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Registers the sequence annotation row (Find ORFs) and, only when it
    /// starts, calls `launch` with the operation ID. The row locks the
    /// request's bundle and records the `lungfish-cli sequence annotate-orfs`
    /// command that `SequenceAnnotationOperationRunner` executes for it.
    @discardableResult
    static func beginSequenceAnnotationOperation(
        request: SequenceAnnotationOperationRequest,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: request.operation.displayName,
            detail: "Running \(request.operation.displayName)...",
            operationType: .bundleBuild,
            targetBundleURL: request.bundleURL,
            cliCommand: SequenceAnnotationOperationRunner.displayCommand(for: request),
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
