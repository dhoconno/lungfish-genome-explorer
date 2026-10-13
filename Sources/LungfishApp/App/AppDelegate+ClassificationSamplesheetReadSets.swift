// AppDelegate+ClassificationSamplesheetReadSets.swift - The TaxTriage launch resolves each sample's inputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishOperations
import LungfishWorkflow

/// The TaxTriage launch in AppDelegate+Classification.swift resolves each
/// sample's inputs here.
extension AppDelegate {

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
