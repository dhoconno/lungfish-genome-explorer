// MainSplitViewController+FASTQImportOperationBegin.swift - Operations panel registration for ONT import recipe launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// The begin helper for the ONT import recipe launches in
/// MainSplitViewController+FASTQImport.swift (finding R4). It lives here, not
/// beside its launch sites, so the baselined launch-site file does not grow
/// (scripts/ratchets/file-size.sh). The helper registers its row through
/// `OperationReporting`, so a test can check the row and its command without
/// touching `OperationCenter.shared`.
extension MainSplitViewController {
    /// Registers the row for an ONT run folder import that the import sheet
    /// routes to a FASTQ operation recipe, the Fluidigm sample split or the
    /// PacBio barcode demultiplex, and, only when it starts, calls `launch`
    /// with the operation ID. The row is a FASTQ operation row and locks no
    /// bundle.
    ///
    /// Neither launch declares a bundle lock, so `begin` cannot refuse it on a
    /// real `OperationCenter` today. A launch still runs nothing on a refusal,
    /// which keeps it correct if a lock is added later.
    ///
    /// `cliCommand` comes from ``ontImportRecipeCLICommand(request:workingDirectory:)``.
    /// Both requests have a `lungfish-cli fastq` subcommand that reproduces the
    /// run, `ont-fluidigm-samples` and `ont-pacbio-barcode-demux`.
    @discardableResult
    static func beginONTImportRecipeOperation(
        request: FASTQOperationLaunchRequest,
        workingDirectory: URL,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "FASTQ: \(request.operationDisplayTitle)",
            detail: "Preparing...",
            operationType: .fastqOperation,
            cliCommand: ontImportRecipeCLICommand(request: request, workingDirectory: workingDirectory),
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

    /// The `lungfish-cli fastq` command the execution service runs for an ONT
    /// import recipe request. The service plans the output the same way, so
    /// `--output` names the folder the run writes into. The result is nil when
    /// the invocation builder cannot encode the request, which neither ONT
    /// recipe request triggers today.
    static func ontImportRecipeCLICommand(
        request: FASTQOperationLaunchRequest,
        workingDirectory: URL
    ) -> String? {
        try? {
            let outputTarget = FASTQOperationPlanner()
                .makeExecutionPlans(
                    originalRequest: request,
                    resolvedRequest: request,
                    baseOutputDirectory: workingDirectory
                )
                .first?
                .outputTarget
                .path ?? workingDirectory.path
            let invocation = try FASTQOperationCLIInvocationBuilder()
                .buildInvocation(for: request, outputTargetPath: outputTarget)
            return OperationCenter.buildCLICommand(
                subcommand: invocation.subcommand,
                args: invocation.arguments
            )
        }()
    }
}
