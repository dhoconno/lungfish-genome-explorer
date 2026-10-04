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
    /// The row records the `lungfish-cli conda classify` command that
    /// `ClassificationCLIInvocationBuilder` builds from `config`, the same
    /// argv mapping the batch replay command uses. `--db` is the registry name
    /// and not a filesystem path, and the preset, read format, profile options
    /// and output folder are all included, so the command runs as pasted. The
    /// row used to print the builder's `displayString`, which starts with the
    /// legacy executable name `lungfish`. The arguments are unchanged and the
    /// command now starts with `lungfish-cli`.
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

    /// The `lungfish-cli conda classify` command for one sample, built from
    /// `config` by `ClassificationCLIInvocationBuilder`, the argv mapping the
    /// batch provenance replay command uses too.
    nonisolated static func classificationCLICommand(for config: ClassificationConfig) -> String {
        OperationCenter.buildCLICommand(
            subcommand: "conda classify",
            args: Array(ClassificationCLIInvocationBuilder.build(for: config).arguments.dropFirst(2))
        )
    }

    /// The command a Kraken2 batch row records, one `lungfish-cli conda
    /// classify` command per sample on its own line, or nil for an empty
    /// batch (R3).
    ///
    /// `conda classify` has no batch form, and the batch runs one
    /// classification per sample, so each line is that sample's command from
    /// `classificationCLICommand(for:)`. Each line is the `conda classify`
    /// command of that sample in the provenance replay command,
    /// `classificationBatchReplayCommand`, with the registry name in `--db`,
    /// the sample's output folder and the run's settings. The replay command
    /// also checks the database's installation receipt before each sample,
    /// which the row leaves out because those checks are shell tests, not
    /// `lungfish-cli` commands. The row used to record one command with the
    /// database path in `--db`, no output folder and every input of every
    /// sample in one unpaired list, which reproduced nothing.
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

    /// Arguments after `lungfish esviritu detect` recorded for a single-sample run.
    ///
    /// The command names every setting the run uses, so a pasted command runs
    /// the same detection (R3). The inputs are recorded as the wizard chose
    /// them, and `esviritu detect` resolves a `.lungfishfastq` bundle as the
    /// run does. The read format the wizard chose is recorded explicitly so
    /// the copied command runs pairs as pairs and mixed input as single-end.
    /// An input the read-set planner decides (`plansReadSet`: separate R1 and
    /// R2 files, a mix of pairs and single reads, or several files of single
    /// reads) records `--read-format auto`, so the CLI plans the bundle and
    /// runs the same files. The database, output folder, thread count, quality
    /// filter and extra arguments follow, so the CLI never falls back to
    /// defaults of its own.
    nonisolated static func esVirituDetectCLIArguments(for config: EsVirituConfig) -> [String] {
        var args = ["--input"] + config.inputFiles.map(\.path)
        args += ["--sample", config.sampleName]
        args += ["--read-format", config.plansReadSet ? "auto" : config.readFormat.rawValue]
        args += ["--db", config.databasePath.path]
        args += ["--output", config.outputDirectory.path]
        args += ["--threads", String(config.threads)]
        if !config.qualityFilter {
            args.append("--no-qc")
        }
        if !config.extraArguments.isEmpty {
            args += ["--extra-args", AdvancedCommandLineOptions.join(config.extraArguments)]
        }
        return args
    }

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
                args: esVirituDetectCLIArguments(for: config)
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

    /// Arguments after `lungfish-cli esviritu detect` recorded for a batch run.
    ///
    /// Every sample's inputs follow one `--input`, and `--sample` names the
    /// first sample. The batch row and the batch provenance both start from
    /// this list.
    nonisolated static func esVirituBatchCLIArguments(for configs: [EsVirituConfig]) -> [String] {
        var args = ["--input"]
        for config in configs {
            args += config.inputFiles.map(\.path)
        }
        args += ["--sample", configs.first?.sampleName ?? "batch"]
        return args
    }

    /// Registers the EsViritu batch row and calls `launch` with the operation
    /// ID only when the row started. The row locks no bundle.
    ///
    /// CLI parity gap. The row records one `lungfish-cli esviritu detect`
    /// command that lists every input of every sample after `--input` and
    /// names the first sample. The batch runs EsViritu once per sample, and
    /// the pasted command would fold every input into one unpaired sample. It
    /// shares the bundle refusal that `beginEsVirituOperation` describes. The
    /// closest reproduction is `esviritu detect` once per sample.
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
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "esviritu detect",
                args: esVirituBatchCLIArguments(for: configs)
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

    // MARK: - TaxTriage

    /// The command a TaxTriage row records for `config`.
    ///
    /// A one-sample run records `lungfish-cli taxtriage --input <fastq>
    /// --sample <id>` with every setting the run uses. `taxtriage run` builds
    /// the same Nextflow arguments from it, which a test compares. The app's
    /// own result grouping has no option. That covers `sourceBundleURLs`, the
    /// negative control flags and the sample metadata, and none of them
    /// reaches Nextflow. A `.lungfishfastq` input works in `taxtriage run`
    /// only when the bundle holds one physical FASTQ file, because only the
    /// app materializes a virtual bundle.
    ///
    /// CLI parity gap for several samples. `taxtriage run` takes one `--input`
    /// or one `--samplesheet`, and the app runs the samples one after another
    /// through `TaxTriageSerialBatchRunner`, which `taxtriage run` does not
    /// use. No single command reproduces that, so a batch keeps the flat
    /// `--input` list the row recorded before, which the CLI rejects. The
    /// closest commands are `taxtriage run` once per sample, or `taxtriage run
    /// --samplesheet`, which runs every sample in one Nextflow pass and writes
    /// no batch result manifest.
    nonisolated static func taxTriageCLICommand(for config: TaxTriageConfig) -> String {
        if config.samples.count == 1, let sample = config.samples.first {
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
        var args = ["--input"]
        for sample in config.samples {
            args.append(sample.fastq1.path)
            if let fastq2 = sample.fastq2 { args.append(fastq2.path) }
        }
        if let removeTaxids = config.effectiveRemoveTaxids {
            args += ["--remove-taxids", removeTaxids]
        }
        return OperationCenter.buildCLICommand(subcommand: "taxtriage", args: args)
    }

    /// Registers the TaxTriage row and calls `launch` with the operation ID
    /// only when the row started. The row locks no bundle and records the
    /// command that `taxTriageCLICommand(for:)` builds.
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
