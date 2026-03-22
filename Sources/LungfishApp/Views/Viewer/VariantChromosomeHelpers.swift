// VariantChromosomeHelpers.swift - Free functions for chromosome resolution and genotype classification
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Canonicalizes chromosome labels for loose matching (e.g. `chr1` == `1`, `NC_000001.11` == `NC_000001`).
func canonicalVariantChromosomeLookupKey(_ name: String) -> String {
    var value = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("chr") {
        value = String(value.dropFirst(3))
    }
    if let dot = value.firstIndex(of: ".") {
        value = String(value[..<dot])
    }
    return value
}

/// Resolves the ordered list of chromosome query candidates for a track database.
///
/// Order is:
/// 1) Requested chromosome (exact) when present in the database
/// 2) Alias-map forward/reverse matches
/// 3) Canonicalized fallback matches
/// 4) Requested chromosome as final fallback (for legacy databases with unknown chromosome sets)
func resolveVariantChromosomeCandidates(
    requestedChromosome: String,
    availableChromosomes: Set<String>,
    aliasMap: [String: String]
) -> [String] {
    if availableChromosomes.isEmpty {
        return [requestedChromosome]
    }

    var ordered: [String] = []
    if availableChromosomes.contains(requestedChromosome) {
        ordered.append(requestedChromosome)
    }

    if let aliased = aliasMap[requestedChromosome], availableChromosomes.contains(aliased) {
        ordered.append(aliased)
    }

    for (refName, vcfName) in aliasMap where vcfName == requestedChromosome {
        if availableChromosomes.contains(refName) {
            ordered.append(refName)
        }
    }

    let canonical = canonicalVariantChromosomeLookupKey(requestedChromosome)
    for candidate in availableChromosomes {
        if canonicalVariantChromosomeLookupKey(candidate) == canonical {
            ordered.append(candidate)
        }
    }

    if ordered.isEmpty {
        ordered.append(requestedChromosome)
    }

    // Deduplicate while preserving priority order (Swift-native, avoids NSObject bridging).
    var seen = Set<String>()
    return ordered.filter { seen.insert($0).inserted }
}

// MARK: - Genotype Classification (free functions for background-thread use)

/// Classifies a GenotypeRecord into a display call category.
/// This is a module-level free function (not a method on @MainActor SequenceViewerView)
/// so it can be safely called from GCD background queues.
func classifyGenotype(_ gt: GenotypeRecord) -> GenotypeDisplayCall {
    GenotypeDisplayCall.classify(genotype: gt.genotype, allele1: gt.allele1, allele2: gt.allele2)
}

/// Returns alt allele fraction from VCF AD string ("ref,alt,...") when available.
func alleleFraction(from alleleDepths: String?) -> Double? {
    guard let alleleDepths else { return nil }
    let depths = alleleDepths
        .split(separator: ",")
        .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    guard depths.count >= 2 else { return nil }
    let total = depths.reduce(0, +)
    guard total > 0 else { return nil }
    let altDepth = depths.dropFirst().reduce(0, +)
    return min(1.0, max(0.0, Double(altDepth) / Double(total)))
}

/// Returns an allele fraction from common INFO AF keys.
///
/// Supports scalar and comma-delimited values by using the first parsable value.
func alleleFractionFromINFO(_ info: [String: String]) -> Double? {
    let candidateKeys = ["AF", "af", "VAF", "FREQ", "ALT_FREQ", "MLEAF"]
    for key in candidateKeys {
        guard let raw = info[key], !raw.isEmpty else { continue }
        let first = raw.split(separator: ",", omittingEmptySubsequences: true).first.map(String.init) ?? raw
        if let value = Double(first.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return min(1.0, max(0.0, value))
        }
    }
    return nil
}

/// Enriches variant sites with amino acid impact data from CSQ/INFO fields.
/// Called on the background genotype fetch queue -- does NOT access @MainActor state.
func enrichSitesWithCSQImpact(
    _ sites: inout [VariantSite],
    variantDatabasesByTrackId: [String: VariantDatabase]
) {
    guard !sites.isEmpty, !variantDatabasesByTrackId.isEmpty else { return }

    // Group row IDs by source track to avoid cross-database row-id collisions.
    var rowIdsByTrack: [String: [Int64]] = [:]
    for site in sites {
        guard let trackId = site.sourceTrackId, let rowId = site.databaseRowId else { continue }
        rowIdsByTrack[trackId, default: []].append(rowId)
    }
    guard !rowIdsByTrack.isEmpty else { return }

    // Batch-fetch INFO maps per track/database.
    var infoMapByTrack: [String: [Int64: [String: String]]] = [:]
    for (trackId, rowIds) in rowIdsByTrack {
        guard let db = variantDatabasesByTrackId[trackId], !rowIds.isEmpty else { continue }
        infoMapByTrack[trackId] = db.batchInfoValues(variantIds: rowIds)
    }

    // Enrich each site
    for i in sites.indices {
        guard let trackId = sites[i].sourceTrackId else { continue }
        guard let rowId = sites[i].databaseRowId,
              let info = infoMapByTrack[trackId]?[rowId] else { continue }

        let consequence = info["CSQ_Consequence"] ?? info["ANN_Consequence"] ?? info["Consequence"]
        let csqImpact = info["CSQ_IMPACT"] ?? info["ANN_IMPACT"] ?? info["IMPACT"] ?? info["impact"]
        let symbol = info["CSQ_SYMBOL"] ?? info["CSQ_Gene"] ?? info["ANN_Gene"] ?? info["GENE"] ?? info["Gene"]
        let aminoAcids = info["CSQ_Amino_acids"] ?? info["ANN_AA_pos_len"]
        let proteinPos = info["CSQ_Protein_position"] ?? info["Protein_position"]

        // Classify impact from CSQ fields
        if consequence != nil || csqImpact != nil {
            sites[i].impact = VariantImpact.fromCSQ(impact: csqImpact, consequence: consequence)
            sites[i].geneSymbol = symbol

            // Build amino-acid changes from possibly multi-entry CSQ strings.
            if let aasRaw = aminoAcids {
                let aaEntries = splitMultiInfoValue(aasRaw)
                let posEntries = splitMultiInfoValue(proteinPos ?? "")
                var longChanges: [String] = []
                var shortChanges: [String] = []
                for (idx, aaEntry) in aaEntries.enumerated() {
                    guard aaEntry.contains("/") else { continue }
                    let parts = aaEntry.split(separator: "/", omittingEmptySubsequences: false)
                    guard parts.count == 2 else { continue }
                    let refAA = String(parts[0])
                    let altAA = String(parts[1])
                    let pos = idx < posEntries.count ? posEntries[idx] : (proteinPos ?? "")
                    let normalizedPos = pos.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalizedPos.isEmpty else { continue }
                    longChanges.append("p.\(refAA)\(normalizedPos)\(altAA)")
                    if refAA.count == 1 && altAA.count == 1 {
                        shortChanges.append("\(refAA)\(normalizedPos)\(altAA)")
                    } else {
                        let refSingle = threeLetterToSingleAA(refAA)
                        let altSingle = threeLetterToSingleAA(altAA)
                        if let r = refSingle, let a = altSingle {
                            shortChanges.append("\(r)\(normalizedPos)\(a)")
                        }
                    }
                }
                let dedupLong = orderedUniqueStrings(longChanges)
                let dedupShort = orderedUniqueStrings(shortChanges)
                if !dedupLong.isEmpty {
                    sites[i].aminoAcidChange = dedupLong.joined(separator: ", ")
                }
                if !dedupShort.isEmpty {
                    sites[i].shortAAChange = dedupShort.joined(separator: ", ")
                }
            }
        } else {
            // No CSQ annotation -- classify by variant type heuristic
            if sites[i].variantType == "INS" || sites[i].variantType == "DEL" {
                let refLen = sites[i].ref.count
                let altLen = sites[i].alt.count
                if abs(refLen - altLen) % 3 != 0 {
                    sites[i].impact = .frameshift
                }
            }
        }

        // Haploid/viral callsets often provide AF in INFO without per-sample AD.
        // Fill missing per-sample AF from INFO so genotype row intensity reflects AF.
        if let variantAF = alleleFractionFromINFO(info), !sites[i].genotypes.isEmpty {
            for (sample, call) in sites[i].genotypes where call == .het || call == .homAlt {
                if sites[i].sampleAlleleFractions[sample] == nil {
                    sites[i].sampleAlleleFractions[sample] = variantAF
                }
            }
        }
    }
}

/// Converts a 3-letter amino acid code to its single-letter equivalent.
private func threeLetterToSingleAA(_ code: String) -> String? {
    let map: [String: String] = [
        "Ala": "A", "Arg": "R", "Asn": "N", "Asp": "D", "Cys": "C",
        "Gln": "Q", "Glu": "E", "Gly": "G", "His": "H", "Ile": "I",
        "Leu": "L", "Lys": "K", "Met": "M", "Phe": "F", "Pro": "P",
        "Ser": "S", "Thr": "T", "Trp": "W", "Tyr": "Y", "Val": "V",
        "Sec": "U", "Pyl": "O", "Ter": "*",
    ]
    // Already single-letter?
    if code.count == 1 { return code }
    return map[code]
}

/// Splits an INFO field value containing comma/ampersand-delimited items.
private func splitMultiInfoValue(_ raw: String) -> [String] {
    raw.split(whereSeparator: { $0 == "," || $0 == "&" })
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// Returns unique strings preserving first-seen order.
private func orderedUniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    result.reserveCapacity(values.count)
    for value in values where seen.insert(value).inserted {
        result.append(value)
    }
    return result
}
