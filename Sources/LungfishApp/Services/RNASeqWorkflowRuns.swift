// RNASeqWorkflowRuns.swift - The export and pseudobulk rows of the Workflow Operations dialog, run through lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit

/// The words of the export pane that the golden help of `lungfish-cli rnaseq export` also states, so a test pins them to it.
enum RNASeqExportDefaults {
    /// The CLI's own default, shown in the pane before the person types.
    static let padjCutoff = 0.05
    /// The cutoff and `alpha` are one number (`docs/formats/rnaseq-bundle.md`, Design, cutoff and alpha).
    static let cutoffHelp = "The adjusted p-value cutoff, which is also alpha in DESeq2's results()"
    static let designHelp = "A column of samples.tsv that enters the model. Repeat it, and the last one is the tested factor"
    static let contrastHelp = "FACTOR:NUMERATOR:DENOMINATOR, such as group:TB:HIV. Repeat it for more contrasts"
    static let lfcBarHelp = "A bar on the absolute log2 fold change. None by default"
    static let batchHelp = "The column of samples.tsv that names each sample's batch, for --batch-correction"
}

/// One `lungfish-cli rnaseq <leaf>` row. The dialog never writes a count. It builds this, runs the CLI on `argv` and shows what
/// the CLI wrote and said. `argv` is the one array that runs, shows in the Operations row and parses back through the real
/// subcommand.
struct RNASeqLeafRun {
    let title: String
    let detail: String
    let operationType: OperationType
    /// The results the leaf reads and that must not change mid-run (Rule 3 of `ADDING-AN-OPERATION.md`).
    let lockedBundleURLs: [URL]
    let subcommand: String
    let argv: [String]
    /// The folder the leaf writes. The leaf's `complete` line names it too, and wins.
    let outputURL: URL
    let completionDetail: String

    /// The shell-quoted command the Operations row shows, built from the argv that runs.
    var cliCommand: String {
        OperationCenter.buildCLICommand(subcommand: subcommand, args: Array(argv.dropFirst(2)))
    }
}

/// What the export pane asks for, in the words of `lungfish-cli rnaseq export`. The CLI does every check, so a refusal such as two
/// routes, a batch nested in a factor or fewer than 3 animals in a pseudobulk level comes back in the CLI's words on the row.
struct RNASeqExportRunRequest: Sendable, Equatable {
    enum BatchCorrection: String, CaseIterable, Sendable {
        case none
        case combatSeq = "combat-seq"
        case sva
    }

    var resultURLs: [URL]
    var outputURL: URL
    var sampleSheetURL: URL?
    /// `--design`, repeated. The last one is the tested factor.
    var design: [String] = []
    /// `--contrast FACTOR:NUMERATOR:DENOMINATOR`, repeated.
    var contrasts: [String] = []
    var padjCutoff: Double = RNASeqExportDefaults.padjCutoff
    var lfcBar: Double?
    var batch: String?
    var batchCorrection: BatchCorrection = .none

    /// The argv after the binary name. Every setting that is not the CLI's default is named, and the cutoff always is, so the
    /// recorded command keeps its meaning if a default changes.
    var argv: [String] {
        var arguments = ["rnaseq", "export"] + resultURLs.map(\.path) + ["--output", outputURL.path]
        if let sampleSheetURL { arguments += ["--sample-sheet", sampleSheetURL.path] }
        for term in design { arguments += ["--design", term] }
        for words in contrasts { arguments += ["--contrast", words] }
        arguments += ["--padj-cutoff", "\(padjCutoff)"]
        if let lfcBar { arguments += ["--lfc-bar", "\(lfcBar)"] }
        if let batch { arguments += ["--batch", batch] }
        if batchCorrection != .none { arguments += ["--batch-correction", batchCorrection.rawValue] }
        arguments += ["--format", "json"]
        return arguments
    }

    var run: RNASeqLeafRun {
        let count = resultURLs.count
        let noun = count == 1 ? "result" : "results"
        return RNASeqLeafRun(
            title: "Export RNA-seq counts",
            detail: "Writing counts and scripts for \(count) \(noun) to \(outputURL.lastPathComponent)",
            operationType: .rnaSeqExport,
            lockedBundleURLs: resultURLs,
            subcommand: "rnaseq export",
            argv: argv,
            outputURL: outputURL,
            completionDetail: "Exported \(count) \(noun) to \(outputURL.lastPathComponent)")
    }
}

/// What the pseudobulk pane asks for, in the words of `lungfish-cli rnaseq pseudobulk`. A group under 10 cells is left out and the
/// CLI says so in a warning line, which the row shows as the CLI prints it.
struct RNASeqPseudobulkRunRequest: Sendable, Equatable {
    var resultURL: URL
    var labelsURL: URL
    /// The new `.lungfishrnaseq` folder. The CLI refuses a name that does not end in that extension.
    var outputURL: URL

    var argv: [String] {
        ["rnaseq", "pseudobulk", resultURL.path, "--labels", labelsURL.path, "--output", outputURL.path, "--format", "json"]
    }

    var run: RNASeqLeafRun {
        RNASeqLeafRun(
            title: "Pseudobulk RNA-seq cells",
            detail: "Summing the cells of \(resultURL.lastPathComponent) by sample and label",
            operationType: .rnaSeqPseudobulk,
            lockedBundleURLs: [resultURL],
            subcommand: "rnaseq pseudobulk",
            argv: argv,
            outputURL: outputURL,
            completionDetail: "Wrote the pseudobulk result \(outputURL.lastPathComponent)")
    }
}

/// What a launched row hands back, so a caller can wait for it.
struct RNASeqLeafLaunch {
    let operationID: UUID
    let task: Task<CLIViewerExportRunner.Outcome, Never>
}

/// Registers the row with `begin` and runs the leaf on `CLIViewerExportRunner`, the one runner every leaf that writes its output
/// and record in one transaction runs on (`ADDING-AN-OPERATION.md`, Recipe of a new CLI route). The runner shows the leaf's events
/// on the row through `OperationCenterCLIBridge`, so a `warning` log line such as the note of a group under 10 cells reads
/// as the CLI prints it and the row ends Completed with Warnings. A failure shows the leaf's `failed` message and nothing added.
/// A cancel sends the leaf SIGTERM, which rolls its stage back, so a cancelled run leaves no folder and no stage.
@MainActor
enum RNASeqLeafRoute {
    /// Registers the row. `launch` runs only when the row started, as Rule 1 of `ADDING-AN-OPERATION.md` requires.
    @discardableResult
    static func begin(
        _ run: RNASeqLeafRun,
        routeContext: OperationRouteContext? = nil,
        operations: any OperationReporting = OperationCenter.shared,
        onCancel: @escaping @Sendable () -> Void = {},
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = operations.begin(
            title: run.title,
            detail: run.detail,
            operationType: run.operationType,
            targetBundleURL: nil,
            additionalLockedBundleURLs: run.lockedBundleURLs,
            cliCommand: run.cliCommand,
            routeContext: routeContext,
            onCancel: onCancel
        )
        if case .started(let id) = result { launch(id) }
        return result
    }

    /// Begins the row and starts the leaf. It returns `nil` when `begin` refused the run, and then nothing launched.
    /// `environmentAdditions` is for a test, which names the leaf's hold variable there. No production caller passes any.
    @discardableResult
    static func launch(
        _ run: RNASeqLeafRun,
        routeContext: OperationRouteContext? = nil,
        operations: any OperationReporting = OperationCenter.shared,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        environmentAdditions: [String: String] = [:]
    ) -> RNASeqLeafLaunch? {
        var launched: RNASeqLeafLaunch?
        begin(run, routeContext: routeContext, operations: operations, onCancel: { runner.cancel() }) { id in
            let task = Task { @MainActor in
                await runner.run(
                    arguments: run.argv, outputURL: run.outputURL, operationID: id,
                    completionDetail: run.completionDetail, environmentAdditions: environmentAdditions)
            }
            launched = RNASeqLeafLaunch(operationID: id, task: task)
        }
        return launched
    }
}
