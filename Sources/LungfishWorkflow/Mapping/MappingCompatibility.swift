// MappingCompatibility.swift - Shared mapping compatibility rules
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Whether a mapper, mode and input can run together.
///
/// Read class and platform only choose defaults. A preset that does not suit
/// the read class is a `.warning`, and the run uses what the user chose. Only
/// a combination the tool cannot run, or one whose output would be invalid,
/// is `.blocked`.
public enum MappingCompatibilityState: Sendable, Equatable {
    case allowed
    case warning(String)
    case blocked(String)
}

public struct MappingCompatibilityEvaluation: Sendable, Equatable {
    public let tool: MappingTool
    public let mode: MappingMode
    public let inputFormat: SequenceFormat
    public let readClass: MappingReadClass?
    public let observedMaxReadLength: Int?
    public let state: MappingCompatibilityState

    public init(
        tool: MappingTool,
        mode: MappingMode,
        inputFormat: SequenceFormat,
        readClass: MappingReadClass?,
        observedMaxReadLength: Int?,
        state: MappingCompatibilityState
    ) {
        self.tool = tool
        self.mode = mode
        self.inputFormat = inputFormat
        self.readClass = readClass
        self.observedMaxReadLength = observedMaxReadLength
        self.state = state
    }

    public var isBlocked: Bool {
        if case .blocked = state {
            return true
        }
        return false
    }

    /// The warning to show, when the run is allowed with one.
    public var warningMessage: String? {
        if case .warning(let message) = state {
            return message
        }
        return nil
    }
}

public enum MappingCompatibility {
    public static let bbmapStandardMaxReadLength = 500
    public static let bbmapPacBioMaxReadLength = 6_000

    public static func evaluate(
        tool: MappingTool,
        mode: MappingMode,
        inputFormat: SequenceFormat = .fastq,
        readClass: MappingReadClass?,
        observedMaxReadLength: Int? = nil
    ) -> MappingCompatibilityEvaluation {
        let state: MappingCompatibilityState

        if !mode.isValid(for: tool) {
            state = .blocked("\(mode.displayName) mode is not available for \(tool.displayName).")
        } else if inputFormat == .fasta {
            switch tool {
            case .minimap2, .bwaMem2, .bowtie2:
                state = .allowed
            case .bbmap:
                state = bbmapState(
                    mode: mode,
                    readClass: nil,
                    observedMaxReadLength: observedMaxReadLength,
                    inputFormat: inputFormat
                )
            }
        } else {
            switch tool {
            case .minimap2:
                state = minimap2State(mode: mode, readClass: readClass)
            case .bwaMem2, .bowtie2:
                state = shortReadOnlyState(tool: tool, readClass: readClass)
            case .bbmap:
                state = bbmapState(mode: mode, readClass: readClass, observedMaxReadLength: observedMaxReadLength)
            }
        }

        return MappingCompatibilityEvaluation(
            tool: tool,
            mode: mode,
            inputFormat: inputFormat,
            readClass: readClass,
            observedMaxReadLength: observedMaxReadLength,
            state: state
        )
    }

    /// The suffix of every read-class warning.
    static let proceedsAsChosen = "The run uses the settings you chose."

    private static func shortReadOnlyState(tool: MappingTool, readClass: MappingReadClass?) -> MappingCompatibilityState {
        guard let readClass else { return .warning(PlatformInference.untunedDefaultsNote) }
        return readClass == .illuminaShortReads
            ? .allowed
            : .warning("\(tool.displayName) is designed for Illumina-style short reads, and these are \(readClass.displayName). \(proceedsAsChosen)")
    }

    private static func minimap2State(mode: MappingMode, readClass: MappingReadClass?) -> MappingCompatibilityState {
        let expected: MappingReadClass?
        switch mode {
        case .minimap2Asm5, .minimap2Splice:
            return readClass == nil ? .warning(PlatformInference.untunedDefaultsNote) : .allowed
        case .defaultShortRead:
            expected = .illuminaShortReads
        case .minimap2MapONT:
            expected = .ontReads
        case .minimap2MapHiFi:
            expected = .pacBioHiFi
        case .minimap2MapPB:
            expected = .pacBioCLR
        case .bbmapStandard, .bbmapPacBio:
            return .blocked("\(mode.displayName) mode is not available for minimap2.")
        }
        guard let readClass else { return .warning(PlatformInference.untunedDefaultsNote) }
        guard let expected, readClass != expected else { return .allowed }
        return .warning("The minimap2 \(mode.displayName) preset is tuned for \(expected.displayName), and these are \(readClass.displayName). \(proceedsAsChosen)")
    }

    private static func bbmapState(
        mode: MappingMode,
        readClass: MappingReadClass?,
        observedMaxReadLength: Int?,
        inputFormat: SequenceFormat = .fastq
    ) -> MappingCompatibilityState {
        switch mode {
        case .bbmapStandard:
            // BBMap splits longer reads into 500-base pieces named r_1, r_2 and
            // so on, so the output would not be one alignment per read.
            if let observedMaxReadLength, observedMaxReadLength > bbmapStandardMaxReadLength {
                return .blocked("Standard BBMap mode supports reads up to 500 bases. Switch to PacBio mode or choose another mapper.")
            }
            return inputFormat == .fastq && readClass == nil ? .warning(PlatformInference.untunedDefaultsNote) : .allowed
        case .bbmapPacBio:
            // BBMap splits longer reads into pieces of this length and renames
            // them, so the output would not be one alignment per read.
            if let observedMaxReadLength, observedMaxReadLength > bbmapPacBioMaxReadLength {
                return .blocked("BBMap PacBio mode supports reads up to 6000 bases. Choose another mapper for longer reads.")
            }
            if inputFormat == .fasta || readClass == .pacBioHiFi || readClass == .pacBioCLR {
                return .allowed
            }
            guard let readClass else { return .warning(PlatformInference.untunedDefaultsNote) }
            return .warning("BBMap PacBio mode is tuned for PacBio reads, and these are \(readClass.displayName). \(proceedsAsChosen)")
        case .defaultShortRead, .minimap2Asm5, .minimap2Splice, .minimap2MapONT, .minimap2MapHiFi, .minimap2MapPB:
            return .blocked("\(mode.displayName) mode is not available for BBMap.")
        }
    }
}
