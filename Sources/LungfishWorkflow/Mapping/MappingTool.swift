// MappingTool.swift - Neutral mapper metadata for the shared mapping surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

public enum MappingTool: String, CaseIterable, Codable, Sendable {
    case minimap2
    case bwaMem2 = "bwa-mem2"
    case bowtie2
    case bbmap

    public var displayName: String {
        switch self {
        case .minimap2: return "minimap2"
        case .bwaMem2: return "BWA-MEM2"
        case .bowtie2: return "Bowtie2"
        case .bbmap: return "BBMap"
        }
    }

    public var environmentName: String { rawValue }

    public var executableName: String {
        switch self {
        case .minimap2: return "minimap2"
        case .bwaMem2: return "bwa-mem2"
        case .bowtie2: return "bowtie2"
        case .bbmap: return "bbmap.sh"
        }
    }
}

public enum MappingReadClass: String, CaseIterable, Codable, Sendable {
    case illuminaShortReads
    case ontReads
    case pacBioHiFi
    case pacBioCLR

    public var displayName: String {
        switch self {
        case .illuminaShortReads: return "Illumina short reads"
        case .ontReads: return "ONT reads"
        case .pacBioHiFi: return "PacBio HiFi"
        case .pacBioCLR: return "PacBio CLR"
        }
    }

    public static func detect(fromInputURL url: URL) -> Self? {
        guard let fastqURL = resolveFASTQURL(forInputURL: url) else {
            return nil
        }

        let persistedMetadata = FASTQMetadataStore.load(for: fastqURL)
        if let explicitReadType = persistedMetadata?.assemblyReadType.flatMap(Self.init(persistedReadType:)) {
            return explicitReadType
        }

        if let detected = detect(fromFASTQ: fastqURL) {
            return detected
        }

        if let platform = persistedMetadata?.sequencingPlatform {
            return detect(from: platform)
        }

        return nil
    }

    /// Detects the read class from a bounded sample of the FASTQ with the
    /// shared platform detector.
    public static func detect(fromFASTQ url: URL) -> Self? {
        detect(fromInference: PlatformInference.infer(fromFASTQ: url))
    }

    public static func detect(fromFASTQHeader header: String) -> Self? {
        detect(fromInference: PlatformInference.infer(fromHeader: header))
    }

    /// The mapping read class of an inference. PacBio reads without HiFi
    /// evidence (subreads) map as CLR.
    public static func detect(fromInference inference: PlatformInference) -> Self? {
        guard inference.isActionable else { return nil }
        if inference.platform == .pacbio {
            return inference.readClass == .pacBioHiFi ? .pacBioHiFi : .pacBioCLR
        }
        return inference.readClass.flatMap(Self.init(persistedReadType:))
    }

    public static func detect(from platform: LungfishIO.SequencingPlatform) -> Self? {
        switch platform {
        case .illumina, .element, .mgi:
            return .illuminaShortReads
        case .oxfordNanopore:
            return .ontReads
        case .pacbio:
            return .pacBioCLR
        default:
            return nil
        }
    }

    /// The read class an input of unknown platform defaults to, from its read
    /// lengths: ONT reads for long reads, short reads for short reads, nil when
    /// the lengths say neither. Only a default, never a gate.
    public static func lengthDefault(forInputURL url: URL) -> Self? {
        guard let fastqURL = resolveFASTQURL(forInputURL: url) else { return nil }
        return PlatformInference.defaultReadType(forLengthProfile: PlatformInference.lengthProfile(forFASTQ: fastqURL))
            .flatMap(Self.init(persistedReadType:))
    }

    public init?(persistedReadType: FASTQAssemblyReadType) {
        switch persistedReadType {
        case .illuminaShortReads:
            self = .illuminaShortReads
        case .ontReads:
            self = .ontReads
        case .pacBioHiFi:
            self = .pacBioHiFi
        }
    }

    static func resolveFASTQURL(forInputURL url: URL) -> URL? {
        let standardizedURL = url.standardizedFileURL
        if let resolved = FASTQBundle.resolvePrimaryFASTQURL(for: standardizedURL) {
            return resolved
        }

        let parentURL = standardizedURL.deletingLastPathComponent().standardizedFileURL
        return FASTQBundle.resolvePrimaryFASTQURL(for: parentURL)
    }
}

public enum MappingMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case defaultShortRead = "short-read-default"
    case minimap2Asm5 = "asm5"
    case minimap2Splice = "splice"
    case minimap2MapONT = "map-ont"
    case minimap2MapHiFi = "map-hifi"
    case minimap2MapPB = "map-pb"
    case bbmapStandard = "bbmap-standard"
    case bbmapPacBio = "bbmap-pacbio"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .defaultShortRead: return "Short-read"
        case .minimap2Asm5: return "Assembly-to-assembly"
        case .minimap2Splice: return "Spliced CDS/cDNA"
        case .minimap2MapONT: return "Oxford Nanopore"
        case .minimap2MapHiFi: return "PacBio HiFi"
        case .minimap2MapPB: return "PacBio CLR"
        case .bbmapStandard: return "Standard"
        case .bbmapPacBio: return "PacBio"
        }
    }

    public var commandPresetValue: String? {
        switch self {
        case .defaultShortRead: return "sr"
        case .minimap2Asm5: return "asm5"
        case .minimap2Splice: return "splice"
        case .minimap2MapONT: return "map-ont"
        case .minimap2MapHiFi: return "map-hifi"
        case .minimap2MapPB: return "map-pb"
        case .bbmapStandard, .bbmapPacBio: return nil
        }
    }

    public func isValid(for tool: MappingTool) -> Bool {
        switch tool {
        case .minimap2:
            return [.defaultShortRead, .minimap2Asm5, .minimap2Splice, .minimap2MapONT, .minimap2MapHiFi, .minimap2MapPB].contains(self)
        case .bwaMem2, .bowtie2:
            return self == .defaultShortRead
        case .bbmap:
            return [.bbmapStandard, .bbmapPacBio].contains(self)
        }
    }

    public static func availableModes(for tool: MappingTool) -> [MappingMode] {
        allCases.filter { $0.isValid(for: tool) }
    }

    public static func preferredMode(
        for tool: MappingTool,
        readClass: MappingReadClass?,
        inputFormat: SequenceFormat = .fastq
    ) -> MappingMode? {
        let availableModes = availableModes(for: tool)

        if inputFormat == .fasta {
            return availableModes.first
        }

        guard let readClass else {
            return availableModes.first
        }

        switch tool {
        case .minimap2:
            switch readClass {
            case .illuminaShortReads:
                return .defaultShortRead
            case .ontReads:
                return .minimap2MapONT
            case .pacBioHiFi:
                return .minimap2MapHiFi
            case .pacBioCLR:
                return .minimap2MapPB
            }
        case .bwaMem2, .bowtie2:
            return readClass == .illuminaShortReads ? .defaultShortRead : nil
        case .bbmap:
            switch readClass {
            case .pacBioHiFi, .pacBioCLR:
                return .bbmapPacBio
            case .illuminaShortReads, .ontReads:
                return .bbmapStandard
            }
        }
    }
}
