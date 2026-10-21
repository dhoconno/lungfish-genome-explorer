// VariantDatabase+INFOExpansion.swift - One INFO parser for the inline import and the materializer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The part names of the structured INFO fields of one VCF, built once from its `##INFO` header lines.
///
/// `ANN` splits by the SnpEff template, `CSQ` by the names after `Format: ` in its header Description or else by the
/// VEP template, and any other key only when its Description lists two or more `Format: ` names. The import stores
/// the declared names in `db_metadata`, so the materializer of an `ultra-low-memory` import splits by the same names.
struct StructuredINFOFieldNames: Sendable, Equatable {

    /// The `db_metadata` key that holds `metadataValue`.
    static let metadataKey = "structured_info_formats"

    /// The `Format: ` names each `##INFO` Description listed, by INFO id.
    private(set) var declared: [String: [String]]

    init(declared: [String: [String]] = [:]) {
        self.declared = declared
    }

    /// The names `metadataValue` stored, or none when `json` is nil or unreadable.
    init(metadataValue json: String?) {
        let data = json.flatMap { $0.data(using: .utf8) }
        self.init(declared: data.flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:])
    }

    /// The names the import of database `db` stored, or none for a database imported before they were stored.
    static func stored(in db: OpaquePointer) -> StructuredINFOFieldNames {
        StructuredINFOFieldNames(metadataValue: VariantDatabase.readMetadataValue(db, key: metadataKey))
    }

    /// `declared` as JSON with sorted keys, or nil when no Description listed `Format: ` names.
    var metadataValue: String? {
        guard !declared.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(declared)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Records the `Format: ` names of one `##INFO` Description and returns the part names `id` splits into.
    @discardableResult
    mutating func register(id: String, description: String) -> [String]? {
        if let names = Self.formatNames(in: description) {
            declared[id] = names
        }
        return partNames(forKey: id)
    }

    /// The part names `key` splits into, or nil when its value is one scalar.
    func partNames(forKey key: String) -> [String]? {
        switch key {
        case "ANN": VariantDatabase.annSubFieldTemplate
        case "CSQ": declared["CSQ"] ?? VariantDatabase.csqSubFieldTemplate
        default: declared[key]
        }
    }

    /// The pipe-separated names after `Format: ` in a Description, each trimmed of spaces and quotes, when there are
    /// two or more (VEP writes `Format: Allele|Consequence|...`, SnpEff's LOF writes `Format: 'Gene_Name | ...'`).
    static func formatNames(in description: String) -> [String]? {
        guard let start = description.range(of: "Format: ", options: .caseInsensitive) else { return nil }
        let names = description[start.upperBound...].split(separator: "|").map { $0.trimmingCharacters(in: nameTrim) }
        return names.count >= 2 ? names : nil
    }

    private static let nameTrim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))
}

extension VariantDatabase {

    /// Parses a raw VCF INFO string (e.g. "AC=2;AF=0.5;DP=100") into the rows an import writes for it, splitting
    /// structured fields by `names` (`forEachINFORow`).
    static func parseRawINFOString(
        _ info: String,
        names: StructuredINFOFieldNames = StructuredINFOFieldNames()
    ) -> [String: String] {
        guard info != "." else { return [:] }
        var result: [String: String] = [:]
        for field in info.split(separator: ";") {
            forEachINFORow(field: field, names: names) { result[$0] = $1 }
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

    /// Splits one `KEY=VALUE` INFO field and hands its rows to `row` (`forEachINFORow(key:value:names:_:)`). A flag
    /// writes one `true` row and is never split.
    static func forEachINFORow(
        field: Substring,
        names: StructuredINFOFieldNames,
        _ row: (String, String) throws -> Void
    ) rethrows {
        let parts = field.split(separator: "=", maxSplits: 1)
        guard let key = parts.first.map(String.init) else { return }
        guard parts.count == 2 else { return try row(key, "true") }
        try forEachINFORow(key: key, value: parts[1], names: names, row)
    }

    /// Hands each `variant_info` row of one INFO field to `row`. The inline import of `fast` and `low-memory` and the
    /// materializer of `ultra-low-memory` both write these rows, so the three profiles store the same keys.
    ///
    /// The raw `key` row comes first. When `names` marks `key` as structured, one row a part (`<key>_<part>`) follows,
    /// holding the unique non-empty values of that part across the comma-separated entries in first-seen order, then
    /// `<key>_entries` when there is more than one entry, and for `ANN` the aliases `ANN_Consequence`, `ANN_IMPACT`
    /// and `ANN_Gene` that the High Impact filter and the searches read. It reads only `value`, so an import stays one
    /// streaming pass.
    static func forEachINFORow(
        key: String,
        value: Substring,
        names: StructuredINFOFieldNames,
        _ row: (String, String) throws -> Void
    ) rethrows {
        try row(key, String(value))
        guard let partNames = names.partNames(forKey: key) else { return }
        let entries = value.split(separator: ",")
        var valuesByPart: [String: [String]] = [:]
        for entry in entries {
            let values = entry.split(separator: "|", omittingEmptySubsequences: false)
            for (index, name) in partNames.enumerated() where index < values.count {
                let trimmed = values[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { valuesByPart[name, default: []].append(trimmed) }
            }
        }
        var joinedByPart: [String: String] = [:]
        for name in partNames where joinedByPart[name] == nil {
            guard let values = valuesByPart[name] else { continue }
            let joined = orderedUniqueStrings(values).joined(separator: ",")
            joinedByPart[name] = joined
            try row("\(key)_\(name)", joined)
        }
        if entries.count > 1 {
            try row("\(key)_entries", String(entries.count))
        }
        guard key == "ANN" else { return }
        for (alias, part) in annAliasParts {
            if let joined = joinedByPart[part] { try row(alias, joined) }
        }
    }

    /// The SnpEff parts the smart tokens, the consequence filter and the gene search read under a shorter key.
    static let annAliasParts: [(alias: String, part: String)] = [
        ("ANN_Consequence", "Annotation"), ("ANN_IMPACT", "Annotation_Impact"), ("ANN_Gene", "Gene_Name"),
    ]

    /// Adds the template parts of a raw `ANN` or `CSQ` value to `result`, with the entry count and the ANN aliases.
    static func expandStructuredINFOFieldIfNeeded(
        key: String,
        value: String,
        into result: inout [String: String]
    ) {
        guard key == "ANN" || key == "CSQ" else { return }
        forEachINFORow(key: key, value: value[...], names: StructuredINFOFieldNames()) { rowKey, rowValue in
            if rowKey != key { result[rowKey] = rowValue }
        }
    }

    /// Splits a raw `ANN` or `CSQ` value by its template when `info` holds none of its parts, as an older `fast` or
    /// `low-memory` import stored a SnpEff ANN. Parts a database stored are read as stored, so the names a CSQ
    /// header's `Format: ` list gave are never renamed on read.
    static func expandLegacyStructuredINFO(_ info: inout [String: String]) {
        for key in ["ANN", "CSQ"] {
            guard let raw = info[key] else { continue }
            let prefix = "\(key)_"
            if info.keys.contains(where: { $0.hasPrefix(prefix) }) { continue }
            expandStructuredINFOFieldIfNeeded(key: key, value: raw, into: &info)
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
