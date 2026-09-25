// TaxonTree+BlastTaxonomy.swift - The clade and genus relatives BLAST hits are judged against
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension TaxonTree {

    /// The taxonomy BLAST verification judges hits against for `taxId`.
    ///
    /// - The clade is the taxon and every descendant in this tree.
    /// - The related set is the rest of the taxon's genus in this tree (the
    ///   nearest genus-rank ancestor and its descendants, minus the clade),
    ///   with the genus name leading the related names. A taxon at or above
    ///   genus rank has no relatives.
    ///
    /// A taxon missing from the tree yields a clade of just `taxId`.
    public func blastTaxonomyContext(for taxId: Int) -> BlastTaxonomyContext {
        guard let node = node(taxId: taxId) else {
            return BlastTaxonomyContext(cladeTaxIds: [taxId])
        }
        let clade = node.allDescendants()
        let cladeIds = Set(clade.map(\.taxId))
        let cladeNames = Array(Set(clade.map(\.name))).sorted()

        var genus: TaxonNode?
        var cursor: TaxonNode? = node.parent
        while let current = cursor {
            if current.rank == .genus {
                genus = current
                break
            }
            cursor = current.parent
        }
        guard node.rank != .genus, let genus else {
            return BlastTaxonomyContext(cladeTaxIds: cladeIds, cladeNames: cladeNames)
        }

        let relatives = genus.allDescendants().filter { !cladeIds.contains($0.taxId) }
        let relatedNames = [genus.name] + Array(Set(relatives.map(\.name)).subtracting([genus.name])).sorted()
        return BlastTaxonomyContext(
            cladeTaxIds: cladeIds,
            cladeNames: cladeNames,
            relatedTaxIds: Set(relatives.map(\.taxId)),
            relatedNames: relatedNames
        )
    }
}
