// AppDelegate+SequenceMenuOperationBegin.swift - Operations panel registration for Sequence menu launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit
import LungfishWorkflow

/// The begin helpers for the Sequence menu's annotation launches (finding R4).
/// They live here, not beside their launch sites, so the baselined
/// AppDelegate+SequenceMenu.swift does not grow (scripts/ratchets/file-size.sh).
/// Each helper registers its row through `OperationReporting` and calls
/// `launch` only when the row started, so a test can check the row, its lock
/// and its command without touching `OperationCenter.shared`.
extension AppDelegate {
    /// Registers the manual annotation row and, only when it starts, awaits
    /// `launch` with the operation ID and the argv the write records. The
    /// launch is `async` because the caller awaits the bundle write inside it.
    ///
    /// The edit's only inputs are the bundle and the values the sheet holds,
    /// so it runs in process the Workflow function `lungfish-cli sequence
    /// add-annotation` runs, `ReferenceBundleManualAnnotationService.addAnnotation`
    /// (2.10 decision C3). The row records that command, built by
    /// `ReferenceBundleManualAnnotationService.annotationAddArguments` from the
    /// annotation's region, name, type and strand, `chromosome` and the
    /// bundle, and `launch` gets the same argv for the write's record. The row
    /// locks the bundle, so the write ends inside the bundle lock.
    @discardableResult
    static func beginManualReferenceAnnotationOperation(
        annotation: SequenceAnnotation,
        chromosome: String,
        bundleURL: URL,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID, [String]) async -> Void
    ) async -> OperationStartResult {
        let region = annotation.boundingRegion
        let arguments = ReferenceBundleManualAnnotationService.annotationAddArguments(
            chromosome: chromosome,
            start: region.start,
            end: region.end,
            name: annotation.name,
            type: annotation.type.rawValue,
            strand: annotation.strand.rawValue,
            bundleURL: bundleURL.standardizedFileURL
        )
        let result = reporter.begin(
            title: "Add Annotation",
            detail: "Adding \(annotation.name)...",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "sequence add-annotation",
                args: Array(arguments.dropFirst(2))
            ),
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            await launch(operationID, [LungfishAppIdentity.recordedToolName] + arguments)
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
