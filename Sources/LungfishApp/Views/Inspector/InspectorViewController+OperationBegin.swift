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

    /// The argv after the binary that removes `trackID` from `bundleURL`,
    /// `bam remove-track` with its events on (Phase 2.10 lane A51). The row
    /// records it and the L3 runner runs it.
    static func removeDerivedAlignmentCLIArguments(bundleURL: URL, trackID: String) -> [String] {
        ["bam", "remove-track", "--bundle", bundleURL.path, "--track", trackID, "--format", "json"]
    }

    /// Registers the derived-alignment removal row and, only when it starts,
    /// calls `launch` with the operation ID. The row locks `bundleURL` and
    /// records the `lungfish-cli bam remove-track` command the runner runs.
    @discardableResult
    static func beginRemoveDerivedAlignmentOperation(
        trackName: String,
        trackID: String,
        bundleURL: URL,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let arguments = removeDerivedAlignmentCLIArguments(bundleURL: bundleURL, trackID: trackID)
        let result = reporter.begin(
            title: "Remove Derived Alignment",
            detail: "Removing \(trackName)...",
            operationType: .bamImport,
            targetBundleURL: bundleURL,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "bam remove-track",
                args: Array(arguments.dropFirst(2))
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

    /// Runs the removal row's `bam remove-track` on the L3 runner and hands
    /// how it ended to `finish` on the main actor. The command wrote the
    /// manifest, the record and the deletions before it exited, so the app
    /// writes nothing. The row's Cancel reaches the runner's `cancel()`, and a
    /// cancelled run ends the row Cancelled with no alert and no `finish`.
    static func runRemoveDerivedAlignmentThroughCLI(
        bundleURL: URL,
        trackID: String,
        operationID: UUID,
        runner: CLIAlignmentActionRunner = CLIAlignmentActionRunner(),
        finish: @escaping @MainActor (Result<CLIAlignmentActionRunner.Completion, any Error>) -> Void
    ) {
        runAlignmentLeafThroughCLI(
            arguments: removeDerivedAlignmentCLIArguments(bundleURL: bundleURL, trackID: trackID),
            operationID: operationID,
            runner: runner,
            finish: finish
        )
    }

    /// A leaf that completed without a fact the app needs from it, such as the bundle or the track it made.
    /// The row then fails with `message` instead of showing a result the app cannot name.
    struct AlignmentLeafCompletionError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs one L3 leaf, `arguments` being the argv after the binary, on the runner for the row `operationID`
    /// and hands how it ended to `finish` on the main actor (Phase 2.10 lanes A51 and A54, the one run
    /// helper of the family). The leaf wrote every file before it exited, so the app writes nothing, and
    /// the runner completes nothing: `finish` completes the row, so the result stays hidden until then.
    /// The row's Cancel reaches the runner's `cancel()`. A cancelled run ends the row Cancelled, calls
    /// `cancelled` so the caller can reset what it showed, and calls no `finish`. `overlay` gets each
    /// progress message the row takes, for a caller that shows it in the viewer's progress overlay.
    static func runAlignmentLeafThroughCLI(
        arguments: [String],
        operationID: UUID,
        runner: CLIAlignmentActionRunner = CLIAlignmentActionRunner(),
        overlay: (@MainActor @Sendable (String) -> Void)? = nil,
        cancelled: @escaping @MainActor () -> Void = {},
        finish: @escaping @MainActor (Result<CLIAlignmentActionRunner.Completion, any Error>) -> Void
    ) {
        let task = Task(priority: .userInitiated) { @MainActor in
            do {
                finish(.success(try await runner.run(arguments: arguments, operationID: operationID, overlay: overlay)))
            } catch is CancellationError {
                OperationCenterCLIBridge.acknowledgeCancellation(operationID)
                cancelled()
            } catch {
                finish(.failure(error))
            }
        }
        OperationCenter.shared.setCancelCallback(for: operationID) {
            task.cancel()
            runner.cancel()
        }
    }
}
