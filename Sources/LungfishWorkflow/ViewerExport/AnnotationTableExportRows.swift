// AnnotationTableExportRows.swift - The sample and genotype rows of the annotation table
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// Value rows, so the drawer and the bundle export-annotation-table leaf build one table (Phase 2.12 lane 12.39,
// ARCH ruling on 12.39 R1 item 5). The drawer spells them `SampleDisplayRow` and `GenotypeDisplayRow`.

/// A single row in the samples tab display.
package struct AnnotationTableSampleRow: Sendable {
    package let rowKey: String
    package let name: String
    package let sourceFile: String
    package var isVisible: Bool
    package var metadata: [String: String]
    package var displayName: String?

    package init(
        rowKey: String, name: String, sourceFile: String, isVisible: Bool, metadata: [String: String],
        displayName: String? = nil
    ) {
        self.rowKey = rowKey
        self.name = name
        self.sourceFile = sourceFile
        self.isVisible = isVisible
        self.metadata = metadata
        self.displayName = displayName
    }
}

/// A single row in the genotype subtab display.
package struct AnnotationTableGenotypeRow: Sendable {
    package let sampleName: String
    package let variantRowId: Int64
    package let variantID: String   // rs ID or "."
    package let chromosome: String
    package let position: Int       // 0-based
    package let ref: String
    package let alt: String
    package let genotype: String    // Raw GT string (e.g. "0/1")
    package let zygosity: String    // "Het", "Hom Ref", "Hom Alt", "Missing"
    package let alleleDepths: String // AD field
    package let depth: Int?         // DP
    package let genotypeQuality: Int? // GQ
    package let alleleBalance: Double? // Computed from AD
    package let infoDict: [String: String] // INFO key-value pairs for this variant
    package let trackId: String
    package let trackName: String

    package init(
        sampleName: String,
        variantRowId: Int64,
        variantID: String,
        chromosome: String,
        position: Int,
        ref: String,
        alt: String,
        genotype: String,
        zygosity: String,
        alleleDepths: String,
        depth: Int?,
        genotypeQuality: Int?,
        alleleBalance: Double?,
        infoDict: [String: String],
        trackId: String = "",
        trackName: String = ""
    ) {
        self.sampleName = sampleName
        self.variantRowId = variantRowId
        self.variantID = variantID
        self.chromosome = chromosome
        self.position = position
        self.ref = ref
        self.alt = alt
        self.genotype = genotype
        self.zygosity = zygosity
        self.alleleDepths = alleleDepths
        self.depth = depth
        self.genotypeQuality = genotypeQuality
        self.alleleBalance = alleleBalance
        self.infoDict = infoDict
        self.trackId = trackId
        self.trackName = trackName
    }

    /// Classifies genotype for display.
    package static func classify(allele1: Int, allele2: Int) -> String {
        if allele1 < 0 || allele2 < 0 { return "Missing" }
        if allele1 == 0 && allele2 == 0 { return "Hom Ref" }
        if allele1 == allele2 { return "Hom Alt" }
        return "Het"
    }

    /// Computes allele balance from AD string (e.g. "10,15" -> 0.6).
    package static func computeAlleleBalance(from adString: String?) -> Double? {
        guard let adString, !adString.isEmpty else { return nil }
        let parts = adString.split(separator: ",").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        let total = parts.reduce(0, +)
        guard total > 0 else { return nil }
        // Allele balance = alt reads / total reads
        let altReads = parts.dropFirst().reduce(0, +)
        return Double(altReads) / Double(total)
    }
}
