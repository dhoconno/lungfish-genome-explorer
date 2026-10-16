// ViewerViewController+OperationBegin.swift - Operations panel registration for ViewerViewController launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

/// The begin helpers for the launches in the baselined ViewerViewController.swift
/// (finding R4). Each one registers a row through `OperationReporting` and
/// calls `launch` only when the row started, so a test can check the row and
/// its command without touching `OperationCenter.shared`. They live here, not
/// beside their launch sites, so ViewerViewController.swift does not grow
/// (scripts/ratchets/file-size.sh).
extension ViewerViewController {
    /// Registers the BLAST row for the selected FASTA sequences and, only when
    /// it starts, calls `launch` with the operation ID. The row locks no
    /// bundle.
    ///
    /// cli-parity-gap: blast-fasta-selection. `lungfish-cli blast verify`
    /// verifies one Kraken2 taxon and needs the Kraken2 report, the per-read
    /// output, the source FASTQ and a taxon ID. No command submits selected
    /// FASTA sequences to BLAST, so the row records no command until one
    /// does.
    @discardableResult
    static func beginGenericBlastVerificationOperation(
        sourceLabel: String,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "BLAST \(sourceLabel)",
            detail: "Preparing BLAST verification\u{2026}",
            operationType: .blastVerification,
            cliCommand: nil
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Registers the row for creating a reference bundle straight from
    /// selected FASTA sequences and, only when it starts, calls `launch` with
    /// the operation ID. The row locks no bundle.
    ///
    /// `cliArguments` is the argv the run executes, which
    /// ``FASTASelectionReferenceBundleCLI/arguments(sourceURL:sequenceIDs:projectURL:bundleName:)``
    /// builds and the call site ends with `--quiet`. The row records it as the
    /// `lungfish-cli extract contigs --bundle` command it is.
    @discardableResult
    static func beginDurableFASTAReferenceBundleOperation(
        cliArguments: [String],
        selectedCount: Int,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Create Reference Bundle",
            detail: "Creating a reference bundle from \(selectedCount) selected FASTA sequence(s)...",
            operationType: .bundleBuild,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "extract contigs",
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

    /// Registers the annotated reference import row and, only when it starts,
    /// calls `launch` with the operation ID. The row locks no bundle.
    ///
    /// `arguments` is the argv after `lungfish-cli` that the run hands
    /// `CLIBundleBuildRunner` (`AppDelegate.referenceImportArguments`), `import
    /// fasta` on the staged FASTA with `--annotations`, `--annotation-selection`,
    /// `--source-alignment-bundle` and a `--provenance-input` for each durable
    /// source, so the row records the command the run is (2.11 A48 M3). The
    /// staged files are removed once the run ends, so a copied command replays
    /// only while they are kept.
    @discardableResult
    static func beginAnnotatedReferenceImportOperation(
        arguments: [String],
        bundleStem: String,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Annotated Reference Import",
            detail: "Creating \(bundleStem).lungfishref...",
            operationType: .bundleBuild,
            cliCommand: OperationCenter.buildCLICommand(subcommand: "import fasta", args: Array(arguments.dropFirst(2))),
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
