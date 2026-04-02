// TaxonomyNameResolver.swift - Local NCBI taxonomy name lookup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Reads NCBI `names.dmp` from a local taxonomy dump and provides
/// taxon ID to scientific name lookups.
///
/// The taxonomy dump is managed through the Plugin Manager databases system
/// and downloaded from `https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdump.tar.gz`.
///
/// ## File Format
///
/// Each line in `names.dmp` is pipe-delimited with tab padding:
/// ```
/// taxid\t|\tname\t|\tunique_name\t|\tname_class\t|
/// ```
///
/// We only keep rows where `name_class` is `"scientific name"`, giving
/// one canonical name per taxon ID.
///
/// ## Memory Usage
///
/// The full `names.dmp` (~250 MB, ~4M lines) loads into a dictionary
/// of ~2.5M entries using approximately 200 MB of RAM.
public final class TaxonomyNameResolver: @unchecked Sendable {
    private var names: [Int: String] = [:]

    /// Loads `names.dmp` from the taxonomy directory.
    ///
    /// - Parameter taxonomyDirectory: Directory containing the extracted taxdump files.
    /// - Throws: ``TaxonomyResolverError`` if the file is missing or cannot be parsed.
    public init(taxonomyDirectory: URL) throws {
        let namesURL = taxonomyDirectory.appendingPathComponent("names.dmp")
        guard FileManager.default.fileExists(atPath: namesURL.path) else {
            throw TaxonomyResolverError.fileNotFound(namesURL)
        }
        // Parse names.dmp -- pipe-delimited, tab-padded
        // Format: taxid\t|\tname\t|\tunique_name\t|\tname_class\t|
        let data = try Data(contentsOf: namesURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TaxonomyResolverError.parseError("Invalid UTF-8")
        }
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 4 else { continue }
            guard fields[3] == "scientific name" else { continue }
            guard let taxId = Int(fields[0]) else { continue }
            names[taxId] = fields[1]
        }
    }

    /// Returns the scientific name for a taxon ID, or nil if unknown.
    public func scientificName(forTaxId taxId: Int) -> String? {
        names[taxId]
    }

    /// Batch resolve: returns a dictionary of taxId -> name for all found IDs.
    public func resolve(taxIds: [Int]) -> [Int: String] {
        var result: [Int: String] = [:]
        for id in taxIds {
            if let name = names[id] {
                result[id] = name
            }
        }
        return result
    }
}

/// Errors produced by ``TaxonomyNameResolver``.
public enum TaxonomyResolverError: Error, LocalizedError, Sendable {
    case fileNotFound(URL)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url): return "Taxonomy file not found: \(url.path)"
        case .parseError(let msg): return "Taxonomy parse error: \(msg)"
        }
    }
}
