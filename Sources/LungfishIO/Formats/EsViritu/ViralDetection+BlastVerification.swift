// ViralDetection+BlastVerification.swift - The BLAST verification request for an EsViritu detection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension ViralDetection {

    /// The names-only taxonomy, used when no lineage can be read. The clade names are the detection's name and its
    /// species, and the genus is the relative. Hits are judged by name, so a sibling named otherwise contradicts.
    ///
    /// A subspecies never counts, because `t__1` bare would match any organism that holds a 1.
    public var blastTaxonomyContext: BlastTaxonomyContext {
        var cladeNames: [String] = []
        for candidate in [name, species] {
            let bare = Self.bareLineageName(candidate)
            if !bare.isEmpty && !cladeNames.contains(bare) { cladeNames.append(bare) }
        }
        let genusName = Self.bareLineageName(genus)
        let relatedNames = genusName.isEmpty || cladeNames.contains(genusName) ? [] : [genusName]
        return BlastTaxonomyContext(cladeNames: cladeNames, relatedNames: relatedNames, basis: .names)
    }

    /// EsViritu writes lineage names with a rank prefix, `s__Betacoronavirus 1`. No NCBI record carries it.
    static func bareLineageName(_ raw: String?) -> String {
        var text = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        if text.count > 3, text.dropFirst().hasPrefix("__") { text.removeFirst(3) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The taxonomy judged at species level, the way NAO-MGS is (BIO-BLAST-WALK Q2). The row's tax ID is the one EsViritu's
    /// database files its accession under, and the row takes that ID's species clade. The clade names are the row's own
    /// name and the path's NCBI names, never EsViritu's species name, which on 23 of the table's rows names another
    /// NCBI species. It reads local files only and takes seconds, so call it off the main actor.
    ///
    /// With either directory nil, or no tax ID or lineage for the row, it is the names-only ``blastTaxonomyContext``.
    public func blastTaxonomyContext(databaseDirectory: URL?, taxonomyDirectory: URL?) -> BlastTaxonomyContext {
        let names = blastTaxonomyContext
        guard let databaseDirectory,
              let taxId = EsVirituDatabaseTaxonomy.taxId(accession: accession, species: species, databaseDirectory: databaseDirectory),
              let lineage = NCBITaxonomyLineage.blastTaxonomyContext(of: taxId, names: [name], taxonomyDirectory: taxonomyDirectory)
        else { return names }
        return BlastTaxonomyContext(
            cladeTaxIds: lineage.cladeTaxIds, cladeNames: lineage.cladeNames, relatedNames: names.relatedNames,
            basis: .species
        )
    }

    /// The request that re-BLASTs reads mapped to this detection against NCBI `core_nt`.
    ///
    /// - Parameters:
    ///   - sequences: The subsampled reads to submit.
    ///   - taxonomyContext: The taxonomy to judge by, from ``blastTaxonomyContext(databaseDirectory:taxonomyDirectory:)``.
    ///     With nil, the names-only ``blastTaxonomyContext``.
    public func blastVerificationRequest(
        sequences: [(id: String, sequence: String)],
        taxonomyContext: BlastTaxonomyContext? = nil
    ) -> BlastVerificationRequest {
        let context = taxonomyContext ?? blastTaxonomyContext
        return BlastVerificationRequest(
            taxonName: name,
            taxId: 0,
            sequences: sequences,
            database: BlastDatabaseID.coreNT.rawValue,
            entrezQuery: nil,
            acceptedTaxIds: context.cladeTaxIds,
            acceptedTaxonNames: context.cladeNames,
            relatedTaxIds: context.relatedTaxIds,
            relatedTaxonNames: context.relatedNames,
            judgedAt: context.basis
        )
    }
}
