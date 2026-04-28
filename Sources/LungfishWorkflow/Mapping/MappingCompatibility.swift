// MappingCompatibility.swift - Shared mapping compatibility rules
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

public enum MappingCompatibilityState: Sendable, Equatable {
    case allowed
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
            guard let readClass else {
                state = .blocked("Unable to detect a supported read class from the selected FASTQ inputs.")
                return MappingCompatibilityEvaluation(
                    tool: tool,
                    mode: mode,
                    inputFormat: inputFormat,
                    readClass: nil,
                    observedMaxReadLength: observedMaxReadLength,
                    state: state
                )
            }
            switch tool {
            case .minimap2:
                state = minimap2State(mode: mode, readClass: readClass)
            case .bwaMem2:
                state = readClass == .illuminaShortReads
                    ? .allowed
                    : .blocked("BWA-MEM2 is only available for Illumina-style short-read mapping in v1.")
            case .bowtie2:
                state = readClass == .illuminaShortReads
                    ? .allowed
                    : .blocked("Bowtie2 is only available for Illumina-style short-read mapping in v1.")
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

    private static func minimap2State(mode: MappingMode, readClass: MappingReadClass) -> MappingCompatibilityState {
        switch mode {
        case .minimap2Asm5:
            return .allowed
        case .minimap2Splice:
            return .allowed
        case .defaultShortRead:
            return readClass == .illuminaShortReads
                ? .allowed
                : .blocked("minimap2 short-read mode is only available for Illumina-style short reads.")
        case .minimap2MapONT:
            return readClass == .ontReads
                ? .allowed
                : .blocked("Select the Oxford Nanopore minimap2 preset only for ONT reads.")
        case .minimap2MapHiFi:
            return readClass == .pacBioHiFi
                ? .allowed
                : .blocked("Select the PacBio HiFi minimap2 preset only for PacBio HiFi reads.")
        case .minimap2MapPB:
            return readClass == .pacBioCLR
                ? .allowed
                : .blocked("Select the PacBio CLR minimap2 preset only for PacBio CLR reads.")
        case .bbmapStandard, .bbmapPacBio:
            return .blocked("\(mode.displayName) mode is not available for minimap2.")
        }
    }

    private static func bbmapState(
        mode: MappingMode,
        readClass: MappingReadClass?,
        observedMaxReadLength: Int?,
        inputFormat: SequenceFormat = .fastq
    ) -> MappingCompatibilityState {
        switch mode {
        case .bbmapStandard:
            if let observedMaxReadLength, observedMaxReadLength > bbmapStandardMaxReadLength {
                return .blocked("Standard BBMap mode supports reads up to 500 bases. Switch to PacBio mode or choose another mapper.")
            }
            return .allowed
        case .bbmapPacBio:
            guard inputFormat == .fasta || readClass == .pacBioHiFi || readClass == .pacBioCLR else {
                return .blocked("BBMap PacBio mode is only available for PacBio-class reads in v1.")
            }
            if let observedMaxReadLength, observedMaxReadLength > bbmapPacBioMaxReadLength {
                return .blocked("BBMap PacBio mode supports reads up to 6000 bases. Choose another mapper for longer reads.")
            }
            return .allowed
        case .defaultShortRead, .minimap2Asm5, .minimap2Splice, .minimap2MapONT, .minimap2MapHiFi, .minimap2MapPB:
            return .blocked("\(mode.displayName) mode is not available for BBMap.")
        }
    }
}
