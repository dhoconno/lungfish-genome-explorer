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
}
