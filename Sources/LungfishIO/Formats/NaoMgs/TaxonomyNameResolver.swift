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
/// ## Performance
///
/// When resolving a specific set of tax IDs, use ``resolveFromFile(_:taxIds:)``
/// which streams the 250 MB file and only keeps matching entries (~1000×
/// fewer allocations than loading the full dictionary).
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

    /// Streaming targeted resolve: scans `names.dmp` once, keeping only entries
    /// matching the requested tax IDs. Avoids loading the full 250 MB / 2.5M-entry
    /// dictionary when only a few hundred IDs are needed.
    public static func resolveFromFile(
        _ taxonomyDirectory: URL,
        taxIds: [Int]
    ) throws -> [Int: String] {
        let namesURL = taxonomyDirectory.appendingPathComponent("names.dmp")
        guard FileManager.default.fileExists(atPath: namesURL.path) else {
            throw TaxonomyResolverError.fileNotFound(namesURL)
        }

        let needed = Set(taxIds)
        if needed.isEmpty { return [:] }
        var result: [Int: String] = [:]
        result.reserveCapacity(needed.count)

        let handle = try FileHandle(forReadingFrom: namesURL)
        defer { try? handle.close() }

        let chunkSize = 4_194_304  // 4 MB
        var partial = Data()

        // A plain file's read hands back an autoreleased chunk, so each pass has a pool and its chunk dies with it.
        while try autoreleasepool(invoking: { () throws -> Bool in
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { return false }

            partial.append(chunk)
            guard let lastNewline = partial.lastIndex(of: UInt8(ascii: "\n")) else {
                return true
            }

            let completeRange = partial[partial.startIndex...lastNewline]
            if let text = String(data: Data(completeRange), encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    // Quick reject: skip lines not ending with "scientific name\t|"
                    // The pipe-delimited format means scientific name lines contain that string.
                    guard line.hasSuffix("scientific name\t|") else { continue }

                    let fields = line.split(separator: "|")
                    guard fields.count >= 4 else { continue }

                    let taxIdStr = fields[0].drop(while: { $0 == " " || $0 == "\t" })
                        .prefix(while: { $0 != " " && $0 != "\t" })
                    guard let taxId = Int(taxIdStr), needed.contains(taxId) else { continue }

                    let name = fields[1].trimmingCharacters(in: .whitespaces)
                    result[taxId] = name

                    if result.count == needed.count { break }
                }
            }

            if result.count == needed.count { return false }

            let nextIndex = partial.index(after: lastNewline)
            partial = nextIndex < partial.endIndex ? Data(partial[nextIndex...]) : Data()
            return true
        }) {}

        // Process remaining partial line
        if result.count < needed.count, !partial.isEmpty,
           let text = String(data: partial, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard line.hasSuffix("scientific name\t|") else { continue }
                let fields = line.split(separator: "|")
                guard fields.count >= 4 else { continue }
                let taxIdStr = fields[0].drop(while: { $0 == " " || $0 == "\t" })
                    .prefix(while: { $0 != " " && $0 != "\t" })
                guard let taxId = Int(taxIdStr), needed.contains(taxId) else { continue }
                result[taxId] = fields[1].trimmingCharacters(in: .whitespaces)
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
