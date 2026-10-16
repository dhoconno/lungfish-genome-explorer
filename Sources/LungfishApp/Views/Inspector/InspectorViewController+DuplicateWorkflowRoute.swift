// InspectorViewController+DuplicateWorkflowRoute.swift - What a duplicate workflow runs and shows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The pure parts of the duplicate workflows' route (Phase 2.10 lane A54, decision C4), kept apart from
// the launch in InspectorViewController+TrimDuplicateWorkflows.swift so that file stays under its size
// limit and a test reaches them without a window. The route runs `bundle mark-duplicates` or
// `bundle deduplicate-alignments` on the L3 runner and completes the row with the words from
// `duplicateWorkflowCompletionDetail`. The in-process route and its hidden key went in Phase 2.11 (K3).

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow

extension InspectorViewController {
    /// What a duplicate workflow's launch runs.
    enum DuplicateWorkflowLaunch: Equatable {
        /// `lungfish-cli` with these arguments, the argv after the binary, on the L3 runner.
        case leaf(arguments: [String])
    }

    static func duplicateWorkflowLaunch(kind: DuplicateWorkflowKind, bundleURL: URL) -> DuplicateWorkflowLaunch {
        .leaf(arguments: kind.cliArguments(bundleURL: bundleURL))
    }

    /// What a duplicate workflow's launch decides before any window work (Phase 2.10 lane A54 M3): what it
    /// runs, the track count read before the row begins, and the row itself.
    struct DuplicateWorkflowPlan {
        let launch: DuplicateWorkflowLaunch
        let trackCount: Int
        let operationID: UUID
    }

    enum DuplicateWorkflowBegin {
        case started(DuplicateWorkflowPlan)
        case refused(OperationStartRefusal)
    }

    /// Counts the tracks and begins the row. The Inspector's launch calls it and runs what the plan says. A
    /// test passes a center of its own.
    static func beginDuplicateWorkflow(
        kind: DuplicateWorkflowKind,
        bundleURL: URL,
        routeContext: OperationRouteContext?,
        center: OperationCenter = .shared,
        onCancel: (@Sendable () -> Void)? = nil
    ) -> DuplicateWorkflowBegin {
        let trackCount = duplicateWorkflowTrackCount(kind: kind, bundleURL: bundleURL)
        let launch = duplicateWorkflowLaunch(kind: kind, bundleURL: bundleURL)
        switch startDuplicateWorkflowOperation(
            kind: kind, bundleURL: bundleURL, routeContext: routeContext, center: center, onCancel: onCancel
        ) {
        case .started(let id):
            return .started(DuplicateWorkflowPlan(launch: launch, trackCount: trackCount, operationID: id))
        case .refused(let refusal):
            return .refused(refusal)
        }
    }

    /// The number of alignment tracks the run will process, read from the bundle before the row begins.
    /// The service processes every one of them or throws, so this is the count the final detail names.
    /// The app reads it here because the leaf's `complete` message is text, and the app parses no number
    /// out of text. A bundle that cannot be read gives 0, and the leaf then fails with its own words
    /// before any row completes.
    static func duplicateWorkflowTrackCount(kind: DuplicateWorkflowKind, bundleURL: URL) -> Int {
        guard let manifest = try? BundleManifest.load(from: bundleURL) else { return 0 }
        switch kind {
        case .markDuplicates:
            return AlignmentDuplicateService.tracksPendingDuplicateMarking(in: manifest).count
        case .createDeduplicatedBundle:
            return manifest.alignments.count
        }
    }

    /// The result the completion code reads, from what the leaf's `complete` named and the count read
    /// before the row began. `mark-duplicates` marks `bundleURL` in place, and `deduplicate-alignments`
    /// names the bundle it made first among its outputs.
    static func duplicateWorkflowResult(
        kind: DuplicateWorkflowKind,
        bundleURL: URL,
        trackCount: Int,
        completion: CLIAlignmentActionRunner.Completion
    ) throws -> AlignmentDuplicateService.WorkflowResult {
        switch kind {
        case .markDuplicates:
            return AlignmentDuplicateService.WorkflowResult(
                bundleURL: bundleURL, processedTracks: trackCount, newTrackIds: [], retainedTrackIds: []
            )
        case .createDeduplicatedBundle:
            guard let output = completion.outputs.first else {
                throw AlignmentLeafCompletionError(message: "The command finished without naming the new bundle.")
            }
            return AlignmentDuplicateService.WorkflowResult(
                bundleURL: URL(fileURLWithPath: output, isDirectory: true),
                processedTracks: trackCount,
                newTrackIds: [],
                retainedTrackIds: []
            )
        }
    }

    /// "2 alignment tracks", the words the row and the alerts use.
    static func alignmentTrackCountText(_ count: Int) -> String {
        "\(count) alignment track\(count == 1 ? "" : "s")"
    }

    /// The final detail of the row.
    static func duplicateWorkflowCompletionDetail(
        kind: DuplicateWorkflowKind,
        result: AlignmentDuplicateService.WorkflowResult
    ) -> String {
        let tracks = alignmentTrackCountText(result.processedTracks)
        switch kind {
        case .markDuplicates:
            return "Marked duplicates in \(tracks)."
        case .createDeduplicatedBundle:
            return "Created \(result.bundleURL.lastPathComponent) from \(tracks)."
        }
    }

    /// Completes the row with the final detail and the bundle the run made. False when the row no longer
    /// runs, as when a cancel took it, and the caller then shows nothing.
    @discardableResult
    static func completeDuplicateWorkflowRow(
        kind: DuplicateWorkflowKind,
        operationID: UUID,
        result: AlignmentDuplicateService.WorkflowResult,
        center: OperationCenter = .shared
    ) -> Bool {
        center.complete(
            id: operationID,
            detail: duplicateWorkflowCompletionDetail(kind: kind, result: result),
            bundleURLs: [result.bundleURL]
        )
    }
}
