// MainSplitViewController+ReferenceDrop.swift - The sidebar drop of a standalone reference file, on lungfish-cli import fasta
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// How the import of a standalone reference dropped on the sidebar ended, for the drop's notice.
enum DroppedReferenceImportOutcome: Equatable {
    case imported(URL)
    case failed(String)
    case cancelled
}

extension MainSplitViewController {
    /// Imports the standalone reference `sourceURL` dropped on the sidebar into the project at
    /// `projectURL` with `lungfish-cli import fasta` (2.11 lane A48 M4, plan decision C3). It uses the
    /// Reference Import row the Import Center registers, so the row records the command it runs. The
    /// command makes the project's Reference Sequences folder, then builds, publishes and records the
    /// bundle there, so the app writes nothing after it exits, and the row's Cancel stops it.
    ///
    /// - Parameter run: Runs the command for the row, the row's runner in the app and a test's own runner.
    /// - Returns: The published bundle, the message of a refused or failed run, or `cancelled`.
    @MainActor
    static func importDroppedReference(
        sourceURL: URL,
        projectURL: URL,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        run: ([String], UUID) async throws -> CLISubprocessTransport.Result = { arguments, id in
            try await CLIBundleBuildRunner.launch(arguments: arguments, operationID: id)
        }
    ) async -> DroppedReferenceImportOutcome {
        var operationID: UUID?
        let began = AppDelegate.beginReferenceImportOperation(
            sourceURL: sourceURL,
            projectURL: projectURL,
            preferredBundleName: nil,
            routeContext: routeContext,
            reporter: reporter
        ) { operationID = $0 }
        guard let operationID else {
            guard case .refused(let refusal) = began else { return .failed("The reference import did not start.") }
            return .failed(OperationRefusedError(refusal).localizedDescription)
        }
        let outcome = await AppDelegate.runReferenceImport(
            arguments: AppDelegate.referenceImportArguments(sourceURL: sourceURL, projectURL: projectURL, preferredBundleName: nil),
            operationID: operationID,
            reporter: reporter,
            run: run
        )
        if let bundleURL = outcome.bundleURL { return .imported(bundleURL) }
        if let error = outcome.error { return .failed(error.localizedDescription) }
        return .cancelled
    }
}
