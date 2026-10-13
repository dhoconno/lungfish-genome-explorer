// AppDelegate+ClassificationOperationBegin.swift - Operations panel registration for the classifier launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// The begin helper for the TaxTriage launch in AppDelegate+Classification.swift
/// (finding R4).
/// The helper registers its row through `OperationReporting` and calls `launch`
/// only when the row started, so a test can check the row and its command
/// without touching `OperationCenter.shared`. The row locks no bundle, so a real
/// `OperationCenter` never refuses it. The Kraken2 and EsViritu launches begin
/// their rows in AppDelegate+ClassificationCLIRoute.swift.
extension AppDelegate {
    // MARK: - TaxTriage

    /// The command a TaxTriage row records for `config`, or nil for a run of
    /// several samples.
    ///
    /// A one-sample run records `lungfish-cli taxtriage --input <input>
    /// --sample <id>` with every setting the run uses. The input is the one
    /// the user chose, a `.lungfishfastq` bundle or a loose file, and never a
    /// scratch file the run deletes. `taxtriage run` plans a bundle itself,
    /// through the same ``TaxTriageReadSetPlanner`` the launch uses, so the
    /// pasted command hands TaxTriage the files the run read. It builds the
    /// same Nextflow arguments from the rest, which a test compares. The app's
    /// own result grouping has no option. That covers `sourceBundleURLs`, the
    /// negative control flags and the sample metadata, and none of them
    /// reaches Nextflow.
    ///
    /// Several samples record nil. `taxtriage run` takes one `--input` or one
    /// `--samplesheet`, and the app runs the samples one after another through
    /// `TaxTriageSerialBatchRunner`, which `taxtriage run` does not use. No
    /// single command reproduces that, and the flat `--input` list the row
    /// used to record is one the CLI rejects.
    nonisolated static func taxTriageCLICommand(for config: TaxTriageConfig) -> String? {
        guard config.samples.count == 1, let sample = config.samples.first else { return nil }
        var args = ["--input", sample.fastq1.path]
        if let fastq2 = sample.fastq2 {
            args += ["--input2", fastq2.path]
        }
        args += ["--sample", sample.sampleId]
        args += ["--output", config.outputDirectory.path]
        if let databasePath = config.kraken2DatabasePath {
            args += ["--db", databasePath.path]
        }
        args += ["--platform", sample.platform.rawValue.lowercased()]
        args += ["--confidence", String(config.k2Confidence)]
        args += ["--top-hits", String(config.topHitsCount)]
        args += ["--rank", config.rank]
        if !config.skipAssembly {
            args.append("--no-skip-assembly")
        }
        if config.skipKrona {
            args.append("--skip-krona")
        }
        if let removeTaxids = config.effectiveRemoveTaxids {
            args += ["--remove-taxids", removeTaxids]
        }
        args += ["--max-memory", config.maxMemory]
        args += ["--max-cpus", String(config.maxCpus)]
        args += ["--nf-profile", config.profile]
        // The row names the revision the run takes, the pinned commit when the config names none (N4).
        if let revision = config.revision ?? (try? NextflowWorkflowDescriptor.taxTriage.resolveBundledPin())?.revision {
            args += ["--revision", revision]
        }
        if !config.extraArguments.isEmpty {
            args += ["--extra-args", AdvancedCommandLineOptions.join(config.extraArguments)]
        }
        return OperationCenter.buildCLICommand(subcommand: "taxtriage", args: args)
    }

    /// Registers the TaxTriage row and calls `launch` with the operation ID
    /// only when the row started. The row locks no bundle and records the
    /// command that `taxTriageCLICommand(for:)` builds.
    ///
    /// cli-parity-gap: taxtriage-multi-sample. A run of several samples
    /// records no command, because the app runs the samples one after another
    /// and no `taxtriage run` command does. The row used to record a flat
    /// `--input` list the CLI rejects. The closest reproduction is
    /// `taxtriage run` once per sample.
    @discardableResult
    static func beginTaxTriageOperation(
        config: TaxTriageConfig,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let sampleCount = config.samples.count
        let result = reporter.begin(
            title: "TaxTriage (\(sampleCount) sample\(sampleCount == 1 ? "" : "s"))",
            detail: "Starting TaxTriage pipeline\u{2026}",
            operationType: .classification,
            cliCommand: taxTriageCLICommand(for: config),
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
