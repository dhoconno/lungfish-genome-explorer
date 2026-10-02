// NaoMgsTaxonSummary.swift - Aggregated statistics for a single taxon across all virus hits
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

// MARK: - NaoMgsTaxonSummary

/// Aggregated statistics for a single taxon across all virus hits.
public struct NaoMgsTaxonSummary: Sendable, Codable, Equatable {
    /// NCBI taxonomy ID.
    public let taxId: Int

    /// Organism name (derived from the subject title).
    public let name: String

    /// Number of reads hitting this taxon.
    public let hitCount: Int

    /// Average percent identity across all hits for this taxon.
    public let avgIdentity: Double

    /// Average bit score across all hits for this taxon.
    public let avgBitScore: Double

    /// Average edit distance across all hits for this taxon (v2 format).
    public let avgEditDistance: Double

    /// Distinct GenBank accessions hit for this taxon.
    public let accessions: [String]

    /// Estimated PCR duplicate reads for this taxon.
    ///
    /// Computed by grouping alignments with identical accession/start/end/strand
    /// and counting all but the first hit in each group.
    public let pcrDuplicateCount: Int

    /// Estimated unique reads (`hitCount - pcrDuplicateCount`).
    public var uniqueReadCount: Int {
        max(0, hitCount - pcrDuplicateCount)
    }

    /// Creates a new taxon summary.
    public init(
        taxId: Int,
        name: String,
        hitCount: Int,
        avgIdentity: Double,
        avgBitScore: Double,
        avgEditDistance: Double = 0,
        accessions: [String],
        pcrDuplicateCount: Int = 0
    ) {
        self.taxId = taxId
        self.name = name
        self.hitCount = hitCount
        self.avgIdentity = avgIdentity
        self.avgBitScore = avgBitScore
        self.avgEditDistance = avgEditDistance
        self.accessions = accessions
        self.pcrDuplicateCount = max(0, min(pcrDuplicateCount, hitCount))
    }

    private enum CodingKeys: String, CodingKey {
        case taxId
        case name
        case hitCount
        case avgIdentity
        case avgBitScore
        case avgEditDistance
        case accessions
        case pcrDuplicateCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taxId = try container.decode(Int.self, forKey: .taxId)
        name = try container.decode(String.self, forKey: .name)
        hitCount = try container.decode(Int.self, forKey: .hitCount)
        avgIdentity = try container.decode(Double.self, forKey: .avgIdentity)
        avgBitScore = try container.decode(Double.self, forKey: .avgBitScore)
        avgEditDistance = try container.decode(Double.self, forKey: .avgEditDistance)
        accessions = try container.decode([String].self, forKey: .accessions)
        let decodedDupCount = try container.decodeIfPresent(Int.self, forKey: .pcrDuplicateCount) ?? 0
        pcrDuplicateCount = max(0, min(decodedDupCount, hitCount))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(taxId, forKey: .taxId)
        try container.encode(name, forKey: .name)
        try container.encode(hitCount, forKey: .hitCount)
        try container.encode(avgIdentity, forKey: .avgIdentity)
        try container.encode(avgBitScore, forKey: .avgBitScore)
        try container.encode(avgEditDistance, forKey: .avgEditDistance)
        try container.encode(accessions, forKey: .accessions)
        try container.encode(pcrDuplicateCount, forKey: .pcrDuplicateCount)
    }
}
