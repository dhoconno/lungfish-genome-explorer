// TaxTriageOrganism+BlastVerification.swift - The BLAST verification request for a TaxTriage organism
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension TaxTriageOrganism {

    /// The taxonomy an NCBI re-BLAST of this organism's reads is judged against.
    ///
    /// With the installed NCBI Taxonomy's folder, the claim is judged at species
    /// level (`NCBITaxonomyLineage`): the clade is the organism's nearest
    /// species-rank ancestor, or the organism itself at or above species, the
    /// path up to it and its descendants up to 5,000, named by the organism's
    /// name and the path's names. The read walks whole files, so call this off
    /// the main actor when a folder is passed.
    ///
    /// With no folder, or a tax ID the taxonomy does not hold, the clade is the
    /// organism's own tax ID, named by the organism name. TaxTriage keeps no
    /// taxonomy tree beside its results, so descendants such as strains are
    /// recognised by name: a hit reporting a strain-level tax ID still supports
    /// the organism when its NCBI organism name contains this one. A row
    /// without a tax ID is judged by name alone. There are no known relatives. The context's basis says which of the
    /// three it came to, `species`, `rowTaxId` or `names` (BLAST-ESVIRITU-FIRST-WORD).
    public func blastTaxonomyContext(taxonomyDirectory: URL? = nil) -> BlastTaxonomyContext {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let names = trimmedName.isEmpty ? [] : [trimmedName]
        guard let taxId, taxId > 0 else {
            return BlastTaxonomyContext(cladeNames: names, basis: .names)
        }
        return NCBITaxonomyLineage.blastTaxonomyContext(of: taxId, names: names, taxonomyDirectory: taxonomyDirectory)
            ?? BlastTaxonomyContext(cladeTaxIds: [taxId], cladeNames: names, basis: .rowTaxId)
    }

    /// The request that re-BLASTs reads assigned to this organism against NCBI `core_nt`.
    ///
    /// - Parameters:
    ///   - sequences: The subsampled reads to submit.
    ///   - taxonomyDirectory: The installed NCBI Taxonomy's folder, nil to judge by the organism's own tax ID.
    public func blastVerificationRequest(
        sequences: [(id: String, sequence: String)],
        taxonomyDirectory: URL? = nil
    ) -> BlastVerificationRequest {
        let context = blastTaxonomyContext(taxonomyDirectory: taxonomyDirectory)
        return BlastVerificationRequest(
            taxonName: name,
            taxId: taxId ?? 0,
            sequences: sequences,
            database: BlastDatabaseID.coreNT.rawValue,
            entrezQuery: nil,
            acceptedTaxIds: context.cladeTaxIds,
            acceptedTaxonNames: context.cladeNames,
            judgedAt: context.basis
        )
    }
}
