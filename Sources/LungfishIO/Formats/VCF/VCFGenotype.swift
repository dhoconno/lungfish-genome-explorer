// VCFGenotype.swift - Genotype information for a sample
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - VCFGenotype

/// Genotype information for a sample.
public struct VCFGenotype: Sendable, Equatable {

    /// Raw genotype string (e.g., "0/1", "1|1")
    public let rawGenotype: String

    /// All field values keyed by FORMAT field name
    public let fields: [String: String]

    /// Allele indices parsed once at init. Missing alleles (".") are represented as -1.
    public let alleleIndices: [Int]

    public init(rawGenotype: String, fields: [String: String]) {
        self.rawGenotype = rawGenotype
        self.fields = fields
        self.alleleIndices = rawGenotype
            .split(whereSeparator: { $0 == "/" || $0 == "|" })
            .map { $0 == "." ? -1 : (Int($0) ?? -1) }
    }

    /// Whether any allele is missing (".").
    public var hasMissingAlleles: Bool {
        alleleIndices.contains(-1)
    }

    /// Whether this genotype is phased (uses | separator)
    public var isPhased: Bool {
        rawGenotype.contains("|")
    }

    /// Whether this is homozygous reference (0/0). Missing alleles (-1) cause this to return false.
    public var isHomRef: Bool {
        !alleleIndices.isEmpty && alleleIndices.allSatisfy { $0 == 0 }
    }

    /// Whether this is homozygous alternate. Missing alleles (-1) cause this to return false.
    public var isHomAlt: Bool {
        !alleleIndices.isEmpty && alleleIndices.allSatisfy { $0 > 0 && $0 == alleleIndices[0] }
    }

    /// Whether this is heterozygous. Missing alleles are excluded from consideration.
    public var isHet: Bool {
        let nonMissing = alleleIndices.filter { $0 >= 0 }
        return Set(nonMissing).count > 1
    }

    /// Depth of coverage (DP field)
    public var depth: Int? {
        fields["DP"].flatMap { Int($0) }
    }

    /// Genotype quality (GQ field)
    public var genotypeQuality: Int? {
        fields["GQ"].flatMap { Int($0) }
    }
}
