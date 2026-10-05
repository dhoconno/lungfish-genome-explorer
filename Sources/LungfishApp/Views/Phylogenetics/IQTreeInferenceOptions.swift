// IQTreeInferenceOptions.swift - IQ-TREE runner options
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The options the IQ-TREE dialog hands to the runner. Every value is already
/// validated. `rows` and `columns` are set only for the Selected scope (K4).
/// `seed` is nil when the user left the field blank, and the launch draws one
/// before `begin` (D5). `threads` is always set (D6).
struct IQTreeInferenceOptions: Equatable, Sendable {
    var outputName: String
    var rows: String?
    var columns: String?
    var model: String
    var sequenceType: String
    var bootstrap: Int?
    var alrt: Int?
    var seed: Int?
    var threads: Int
    var outgroup: [String]
    var safeMode: Bool
    var keepIdenticalSequences: Bool
    var iqtreePath: String?
    var extraIQTreeOptions: String
}

/// The exact argv the GUI runs for one IQ-TREE launch, with the seed resolved.
/// The Operations row records the command built from these same arguments, so
/// the recorded command and the run cannot drift apart.
struct IQTreeInferenceLaunch: Equatable, Sendable {
    let arguments: [String]
    let seed: Int
    let seedWasDrawn: Bool

    var cliCommand: String {
        CLIMSAActionCommandBuilder.displayCommand(arguments: arguments)
    }

    /// The Operations row log line that names the seed.
    var seedLogMessage: String {
        seedWasDrawn
            ? "Random seed \(seed) was drawn for this run and recorded in the command."
            : "Seed \(seed) was set in the dialog."
    }

    /// Draws a seed in 1...Int32.max, the range IQ-TREE accepts.
    static func drawRandomSeed() -> Int {
        Int.random(in: 1...Int(Int32.max))
    }

    static func make(
        bundleURL: URL,
        projectURL: URL,
        outputURL: URL,
        outputName: String,
        options: IQTreeInferenceOptions,
        drawSeed: () -> Int = IQTreeInferenceLaunch.drawRandomSeed
    ) -> IQTreeInferenceLaunch {
        let seed = options.seed ?? drawSeed()
        let arguments = CLIMSAActionCommandBuilder.buildIQTreeInferenceArguments(
            bundleURL: bundleURL,
            projectURL: projectURL,
            outputURL: outputURL,
            rows: options.rows,
            columns: options.columns,
            name: outputName,
            model: options.model,
            sequenceType: options.sequenceType,
            bootstrap: options.bootstrap,
            alrt: options.alrt,
            seed: seed,
            threads: options.threads,
            outgroup: options.outgroup,
            safeMode: options.safeMode,
            keepIdenticalSequences: options.keepIdenticalSequences,
            extraIQTreeOptions: options.extraIQTreeOptions,
            iqtreePath: options.iqtreePath,
            force: false
        )
        return IQTreeInferenceLaunch(
            arguments: arguments,
            seed: seed,
            seedWasDrawn: options.seed == nil
        )
    }
}
