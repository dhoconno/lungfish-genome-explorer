// ViralDetection+BlastVerification.swift - The BLAST verification request for an EsViritu detection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension ViralDetection {

    /// The taxonomy an NCBI re-BLAST of this detection's reads is judged against.
    ///
    /// EsViritu reports lineage names but no tax IDs, so hits are judged by
    /// name. The clade names are the detection's own name, its species, and
    /// its subspecies. EsViritu's name for a virus often differs from the one
    /// NCBI records carry, and the species name is the one a hit is most
    /// likely to share. The genus is recorded as the relative name.
    public var blastTaxonomyContext: BlastTaxonomyContext {
        var cladeNames: [String] = []
        for candidate in [name, species, subspecies] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespaces) ?? ""
            if !trimmed.isEmpty && !cladeNames.contains(trimmed) {
                cladeNames.append(trimmed)
            }
        }
        let genusName = genus?.trimmingCharacters(in: .whitespaces) ?? ""
        let relatedNames = genusName.isEmpty || cladeNames.contains(genusName) ? [] : [genusName]
        return BlastTaxonomyContext(cladeNames: cladeNames, relatedNames: relatedNames)
    }

    /// The request that re-BLASTs reads mapped to this detection against NCBI `core_nt`.
    ///
    /// - Parameter sequences: The subsampled reads to submit.
    public func blastVerificationRequest(sequences: [(id: String, sequence: String)]) -> BlastVerificationRequest {
        let context = blastTaxonomyContext
        return BlastVerificationRequest(
            taxonName: name,
            taxId: 0,
            sequences: sequences,
            database: "core_nt",
            entrezQuery: nil,
            acceptedTaxIds: context.cladeTaxIds,
            acceptedTaxonNames: context.cladeNames,
            relatedTaxIds: context.relatedTaxIds,
            relatedTaxonNames: context.relatedNames
        )
    }
}
