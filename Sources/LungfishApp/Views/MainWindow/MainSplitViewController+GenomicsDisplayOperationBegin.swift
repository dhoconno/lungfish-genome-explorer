// MainSplitViewController+GenomicsDisplayOperationBegin.swift - Operations panel registration for genomics display launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// The begin helpers for the launches in MainSplitViewController+GenomicsDisplay.swift
/// (finding R4). They live here, not beside their launch sites, so the baselined
/// launch-site file does not grow (scripts/ratchets/file-size.sh). Each helper
/// registers its row through `OperationReporting`, so a test can check the row,
/// its lock and its command without touching `OperationCenter.shared`.
///
/// Neither launch declares a bundle lock, so `begin` cannot refuse either one
/// on a real `OperationCenter` today. Each launch still switches on the
/// result and runs nothing on a refusal, which keeps it correct if a lock is
/// added later.
extension MainSplitViewController {
    // MARK: - Reference download

    /// Registers the reference download row for a variant-only (naked) bundle
    /// and, only when it starts, calls `launch` with the operation ID. The row
    /// is a download row, locks no bundle and records no command.
    ///
    /// The run merges the downloaded genome and annotations into the existing
    /// bundle without declaring a bundle lock. That is how the site behaved
    /// before this migration, and the helper keeps it. Adding a lock target is
    /// a separate decision (Rule 3 in docs/contracts/ADDING-AN-OPERATION.md).
    ///
    /// cli-parity-gap: variant-only-reference-download. No lungfish-cli
    /// command adds a downloaded reference to an existing bundle. The closest is `lungfish-cli fetch genome`, which
    /// builds a new bundle from one accession and never merges into an
    /// existing one. The row keeps recording no command until a merge command
    /// exists.
    @discardableResult
    static func beginNakedBundleReferenceDownloadOperation(
        assemblyName: String,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "\(assemblyName) Reference",
            detail: "Searching NCBI\u{2026}",
            operationType: .download,
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

    // MARK: - FASTQ operations

    /// Registers the row for a FASTQ operations dialog launch and, only when
    /// it starts, calls `launch` with the operation ID. The row locks no
    /// bundle.
    ///
    /// `cliCommand` is the `lungfish-cli` invocation `executionService` builds
    /// for `request`, with the output shown as `<derived>`. It is nil when the
    /// builder cannot encode the request, such as an adapter FASTA or a
    /// demultiplex sample sheet. Those requests have no CLI equivalent yet,
    /// which is a parity gap pinned by MainSplitGenomicsDisplayOperationTests.
    @discardableResult
    static func beginFASTQLaunchRequestOperation(
        title: String,
        request: FASTQOperationLaunchRequest,
        executionService: FASTQOperationExecutionService,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let cliCommand: String? = try? {
            let invocation = try executionService.buildInvocation(for: request)
            return OperationCenter.buildCLICommand(
                subcommand: invocation.subcommand,
                args: invocation.arguments
            )
        }()
        let result = reporter.begin(
            title: title,
            detail: "Preparing...",
            operationType: .fastqOperation,
            cliCommand: cliCommand,
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
