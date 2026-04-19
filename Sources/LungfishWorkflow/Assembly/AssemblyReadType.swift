// AssemblyReadType.swift - Read-class model for the shared assembly surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Visible read classes supported by the v1 assembly experience.
public enum AssemblyReadType: String, CaseIterable, Codable, Sendable {
    case illuminaShortReads
    case ontReads
    case pacBioHiFi

    /// Human-readable display name shown in the shared assembly UI.
    public var displayName: String {
        switch self {
        case .illuminaShortReads: return "Illumina short reads"
        case .ontReads: return "ONT reads"
        case .pacBioHiFi: return "PacBio HiFi"
        }
    }

    /// Short explanation of the expected input class.
    public var detail: String {
        switch self {
        case .illuminaShortReads:
            return "Single-end or paired-end short reads from Illumina-style data."
        case .ontReads:
            return "Single-file Oxford Nanopore long reads."
        case .pacBioHiFi:
            return "Single-file PacBio HiFi long reads."
        }
    }

    /// Maps sequencing-platform detection onto the supported v1 assembly classes.
    public static func detect(from platform: SequencingPlatform) -> Self? {
        switch platform {
        case .illumina: return .illuminaShortReads
        case .oxfordNanopore: return .ontReads
        case .pacbio: return .pacBioHiFi
        default: return nil
        }
    }

    /// Best-effort FASTQ-based read-type detection.
    public static func detect(fromFASTQ url: URL) -> Self? {
        guard let platform = SequencingPlatform.detect(fromFASTQ: url) else {
            return nil
        }
        return detect(from: platform)
    }

    /// Best-effort multi-input detection, preserving stable case order.
    public static func detectAll(fromFASTQs urls: [URL]) -> [Self] {
        let detected = Set(urls.compactMap(detect(fromFASTQ:)))
        return allCases.filter { detected.contains($0) }
    }
}
