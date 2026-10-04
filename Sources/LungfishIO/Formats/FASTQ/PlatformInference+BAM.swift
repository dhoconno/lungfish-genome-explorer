// PlatformInference+BAM.swift - Platform inference from an unaligned BAM header
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension PlatformInference {

    /// Infers the platform of a BAM read file from its header (`@RG PL`, `@RG DS`
    /// and `@PG` program names). The header is read natively from the BGZF
    /// stream, so no tool is needed.
    ///
    /// A BAM with no platform evidence gives Unknown. It is never assumed to be
    /// Oxford Nanopore.
    public static func infer(fromBAM url: URL, maxBytes: Int = 1_048_576) -> PlatformInference {
        guard let headerText = bamHeaderText(at: url, maxBytes: maxBytes) else {
            return PlatformInference(
                platform: .unknown, readClass: nil, confidence: .none,
                evidence: ["The BAM header could not be read."], sampledRecords: 0
            )
        }
        return infer(fromSAMHeader: headerText)
    }

    /// Reads the SAM header text of a BAM file, or nil when it is not a BAM.
    public static func bamHeaderText(at url: URL, maxBytes: Int = 1_048_576) -> String? {
        guard let data = GzipPrefixDecoder.decodedPrefix(of: url, maxBytes: maxBytes),
              data.count >= 8 else { return nil }
        let bytes = [UInt8](data.prefix(8))
        guard bytes[0] == 0x42, bytes[1] == 0x41, bytes[2] == 0x4D, bytes[3] == 0x01 else { return nil }
        let textLength = Int(UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24)
        let text = data.dropFirst(8).prefix(textLength)
        return String(decoding: text, as: UTF8.self).replacingOccurrences(of: "\0", with: "")
    }

    /// Infers the platform from SAM header text.
    public static func infer(fromSAMHeader headerText: String) -> PlatformInference {
        let readGroups = SAMParser.parseReadGroups(from: headerText)
        let programs = SAMParser.parseProgramRecords(from: headerText)
        var evidence: [String] = []
        var platforms = Set<SequencingPlatform>()

        for group in readGroups {
            guard let value = group.platform else { continue }
            let platform = SequencingPlatform(vendor: value)
            evidence.append("Read group \(group.id) has PL:\(value).")
            platforms.insert(platform)
        }
        let programNames = programs.compactMap { $0.name?.lowercased() }
        if programNames.contains(where: { ["dorado", "guppy", "minknow", "basecaller"].contains($0) }) {
            evidence.append("The header names an Oxford Nanopore basecaller (@PG \(programNames.joined(separator: ", "))).")
            platforms.insert(.oxfordNanopore)
        }
        if programNames.contains(where: { ["ccs", "ccs-alt", "smrtlink"].contains($0) }) {
            evidence.append("The header names a PacBio program (@PG \(programNames.joined(separator: ", "))).")
            platforms.insert(.pacbio)
        }

        let named = platforms.subtracting([.unknown])
        guard named.count == 1, let platform = named.first else {
            if named.count > 1 {
                evidence.append("The header names more than one platform.")
            } else if evidence.isEmpty {
                evidence.append("The BAM header has no @RG PL and no basecaller @PG line.")
            }
            return PlatformInference(
                platform: .unknown, readClass: nil, confidence: .none,
                evidence: evidence, sampledRecords: 0
            )
        }

        let readClass: FASTQAssemblyReadType?
        switch platform {
        case .oxfordNanopore:
            readClass = .ontReads
        case .pacbio:
            let ccs = readGroups.contains { $0.description?.uppercased().contains("READTYPE=CCS") ?? false }
                || programNames.contains("ccs")
            readClass = ccs ? .pacBioHiFi : nil
        case .illumina, .element, .mgi:
            readClass = .illuminaShortReads
        case .ultima, .unknown:
            readClass = nil
        }
        return PlatformInference(
            platform: platform, readClass: readClass, confidence: .high,
            evidence: evidence, sampledRecords: 0
        )
    }
}
