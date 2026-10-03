// MapCommand+DefaultPreset.swift - The preset `lungfish-cli map` uses when --preset is not given
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

extension MapCommand {

    /// The preset chosen when `--preset` is absent, and a note saying why.
    struct DefaultPreset: Equatable {
        let mode: MappingMode
        let note: String
    }

    /// The default preset follows the read class the inputs record or show,
    /// as the Map Reads window preselects it. Inputs of unknown platform take
    /// the long-read or short-read default from their read lengths, with a
    /// note that the default is not tuned to a platform. An explicit
    /// `--preset` always wins and never reaches this function.
    static func defaultPreset(tool: MappingTool, inputURLs: [URL]) -> DefaultPreset {
        let inspection = MappingInputInspection.inspect(urls: inputURLs)
        let inputFormat = inspection.sequenceFormat ?? .fastq
        let fallback = MappingMode.availableModes(for: tool).first ?? .defaultShortRead
        if inputFormat == .fasta {
            let mode = MappingMode.preferredMode(for: tool, readClass: nil, inputFormat: .fasta) ?? fallback
            return DefaultPreset(mode: mode, note: "Preset \(Self.presetSpelling(mode)) is the default for FASTA input. Pass --preset to choose another.")
        }
        if let readClass = inspection.readClass {
            let mode = MappingMode.preferredMode(for: tool, readClass: readClass) ?? fallback
            return DefaultPreset(
                mode: mode,
                note: "Preset \(Self.presetSpelling(mode)) follows the input read class, \(readClass.displayName). Pass --preset to choose another."
            )
        }
        let lengthClass = inspection.mixedReadClasses ? nil : inputURLs.first.flatMap(MappingReadClass.lengthDefault(forInputURL:))
        let mode = MappingMode.preferredMode(for: tool, readClass: lengthClass) ?? fallback
        let basis = lengthClass.map { "was chosen from the read lengths, which look like \($0.displayName)" } ?? "is the default"
        return DefaultPreset(
            mode: mode,
            note: "Preset \(Self.presetSpelling(mode)) \(basis). \(PlatformInference.untunedDefaultsNote) Pass --preset to choose another."
        )
    }

    /// The `--preset` spelling of a mode.
    static func presetSpelling(_ mode: MappingMode) -> String {
        mode == .defaultShortRead ? "sr" : mode.rawValue
    }

    /// Prints the compatibility warnings for a request to standard error. The
    /// run continues with the settings as given.
    static func printCompatibilityWarnings(for request: MappingRunRequest) {
        guard let warnings = try? ManagedMappingPipeline.validateCompatibility(for: request) else { return }
        for warning in warnings {
            FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
        }
    }
}
