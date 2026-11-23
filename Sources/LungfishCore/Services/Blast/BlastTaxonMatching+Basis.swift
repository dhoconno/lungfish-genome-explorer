// BlastTaxonMatching+Basis.swift - What a BLAST verdict was judged at, and the words that say so
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension BlastTaxonomyContext {
    /// What a verdict was judged at (BLAST-ESVIRITU-FIRST-WORD, BIO ruling of the Phase 3.2 meeting).
    ///
    /// A count of accepted tax IDs cannot tell these apart, since a species can hold one ID, so the plan that builds
    /// the request records which one it used. A verdict is given only at `species` (UX-BLAST-NOTAX). The raw values are
    /// the ones saved records and `--judged-at` use, so an older build still decodes a new record. A record from before
    /// this field has no basis and shows no line.
    public enum Basis: String, Sendable, Codable, CaseIterable {
        /// The NCBI Taxonomy's lineage gave the clade, so a hit is judged at species level.
        case species
        /// No NCBI Taxonomy lineage was found for the row (not installed, or it does not list the tax ID), so no verdict
        /// is given.
        case rowTaxId
        /// The row has no tax ID, so no verdict is given.
        case names

        /// The line the pane shows beside the badge for a row with tax ID `taxId`, or nil when the reading needs no
        /// caveat. UX's words (UX-BLAST-NOTAX item 5).
        public func judgedAtWords(taxId: Int) -> String? {
            switch self {
            case .species:
                return nil
            case .rowTaxId:
                return "Not judged: without NCBI Taxonomy, LGE cannot tell this species from another species whose name holds this row's name. "
                    + "Install NCBI Taxonomy in the Databases tab of the Plugin Manager, or update it if it does not list tax ID \(taxId), "
                    + "then run Verify with BLAST… again. Each read's best match is listed below."
            case .names:
                return "Not judged: this row has no tax ID, so LGE cannot tell its species from another species whose name holds this row's name. "
                    + "Each read's best match is listed below."
            }
        }
    }
}

extension BlastVerificationResult {
    /// This result with what its verdicts were judged at (BLAST-ESVIRITU-FIRST-WORD).
    public func judged(at basis: BlastTaxonomyContext.Basis?) -> BlastVerificationResult {
        var copy = self
        copy.judgedAt = basis
        return copy
    }

    /// The line the pane shows beside the badge, from ``judgedAt`` and this row's tax ID, or nil for a species-level
    /// verdict and for a record from before the field.
    public var judgedAtWords: String? {
        judgedAt?.judgedAtWords(taxId: taxId)
    }

    /// The number of reads with a significant hit, which a result that was not judged gives in place of its counts for
    /// and against.
    public var significantHitCount: Int {
        supportingCount + contradictingCount
    }
}
