// EsVirituCommand+ReadSets.swift - How lungfish-cli esviritu detect reads its inputs and read format
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

// The run itself resolves its inputs and plans each sample's read set in
// ``EsVirituAnalysisRunTool`` (2.7 A9), through the functions the app's EsViritu
// launch runs too (owner decision 1 of 2026-10-03, docs/contracts/READ-PAIRING.md).
// These are the same rules for the callers that check the command against the app,
// such as the parity and round-trip tests.
extension EsVirituCommand.DetectSubcommand {

    /// The folder in the result folder that holds the files a virtual bundle is materialized
    /// into, and the files a join writes (E3).
    static let materializationDirectoryName = EsVirituAnalysisRunTool.materializationDirectoryName

    /// Resolves `--read-format` and `--paired` into the EsViritu read format, as the run's plan
    /// does. `auto` classifies a single input with ``FASTQReadLayoutClassifier``.
    func resolveReadFormat(
        inputURLs: [URL]
    ) throws -> (format: EsVirituReadFormat, layout: FASTQReadLayoutClassification?) {
        try EsVirituAnalysisRunTool.resolveReadFormat(
            EsVirituAnalysisRunOptions.ReadFormatChoice(rawValue: readFormat.rawValue) ?? .auto,
            pairedEnd: pairedEnd,
            inputURLs: inputURLs
        )
    }

    /// Why `fileCount` input files do not fit `format`, or nil when they do.
    static func inputCountError(format: EsVirituReadFormat, fileCount: Int) -> String? {
        EsVirituAnalysisRunTool.inputCountError(format: format, fileCount: fileCount)
    }

    /// Resolves the inputs as the run does. Every file a `.lungfishfastq` bundle holds is its own
    /// EsViritu input, a virtual bundle is materialized into `materializationDirectory`, and an
    /// input with no readable sequence file is refused before anything is written.
    static func resolveExecutionInputs(
        for inputURLs: [URL],
        materializationDirectory: URL,
        materializer: any CLISequenceInputMaterializing & Sendable,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ResolvedSequenceInputs {
        try await ResolvedSequenceInputs.resolvePreflighted(
            inputURLs: inputURLs,
            operationName: "EsViritu detection",
            materializationDirectory: materializationDirectory,
            materializer: materializer,
            progress: progress
        )
    }

    /// Plans the sample's read set as the run does under `--read-format auto` without `--paired`, and
    /// sets `config` from it. Any other format keeps today's config and returns false.
    func planReadSet(
        inputURLs: [URL],
        executionInputURLs: [URL],
        config: inout EsVirituConfig,
        materializationDirectory: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Bool {
        guard readFormat == .auto, !pairedEnd else { return false }
        return try await EsVirituAnalysisRunTool.planReadSet(
            of: inputURLs,
            into: &config,
            materializedInputs: executionInputURLs,
            materializationDirectory: materializationDirectory,
            progress: progress
        )
    }

    /// The configuration of one sample's run on its inputs as given, before any input is resolved.
    func makeConfigForTesting(
        databaseURL: URL,
        outputDirectory: URL
    ) throws -> EsVirituConfig {
        let inputURLs = try CLIClassificationFolderResolver.expandInputArguments(
            inputFiles,
            recursive: recursive
        )
        let resolved = try resolveReadFormat(inputURLs: inputURLs)
        return EsVirituConfig(
            inputFiles: inputURLs,
            isPairedEnd: resolved.format == .paired,
            sampleName: sampleName ?? "sample",
            outputDirectory: outputDirectory,
            databasePath: databaseURL,
            qualityFilter: !noQC,
            threads: globalOptions.threads ?? ProcessInfo.processInfo.activeProcessorCount,
            extraArguments: try AdvancedCommandLineOptions.parse(extraArgs),
            readFormat: resolved.format,
            inputLayout: resolved.layout
        )
    }
}
