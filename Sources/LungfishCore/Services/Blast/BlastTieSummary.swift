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

/// The words a person reads about a tie, from BIO-BLAST-TIES section 3.
public enum BlastTieWords {

    /// The words for one read, or `nil` when it has no tie to speak of. A saved record has no summary, so none.
    public static func read(_ row: BlastReadResult) -> String? {
        guard let tie = row.tieSummary else { return nil }
        if tie.runsPastList, tie.inClade == 0, !row.matchesQueriedTaxon {
            let list = tie.hitListSize ?? tie.hitsReturned
            return "More than \(list) records tie at the best score and none returned is in this taxon. "
                + "NCBI's list ended before the tie did, so this read counts neither way."
        }
        guard tie.tied > 1 else { return nil }
        // A tie that holds the clade shows a clade record first, so "more" counts the ones beside the record shown.
        let others = tie.tied - 1
        let more = max(tie.inClade - 1, 0)
        let outside = tie.inClade > 0 ? tie.outside : max(tie.outside - 1, 0)
        return "Tied with \(others) other \(others == 1 ? "record" : "records") at the best score: "
            + "\(more) more in this taxon, \(outside) outside. NCBI returned \(tie.hitsReturned)."
    }

    /// The count beside a row's numbers, empty when no read is flagged. A flag with no shared tie behind it, on the
    /// name rule, on mates that split or on a saved record, keeps the older words.
    public static func flaggedCount(in result: BlastVerificationResult) -> String {
        let flagged = result.readResults.filter(\.hasLCADisagreement)
        let shared = flagged.filter { row in
            ([row] + (row.otherMates ?? [])).contains { ($0.tieSummary?.outside ?? 0) > 0 }
        }.count
        var parts: [String] = []
        if shared > 0 { parts.append("\(shared) also \(shared == 1 ? "matches" : "match") other records equally") }
        if flagged.count > shared { parts.append("\(flagged.count - shared) with conflicting organisms") }
        return parts.joined(separator: ", ")
    }

    /// The sentence beside a Not specific row's counts, or `nil` on any other row.
    public static func notSpecificSummary(for result: BlastVerificationResult) -> String? {
        guard result.confidence == .notSpecific else { return nil }
        var examples: [String] = []
        for row in result.readResults where row.verdict == .verified && row.matchesQueriedTaxon {
            for mate in [row] + (row.otherMates ?? []) {
                for name in mate.tieSummary?.outsideExamples ?? [] where !examples.contains(name) { examples.append(name) }
            }
        }
        let suchAs = examples.isEmpty ? "" : ", such as " + examples.prefix(2).joined(separator: " and ")
        return "Every supporting read also matches other records equally\(suchAs). "
            + "These reads cannot tell \(result.taxonName) apart from them."
    }
}
