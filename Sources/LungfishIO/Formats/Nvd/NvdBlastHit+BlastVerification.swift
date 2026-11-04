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
    /// A row whose subject is some other organism adds nothing. There are no
    /// known relatives.
    ///
    /// With the installed NCBI Taxonomy's folder, the claim is judged at species
    /// level (`NCBITaxonomyLineage`): the clade is the adjusted taxon's nearest
    /// species-rank ancestor, or the taxon itself at or above species, the path
    /// up to it and its descendants up to 5,000, and the path's names follow
    /// these names. NVD's adjusted rank can sit below the current species (its
    /// `adjusted_taxid_rank` also reads `clade`). The read walks whole files, so
    /// call this off the main actor when a folder is passed. With no folder, or
    /// a tax ID the taxonomy does not hold, the clade is the adjusted tax ID. The context's basis is `species` with a
    /// lineage and `rowTaxId` without (BLAST-ESVIRITU-FIRST-WORD).
    public func blastTaxonomyContext(taxonomyDirectory: URL? = nil) -> BlastTaxonomyContext {
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
        return NCBITaxonomyLineage.blastTaxonomyContext(of: taxId, names: names, taxonomyDirectory: taxonomyDirectory)
            ?? BlastTaxonomyContext(cladeTaxIds: [taxId], cladeNames: names, basis: .rowTaxId)
    }

    /// The request that re-BLASTs this hit's contig against NCBI `core_nt`.
    ///
    /// - Parameters:
    ///   - taxonName: The name shown for the classification being checked.
    ///   - sequence: The contig sequence to submit.
    ///   - taxonomyDirectory: The installed NCBI Taxonomy's folder, nil to judge by the adjusted tax ID.
    public func blastVerificationRequest(
        taxonName: String,
        sequence: String,
        taxonomyDirectory: URL? = nil
    ) -> BlastVerificationRequest {
        let context = blastTaxonomyContext(taxonomyDirectory: taxonomyDirectory)
        return BlastVerificationRequest(
            taxonName: taxonName,
            taxId: Int(adjustedTaxid) ?? 0,
            sequences: [(id: qseqid, sequence: sequence)],
            database: BlastDatabaseID.coreNT.rawValue,
            entrezQuery: nil,
            acceptedTaxIds: context.cladeTaxIds,
            acceptedTaxonNames: context.cladeNames,
            judgedAt: context.basis
        )
    }

    /// Splits a BLAST multi-value column (`;`-separated) into trimmed entries.
    private static func splitList(_ value: String) -> [String] {
        value.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
