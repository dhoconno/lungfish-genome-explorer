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
    /// chunked sample runs in one file, with the reason logged.
    func resolvedEsVirituConfig(
        _ config: EsVirituConfig,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> EsVirituConfig {
        var resolved = config
        resolved.inputFiles = try await resolveInputFiles(
            config.inputFiles,
            tempDirectory: tempDirectory,
            progress: progress
        )
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

    /// The config a TaxTriage run uses. Each sample's inputs are resolved,
    /// with a virtual bundle materialized into `tempDirectory`.
    func resolvedTaxTriageConfig(
        _ config: TaxTriageConfig,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> TaxTriageConfig {
        var resolvedConfig = config
        for (i, sample) in resolvedConfig.samples.enumerated() {
            let allFiles = [sample.fastq1] + (sample.fastq2.map { [$0] } ?? [])
            let resolved = try await resolveInputFiles(
                allFiles,
                tempDirectory: tempDirectory,
                progress: progress
            )
            resolvedConfig.samples[i].fastq1 = resolved[0]
            if resolved.count > 1 {
                resolvedConfig.samples[i].fastq2 = resolved[1]
            } else if sample.fastq2 == nil,
                      resolved[0].standardizedFileURL != sample.fastq1.standardizedFileURL {
                // A materialized scratch copy carries no bundle sidecar,
                // so resolve its layout now with the bundle's metadata as
                // hints (a VSP2 merge in the lineage demotes strict to
                // mixed). TaxTriagePipeline splits a strictly interleaved
                // file into R1/R2 and runs it as pairs.
                resolvedConfig.samples[i].readLayout = FASTQInputLayoutResolver.resolve(
                    fastqURL: resolved[0],
                    metadataFrom: sample.fastq1
                ).layout
            }
        }
        return resolvedConfig
    }
}
