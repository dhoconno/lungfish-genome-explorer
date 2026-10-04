// AppDelegate+ClassificationSamplesheetReadSets.swift - The EsViritu and TaxTriage launches resolve each sample's inputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

/// The EsViritu and TaxTriage launches in AppDelegate+Classification.swift
/// resolve each sample's inputs here, so the baselined
/// AppDelegate+Classification.swift does not grow.
extension AppDelegate {

    /// The config an EsViritu sample runs with. Its inputs are resolved, with
    /// a virtual bundle materialized into `tempDirectory`. A sample whose
    /// recorded command plans it (`plansReadSet`) gets its files and read
    /// format from ``EsVirituConfig/readSet(for:materializedInputs:materializationDirectory:progress:)``,
    /// the function `lungfish-cli esviritu detect --read-format auto` runs
    /// (owner decision 1 of 2026-10-03, docs/contracts/READ-PAIRING.md).
    /// Separate R1 and R2 files run as a pair, and every read of a mixed or
    /// chunked sample runs in one file, with the reason logged. `materializer`
    /// is the launch's own unless a test gives one.
    func resolvedEsVirituConfig(
        _ config: EsVirituConfig,
        tempDirectory: URL,
        materializer: (any CLISequenceInputMaterializing & Sendable)? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> EsVirituConfig {
        var resolved = config
        resolved.inputFiles = try await ResolvedSequenceInputs.resolve(
            inputURLs: config.inputFiles,
            materializationDirectory: tempDirectory,
            materializer: materializer ?? Self.launchMaterializer,
            progress: progress
        ).executionInputURLs
        guard config.plansReadSet,
              let input = SamplesheetReadSetPlanner.plannableInput(config.inputFiles) else {
            return resolved
        }
        let readSet = try await EsVirituConfig.readSet(
            for: input,
            materializedInputs: resolved.inputFiles,
            materializationDirectory: tempDirectory,
            progress: progress
        )
        if resolved.apply(readSet), let reason = readSet.plan.singleReadReason {
            progress?(reason)
        }
        return resolved
    }

    /// The config a TaxTriage run uses. Each sample's inputs are resolved to
    /// the files TaxTriage reads, with a virtual bundle materialized into
    /// `tempDirectory`. The resolution is
    /// ``TaxTriageReadSetPlanner/resolve(_:materializationDirectory:materializer:progress:)``,
    /// the function `lungfish-cli taxtriage run` runs too (owner decision 1 of
    /// 2026-10-03, docs/contracts/READ-PAIRING.md). A bundle of pairs runs as
    /// fastq_1 and fastq_2, and every read of a mixed or chunked bundle runs in
    /// one single-end file, with the reason logged. `materializer` is the
    /// launch's own unless a test gives one.
    func resolvedTaxTriageConfig(
        _ config: TaxTriageConfig,
        tempDirectory: URL,
        materializer: (any CLISequenceInputMaterializing & Sendable)? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> TaxTriageConfig {
        var resolvedConfig = config
        for (index, sample) in config.samples.enumerated() {
            resolvedConfig.samples[index] = try await TaxTriageReadSetPlanner.resolve(
                sample,
                materializationDirectory: tempDirectory,
                materializer: materializer ?? Self.launchMaterializer,
                progress: progress
            )
        }
        return resolvedConfig
    }

    /// The materializer the classifier launches use for a virtual bundle, the
    /// derivative service's tool runner.
    private static var launchMaterializer: any CLISequenceInputMaterializing & Sendable {
        FASTQCLIMaterializer(runner: FASTQDerivativeService.shared.runner)
    }
}
