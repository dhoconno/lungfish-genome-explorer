// NvdBlastHit+BlastVerification.swift - The BLAST verification request for an NVD contig
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension NvdBlastHit {

    /// The taxonomy an NCBI re-BLAST of this contig is judged against.
    ///
    /// The clade is the NVD adjusted tax ID, named by `adjustedTaxidName`.
    /// NVD often uses a short name ("SARS-CoV-2") where NCBI records carry
    /// the scientific name ("Severe acute respiratory syndrome coronavirus
    /// 2"), so when this row's own subject is the adjusted taxon its
    /// `sscinames` entry is added as an alternate name. That name also
    /// catches NCBI hits reporting an isolate-level tax ID below the taxon.
    /// A row whose subject is some other organism adds nothing. Without a
    /// taxonomy tree there are no known relatives.
    public var blastTaxonomyContext: BlastTaxonomyContext {
        guard let taxId = Int(adjustedTaxid.trimmingCharacters(in: .whitespaces)) else {
            return BlastTaxonomyContext()
        }
        var names: [String] = []
        let adjustedName = adjustedTaxidName.trimmingCharacters(in: .whitespaces)
        if !adjustedName.isEmpty { names.append(adjustedName) }

        let subjectIds = Self.splitList(staxids)
        let subjectNames = Self.splitList(sscinames)
        if subjectIds.count == subjectNames.count {
            for (id, name) in zip(subjectIds, subjectNames)
            where Int(id) == taxId && !names.contains(name) {
                names.append(name)
            }
        }
        return BlastTaxonomyContext(cladeTaxIds: [taxId], cladeNames: names)
    }

    /// The request that re-BLASTs this hit's contig against NCBI `core_nt`.
    ///
    /// - Parameters:
    ///   - taxonName: The name shown for the classification being checked.
    ///   - sequence: The contig sequence to submit.
    public func blastVerificationRequest(taxonName: String, sequence: String) -> BlastVerificationRequest {
        let context = blastTaxonomyContext
        return BlastVerificationRequest(
            taxonName: taxonName,
            taxId: Int(adjustedTaxid) ?? 0,
            sequences: [(id: qseqid, sequence: sequence)],
            database: BlastDatabaseID.coreNT.rawValue,
            entrezQuery: nil,
            acceptedTaxIds: context.cladeTaxIds,
            acceptedTaxonNames: context.cladeNames
        )
    }

    /// Splits a BLAST multi-value column (`;`-separated) into trimmed entries.
    private static func splitList(_ value: String) -> [String] {
        value.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
