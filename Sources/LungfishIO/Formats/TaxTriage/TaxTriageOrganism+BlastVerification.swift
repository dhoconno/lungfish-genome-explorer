// TaxTriageOrganism+BlastVerification.swift - The BLAST verification request for a TaxTriage organism
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension TaxTriageOrganism {

    /// The taxonomy an NCBI re-BLAST of this organism's reads is judged against.
    ///
    /// The clade is the organism's own tax ID, named by the organism name.
    /// TaxTriage keeps no taxonomy tree beside its results, so descendants
    /// such as strains are recognised by name: a hit reporting a strain-level
    /// tax ID still supports the organism when its NCBI organism name contains
    /// this one. A row without a tax ID is judged by name alone. Without a
    /// tree there are no known relatives.
    public var blastTaxonomyContext: BlastTaxonomyContext {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let names = trimmedName.isEmpty ? [] : [trimmedName]
        guard let taxId, taxId > 0 else {
            return BlastTaxonomyContext(cladeNames: names)
        }
        return BlastTaxonomyContext(cladeTaxIds: [taxId], cladeNames: names)
    }

    /// The request that re-BLASTs reads assigned to this organism against NCBI `core_nt`.
    ///
    /// - Parameter sequences: The subsampled reads to submit.
    public func blastVerificationRequest(sequences: [(id: String, sequence: String)]) -> BlastVerificationRequest {
        let context = blastTaxonomyContext
        return BlastVerificationRequest(
            taxonName: name,
            taxId: taxId ?? 0,
            sequences: sequences,
            database: BlastDatabaseID.coreNT.rawValue,
            entrezQuery: nil,
            acceptedTaxIds: context.cladeTaxIds,
            acceptedTaxonNames: context.cladeNames
        )
    }
}
