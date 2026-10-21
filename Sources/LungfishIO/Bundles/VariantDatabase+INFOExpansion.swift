// VariantDatabase+INFOExpansion.swift - One INFO parser for the inline import and the materializer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension VariantDatabase {

    /// Parses a raw VCF INFO string (e.g. "AC=2;AF=0.5;DP=100") into key-value pairs.
    static func parseRawINFOString(_ info: String) -> [String: String] {
        guard info != "." else { return [:] }
        var result: [String: String] = [:]
        for field in info.split(separator: ";") {
            let parts = field.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0])
                let value = String(parts[1])
                result[key] = value
                expandStructuredINFOFieldIfNeeded(key: key, value: value, into: &result)
            } else if parts.count == 1 {
                result[String(parts[0])] = "true"
            }
        }
        return result
    }

    /// Common VEP CSQ sub-field order.
    static let csqSubFieldTemplate: [String] = [
        "Allele", "Consequence", "IMPACT", "SYMBOL", "Gene", "Feature_type", "Feature",
        "BIOTYPE", "EXON", "INTRON", "HGVSc", "HGVSp", "cDNA_position", "CDS_position",
        "Protein_position", "Amino_acids", "Codons", "Existing_variation", "DISTANCE",
        "STRAND", "FLAGS", "SYMBOL_SOURCE", "HGNC_ID",
    ]

    /// Common SnpEff ANN sub-field order.
    static let annSubFieldTemplate: [String] = [
        "Allele", "Annotation", "Annotation_Impact", "Gene_Name", "Gene_ID", "Feature_Type",
        "Feature_ID", "Transcript_BioType", "Rank", "HGVS_c", "HGVS_p", "cDNA_pos_len",
        "CDS_pos_len", "AA_pos_len", "Distance", "ERRORS_WARNINGS_INFO",
    ]

    /// Expands raw CSQ/ANN entries into synthetic `CSQ_*` / `ANN_*` keys.
    ///
    /// This keeps high-value fields such as IMPACT/Consequence/Gene available even when
    /// databases were built from raw INFO strings instead of pre-expanded EAV rows.
    static func expandStructuredINFOFieldIfNeeded(
        key: String,
        value: String,
        into result: inout [String: String]
    ) {
        let template: [String]
        switch key {
        case "CSQ":
            template = csqSubFieldTemplate
        case "ANN":
            template = annSubFieldTemplate
        default:
            return
        }

        let entries = value.split(separator: ",", omittingEmptySubsequences: true)
        guard !entries.isEmpty else { return }

        // Preserve all transcript/frame annotations by aggregating unique values
        // across every CSQ/ANN entry for each sub-field.
        var aggregatedByField: [String: [String]] = [:]
        for entry in entries {
            let subValues = entry.split(separator: "|", omittingEmptySubsequences: false)
            guard !subValues.isEmpty else { continue }
            for (index, fieldName) in template.enumerated() where index < subValues.count {
                let trimmed = String(subValues[index]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                aggregatedByField[fieldName, default: []].append(trimmed)
            }
        }

        for fieldName in template {
            guard let values = aggregatedByField[fieldName], !values.isEmpty else { continue }
            let deduped = orderedUniqueStrings(values)
            result["\(key)_\(fieldName)"] = deduped.joined(separator: ",")
        }

        if entries.count > 1 {
            result["\(key)_entries"] = String(entries.count)
        }

        // Compatibility aliases used by smart tokens/query UI.
        if key == "ANN" {
            if let consequence = result["ANN_Annotation"] {
                result["ANN_Consequence"] = consequence
            }
            if let impact = result["ANN_Annotation_Impact"] {
                result["ANN_IMPACT"] = impact
            }
            if let gene = result["ANN_Gene_Name"] {
                result["ANN_Gene"] = gene
            }
        }
    }

    /// Returns unique strings preserving first-seen order.
    static func orderedUniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        ordered.reserveCapacity(values.count)
        for value in values where seen.insert(value).inserted {
            ordered.append(value)
        }
        return ordered
    }
}
