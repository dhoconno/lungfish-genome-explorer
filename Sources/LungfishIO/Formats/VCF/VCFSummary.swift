// VCFSummary.swift - Summary statistics for a VCF file, computed in a single pass
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - VCFSummary

/// Summary statistics for a VCF file, computed in a single pass.
///
/// Contains header metadata, variant counts, chromosome information,
/// and an inferred reference genome when chromosome names match known assemblies.
public struct VCFSummary: Sendable {
    /// Parsed VCF header.
    public let header: VCFHeader
    /// Total number of variant records.
    public let variantCount: Int
    /// Unique chromosome names from variant records.
    public let chromosomes: Set<String>
    /// Maximum variant position per chromosome.
    public let maxPositionPerChromosome: [String: Int]
    /// Variant type counts (e.g., "SNP": 98, "INDEL": 15).
    public let variantTypes: [String: Int]
    /// Whether the VCF has sample genotype columns.
    public let hasSampleColumns: Bool
    /// Inferred reference genome from chromosome names/contigs.
    public let inferredReference: ReferenceInference.Result?
    /// Quality score statistics.
    public let qualityStats: QualityStats
    /// Filter status counts (e.g., "PASS": 112, "min_dp_10": 4).
    public let filterCounts: [String: Int]

    /// Quality score statistics for the VCF file.
    public struct QualityStats: Sendable {
        public let min: Double?
        public let max: Double?
        public let mean: Double?
        public let count: Int
    }
}
