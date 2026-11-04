// TaxonTree+BlastTaxonomy.swift - The clade and genus relatives BLAST hits are judged against
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension TaxonTree {

    /// The taxonomy BLAST verification judges hits against for `taxId`.
    ///
    /// - The clade is judged at species level. Its root is the taxon's nearest
    ///   species-rank ancestor in this tree, or the taxon itself when it is at
    ///   species rank or has no species above it, and the clade is that root
    ///   and every descendant in this tree. A report codes a no-rank node below
    ///   a species `S1`, `S2` and so on, which is not `.species`, so a claim on
    ///   such a node reaches the binomial species (BIO-BLAST-CLADE Q3).
    /// - The related set is the rest of the taxon's genus in this tree (the
    ///   nearest genus-rank ancestor and its descendants, minus the clade),
    ///   with the genus name leading the related names. A taxon at or above
    ///   genus rank has no relatives.
    ///
    /// A taxon missing from the tree yields a clade of just `taxId`. The context's basis is `species` for a clade the
    /// tree gave and `rowTaxId` for that lone tax ID (BLAST-ESVIRITU-FIRST-WORD).
    public func blastTaxonomyContext(for taxId: Int) -> BlastTaxonomyContext {
        guard let node = node(taxId: taxId) else {
            return BlastTaxonomyContext(cladeTaxIds: [taxId], basis: .rowTaxId)
        }
        var root = node
        var ancestor = node.rank == .species ? nil : node.parent
        while let current = ancestor, current.rank != .genus {
            if current.rank == .species {
                root = current
                break
            }
            ancestor = current.parent
        }
        // `allDescendants()` starts with the node itself, so the root is in the clade.
        let clade = root.allDescendants()
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
            return BlastTaxonomyContext(cladeTaxIds: cladeIds, cladeNames: cladeNames, basis: .species)
        }

        let relatives = genus.allDescendants().filter { !cladeIds.contains($0.taxId) }
        let relatedNames = [genus.name] + Array(Set(relatives.map(\.name)).subtracting([genus.name])).sorted()
        return BlastTaxonomyContext(
            cladeTaxIds: cladeIds,
            cladeNames: cladeNames,
            relatedTaxIds: Set(relatives.map(\.taxId)),
            relatedNames: relatedNames,
            basis: .species
        )
    }
}
