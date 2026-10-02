// VariantType.swift - Classification of variant types
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - VariantType

/// Classification of variant types.
public enum VariantType: String, Codable, Sendable, CaseIterable {
    /// Single nucleotide polymorphism (A>G)
    case snp = "SNP"

    /// Multi-nucleotide polymorphism (AT>GC)
    case mnp = "MNP"

    /// Insertion (A>ATG)
    case insertion = "INS"

    /// Deletion (ATG>A)
    case deletion = "DEL"

    /// Complex variant (multiple changes)
    case complex = "COMPLEX"

    /// Reference/monomorphic site
    case reference = "REF"

    /// Default color for this variant type (IGV-inspired colors).
    public var defaultColor: AnnotationColor {
        switch self {
        case .snp:
            // Green for SNPs (IGV default)
            return AnnotationColor(red: 0.0, green: 0.6, blue: 0.0)
        case .mnp:
            // Blue-green for MNPs
            return AnnotationColor(red: 0.0, green: 0.5, blue: 0.5)
        case .insertion:
            // Purple/magenta for insertions (IGV default)
            return AnnotationColor(red: 0.6, green: 0.0, blue: 0.6)
        case .deletion:
            // Red for deletions (IGV default)
            return AnnotationColor(red: 0.8, green: 0.0, blue: 0.0)
        case .complex:
            // Orange for complex variants
            return AnnotationColor(red: 0.9, green: 0.5, blue: 0.0)
        case .reference:
            // Gray for reference sites
            return AnnotationColor(red: 0.5, green: 0.5, blue: 0.5)
        }
    }

    /// User-friendly description of the variant type.
    public var displayName: String {
        switch self {
        case .snp: return "Single Nucleotide Polymorphism"
        case .mnp: return "Multi-Nucleotide Polymorphism"
        case .insertion: return "Insertion"
        case .deletion: return "Deletion"
        case .complex: return "Complex Variant"
        case .reference: return "Reference"
        }
    }
}
