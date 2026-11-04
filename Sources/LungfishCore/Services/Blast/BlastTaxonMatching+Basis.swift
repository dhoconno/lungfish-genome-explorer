// BlastTaxonMatching+Basis.swift - What a BLAST verdict was judged at, and the words that say so
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension BlastTaxonomyContext {
    /// What a verdict was judged at (BLAST-ESVIRITU-FIRST-WORD, BIO ruling of the Phase 3.2 meeting).
    ///
    /// A count of accepted tax IDs cannot tell these apart, since a species can hold one ID, so the plan that builds
    /// the request records which one it used. The verdict rule does not change. A record from before this field has
    /// no basis and shows no line.
    public enum Basis: String, Sendable, Codable, CaseIterable {
        /// The NCBI Taxonomy's lineage, or the classifier's own tree, gave the clade, so a hit is judged at species level.
        case species
        /// Only the row's own tax ID and name were known. A best match filed under another name in the same species
        /// counts as contradicting.
        case rowTaxId
        /// No tax ID was known, so organism names alone judged the row.
        case names

        /// The line the pane shows beside the counts, or nil when the reading needs no caveat. BIO's words, which UX may
        /// change.
        public var judgedAtWords: String? {
            switch self {
            case .species:
                return nil
            case .rowTaxId:
                return "Judged by this row's own tax ID and name, because the NCBI Taxonomy database is not installed. "
                    + "A best match filed under another name in the same species counts as contradicting. "
                    + "Install NCBI Taxonomy in the database manager and run Verify with BLAST… again."
            case .names:
                return "Judged by organism names, because the NCBI Taxonomy database is not installed. "
                    + "A read can count for or against this row by a name it happens to share. "
                    + "Install NCBI Taxonomy in the database manager and run Verify with BLAST… again."
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
}
