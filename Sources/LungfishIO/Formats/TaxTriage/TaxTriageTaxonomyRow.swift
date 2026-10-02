// TaxTriageTaxonomyRow.swift - A single taxonomy row from TaxTriage output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

// MARK: - Row Type

/// A single taxonomy row from TaxTriage output.
public struct TaxTriageTaxonomyRow: Sendable {
    public let sample: String
    public let organism: String
    public let taxId: Int?
    public let status: String?
    public let tassScore: Double
    public let readsAligned: Int
    public let uniqueReads: Int?
    public let pctReads: Double?
    public let pctAlignedReads: Double?
    public let coverageBreadth: Double?
    public let meanCoverage: Double?
    public let meanDepth: Double?
    public let confidence: String?
    public let k2Reads: Int?
    public let parentK2Reads: Int?
    public let giniCoefficient: Double?
    public let meanBaseQ: Double?
    public let meanMapQ: Double?
    public let mapqScore: Double?
    public let disparityScore: Double?
    public let minhashScore: Double?
    public let diamondIdentity: Double?
    public let k2DisparityScore: Double?
    public let siblingsScore: Double?
    public let breadthWeightScore: Double?
    public let hhsPercentile: Double?
    public let isAnnotated: Bool?
    public let annClass: String?
    public let microbialCategory: String?
    public let highConsequence: Bool?
    public let isSpecies: Bool?
    public let pathogenicSubstrains: String?
    public let sampleType: String?
    public let bamPath: String?
    public let bamIndexPath: String?
    public let primaryAccession: String?
    public let accessionLength: Int?

    public init(
        sample: String,
        organism: String,
        taxId: Int?,
        status: String?,
        tassScore: Double,
        readsAligned: Int,
        uniqueReads: Int?,
        pctReads: Double?,
        pctAlignedReads: Double?,
        coverageBreadth: Double?,
        meanCoverage: Double?,
        meanDepth: Double?,
        confidence: String?,
        k2Reads: Int?,
        parentK2Reads: Int?,
        giniCoefficient: Double?,
        meanBaseQ: Double?,
        meanMapQ: Double?,
        mapqScore: Double?,
        disparityScore: Double?,
        minhashScore: Double?,
        diamondIdentity: Double?,
        k2DisparityScore: Double?,
        siblingsScore: Double?,
        breadthWeightScore: Double?,
        hhsPercentile: Double?,
        isAnnotated: Bool?,
        annClass: String?,
        microbialCategory: String?,
        highConsequence: Bool?,
        isSpecies: Bool?,
        pathogenicSubstrains: String?,
        sampleType: String?,
        bamPath: String?,
        bamIndexPath: String?,
        primaryAccession: String?,
        accessionLength: Int?
    ) {
        self.sample = sample
        self.organism = organism
        self.taxId = taxId
        self.status = status
        self.tassScore = tassScore
        self.readsAligned = readsAligned
        self.uniqueReads = uniqueReads
        self.pctReads = pctReads
        self.pctAlignedReads = pctAlignedReads
        self.coverageBreadth = coverageBreadth
        self.meanCoverage = meanCoverage
        self.meanDepth = meanDepth
        self.confidence = confidence
        self.k2Reads = k2Reads
        self.parentK2Reads = parentK2Reads
        self.giniCoefficient = giniCoefficient
        self.meanBaseQ = meanBaseQ
        self.meanMapQ = meanMapQ
        self.mapqScore = mapqScore
        self.disparityScore = disparityScore
        self.minhashScore = minhashScore
        self.diamondIdentity = diamondIdentity
        self.k2DisparityScore = k2DisparityScore
        self.siblingsScore = siblingsScore
        self.breadthWeightScore = breadthWeightScore
        self.hhsPercentile = hhsPercentile
        self.isAnnotated = isAnnotated
        self.annClass = annClass
        self.microbialCategory = microbialCategory
        self.highConsequence = highConsequence
        self.isSpecies = isSpecies
        self.pathogenicSubstrains = pathogenicSubstrains
        self.sampleType = sampleType
        self.bamPath = bamPath
        self.bamIndexPath = bamIndexPath
        self.primaryAccession = primaryAccession
        self.accessionLength = accessionLength
    }
}
