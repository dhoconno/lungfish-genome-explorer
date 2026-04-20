// MappingCompatibilityPresentation.swift - UI adapter for mapping compatibility state
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishWorkflow

struct MappingCompatibilityPresentation {
    let message: String
    let color: Color
    let isReady: Bool

    static func make(
        compatibility: MappingCompatibilityEvaluation?,
        hasReference: Bool,
        hasInputs: Bool,
        detectedReadClass: MappingReadClass?,
        mixedReadClasses: Bool
    ) -> MappingCompatibilityPresentation {
        guard hasInputs else {
            return .init(message: "Select at least one FASTQ dataset.", color: .secondary, isReady: false)
        }
        guard hasReference else {
            return .init(message: "Select a reference sequence to continue.", color: Color.lungfishOrangeFallback, isReady: false)
        }
        if mixedReadClasses {
            return .init(
                message: "Selected FASTQ inputs mix incompatible read classes. Select one read class per mapping run.",
                color: Color.lungfishOrangeFallback,
                isReady: false
            )
        }
        guard let detectedReadClass else {
            return .init(
                message: "Inspecting read type from the selected FASTQ inputs.",
                color: .secondary,
                isReady: false
            )
        }
        guard let compatibility else {
            return .init(
                message: "Detected \(detectedReadClass.displayName).",
                color: .secondary,
                isReady: true
            )
        }
        switch compatibility.state {
        case .allowed:
            return .init(
                message: "Ready: \(compatibility.tool.displayName) is compatible with \(detectedReadClass.displayName).",
                color: Color.lungfishSecondaryText,
                isReady: true
            )
        case .blocked(let message):
            return .init(message: message, color: Color.lungfishOrangeFallback, isReady: false)
        }
    }
}
