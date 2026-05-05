// MSAAlignmentNumberingMode.swift - Display options for native MSA coordinates
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

enum MSAAlignmentNumberingMode: String, CaseIterable, Identifiable, Sendable {
    case both
    case alignmentColumns
    case sourceCoordinates
    case hidden

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .both:
            return "Alignment + Source"
        case .alignmentColumns:
            return "Alignment Columns"
        case .sourceCoordinates:
            return "Source Coordinates"
        case .hidden:
            return "Hidden"
        }
    }

    var detailText: String {
        switch self {
        case .both:
            return "Show alignment column ticks and per-row source coordinate ranges."
        case .alignmentColumns:
            return "Show alignment column ticks and row indices."
        case .sourceCoordinates:
            return "Show per-row source coordinate ranges without alignment column ticks."
        case .hidden:
            return "Hide alignment and source numbering in the viewport."
        }
    }

    var showsAlignmentColumns: Bool {
        self == .both || self == .alignmentColumns
    }

    var showsSourceCoordinates: Bool {
        self == .both || self == .sourceCoordinates
    }

    var showsRowIndex: Bool {
        self == .both || self == .alignmentColumns
    }
}

enum MSAConsensusMaskSymbolMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case n
    case x

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .automatic:
            return "Auto"
        case .n:
            return "N"
        case .x:
            return "X"
        }
    }

    func symbol(alphabet: String) -> Character {
        switch self {
        case .automatic:
            let lowercasedAlphabet = alphabet.lowercased()
            return lowercasedAlphabet.contains("protein") || lowercasedAlphabet.contains("amino") ? "X" : "N"
        case .n:
            return "N"
        case .x:
            return "X"
        }
    }
}

struct MSAConsensusDisplayOptions: Equatable, Sendable {
    var lowSupportThresholdPercent: Int = 50
    var highGapThresholdPercent: Int = 50
    var maskSymbolMode: MSAConsensusMaskSymbolMode = .automatic

    var lowSupportThreshold: Double {
        Double(min(max(lowSupportThresholdPercent, 0), 100)) / 100.0
    }

    var highGapThreshold: Double {
        Double(min(max(highGapThresholdPercent, 0), 100)) / 100.0
    }
}

enum MSAResidueIdentityDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case letters
    case dotsToConsensus
    case dotsToReference

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .letters:
            return "Letters"
        case .dotsToConsensus:
            return "Dots to Consensus"
        case .dotsToReference:
            return "Dots to Reference"
        }
    }

    var detailText: String {
        switch self {
        case .letters:
            return "Show each residue as a letter."
        case .dotsToConsensus:
            return "Use dots where residues match the displayed consensus sequence."
        case .dotsToReference:
            return "Use dots where residues match the selected reference sequence."
        }
    }
}

struct MSAReferenceRowOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}
