// MappingCompatibilityPresentation.swift - UI adapter for mapping compatibility state
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO
import LungfishWorkflow

/// The status line under the Map Reads settings.
///
/// Read class and platform only choose defaults. A preset that does not suit
/// the reads, mixed read classes and reads of unknown platform show a warning
/// in orange and the run stays available. Only a combination the mapper cannot
/// run (`MappingCompatibilityState.blocked`) disables Run.
struct MappingCompatibilityPresentation {
    let message: String
    let color: Color
    let isReady: Bool

    static func make(
        compatibility: MappingCompatibilityEvaluation?,
        hasReference: Bool,
        hasInputs: Bool,
        detectedSequenceFormat: SequenceFormat?,
        detectedReadClass: MappingReadClass?,
        mixedReadClasses: Bool,
        mixedSequenceFormats: Bool,
        mixesDetectedAndUnclassifiedReadClasses: Bool = false,
        suspectLabelNote: String? = nil
    ) -> MappingCompatibilityPresentation {
        guard hasInputs else {
            return .init(message: "Select at least one sequence dataset.", color: .secondary, isReady: false)
        }
        guard hasReference else {
            return .init(message: "Select a reference sequence to continue.", color: Color.lungfishOrangeFallback, isReady: false)
        }
        if mixedSequenceFormats {
            return .init(
                message: "Selected sequence inputs mix FASTA and FASTQ formats. Select one format per mapping run.",
                color: Color.lungfishOrangeFallback,
                isReady: false
            )
        }
        if let compatibility, case .blocked(let message) = compatibility.state {
            return .init(message: message, color: Color.lungfishOrangeFallback, isReady: false)
        }

        var warnings: [String] = []
        if detectedSequenceFormat != .fasta {
            if mixedReadClasses {
                warnings.append("Selected FASTQ inputs mix read classes, so one preset maps all of them.")
            }
            if mixesDetectedAndUnclassifiedReadClasses {
                warnings.append("Some selected FASTQ inputs have no known read type.")
            }
        }
        if let warning = compatibility?.warningMessage, !warnings.contains(warning) {
            warnings.append(warning)
        }
        if let suspectLabelNote {
            warnings.append(suspectLabelNote)
        }
        if !warnings.isEmpty {
            return .init(message: warnings.joined(separator: " "), color: Color.lungfishOrangeFallback, isReady: true)
        }

        guard let compatibility else {
            let detected = detectedSequenceFormat == .fasta
                ? "Detected FASTA sequence input."
                : detectedReadClass.map { "Detected \($0.displayName)." } ?? PlatformInference.untunedDefaultsNote
            return .init(message: detected, color: .secondary, isReady: true)
        }
        let target = detectedSequenceFormat == .fasta
            ? "FASTA sequence input"
            : detectedReadClass?.displayName ?? "these reads"
        return .init(
            message: "Ready: \(compatibility.tool.displayName) is compatible with \(target).",
            color: Color.lungfishSecondaryText,
            isReady: true
        )
    }
}
