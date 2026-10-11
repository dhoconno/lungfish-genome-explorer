// AppDelegate+ClassificationOperationBegin.swift - Operations panel registration for the classifier launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// The begin helpers for the Kraken2, EsViritu and TaxTriage launches in
/// AppDelegate+Classification.swift (finding R4). They live here, not beside
/// their launch sites, so the baselined AppDelegate+Classification.swift does
/// not grow (scripts/ratchets/file-size.sh). Each helper registers its row
/// through `OperationReporting` and calls `launch` only when the row started,
/// so a test can check the row and its command without touching
/// `OperationCenter.shared`. None of the five rows locks a bundle, so a real
/// `OperationCenter` never refuses them.
extension AppDelegate {
    // MARK: - Kraken2

    /// Registers the single-sample Kraken2 row and calls `launch` with the
    /// operation ID only when the row started. The row locks no bundle. Its
    /// title names the goal and the first input file.
    ///
    /// The row records the `lungfish-cli kraken2 classify` command with the
    /// arguments `ClassificationCLIInvocationBuilder` builds from `config`, the
    /// same argv mapping the batch replay command uses. `--db` is the registry
    /// name and not a filesystem path, and the preset, read format, profile
    /// options and output folder are all included, so the command runs as
    /// pasted. The row used to print the builder's `displayString`, which
    /// starts with the legacy executable name `lungfish`, and then named the
    /// command `conda classify`, the same command under its older name.
    @discardableResult
    static func beginClassificationOperation(
        config: ClassificationConfig,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let inputName = config.inputFiles.first?.lastPathComponent ?? "reads"
        let goalLabel: String
        switch config.goal {
        case .classify: goalLabel = "Classifying"
        case .profile: goalLabel = "Profiling"
        case .extract: goalLabel = "Classifying (extract)"
        }
        let result = reporter.begin(
            title: "\(goalLabel) \(inputName)",
            detail: "Starting Kraken2 with \(config.databaseName)...",
            operationType: .classification,
            cliCommand: classificationCLICommand(for: config),
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

    /// The `lungfish-cli kraken2 classify` command for one sample, with the
    /// arguments `ClassificationCLIInvocationBuilder` builds from `config`, the
    /// argv mapping the batch provenance replay command uses too. The row names
    /// the command `kraken2 classify`, as the builder, the replay command, the
    /// CLI route and the command's own records do (Phase 2.7 decision E11).
    nonisolated static func classificationCLICommand(for config: ClassificationConfig) -> String {
        OperationCenter.buildCLICommand(
            subcommand: "kraken2 classify",
            args: Array(ClassificationCLIInvocationBuilder.build(for: config).arguments.dropFirst(2))
        )
    }

    /// The command a Kraken2 batch row records, one `lungfish-cli kraken2
    /// classify` command per sample on its own line, or nil for an empty
    /// batch (R3).
    ///
    /// The legacy batch runs one classification per sample, so each line is
    /// that sample's command from `classificationCLICommand(for:)`. Each line
    /// is the `kraken2 classify` command of that sample in the provenance
    /// replay command, `classificationBatchReplayCommand`, with the registry
    /// name in `--db`, the sample's output folder and the run's settings. The
    /// replay command also checks the database's installation receipt before
    /// each sample, which the row leaves out because those checks are shell
    /// tests, not `lungfish-cli` commands. The row used to record one command
    /// with the database path in `--db`, no output folder and every input of
    /// every sample in one unpaired list, which reproduced nothing.
    nonisolated static func classificationBatchCLICommand(for configs: [ClassificationConfig]) -> String? {
        guard !configs.isEmpty else { return nil }
        return configs.map(classificationCLICommand(for:)).joined(separator: "\n")
    }

    /// Registers the Kraken2 batch row and calls `launch` with the operation
    /// ID only when the row started. The row locks no bundle and records
    /// `classificationBatchCLICommand(for:)`.
    @discardableResult
    static func beginClassificationBatchOperation(
        configs: [ClassificationConfig],
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let sampleCount = configs.count
        let result = reporter.begin(
            title: "Classification Batch (\(sampleCount) sample\(sampleCount == 1 ? "" : "s"))",
            detail: "Starting Kraken2/Bracken batch\u{2026}",
            operationType: .classification,
            cliCommand: classificationBatchCLICommand(for: configs),
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

    // MARK: - EsViritu

    /// Registers the single-sample EsViritu row and calls `launch` with the
    /// operation ID only when the row started. The row locks no bundle.
    ///
    /// The row records the `lungfish-cli esviritu detect` command that
    /// `esVirituDetectCLIArguments(for:)` builds from the run's configuration.
    @discardableResult
    static func beginEsVirituOperation(
        config: EsVirituConfig,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "EsViritu \(config.sampleName)",
            detail: "Starting EsViritu viral detection\u{2026}",
            operationType: .classification,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "esviritu detect",
                args: EsVirituCLIInvocationBuilder.esVirituDetectCLIArguments(for: config)
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

    /// Registers the EsViritu batch row and calls `launch` with the operation
    /// ID only when the row started. The row locks no bundle.
    ///
    /// cli-parity-gap: esviritu-batch. The batch runs EsViritu once per
    /// sample, each with its own read format, and no command does. The row
    /// used to record one `lungfish-cli esviritu detect` that lists every
    /// input of every sample after `--input`, which would fold the samples
    /// into one run of one sample. The row records no command until a batch
    /// command lands. The closest reproduction is `esviritu detect` once per
    /// sample.
    @discardableResult
    static func beginEsVirituBatchOperation(
        configs: [EsVirituConfig],
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let sampleCount = configs.count
        let result = reporter.begin(
            title: "EsViritu Batch (\(sampleCount) sample\(sampleCount == 1 ? "" : "s"))",
            detail: "Starting EsViritu batch\u{2026}",
            operationType: .classification,
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
        args += ["--revision", config.revision]
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
