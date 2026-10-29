// Kraken2RunRequest+Planning.swift - The read format, configuration, read set and database checks of a Kraken2 run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

/// Why the inputs of a Kraken2 run have no one sequence format. The command exits with
/// `CLIExitCode.inputError` for both.
public enum Kraken2InputFormatError: Error, LocalizedError, AnalysisRunExitCoding, Equatable, Sendable {
    case undetected(path: String)
    case mixed

    public var errorDescription: String? {
        switch self {
        case .undetected(let path): return "Could not detect format for file: \(path)"
        case .mixed: return "All input sequence files must use the same format (FASTA or FASTQ)."
        }
    }

    public var analysisRunExitCode: Int32 { Kraken2RunRefusal.inputErrorCode }
}

extension Kraken2RunRequest {
    /// Resolves `--read-format` and `--paired` into the classification read format. `auto`
    /// classifies a single input with ``FASTQReadLayoutClassifier``, and several inputs without
    /// `--paired` stay unpaired.
    public func resolveReadFormat(inputURLs: [URL]) throws -> Kraken2ResolvedReadFormat {
        if !unpairedArguments.isEmpty, !((pairedEnd || readFormat == .paired) && inputURLs.count == 2) {
            throw Kraken2RunRefusal.input(
                KrakenReadSetPlannerError.unpairedNeedsAPair.errorDescription ?? "--unpaired needs --paired."
            )
        }
        if pairedEnd {
            guard readFormat == .auto || readFormat == .paired else {
                throw Kraken2RunRefusal.input("--paired conflicts with --read-format \(readFormat.rawValue).")
            }
            return Kraken2ResolvedReadFormat(format: .paired, layout: nil)
        }
        switch readFormat {
        case .unpaired: return Kraken2ResolvedReadFormat(format: .unpaired, layout: nil)
        case .paired: return Kraken2ResolvedReadFormat(format: .paired, layout: nil)
        case .interleaved: return Kraken2ResolvedReadFormat(format: .interleaved, layout: nil)
        case .auto:
            guard inputURLs.count == 1 else { return Kraken2ResolvedReadFormat(format: .unpaired, layout: nil) }
            let layout = FASTQReadLayoutClassifier.classify(inputURL: inputURLs[0])
            return Kraken2ResolvedReadFormat(format: .forSingleFile(layout.layout), layout: layout)
        }
    }

    /// The one sequence format of every input, FASTA or FASTQ.
    public static func inferInputFormat(from inputURLs: [URL]) throws -> SequenceFormat {
        let formats = try inputURLs.map { url -> SequenceFormat in
            guard let format = SequenceInputResolver.inputSequenceFormat(for: url) else {
                throw Kraken2InputFormatError.undetected(path: url.path)
            }
            return format
        }
        guard let first = formats.first else { return .fastq }
        guard formats.dropFirst().allSatisfy({ $0 == first }) else { throw Kraken2InputFormatError.mixed }
        return first
    }

    /// The configuration of one run from its preset, without the `--confidence` and
    /// `--min-hit-groups` overrides (``applyingThresholdOverrides(to:)``).
    public func makeConfig(
        inputURLs: [URL],
        readFormat resolved: Kraken2ResolvedReadFormat,
        databaseInfo: MetagenomicsDatabaseInfo?,
        databasePath: URL,
        inputFormat: SequenceFormat,
        outputDirectory: URL,
        extraArguments: [String]
    ) -> ClassificationConfig {
        ClassificationConfig.fromPreset(
            preset,
            goal: profile ? .profile : .classify,
            inputFiles: inputURLs,
            isPairedEnd: resolved.format == .paired,
            interleavedInput: resolved.format == .interleaved,
            inputLayout: resolved.layout,
            databaseName: databaseName,
            inputFormat: inputFormat,
            databaseVersion: databaseInfo?.checkedVersion ?? "unknown",
            databasePath: databasePath,
            databaseDigest: databaseInfo?.payloadDigest,
            databaseCatalogID: databaseInfo?.catalogID,
            databaseInstallationRecipe: databaseInfo?.installationRecipe,
            brackenProfileRequest: brackenProfileRequest,
            threads: effectiveThreads,
            memoryMapping: memoryMapping,
            quickMode: quickMode,
            outputDirectory: outputDirectory,
            extraArguments: extraArguments
        )
    }

    /// `config` with the given `--confidence` and `--min-hit-groups`.
    public func applyingThresholdOverrides(to config: ClassificationConfig) -> ClassificationConfig {
        var config = config
        if let confidence { config.confidence = confidence }
        if let minimumHitGroups { config.minimumHitGroups = minimumHitGroups }
        return config
    }

    /// Plans the sample's read set through ``KrakenReadSetPlanner``, the function the app's launch
    /// runs too, and sets `config` from it.
    ///
    /// Two inputs given as pairs with `--unpaired` files run the pair and the single reads
    /// together. One bundle or file under `--read-format auto` runs its pairs as pairs and its
    /// merged or single reads beside them. Any other input, and one of single reads only or one
    /// interleaved file, keeps the config and returns nil.
    public func planReadSet(
        inputURLs: [URL],
        executionInputURLs: [URL],
        config: inout ClassificationConfig,
        materializationDirectory: URL
    ) async throws -> Kraken2PlannedReadSet? {
        if !unpairedArguments.isEmpty, config.isPairedEnd, executionInputURLs.count == 2 {
            let plan = try KrakenReadSetPlanner.plan(
                r1: executionInputURLs[0],
                r2: executionInputURLs[1],
                singleReads: unpairedArguments.map { URL(fileURLWithPath: $0).standardizedFileURL },
                materializationDirectory: materializationDirectory
            )
            guard try KrakenReadSetPlanner.apply(plan, to: &config, recordedWithAuto: false) else { return nil }
        } else if readFormat == .auto, !pairedEnd, let input = KrakenReadSetPlanner.plannableInput(inputURLs) {
            let plan = try await KrakenReadSetPlanner.plan(
                bundle: input,
                materializedInputs: executionInputURLs,
                materializationDirectory: materializationDirectory
            )
            guard try KrakenReadSetPlanner.apply(plan, to: &config) else { return nil }
        } else {
            return nil
        }
        let executionURLs = config.inputFiles + config.singleReadFiles
        let originals = inputURLs.count == 1
            ? Array(repeating: inputURLs[0].standardizedFileURL, count: executionURLs.count)
            : executionURLs
        return Kraken2PlannedReadSet(executionInputURLs: executionURLs, originalInputURLs: originals)
    }
}
