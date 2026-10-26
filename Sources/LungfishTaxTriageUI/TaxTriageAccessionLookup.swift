// TaxTriageAccessionLookup.swift - The reference accessions that an organism name stands for in a TaxTriage result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane TT-FUZZY-NAME. The lookup that `TaxTriageResultViewController` ran in place now lives here as
// plain functions of the name, the map and the read counts, so a test can call it without a window. This commit
// moves it with its behaviour unchanged.

import Foundation

/// The name-keyed lookup behind a TaxTriage row that no tax ID map covers.
enum TaxTriageAccessionLookup {

    /// `accessions` without empty entries and repeats, in first-seen order.
    nonisolated static func uniquePreservingOrder(_ accessions: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        ordered.reserveCapacity(accessions.count)
        for accession in accessions where !accession.isEmpty {
            if seen.insert(accession).inserted {
                ordered.append(accession)
            }
        }
        return ordered
    }

    /// The accessions of `accessions` with the most mapped reads first. Equal counts sort by accession.
    nonisolated static func rankedByReadSupport(_ accessions: [String], readCounts: [String: Int]) -> [String] {
        uniquePreservingOrder(accessions).sorted { lhs, rhs in
            let lhsReads = readCounts[lhs] ?? 0
            let rhsReads = readCounts[rhs] ?? 0
            if lhsReads != rhsReads {
                return lhsReads > rhsReads
            }
            return lhs < rhs
        }
    }

    /// The accessions that `mapping` holds for `normalizedOrganismName`, ranked by read support, or nil.
    nonisolated static func accessions(
        for normalizedOrganismName: String,
        in mapping: [String: [String]],
        readCounts: [String: Int]
    ) -> [String]? {
        guard !normalizedOrganismName.isEmpty else { return nil }

        if let exact = mapping[normalizedOrganismName], !exact.isEmpty {
            return rankedByReadSupport(exact, readCounts: readCounts)
        }
        if let fuzzy = mapping.first(where: { key, _ in
            key.contains(normalizedOrganismName) || normalizedOrganismName.contains(key)
        }) {
            return rankedByReadSupport(fuzzy.value, readCounts: readCounts)
        }

        // Token-overlap fallback handles minor source typos/variant formatting
        // (e.g. missing first character, shortened years like /40 vs /1940).
        let best = mapping.max { lhs, rhs in
            tokenSimilarity(lhs.key, normalizedOrganismName) < tokenSimilarity(rhs.key, normalizedOrganismName)
        }
        if let best, tokenSimilarity(best.key, normalizedOrganismName) >= 0.75 {
            return rankedByReadSupport(best.value, readCounts: readCounts)
        }
        return nil
    }

    private nonisolated static func tokenSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = Set(lhs.split(separator: " ").map(String.init))
        let rhsTokens = Set(rhs.split(separator: " ").map(String.init))
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        let intersection = lhsTokens.intersection(rhsTokens).count
        let denominator = max(lhsTokens.count, rhsTokens.count)
        guard denominator > 0 else { return 0 }
        return Double(intersection) / Double(denominator)
    }
}
