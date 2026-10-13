// NCBISearchType.swift - The kinds of NCBI search the database browser offers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - NCBI Search Type

/// The type of NCBI search to perform.
public enum NCBISearchType: String, CaseIterable, Identifiable, Sendable {
    case nucleotide = "GenBank (Nucleotide)"
    case genome = "Genome (Assembly)"
    case virus = "Virus"

    public var id: String { rawValue }

    /// Human-readable display name
    public var displayName: String { rawValue }

    /// Icon for the search type
    public var icon: String {
        switch self {
        case .nucleotide: return "doc.text"
        case .genome: return "circle.hexagongrid"
        case .virus: return "allergens"
        }
    }

    /// Help text explaining this search type
    public var helpText: String {
        switch self {
        case .nucleotide:
            return "Search GenBank nucleotide sequences including genes, plasmids, and genomes"
        case .genome:
            return "Search complete genome assemblies from RefSeq and GenBank"
        case .virus:
            return "Search viral sequences from NCBI Virus database"
        }
    }
}
