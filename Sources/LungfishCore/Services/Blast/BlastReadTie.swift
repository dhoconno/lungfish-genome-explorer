// BlastReadTie.swift - The records tied at NCBI's best bit score on one read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The records tied at NCBI's best bit score on one read, judged against the queried clade (BIO-BLAST-TIES).
///
/// NCBI's order among them is not evidence, and a list is a draw from the tie at any size, so the rule needs one clade
/// record and names no record. Tied means the same bit score as the first record, exactly as the reply prints it.
struct BlastReadTie {
    let summary: BlastTieSummary

    /// Whether a tied record is filed in the clade under any of its deflines, which is what makes a read supporting.
    let holdsClade: Bool

    private let firstCladeIndex: Int?
    private let firstOutsideIndex: Int?

    /// `nil` when the reply has no hit, or when its first record leaves only the name rule to judge (no tax ID on the
    /// record, or none in the claim). The name rule judges the first record and never reads a tie.
    init?(hits: [BlastHit], hitListSize: Int?, queriedTaxonName: String, context: BlastTaxonomyContext) {
        func relation(_ hit: BlastHit) -> BlastHitRelation? {
            BlastTaxonMatching.relation(
                hitOrganism: hit.organism ?? hit.title, hitTaxId: hit.taxId,
                queriedTaxonName: queriedTaxonName, context: context
            )
        }
        guard let first = hits.first, let best = first.hsps.first?.bitScore, relation(first) != nil else { return nil }
        let tied = hits.indices.filter { hits[$0].hsps.first?.bitScore == best }
        let filedInClade = tied.filter { relation(hits[$0]) == .clade }
        let filedOutside = tied.filter { relation(hits[$0]) != .clade }
        let laterDefline = filedOutside.first { !context.cladeTaxIds.isDisjoint(with: hits[$0].otherTaxIds) }

        self.holdsClade = !filedInClade.isEmpty || laterDefline != nil
        let cladeIndex = filedInClade.first ?? laterDefline
        self.firstCladeIndex = cladeIndex
        self.firstOutsideIndex = filedOutside.first { $0 != cladeIndex }
        self.summary = BlastTieSummary(
            hitListSize: hitListSize,
            hitsReturned: hits.count,
            bestBitScore: best,
            tied: tied.count,
            inClade: filedInClade.count,
            outside: filedOutside.count,
            runsPastList: hitListSize.map { hits.count >= $0 && hits.last?.hsps.first?.bitScore == best } ?? false,
            outsideExamples: Self.mostFrequentOrganisms(filedOutside.map { hits[$0].organism ?? hits[$0].title }, count: 3)
        )
    }

    /// A shared tie shows its first clade record first and its first record outside second, then NCBI's order. Any other
    /// list keeps NCBI's order.
    func displayOrder(of hits: [BlastHit]) -> [BlastHit] {
        guard summary.outside > 0, let cladeIndex = firstCladeIndex else { return hits }
        let head = [cladeIndex] + (firstOutsideIndex.map { [$0] } ?? [])
        return head.map { hits[$0] } + hits.indices.filter { !head.contains($0) }.map { hits[$0] }
    }

    private static func mostFrequentOrganisms(_ names: [String], count: Int) -> [String] {
        var tally: [String: (count: Int, firstSeen: Int)] = [:]
        for (index, name) in names.enumerated() {
            tally[name, default: (0, index)].count += 1
        }
        return tally.sorted { ($0.value.count, $1.value.firstSeen) > ($1.value.count, $0.value.firstSeen) }
            .prefix(count).map(\.key)
    }
}
