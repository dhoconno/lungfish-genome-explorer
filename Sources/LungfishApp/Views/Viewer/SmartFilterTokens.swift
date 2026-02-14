// SmartFilterTokens.swift - Curated semantic filter tokens for variant tables
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

// MARK: - Smart Token Definition

/// A semantic variant filter token that provides one-click filtering.
///
/// Each token represents a common genomics filter operation (e.g. "PASS Only",
/// "Rare (AF<1%)", "High Impact") and generates the appropriate filter clauses
/// for the variant query engine.
enum SmartToken: String, CaseIterable, Sendable {
    case passOnly
    case snv
    case indel
    case highImpact
    case moderateImpact
    case rareVariant
    case qualityGE30
    case depthGE10
    case clinvarPathogenic
    case heterozygous

    /// Display label shown on the chip button.
    var label: String {
        switch self {
        case .passOnly:           return "PASS"
        case .snv:                return "SNV"
        case .indel:              return "Indel"
        case .highImpact:         return "High Impact"
        case .moderateImpact:     return "Moderate+"
        case .rareVariant:        return "Rare (<1%)"
        case .qualityGE30:        return "Qual \u{2265} 30"
        case .depthGE10:          return "DP \u{2265} 10"
        case .clinvarPathogenic:  return "ClinVar Path."
        case .heterozygous:       return "Het Only"
        }
    }

    /// SF Symbol name for the token chip (nil = text-only).
    var iconName: String? {
        switch self {
        case .passOnly:          return "checkmark.shield"
        case .clinvarPathogenic: return "exclamationmark.triangle"
        case .heterozygous:      return "person.2"
        default:                 return nil
        }
    }

    /// Returns true if this token should be offered given the available data.
    func isAvailable(
        infoKeys: Set<String>,
        variantTypes: Set<String>,
        hasGenotypes: Bool
    ) -> Bool {
        switch self {
        case .passOnly:
            return true  // FILTER column always exists
        case .snv:
            return variantTypes.contains("SNV") || variantTypes.contains("snv")
                || variantTypes.contains("SNP") || variantTypes.contains("snp")
        case .indel:
            return variantTypes.contains("Indel") || variantTypes.contains("indel")
                || variantTypes.contains("INS") || variantTypes.contains("DEL")
                || variantTypes.contains("Insertion") || variantTypes.contains("Deletion")
        case .highImpact, .moderateImpact:
            return !infoKeys.isDisjoint(with: Self.impactKeys)
        case .rareVariant:
            return !infoKeys.isDisjoint(with: Self.afKeys)
        case .qualityGE30:
            return true  // QUAL column always exists
        case .depthGE10:
            return infoKeys.contains("DP")
        case .clinvarPathogenic:
            return !infoKeys.isDisjoint(with: Self.clinvarKeys)
        case .heterozygous:
            // Requires genotype-level post-filtering, not yet implemented.
            return false
        }
    }

    /// Recognized INFO keys for allele frequency.
    static let afKeys: Set<String> = [
        "AF", "af", "gnomAD_AF", "ExAC_AF", "1000G_AF", "MAX_AF",
        "gnomADe_AF", "gnomADg_AF",
    ]

    /// Recognized INFO keys for variant impact.
    static let impactKeys: Set<String> = [
        "IMPACT", "impact", "ANN_IMPACT", "CSQ_IMPACT",
    ]

    /// Recognized INFO keys for ClinVar significance.
    static let clinvarKeys: Set<String> = [
        "CLNSIG", "ClinVar_SIG", "clinvar_sig", "CLNDN",
    ]

    // MARK: - Filter Clause Generation

    /// The category of filter this token produces.
    enum FilterEffect: Sendable {
        /// Restricts variant types (compose with visibleVariantTypes)
        case typeFilter(Set<String>)
        /// Sets the FILTER column value constraint (e.g. "PASS")
        case filterColumnValue(String)
        /// Sets minimum quality threshold
        case minQuality(Double)
        /// Produces INFO filter objects directly
        case infoFilters([VariantDatabase.InfoFilter])
        /// Requires post-fetch filtering (e.g. genotype-level)
        case postFilter(PostFilterKind)
    }

    enum PostFilterKind: Sendable {
        case heterozygousOnly
    }

    /// Returns the filter effects for this token, given the available INFO keys.
    func filterEffects(infoKeys: Set<String>) -> [FilterEffect] {
        switch self {
        case .passOnly:
            return [.filterColumnValue("PASS")]

        case .snv:
            return [.typeFilter(["SNV", "snv", "SNP", "snp"])]

        case .indel:
            return [.typeFilter(["Indel", "indel", "INS", "DEL", "Insertion", "Deletion"])]

        case .highImpact:
            if let key = Self.impactKeys.first(where: { infoKeys.contains($0) }) {
                return [.infoFilters([
                    VariantDatabase.InfoFilter(key: key, op: .eq, value: "HIGH"),
                ])]
            }
            return []

        case .moderateImpact:
            if let key = Self.impactKeys.first(where: { infoKeys.contains($0) }) {
                // "Moderate+" excludes LOW and MODIFIER. Since the query engine ANDs info
                // filters, we can't OR MODERATE+HIGH. Instead, exclude the unwanted values
                // by requiring the value NOT be LOW or MODIFIER. We use neq for LOW (the
                // more common exclusion) and trust that MODIFIER is also excluded because
                // it doesn't match. Since we can only apply one filter per key effectively,
                // use LIKE with a partial match: both "HIGH" and "MODERATE" contain "E" but
                // "LOW" does not. "MODIFIER" also contains "E" though, so instead use the
                // fact that both target values have length >= 4 with specific patterns.
                // Simplest correct approach: exclude LOW and MODIFIER explicitly.
                return [.infoFilters([
                    VariantDatabase.InfoFilter(key: key, op: .neq, value: "LOW"),
                    VariantDatabase.InfoFilter(key: key, op: .neq, value: "MODIFIER"),
                ])]
            }
            return []

        case .rareVariant:
            if let key = Self.afKeys.first(where: { infoKeys.contains($0) }) {
                return [.infoFilters([
                    VariantDatabase.InfoFilter(key: key, op: .lt, value: "0.01"),
                ])]
            }
            return []

        case .qualityGE30:
            return [.minQuality(30)]

        case .depthGE10:
            return [.infoFilters([
                VariantDatabase.InfoFilter(key: "DP", op: .gte, value: "10"),
            ])]

        case .clinvarPathogenic:
            if let key = Self.clinvarKeys.first(where: { infoKeys.contains($0) }) {
                return [.infoFilters([
                    VariantDatabase.InfoFilter(key: key, op: .like, value: "athogenic"),
                ])]
            }
            return []

        case .heterozygous:
            return [.postFilter(.heterozygousOnly)]
        }
    }
}

// MARK: - Smart Token Set Helpers

extension Set where Element == SmartToken {
    /// Composes all active tokens into filter components.
    ///
    /// Returns a tuple with:
    /// - typeRestrictions: union of all type filters (empty = no restriction)
    /// - filterValue: FILTER column value constraint (e.g. "PASS")
    /// - minQuality: minimum quality threshold
    /// - infoFilters: direct InfoFilter objects to merge with query
    /// - postFilters: post-fetch filter kinds to apply
    func composeFilters(
        infoKeys: Set<String>
    ) -> (
        typeRestrictions: Set<String>,
        filterValue: String?,
        minQuality: Double?,
        infoFilters: [VariantDatabase.InfoFilter],
        postFilters: [SmartToken.PostFilterKind]
    ) {
        var typeRestrictions: Set<String>?
        var filterValue: String?
        var minQuality: Double?
        var infoFilters: [VariantDatabase.InfoFilter] = []
        var postFilters: [SmartToken.PostFilterKind] = []

        for token in self {
            for effect in token.filterEffects(infoKeys: infoKeys) {
                switch effect {
                case .typeFilter(let types):
                    if let existing = typeRestrictions {
                        typeRestrictions = existing.union(types)
                    } else {
                        typeRestrictions = types
                    }
                case .filterColumnValue(let value):
                    filterValue = value
                case .minQuality(let qual):
                    if let existing: Double = minQuality {
                        minQuality = Swift.max(existing, qual)
                    } else {
                        minQuality = qual
                    }
                case .infoFilters(let filters):
                    infoFilters.append(contentsOf: filters)
                case .postFilter(let kind):
                    postFilters.append(kind)
                }
            }
        }

        return (typeRestrictions ?? [], filterValue, minQuality, infoFilters, postFilters)
    }
}
