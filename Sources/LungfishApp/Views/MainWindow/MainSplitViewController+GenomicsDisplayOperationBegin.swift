// MainSplitViewController+GenomicsDisplayOperationBegin.swift - Operations panel registration for genomics display launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// The begin helpers for the launches in MainSplitViewController+GenomicsDisplay.swift
/// and MainSplitViewController+NakedBundleReference.swift (finding R4). They live
/// here, not beside their launch sites, so the baselined launch-site file does not
/// grow (scripts/ratchets/file-size.sh). Each helper registers its row through
/// `OperationReporting`, so a test can check the row, its lock and its command
/// without touching `OperationCenter.shared`.
///
/// The reference download locks the variant-only bundle it merges into, so
/// `begin` refuses it while another operation holds that bundle. The FASTQ
/// operations launch declares no bundle lock. Each launch switches on the
/// result and runs nothing on a refusal.
extension MainSplitViewController {
    // MARK: - Reference download

    /// Registers the reference download row for the variant-only (naked) bundle
    /// at `bundleURL` and, only when it starts, calls `launch` with the
    /// operation ID. The row is a download row and begins with no command,
    /// since the app finds the reference's accession first.
    ///
    /// The row locks `bundleURL`, the bundle the run writes, since the run
    /// replaces its `genome/` and `annotations/` folders and its manifest (Rule 3
    /// in docs/contracts/ADDING-AN-OPERATION.md, Phase 2.10 lane A44 M3, review
    /// ruling M3-3). Another operation that declares the bundle then waits, and a
    /// row refused because one holds it launches nothing.
    ///
    /// cli-parity-gap: variant-only-reference-genbank-fallback. Once the app has
    /// found an assembly, the run records `lungfish-cli fetch genome <accession>
    /// --into-bundle <bundle> --format json` with `setCommand` before it merges
    /// (Phase 2.10 lane A44 M3, review ruling M3-1). The GenBank fallback, the
    /// record of the VCF's versioned accession when no assembly is found, still
    /// builds in process and records no command, because that command builds the
    /// record's bundle with names, a FASTA layout and source fields BIO has not
    /// signed (ruling M3-2, lane A44 M3 report). It is the closest command.
    @discardableResult
    static func beginNakedBundleReferenceDownloadOperation(
        assemblyName: String,
        bundleURL: URL,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "\(assemblyName) Reference",
            detail: "Searching NCBI\u{2026}",
            operationType: .download,
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

    // MARK: - FASTQ operations

    /// Registers the row for a FASTQ operations dialog launch and, only when
    /// it starts, calls `launch` with the operation ID. The row locks no
    /// bundle.
    ///
    /// `cliCommand` is the `lungfish-cli` invocation `executionService` builds
    /// for `request`, with the output shown as `<derived>`. Its words after
    /// `lungfish-cli` are the argv the runner launches
    /// (`FASTQOperationCLIInvocationBuilder.commandLine(for:)`). It is nil when the
    /// builder cannot encode the request, such as an adapter FASTA or a
    /// demultiplex sample sheet. Those requests have no CLI equivalent yet,
    /// which is a parity gap pinned by MainSplitGenomicsDisplayOperationTests.
    ///
    /// The `<derived>` placeholder is replaced after a successful run. The
    /// launch site in MainSplitViewController+GenomicsDisplay.swift asks
    /// `FASTQOperationRowCommand` for the final command once the output paths
    /// are known and applies it with `setCommand` before it completes the row.
    /// A derivative row then shows the command its imported bundles' manifests
    /// record, and a Savont row shows the executed command that names the
    /// published FASTA. A grouped result and every other request keep the
    /// command recorded here.
    @discardableResult
    static func beginFASTQLaunchRequestOperation(
        title: String,
        request: FASTQOperationLaunchRequest,
        executionService: FASTQOperationExecutionService,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let cliCommand: String? = try? FASTQOperationCLIInvocationBuilder.commandLine(
            for: executionService.buildInvocation(for: request)
        )
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
