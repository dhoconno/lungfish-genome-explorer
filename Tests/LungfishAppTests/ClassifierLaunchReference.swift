// ClassifierLaunchReference.swift - The reference rows and read sets the classifier tests compare the CLI against
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A32. The in-process Kraken2 and EsViritu launches left App in Phase 2.9 (E14), and
// their begin helpers, command builders and read-set resolvers (the A12 orphans) only tests called.
// These functions are what those tests compared the CLI against, written with the Workflow
// functions the CLI commands and the CLI route call, so the tests no longer depend on App code that
// no launch uses. Each function does what its orphan did, step for step.

import Foundation
@testable import LungfishIO
import LungfishKit
@testable import LungfishWorkflow

enum ClassifierLaunchReference {

    // MARK: - Recorded commands

    /// The `lungfish-cli kraken2 classify` command for one sample, the argv of
    /// `ClassificationCLIInvocationBuilder` after the two words of the command.
    static func kraken2Command(for config: ClassificationConfig) -> String {
        OperationCenter.buildCLICommand(
            subcommand: "kraken2 classify",
            args: Array(ClassificationCLIInvocationBuilder.build(for: config).arguments.dropFirst(2))
        )
    }

    /// One `kraken2 classify` command per sample, each on its own line, or nil for no sample.
    static func kraken2BatchCommand(for configs: [ClassificationConfig]) -> String? {
        guard !configs.isEmpty else { return nil }
        return configs.map(kraken2Command(for:)).joined(separator: "\n")
    }

    /// The `lungfish-cli esviritu detect` command for one sample.
    static func esVirituCommand(for config: EsVirituConfig) -> String {
        OperationCenter.buildCLICommand(
            subcommand: "esviritu detect",
            args: EsVirituCLIInvocationBuilder.esVirituDetectCLIArguments(for: config)
        )
    }

    // MARK: - Read sets

    /// The config a Kraken2 sample ran with. Its inputs are resolved, with a virtual bundle
    /// materialized into `tempDirectory`, and a bundle whose read set the recorded command plans
    /// (`plansReadSet`) gets its pairs and its merged or single reads from `KrakenReadSetPlanner`.
    static func kraken2Resolved(
        _ config: ClassificationConfig,
        tempDirectory: URL,
        materializer: (any CLISequenceInputMaterializing & Sendable)? = nil
    ) async throws -> ClassificationConfig {
        let resolvedFiles = try await ResolvedSequenceInputs.resolve(
            inputURLs: config.inputFiles,
            materializationDirectory: tempDirectory,
            materializer: materializer ?? FASTQCLIMaterializer(runner: .shared)
        ).executionInputURLs
        var resolved = config
        // The bundle's name, not "materialized", names the sample in the viewer.
        if resolved.sampleDisplayName == nil {
            resolved.sampleDisplayName = config.inputFiles.first?.deletingPathExtension().lastPathComponent
        }
        // Extraction finds the reads through the original inputs after the materialized temp file is gone.
        if resolved.originalInputFiles == nil {
            resolved.originalInputFiles = config.inputFiles
        }
        resolved.inputFiles = resolvedFiles
        return try await kraken2Planned(resolved, materializedInputs: resolvedFiles)
    }

    /// Plans the read set of a sample whose recorded command plans it, as `kraken2 classify` does
    /// for one bundle under `--read-format auto`. Any other config is returned unchanged.
    static func kraken2Planned(
        _ config: ClassificationConfig,
        materializedInputs: [URL]
    ) async throws -> ClassificationConfig {
        guard config.plansReadSet,
              let bundle = KrakenReadSetPlanner.plannableInput(config.originalInputFiles ?? []) else {
            return config
        }
        let plan = try await KrakenReadSetPlanner.plan(
            bundle: bundle,
            materializedInputs: materializedInputs,
            materializationDirectory: config.outputDirectory
                .appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName, isDirectory: true)
        )
        var planned = config
        try KrakenReadSetPlanner.apply(plan, to: &planned)
        return planned
    }

    /// The config an EsViritu sample ran with. Its inputs are resolved, with a virtual bundle
    /// materialized into `tempDirectory`, and a sample whose recorded command plans it
    /// (`plansReadSet`) gets its files and read format from
    /// ``EsVirituConfig/readSet(for:materializedInputs:materializationDirectory:progress:)``.
    static func esVirituResolved(
        _ config: EsVirituConfig,
        tempDirectory: URL,
        materializer: (any CLISequenceInputMaterializing & Sendable)? = nil
    ) async throws -> EsVirituConfig {
        var resolved = config
        resolved.inputFiles = try await ResolvedSequenceInputs.resolve(
            inputURLs: config.inputFiles,
            materializationDirectory: tempDirectory,
            materializer: materializer ?? FASTQCLIMaterializer(runner: .shared)
        ).executionInputURLs
        guard config.plansReadSet,
              let input = SamplesheetReadSetPlanner.plannableInput(config.inputFiles) else {
            return resolved
        }
        let readSet = try await EsVirituConfig.readSet(
            for: input,
            materializedInputs: resolved.inputFiles,
            materializationDirectory: tempDirectory
        )
        _ = resolved.apply(readSet)
        return resolved
    }
}
