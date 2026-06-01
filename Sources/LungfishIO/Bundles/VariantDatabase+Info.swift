// VariantDatabase+Info.swift - Structured INFO + sample source queries
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

extension VariantDatabase {

    // MARK: - Structured INFO Queries

    /// Returns INFO field definitions from the variant_info_defs table.
    ///
    /// These are parsed from VCF `##INFO=<...>` header lines during import.
    /// For `skipVariantInfo` databases where the defs table is empty, falls back
    /// to discovering keys by sampling raw INFO strings from the variants table.
    public func infoKeys() -> [(key: String, type: String, number: String, description: String)] {
        guard let db else { return [] }
        let sql = "SELECT key, type, number, description FROM variant_info_defs ORDER BY key"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var results: [(key: String, type: String, number: String, description: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let type = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "String"
            let number = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "."
            let desc = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let resolvedType = Self.shouldRefineInferredInfoType(type: type, description: desc)
                ? (inferInfoTypeFromStoredValues(forKey: key) ?? type)
                : type
            results.append((key: key, type: resolvedType, number: number, description: desc))
        }
        if !results.isEmpty {
            var seen = Set(results.map(\.key))
            if seen.contains("CSQ") {
                for subField in Self.csqSubFieldTemplate {
                    let subKey = "CSQ_\(subField)"
                    if !seen.contains(subKey) {
                        results.append((key: subKey, type: "String", number: ".", description: "CSQ sub-field: \(subField)"))
                        seen.insert(subKey)
                    }
                }
                if !seen.contains("CSQ_entries") {
                    results.append((key: "CSQ_entries", type: "Integer", number: "1", description: "Number of CSQ transcript entries"))
                    seen.insert("CSQ_entries")
                }
            }
            if seen.contains("ANN") {
                for subField in Self.annSubFieldTemplate {
                    let subKey = "ANN_\(subField)"
                    if !seen.contains(subKey) {
                        results.append((key: subKey, type: "String", number: ".", description: "ANN sub-field: \(subField)"))
                        seen.insert(subKey)
                    }
                }
                for alias in ["ANN_Consequence", "ANN_IMPACT", "ANN_Gene", "ANN_entries"] where !seen.contains(alias) {
                    results.append((key: alias, type: "String", number: ".", description: "ANN compatibility alias"))
                    seen.insert(alias)
                }
            }
            results.sort { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        }
        // For skipVariantInfo databases, discover keys from raw INFO strings.
        if results.isEmpty && variantInfoSkipped {
            return discoverInfoKeysFromRawInfo()
        }
        return results
    }

    /// Discovers INFO keys by sampling raw INFO strings from the variants table.
    ///
    /// Used for databases imported with `skipVariantInfo = true` where the EAV
    /// `variant_info` and `variant_info_defs` tables are empty. Samples rows
    /// from start, middle, and end of the table to capture all keys.
    public func discoverInfoKeysFromRawInfo(sampleSize: Int = 500) -> [(key: String, type: String, number: String, description: String)] {
        if let cached = _cachedDiscoveredInfoKeys { return cached }
        guard let db else { return [] }

        // Sample from three regions of the table for diverse key coverage.
        var maxId: Int64 = 0
        var maxStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT MAX(id) FROM variants", -1, &maxStmt, nil) == SQLITE_OK,
           sqlite3_step(maxStmt!) == SQLITE_ROW {
            maxId = sqlite3_column_int64(maxStmt!, 0)
        }
        sqlite3_finalize(maxStmt)
        guard maxId > 0 else { return [] }

        let perRegion = max(sampleSize / 3, 50)
        let boundaries: [(Int64, Int64)] = [
            (0, maxId / 3),
            (maxId / 3, 2 * maxId / 3),
            (2 * maxId / 3, maxId),
        ]

        var allKeys: [String: (values: [String], count: Int)] = [:]

        for (lo, hi) in boundaries {
            let sql = "SELECT info FROM variants WHERE id > ? AND id <= ? AND info IS NOT NULL AND info != '' AND info != '.' LIMIT ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_int64(stmt, 1, lo)
            sqlite3_bind_int64(stmt, 2, hi)
            sqlite3_bind_int(stmt, 3, Int32(perRegion))

            while sqlite3_step(stmt!) == SQLITE_ROW {
                guard let cStr = sqlite3_column_text(stmt!, 0) else { continue }
                let infoStr = String(cString: cStr)
                for (key, value) in Self.parseRawINFOString(infoStr) {
                    var entry = allKeys[key] ?? (values: [], count: 0)
                    entry.count += 1
                    if entry.values.count < 5 { entry.values.append(value) }
                    allKeys[key] = entry
                }
            }
        }

        let results: [(key: String, type: String, number: String, description: String)] = allKeys.keys.sorted().map { key in
            let entry = allKeys[key]!
            let inferredType = Self.inferInfoType(from: entry.values)
            return (key: key, type: inferredType, number: ".", description: "")
        }
        _cachedDiscoveredInfoKeys = results
        return results
    }

    static func shouldRefineInferredInfoType(type: String, description: String) -> Bool {
        type == "String" && description == "Inferred from data"
    }

    func inferInfoTypeFromStoredValues(forKey key: String, sampleLimit: Int = 50) -> String? {
        guard let db else { return nil }
        let sql = "SELECT value FROM variant_info WHERE key = ? AND TRIM(value) != '' LIMIT ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        variantDBBindText(stmt, 1, key)
        sqlite3_bind_int(stmt, 2, Int32(sampleLimit))

        var values: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            values.append(String(cString: cStr))
        }
        guard !values.isEmpty else { return nil }
        return Self.inferInfoType(from: values)
    }

    /// Infers the VCF INFO type from a sample of values.
    static func inferInfoType(from values: [String]) -> String {
        let nonEmpty = values.filter { !$0.isEmpty && $0 != "." }
        if nonEmpty.isEmpty { return "Flag" }
        if nonEmpty.allSatisfy({ $0 == "true" }) { return "Flag" }
        let valueTokens = nonEmpty.flatMap { value in
            value.split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "." }
        }
        guard !valueTokens.isEmpty else { return "Flag" }
        let allInteger = valueTokens.allSatisfy { Int($0) != nil }
        if allInteger { return "Integer" }
        let allNumeric = valueTokens.allSatisfy { Double($0) != nil }
        if allNumeric { return "Float" }
        return "String"
    }

    /// Returns true if the given INFO key has at least one non-empty value in `variant_info`.
    public func hasNonEmptyInfoValue(forKey key: String) -> Bool {
        guard let db else { return false }
        let sql = "SELECT 1 FROM variant_info WHERE key = ? AND TRIM(value) != '' LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        variantDBBindText(stmt, 1, key)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return true
        }

        // Compatibility for structured raw keys present as CSQ/ANN without expanded sub-fields.
        if key.hasPrefix("CSQ_") {
            var csqStmt: OpaquePointer?
            defer { sqlite3_finalize(csqStmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &csqStmt, nil) == SQLITE_OK else { return false }
            variantDBBindText(csqStmt, 1, "CSQ")
            return sqlite3_step(csqStmt) == SQLITE_ROW
        }
        if key.hasPrefix("ANN_") {
            var annStmt: OpaquePointer?
            defer { sqlite3_finalize(annStmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &annStmt, nil) == SQLITE_OK else { return false }
            variantDBBindText(annStmt, 1, "ANN")
            return sqlite3_step(annStmt) == SQLITE_ROW
        }
        return false
    }

    /// Returns all INFO key-value pairs for a specific variant.
    ///
    /// For standard imports, reads from the `variant_info` EAV table.
    /// For `skipVariantInfo` imports, parses the raw INFO string from `variants.info`.
    public func infoValues(variantId: Int64) -> [String: String] {
        guard let db else { return [:] }

        if variantInfoSkipped {
            // Parse raw INFO string from the variants table.
            let sql = "SELECT info FROM variants WHERE id = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
            sqlite3_bind_int64(stmt, 1, variantId)
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let cStr = sqlite3_column_text(stmt, 0) else { return [:] }
            return Self.parseRawINFOString(String(cString: cStr))
        }

        let sql = "SELECT key, value FROM variant_info WHERE variant_id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        sqlite3_bind_int64(stmt, 1, variantId)
        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let value = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            result[key] = value
            Self.expandStructuredINFOFieldIfNeeded(key: key, value: value, into: &result)
        }
        return result
    }

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

    /// Batch-fetches INFO dictionaries for multiple variant IDs.
    ///
    /// More efficient than calling `infoValues(variantId:)` per-variant.
    /// Returns a dictionary mapping variant ID to its INFO key-value pairs.
    public func batchInfoValues(variantIds: [Int64]) -> [Int64: [String: String]] {
        guard let db, !variantIds.isEmpty else { return [:] }
        var result: [Int64: [String: String]] = [:]
        let uniqueIds = Array(Set(variantIds))
        let chunkSize = 500 // Keep well below SQLite bind-variable limits.

        if variantInfoSkipped {
            // Parse raw INFO from the variants table.
            for chunkStart in stride(from: 0, to: uniqueIds.count, by: chunkSize) {
                let chunkEnd = min(chunkStart + chunkSize, uniqueIds.count)
                let chunk = Array(uniqueIds[chunkStart..<chunkEnd])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let sql = "SELECT id, info FROM variants WHERE id IN (\(placeholders))"
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
                for (i, id) in chunk.enumerated() {
                    sqlite3_bind_int64(stmt, Int32(i + 1), id)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let variantId = sqlite3_column_int64(stmt, 0)
                    if let cStr = sqlite3_column_text(stmt, 1) {
                        result[variantId] = Self.parseRawINFOString(String(cString: cStr))
                    }
                }
            }
            return result
        }

        for chunkStart in stride(from: 0, to: uniqueIds.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, uniqueIds.count)
            let chunk = Array(uniqueIds[chunkStart..<chunkEnd])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT variant_id, key, value FROM variant_info WHERE variant_id IN (\(placeholders))"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            for (i, id) in chunk.enumerated() {
                sqlite3_bind_int64(stmt, Int32(i + 1), id)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let variantId = sqlite3_column_int64(stmt, 0)
                let key = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let value = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                result[variantId, default: [:]][key] = value
                var expanded = result[variantId, default: [:]]
                Self.expandStructuredINFOFieldIfNeeded(key: key, value: value, into: &expanded)
                result[variantId] = expanded
            }
        }
        return result
    }

    /// Returns distinct non-empty values for an INFO key, limited and sorted by frequency.
    public func distinctInfoValues(forKey key: String, limit: Int = 21) -> [String] {
        guard let db, limit > 0 else { return [] }
        let sql = """
            SELECT value, COUNT(*) AS c
            FROM variant_info
            WHERE key COLLATE NOCASE = ? AND TRIM(value) != ''
            GROUP BY value
            ORDER BY c DESC, value COLLATE NOCASE ASC
            LIMIT ?
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        variantDBBindText(stmt, 1, key)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var values: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                values.append(String(cString: cStr))
            }
        }
        return values
    }

    // MARK: - Sample Source File Queries

    /// Returns the source filename for a specific sample.
    public func sourceFile(forSample name: String) -> String? {
        guard let db else { return nil }
        let sql = "SELECT source_file FROM samples WHERE name = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        variantDBBindText(stmt, 1, name)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }

    /// Returns all source filenames keyed by sample name.
    public func allSourceFiles() -> [String: String] {
        guard let db else { return [:] }
        let sql = "SELECT name, source_file FROM samples ORDER BY name"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let file = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            if let file, !name.isEmpty {
                result[name] = file
            }
        }
        return result
    }

    /// Returns display names for all samples that have a custom display_name set.
    /// Only returns entries where display_name differs from the sample name.
    public func allDisplayNames() -> [String: String] {
        guard let db else { return [:] }
        let sql = "SELECT name, display_name FROM samples WHERE display_name IS NOT NULL AND display_name != name ORDER BY name"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let displayName = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            if let displayName, !name.isEmpty, !displayName.isEmpty {
                result[name] = displayName
            }
        }
        return result
    }

    /// Sets or clears the display name for a sample.
    /// Pass nil or the sample's own name to clear the override.
    public func setDisplayName(forSample name: String, displayName: String?) {
        guard let db else { return }
        let effectiveName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueToStore: String
        if let eff = effectiveName, !eff.isEmpty, eff != name {
            valueToStore = eff
        } else {
            valueToStore = name
        }
        let sql = "UPDATE samples SET display_name = ? WHERE name = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        variantDBBindText(stmt, 1, valueToStore)
        variantDBBindText(stmt, 2, name)
        sqlite3_step(stmt)
    }

}
