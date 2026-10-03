// AppDelegate+ClassificationReadSets.swift - The Kraken2 launches resolve and pair each sample as conda classify does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

/// The Kraken2 launches in AppDelegate+Classification.swift build each
/// sample's run from `KrakenReadSetPlanner`, the function
/// `lungfish-cli conda classify --read-format auto` runs (owner decisions 1
/// and 2 of 2026-10-03, docs/contracts/READ-PAIRING.md). The code lives here
/// so the baselined AppDelegate+Classification.swift does not grow.
extension AppDelegate {

    /// The config a Kraken2 sample runs with. Its inputs are resolved, with a
    /// virtual bundle materialized into `tempDirectory`. A bundle whose read
    /// set the recorded command plans (`plansReadSet`) gets its pairs and its
    /// merged or single reads from the planner.
    func resolvedKraken2Config(
        _ config: ClassificationConfig,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ClassificationConfig {
        let resolvedFiles = try await resolveInputFiles(
            config.inputFiles,
            tempDirectory: tempDirectory,
            progress: progress
        )
        var resolved = config
        // The bundle's name, not "materialized", names the sample in the viewer.
        if resolved.sampleDisplayName == nil {
            resolved.sampleDisplayName = config.inputFiles.first?.deletingPathExtension().lastPathComponent
        }
        // Extraction finds the reads through the original inputs after the
        // materialized temp file is gone.
        if resolved.originalInputFiles == nil {
            resolved.originalInputFiles = config.inputFiles
        }
        resolved.inputFiles = resolvedFiles
        return try await Self.planKraken2ReadSet(resolved, materializedInputs: resolvedFiles)
    }

    /// Plans the read set of a sample whose recorded command plans it, as
    /// `conda classify` does for one bundle under `--read-format auto`. Any
    /// other config is returned unchanged.
    nonisolated static func planKraken2ReadSet(
        _ config: ClassificationConfig,
        materializedInputs: [URL]
    ) async throws -> ClassificationConfig {
        guard config.plansReadSet,
              let bundle = KrakenReadSetPlanner.plannableBundle(config.originalInputFiles ?? []) else {
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
}
