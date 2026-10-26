// TaxTriageAccessionLookup.swift - The reference accessions that an organism name stands for in a TaxTriage result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane TT-FUZZY-NAME. The lookup that `TaxTriageResultViewController` ran in place lives here as plain
// functions of the name, the map and the read counts, so a test can call it without a window. A BIO ruling of
// 2026-10-26 narrowed it to the exact normalized name (docs/plans/BACKLOG.md, TT-FUZZY-NAME).

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

    /// The accessions that `mapping` holds under exactly `normalizedOrganismName`, ranked by read support, or nil.
    ///
    /// The name is a key or it is not. A key that contains the name, a name that contains a key and a key whose
    /// tokens mostly agree are other organisms (type 1 and type 16, the 6A and 6B species, two serotypes), so none
    /// of them answers. Nil sends the row to the words of a row that has no reference of its own.
    nonisolated static func accessions(
        for normalizedOrganismName: String,
        in mapping: [String: [String]],
        readCounts: [String: Int]
    ) -> [String]? {
        guard !normalizedOrganismName.isEmpty,
              let exact = mapping[normalizedOrganismName], !exact.isEmpty else { return nil }
        return rankedByReadSupport(exact, readCounts: readCounts)
    }
}
