// ChromosomeNameMapping.swift - Reference genome bundle manifest data model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Chromosome Name Mapping

/// Builds a mapping from VCF chromosome names to bundle chromosome names.
///
/// Handles common mismatches:
/// - Version suffixes: `MN908947.3` → `MN908947`
/// - `chr` prefix: `chr1` → `1` or `1` → `chr1`
/// - Alias matching via `ChromosomeInfo.aliases`
///
/// - Parameters:
///   - vcfChromosomes: Distinct chromosome names found in the VCF
///   - bundleChromosomes: Chromosome info from the bundle manifest
/// - Returns: Dictionary mapping VCF names to bundle names (only for names that differ)
public func mapVCFChromosomes(
    _ vcfChromosomes: [String],
    toBundleChromosomes bundleChromosomes: [ChromosomeInfo]
) -> [String: String] {
    var mapping: [String: String] = [:]

    for vcfChrom in vcfChromosomes {
        // 1. Exact match — no mapping needed
        if bundleChromosomes.contains(where: { $0.name == vcfChrom }) {
            continue
        }

        // 2. Alias match
        if let match = bundleChromosomes.first(where: { $0.aliases.contains(vcfChrom) }) {
            mapping[vcfChrom] = match.name
            continue
        }

        // 3. Version suffix stripping: "MN908947.3" → "MN908947"
        let stripped = stripVersionSuffix(vcfChrom)
        if stripped != vcfChrom {
            if let match = bundleChromosomes.first(where: { $0.name == stripped }) {
                mapping[vcfChrom] = match.name
                continue
            }
            if let match = bundleChromosomes.first(where: { $0.aliases.contains(stripped) }) {
                mapping[vcfChrom] = match.name
                continue
            }
        }

        // 4. chr prefix handling: "chr1" ↔ "1"
        let chrVariant: String
        if vcfChrom.hasPrefix("chr") {
            chrVariant = String(vcfChrom.dropFirst(3))
        } else {
            chrVariant = "chr" + vcfChrom
        }
        if let match = bundleChromosomes.first(where: { $0.name == chrVariant }) {
            mapping[vcfChrom] = match.name
            continue
        }
        if let match = bundleChromosomes.first(where: { $0.aliases.contains(chrVariant) }) {
            mapping[vcfChrom] = match.name
            continue
        }

        // 5. Combined: strip version then try chr prefix
        if stripped != vcfChrom {
            let strippedChr: String
            if stripped.hasPrefix("chr") {
                strippedChr = String(stripped.dropFirst(3))
            } else {
                strippedChr = "chr" + stripped
            }
            if let match = bundleChromosomes.first(where: { $0.name == strippedChr }) {
                mapping[vcfChrom] = match.name
                continue
            }
        }

        // 6. Fuzzy: check if any bundle chromosome name starts with vcfChrom or vice versa
        //    e.g., bundle has "MN908947" and VCF has "MN908947.3"
        if let match = bundleChromosomes.first(where: { vcfChrom.hasPrefix($0.name + ".") }) {
            mapping[vcfChrom] = match.name
            continue
        }

        // 7. FASTA description match: parse "chromosome N" from description
        //    e.g., description "Macaca mulatta chromosome 7" matches VCF "7"
        let needle = "chromosome \(vcfChrom.lowercased())"
        if let match = bundleChromosomes.first(where: { chrom in
            guard let desc = chrom.fastaDescription?.lowercased() else { return false }
            // Match "chromosome <vcfChrom>" at word boundary
            return desc.contains(needle)
                && (desc.hasSuffix(needle)
                    || desc.contains("\(needle),")
                    || desc.contains("\(needle) "))
        }) {
            mapping[vcfChrom] = match.name
            continue
        }
    }

    return mapping
}

/// Strips a trailing version suffix from an accession-style name.
///
/// Examples: `MN908947.3` → `MN908947`, `NC_045512.2` → `NC_045512`, `chr1` → `chr1`
private func stripVersionSuffix(_ name: String) -> String {
    // Match pattern: name ends with .<digits>
    guard let dotIndex = name.lastIndex(of: ".") else { return name }
    let suffix = name[name.index(after: dotIndex)...]
    // Only strip if the suffix is all digits (version number)
    guard !suffix.isEmpty, suffix.allSatisfy(\.isWholeNumber) else { return name }
    return String(name[..<dotIndex])
}
