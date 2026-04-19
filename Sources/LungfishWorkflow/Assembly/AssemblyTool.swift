// AssemblyTool.swift - Neutral assembly tool metadata for managed assemblers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Managed assembly tools supported by the v1 assembly pack.
public enum AssemblyTool: String, CaseIterable, Codable, Sendable {
    case spades
    case megahit
    case skesa
    case flye
    case hifiasm

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .spades: return "SPAdes"
        case .megahit: return "MEGAHIT"
        case .skesa: return "SKESA"
        case .flye: return "Flye"
        case .hifiasm: return "Hifiasm"
        }
    }

    /// Micromamba environment name used by the managed tool pack.
    public var environmentName: String { rawValue }

    /// Primary executable name for the tool.
    public var executableName: String {
        switch self {
        case .spades: return "spades.py"
        default: return rawValue
        }
    }

    /// Stable analysis-directory prefix for normalized output bundles.
    public var analysisDirectoryPrefix: String {
        "assembly-\(rawValue)"
    }

    /// Native primary-output hint used by the later output normalizer.
    public var nativePrimaryOutputHint: String {
        switch self {
        case .spades: return "contigs.fasta"
        case .megahit: return "final.contigs.fa"
        case .skesa: return "stdout redirected to a FASTA file"
        case .flye: return "assembly.fasta"
        case .hifiasm: return "<prefix>.bp.p_ctg.gfa"
        }
    }
}
