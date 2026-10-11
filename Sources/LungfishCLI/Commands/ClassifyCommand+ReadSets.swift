// ClassifyCommand+ReadSets.swift - How lungfish-cli kraken2 classify reads its inputs as pairs and single reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

extension ClassifyCommand {
    /// `--read-format` values. `auto` resolves per input, mirroring
    /// `lungfish esviritu detect`.
    enum ReadFormatChoice: String, ExpressibleByArgument, CaseIterable, Sendable {
        case auto
        case unpaired
        case paired
        case interleaved
    }

    /// The read format a run will use, with the layout scan that chose it.
    typealias ResolvedReadFormat = Kraken2ResolvedReadFormat

    /// The files a planned run reads, with the input each came from.
    typealias PlannedReadSetInputs = Kraken2PlannedReadSet

    /// The parsed options as the request ``Kraken2AnalysisRunTool`` runs, which also plans the read
    /// format, the configuration and the read set for the parity tests below, so both routes run
    /// one function.
    var runRequest: Kraken2RunRequest {
        Kraken2RunRequest(
            inputArguments: fastqFiles,
            databaseName: databaseName,
            databaseDigest: databaseDigest,
            preset: preset.toPreset(),
            confidence: confidence,
            minimumHitGroups: minHitGroups,
            threads: globalOptions.threads,
            readFormat: Kraken2ReadFormatChoice(rawValue: readFormat.rawValue) ?? .auto,
            pairedEnd: pairedEnd,
            unpairedArguments: unpaired,
            recursive: recursive,
            profile: profile,
            brackenReadLength: brackenReadLength,
            brackenLevel: brackenLevel,
            brackenThreshold: brackenThreshold,
            memoryMapping: memoryMapping,
            quickMode: quickMode,
            extraArguments: extraArgs,
            commandPath: Self.commandPath(in: CommandLine.arguments)
        )
    }

    /// Resolves the inputs as the app's classification launch does: every
    /// file a bundle holds is its own kraken2 input (``ResolvedSequenceInputs``).
    static func resolveExecutionInputs(
        for inputURLs: [URL],
        tempDirectory: URL,
        materializer: any CLISequenceInputMaterializing & Sendable,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ResolvedSequenceInputs {
        try await ResolvedSequenceInputs.resolvePreflighted(
            inputURLs: inputURLs,
            operationName: "classification",
            materializationDirectory: tempDirectory,
            materializer: materializer,
            progress: progress
        )
    }

    /// Resolves `--read-format` and `--paired` into the classification read format
    /// (``Kraken2RunRequest/resolveReadFormat(inputURLs:)``).
    func resolveReadFormat(inputURLs: [URL]) throws -> ResolvedReadFormat {
        try runRequest.resolveReadFormat(inputURLs: inputURLs)
    }

    /// Plans the sample's read set through ``KrakenReadSetPlanner``, the function the app's launch
    /// runs too, and sets `config` from it (``Kraken2RunRequest/planReadSet(inputURLs:executionInputURLs:config:materializationDirectory:)``).
    func planReadSet(
        inputURLs: [URL],
        executionInputURLs: [URL],
        config: inout ClassificationConfig,
        materializationDirectory: URL
    ) async throws -> PlannedReadSetInputs? {
        try await runRequest.planReadSet(
            inputURLs: inputURLs,
            executionInputURLs: executionInputURLs,
            config: &config,
            materializationDirectory: materializationDirectory
        )
    }
}
