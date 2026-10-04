// ClassifyCommand+ReadSets.swift - How lungfish-cli conda classify reads its inputs as pairs and single reads
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
    struct ResolvedReadFormat: Equatable, Sendable {
        let format: ClassificationConfig.ReadFormat
        let layout: FASTQReadLayoutClassification?
    }

    /// Resolves `--read-format` and `--paired` into the classification read format.
    ///
    /// `auto` classifies a single input with ``FASTQReadLayoutClassifier``;
    /// several inputs without `--paired` stay unpaired, as before.
    func resolveReadFormat(inputURLs: [URL]) throws -> ResolvedReadFormat {
        if !unpaired.isEmpty, !((pairedEnd || readFormat == .paired) && inputURLs.count == 2) {
            throw CLIError.validationFailed(errors: [
                KrakenReadSetPlannerError.unpairedNeedsAPair.errorDescription ?? "--unpaired needs --paired.",
            ])
        }
        if pairedEnd {
            guard readFormat == .auto || readFormat == .paired else {
                throw CLIError.validationFailed(errors: [
                    "--paired conflicts with --read-format \(readFormat.rawValue)."
                ])
            }
            return ResolvedReadFormat(format: .paired, layout: nil)
        }
        switch readFormat {
        case .unpaired: return ResolvedReadFormat(format: .unpaired, layout: nil)
        case .paired: return ResolvedReadFormat(format: .paired, layout: nil)
        case .interleaved: return ResolvedReadFormat(format: .interleaved, layout: nil)
        case .auto:
            guard inputURLs.count == 1 else { return ResolvedReadFormat(format: .unpaired, layout: nil) }
            let layout = FASTQReadLayoutClassifier.classify(inputURL: inputURLs[0])
            return ResolvedReadFormat(format: .forSingleFile(layout.layout), layout: layout)
        }
    }

    /// The files a planned run reads, with the input each came from.
    struct PlannedReadSetInputs: Sendable {
        let executionInputURLs: [URL]
        let originalInputURLs: [URL]
    }

    /// Plans the sample's read set through ``KrakenReadSetPlanner``, the
    /// function the app's launch runs too (decisions 1 and 2), and sets
    /// `config` from it.
    ///
    /// Two inputs given as pairs with `--unpaired` files run the pair and
    /// the single reads together. One bundle or file under `--read-format
    /// auto` runs its pairs as pairs and its merged or single reads beside
    /// them. Any other input, and one of single reads only or one interleaved
    /// file, keeps today's config and returns nil.
    func planReadSet(
        inputURLs: [URL],
        executionInputURLs: [URL],
        config: inout ClassificationConfig,
        materializationDirectory: URL
    ) async throws -> PlannedReadSetInputs? {
        if !unpaired.isEmpty, config.isPairedEnd, executionInputURLs.count == 2 {
            let plan = try KrakenReadSetPlanner.plan(
                r1: executionInputURLs[0],
                r2: executionInputURLs[1],
                singleReads: unpaired.map { URL(fileURLWithPath: $0).standardizedFileURL },
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
        return PlannedReadSetInputs(executionInputURLs: executionURLs, originalInputURLs: originals)
    }
}
