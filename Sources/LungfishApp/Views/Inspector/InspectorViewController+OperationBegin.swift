// InspectorViewController+OperationBegin.swift - Operations panel registration for Inspector launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishWorkflow

/// The begin helpers for the Inspector's launches from baselined files (finding R4).
/// Each one registers a row through `OperationReporting` and calls `launch`
/// only when the row started, so a test can check the row, its lock and its
/// command without touching `OperationCenter.shared`. They live here, not
/// beside their launch sites, so the baselined launch-site files do not grow
/// (scripts/ratchets/file-size.sh).
extension InspectorViewController {
    /// Registers the primer-trim row and, only when it starts, calls `launch`
    /// with the operation ID. The row locks `bundleURL` and records the
    /// `lungfish-cli bam primer-trim` command built from `cliArguments`, the
    /// argv the runner executes.
    @discardableResult
    static func beginPrimerTrimOperation(
        title: String,
        bundleURL: URL,
        cliArguments: [String],
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: title,
            detail: "Preparing primer trim...",
            operationType: .bamPrimerTrim,
            targetBundleURL: bundleURL,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "bam primer-trim",
                args: Array(cliArguments.dropFirst(2))
            ),
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

    /// Registers the filtered-alignment row and, only when it starts, calls
    /// `launch` with the operation ID. The row locks `bundleURL` and records
    /// the `lungfish-cli bam filter` command for the same target and request
    /// the run uses.
    @discardableResult
    static func beginFilteredAlignmentWorkflowOperation(
        bundleURL: URL,
        serviceTarget: AlignmentFilterTarget,
        request: AlignmentFilterInspectorLaunchRequest,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Create Filtered Alignment Track",
            detail: "Preparing \(request.outputTrackName)...",
            operationType: .bamImport,
            targetBundleURL: bundleURL,
            cliCommand: filteredAlignmentCLICommand(serviceTarget: serviceTarget, request: request)
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// The `lungfish-cli bam filter` command that reproduces a run of
    /// `BundleAlignmentFilterService.deriveFilteredAlignment` with this target
    /// and request, built by `BundleAlignmentFilterService.cliArgv`, the
    /// builder the run's provenance uses (R3). The run passes no output track
    /// ID, so the command passes none and both generate one. The Inspector
    /// never sets `filterRequest.region`, which the CLI cannot express.
    static func filteredAlignmentCLICommand(
        serviceTarget: AlignmentFilterTarget,
        request: AlignmentFilterInspectorLaunchRequest
    ) -> String {
        BundleAlignmentFilterService.cliArgv(
            target: serviceTarget,
            sourceTrackID: request.sourceTrackID,
            outputTrackID: nil,
            outputTrackName: request.outputTrackName,
            filterRequest: request.filterRequest
        ).map(shellEscape).joined(separator: " ")
    }

    /// Registers the mapped-reads annotation row and, only when it starts,
    /// calls `launch` with the operation ID. The row locks the request's
    /// bundle and records the `lungfish-cli bam annotate` command for the
    /// request the run uses.
    @discardableResult
    static func beginMappedReadsAnnotationWorkflowOperation(
        request: MappedReadsAnnotationRequest,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Convert Mapped Reads to Annotations",
            detail: "Preparing \(request.outputTrackName)...",
            operationType: .bamImport,
            targetBundleURL: request.bundleURL,
            cliCommand: mappedReadsAnnotationCLICommand(request: request)
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// The `lungfish-cli bam annotate` command that reproduces a run of
    /// `MappedReadsAnnotationService.convertMappedReads` with this request,
    /// built by `MappedReadsAnnotationService.cliArgv`, the builder the run's
    /// provenance uses (R3).
    static func mappedReadsAnnotationCLICommand(request: MappedReadsAnnotationRequest) -> String {
        MappedReadsAnnotationService.cliArgv(
            request: request,
            bundleURL: request.bundleURL,
            outputTrackName: request.outputTrackName
        ).map(shellEscape).joined(separator: " ")
    }

    /// Registers the derived-alignment removal row and, only when it starts,
    /// calls `launch` with the operation ID. The row locks `bundleURL` and
    /// records no command.
    ///
    /// cli-parity-gap: alignment-track-remove. No lungfish-cli command removes
    /// an alignment track from a bundle, because only the app calls
    /// `BundleAlignmentTrackRemovalService`.
    /// The closest is `bam filter`, which creates the derived tracks this
    /// removes. The row keeps recording no command until a removal command
    /// exists.
    @discardableResult
    static func beginRemoveDerivedAlignmentOperation(
        trackName: String,
        bundleURL: URL,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Remove Derived Alignment",
            detail: "Removing \(trackName)...",
            operationType: .bamImport,
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
