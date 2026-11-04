// BlastTieSummary.swift - What one read's tie at NCBI's best bit score held
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What one read's tie at NCBI's best bit score held (BIO-BLAST-TIES item 11).
///
/// A reply's list is a draw from the tie and not the whole of it, so these are counts of what this run returned.
public struct BlastTieSummary: Sendable, Codable, Equatable {

    /// The list size the request asked for, `nil` when the caller named none.
    public let hitListSize: Int?

    /// The records NCBI returned for this read.
    public let hitsReturned: Int

    /// NCBI's best bit score for this read, as the reply prints it.
    public let bestBitScore: Double

    /// The records at that score, the best record among them.
    public let tied: Int

    /// The tied records filed in the queried clade by their first defline.
    public let inClade: Int

    /// The tied records that are not: a relative, a record outside, or a record with no tax ID.
    public let outside: Int

    /// Whether the list ended inside the tie, so a record past its end cannot be seen.
    public let runsPastList: Bool

    /// Up to three organisms among the tied records outside the clade, the most frequent first.
    public let outsideExamples: [String]

    /// Creates a tie summary.
    public init(
        hitListSize: Int?,
        hitsReturned: Int,
        bestBitScore: Double,
        tied: Int,
        inClade: Int,
        outside: Int,
        runsPastList: Bool,
        outsideExamples: [String]
    ) {
        self.hitListSize = hitListSize
        self.hitsReturned = hitsReturned
        self.bestBitScore = bestBitScore
        self.tied = tied
        self.inClade = inClade
        self.outside = outside
        self.runsPastList = runsPastList
        self.outsideExamples = outsideExamples
    }
}
