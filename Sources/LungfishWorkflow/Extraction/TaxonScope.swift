// TaxonScope.swift - Which reads of a selected taxon a Kraken2 extraction takes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO

/// Which reads of a selected taxon a Kraken2 extraction takes (BIO's ruling on Phase 2.12 lane 12.11,
/// section 2). `children`, the default, takes the reads Kraken2 assigned to the taxon and to each of its
/// descendants. `exact` takes only the reads assigned to the taxon itself, the ones Kraken2 could not
/// place below it. The raw values are the words of `extract reads --taxon-scope` and of the scope in an
/// `extract taxa-collection --target`.
public enum TaxonScope: String, Sendable, Hashable, CaseIterable {
    case children
    case exact

    /// Whether the extraction expands each taxon to its descendants.
    public var includesChildren: Bool { self == .children }

    /// The tax IDs a selection of `taxIds` matches under this scope, the taxa themselves for exact and
    /// with every descendant in `tree` for children, the set a record names as `resolvedTaxIds`.
    public func resolvedTaxIds(_ taxIds: Set<Int>, in tree: TaxonTree?) -> Set<Int> {
        var resolved = taxIds
        guard includesChildren, let tree else { return resolved }
        for taxId in taxIds {
            for descendant in tree.node(taxId: taxId)?.allDescendants() ?? [] {
                resolved.insert(descendant.taxId)
            }
        }
        return resolved
    }
}
