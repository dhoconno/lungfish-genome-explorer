// ViewerViewController+AnnotationDrawerOperationBegin.swift - Operations panel registration for annotation deletions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

/// The begin helpers for the annotation drawer's deletions (finding R4). They
/// live here, not beside their launch sites, so the baselined
/// ViewerViewController+AnnotationDrawer.swift does not grow
/// (scripts/ratchets/file-size.sh). Each helper registers its row through
/// `OperationReporting` and calls `launch` only when the row started, so a
/// test can check the row, its lock and its command without touching
/// `OperationCenter.shared`.
extension ViewerViewController {
    /// Registers the annotation row deletion and, only when it starts, calls
    /// `launch` with the operation ID. The row locks `bundleURL` and records
    /// the `lungfish-cli sequence delete-annotations` command built from
    /// `cliArguments`, the argv the run executes. The launch-site file builds
    /// that argv with ``annotationRowDeletionArguments(bundleURL:trackID:rowIDs:)``.
    @discardableResult
    static func beginAnnotationRowDeletionOperation(
        bundleURL: URL,
        cliArguments: [String],
        deletedCount: Int,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: deletedCount == 1 ? "Delete Annotation" : "Delete Annotations",
            detail: "Deleting \(deletedCount) annotation\(deletedCount == 1 ? "" : "s")...",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "sequence delete-annotations",
                args: Array(cliArguments.dropFirst(2))
            )
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Registers the annotation track deletion and, only when it starts, calls
    /// `launch` with the operation ID. The row locks `bundleURL` and records
    /// the `lungfish-cli sequence delete-annotation-track` command built from
    /// `cliArguments`, the argv the run executes. The launch-site file builds
    /// that argv with ``annotationTrackDeletionArguments(bundleURL:trackID:)``.
    @discardableResult
    static func beginAnnotationTrackDeletionOperation(
        bundleURL: URL,
        cliArguments: [String],
        trackName: String,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Delete Annotation Track",
            detail: "Deleting \(trackName)...",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "sequence delete-annotation-track",
                args: Array(cliArguments.dropFirst(2))
            )
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
