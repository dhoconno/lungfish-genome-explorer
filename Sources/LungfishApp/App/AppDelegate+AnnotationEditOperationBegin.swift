// AppDelegate+AnnotationEditOperationBegin.swift - Operations panel registration for reference bundle annotation edits
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit

/// The begin helpers for the two annotation edits AppDelegate.swift persists
/// to a reference bundle, the Inspector or viewer rename and the delete
/// (findings R3 and R4). They live here, not beside their launch sites, so the
/// baselined AppDelegate.swift does not grow (scripts/ratchets/file-size.sh).
/// Each helper registers its row through `OperationReporting` and returns the
/// result. The launch site switches on it and shows its own alert on a
/// refusal, so the edit runs only on `.started`.
///
/// Both edits run `ReferenceBundleManualAnnotationService`, which calls the
/// `SequenceAnnotationTrackWorkflow` function `lungfish-cli sequence
/// update-annotation` and `sequence delete-annotations` call, with the same
/// bundle, track, row and values. So both rows record that command. They used
/// to record no command.
extension AppDelegate {
    /// The arguments after `lungfish-cli sequence update-annotation` that
    /// persist the edit of `annotation` at `location`, with the values
    /// `ReferenceBundleManualAnnotationService.updateAnnotation` writes, the
    /// name, type, strand and note. The edited values are joined to their
    /// options, so the parser reads the reverse strand `-` or a hyphen-leading
    /// name as a value. A nil note clears the note on both paths, so the
    /// command passes no `--note` then.
    nonisolated static func annotationUpdateCLIArguments(
        annotation: SequenceAnnotation,
        location: ReferenceBundleAnnotationRowLocation,
        bundleURL: URL
    ) -> [String] {
        var arguments = [
            bundleURL.path,
            "--track-id", location.trackID,
            "--row-id", String(location.rowID),
            "--name=\(annotation.name)",
            "--type=\(annotation.type.rawValue)",
            "--strand=\(annotation.strand.rawValue)",
        ]
        if let note = annotation.note {
            arguments.append("--note=\(note)")
        }
        return arguments
    }

    /// Registers the row for an annotation rename, retype or note edit and
    /// returns the result. The row locks `bundleURL` and records the
    /// `lungfish-cli sequence update-annotation` command for the edit.
    @discardableResult
    static func beginAnnotationUpdateOperation(
        annotation: SequenceAnnotation,
        location: ReferenceBundleAnnotationRowLocation,
        bundleURL: URL,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared
    ) -> OperationStartResult {
        reporter.begin(
            title: "Update Annotation",
            detail: "Updating \(annotation.name)...",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "sequence update-annotation",
                args: annotationUpdateCLIArguments(annotation: annotation, location: location, bundleURL: bundleURL)
            ),
            routeContext: routeContext
        )
    }

    /// Registers the row for an annotation delete and returns the result. The
    /// row locks `bundleURL` and records the `lungfish-cli sequence
    /// delete-annotations` command the annotation drawer records for the same
    /// row, built by `ViewerViewController.annotationRowDeletionArguments`.
    @discardableResult
    static func beginAnnotationDeletionOperation(
        location: ReferenceBundleAnnotationRowLocation,
        bundleURL: URL,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared
    ) -> OperationStartResult {
        let arguments = ViewerViewController.annotationRowDeletionArguments(
            bundleURL: bundleURL,
            trackID: location.trackID,
            rowIDs: [location.rowID]
        )
        return reporter.begin(
            title: "Delete Annotation",
            detail: "Deleting annotation...",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "sequence delete-annotations",
                args: Array(arguments.dropFirst(2))
            ),
            routeContext: routeContext
        )
    }
}
