// BlastService+Verdicts.swift - How BlastService judges each read's BLAST hits
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension BlastService {

    // MARK: - Verdict Assignment

    /// Assigns a verification verdict to each read based on BLAST results.
    ///
    /// For each query, the top hit's identity, coverage, and E-value are
    /// compared against thresholds:
    /// - **Verified**: >= 90% identity AND >= 80% query coverage AND E-value <= threshold
    /// - **Ambiguous**: Hit found but thresholds not fully met
    /// - **Unverified**: No hits found within the taxon
    /// - **Error**: NCBI returned no usable entry for the read
    ///
    /// Also builds up to 5 ``BlastHitSummary`` entries per read, flags reads
    /// whose top hits name conflicting organisms, and attaches the original
    /// query sequence.
    ///
    /// - Parameters:
    ///   - searchResults: Parsed BLAST search results
    ///   - eValueThreshold: E-value threshold for significance
    ///   - sequenceMap: Mapping from read ID to original query sequence (default: empty)
    ///   - sequenceMates: Mapping from read ID to the mate (1 or 2) submitted
    ///     for a paired fragment.
    ///   - acceptedTaxIds: Tax IDs of the queried clade (the taxon and its
    ///     descendants). Hits that report a tax ID are judged against these.
    ///   - acceptedTaxonNames: Names in the queried clade.
    ///   - relatedTaxIds: Tax IDs in the queried taxon's genus outside the clade.
    ///   - relatedTaxonNames: Names in the queried taxon's genus outside the clade.
    /// - Returns: Array of per-read verification results
    nonisolated func assignVerdicts(
        searchResults: [BlastSearchResult],
        eValueThreshold: Double,
        sequenceMap: [String: String] = [:],
        queriedTaxonName: String = "",
        sequenceMates: [String: Int] = [:],
        acceptedTaxIds: Set<Int> = [],
        acceptedTaxonNames: [String] = [],
        relatedTaxIds: Set<Int> = [],
        relatedTaxonNames: [String] = []
    ) -> [BlastReadResult] {
        let context = BlastTaxonomyContext(
            cladeTaxIds: acceptedTaxIds,
            cladeNames: acceptedTaxonNames,
            relatedTaxIds: relatedTaxIds,
            relatedNames: relatedTaxonNames
        )
        return searchResults.map { result in
            assignVerdict(
                for: result,
                eValueThreshold: eValueThreshold,
                sequenceMap: sequenceMap,
                queriedTaxonName: queriedTaxonName,
                sequenceMates: sequenceMates,
                context: context
            )
        }
    }

    /// Assigns a verdict for a single query result.
    ///
    /// Besides the alignment-quality thresholds, this decides whether the top
    /// hit lies inside the queried clade (by tax ID where available, see
    /// ``BlastTaxonMatching``) and whether the top hits conflict.
    private nonisolated func assignVerdict(
        for result: BlastSearchResult,
        eValueThreshold: Double,
        sequenceMap: [String: String],
        queriedTaxonName: String,
        sequenceMates: [String: Int],
        context: BlastTaxonomyContext
    ) -> BlastReadResult {
        if let failure = result.failureMessage {
            return BlastReadResult(
                id: result.queryId,
                verdict: .error,
                querySequence: sequenceMap[result.queryId],
                submittedMate: sequenceMates[result.queryId],
                errorMessage: failure
            )
        }

        // Find the best HSP across all hits
        guard let topHit = result.hits.first,
              let bestHSP = topHit.hsps.first else {
            // No hits at all
            return BlastReadResult(
                id: result.queryId,
                verdict: .unverified,
                querySequence: sequenceMap[result.queryId],
                submittedMate: sequenceMates[result.queryId]
            )
        }

        let pctIdentity = bestHSP.percentIdentity
        let coverage = bestHSP.queryCoverage(queryLength: result.queryLength)
        let eValue = bestHSP.evalue

        // Determine verdict based on alignment quality
        let verdict: BlastVerdict
        if eValue <= eValueThreshold
            && pctIdentity >= verifiedIdentityThreshold
            && coverage >= verifiedCoverageThreshold {
            verdict = .verified
        } else {
            verdict = .ambiguous
        }

        // Build up to 5 hit summaries sorted by best HSP e-value
        let topHits = buildHitSummaries(
            hits: result.hits,
            queryLength: result.queryLength,
            maxCount: 5
        )

        let hasLCADisagreement = BlastTaxonMatching.hasConflictingOrganisms(
            hits: topHits,
            queriedTaxonName: queriedTaxonName,
            context: context
        )

        // Determine whether the top hit lies in the queried clade
        let hitOrganism = topHit.organism ?? topHit.title
        let relation = BlastTaxonMatching.relation(
            hitOrganism: hitOrganism,
            hitTaxId: topHit.taxId,
            queriedTaxonName: queriedTaxonName,
            context: context
        )
        let matchesQueriedTaxon = relation.map { $0 == .clade }
            ?? Self.legacyNameMatchesQueriedTaxon(
                hitOrganism: hitOrganism,
                queriedTaxonName: queriedTaxonName,
                acceptedTaxonNames: context.cladeNames
            )

        return BlastReadResult(
            id: result.queryId,
            verdict: verdict,
            topHitOrganism: hitOrganism,
            topHitAccession: topHit.accession,
            percentIdentity: pctIdentity,
            queryCoverage: coverage,
            eValue: eValue,
            alignmentLength: bestHSP.alignLength,
            bitScore: bestHSP.bitScore,
            topHits: topHits,
            querySequence: sequenceMap[result.queryId],
            hasLCADisagreement: hasLCADisagreement,
            matchesQueriedTaxon: matchesQueriedTaxon,
            submittedMate: sequenceMates[result.queryId],
            topHitRelation: relation
        )
    }

    /// Whether a BLAST top hit supports the queried taxon.
    ///
    /// When the hit reports a tax ID and `acceptedTaxIds` is not empty, the
    /// tax ID rule decides (see ``BlastTaxonMatching/relation(hitOrganism:hitTaxId:queriedTaxonName:context:)``):
    /// the hit supports the taxon only when it lies in the clade. Otherwise
    /// the name rule decides: the organism matches the queried name (see
    /// ``organismMatchesTaxon(hitOrganism:queriedTaxonName:)``) or contains
    /// one of `acceptedTaxonNames`. The alternate names matter because NCBI
    /// renamed many virus species to binomials: Kraken 2 may report
    /// "Simplexvirus humanalpha1" while nt records name the same virus
    /// "Human alphaherpesvirus 1".
    static nonisolated func hitMatchesQueriedTaxon(
        hitOrganism: String,
        hitTaxId: Int?,
        queriedTaxonName: String,
        acceptedTaxIds: Set<Int>,
        acceptedTaxonNames: [String],
        relatedTaxIds: Set<Int> = [],
        relatedTaxonNames: [String] = []
    ) -> Bool {
        let context = BlastTaxonomyContext(
            cladeTaxIds: acceptedTaxIds,
            cladeNames: acceptedTaxonNames,
            relatedTaxIds: relatedTaxIds,
            relatedNames: relatedTaxonNames
        )
        if let relation = BlastTaxonMatching.relation(
            hitOrganism: hitOrganism,
            hitTaxId: hitTaxId,
            queriedTaxonName: queriedTaxonName,
            context: context
        ) {
            return relation == .clade
        }
        return legacyNameMatchesQueriedTaxon(
            hitOrganism: hitOrganism,
            queriedTaxonName: queriedTaxonName,
            acceptedTaxonNames: acceptedTaxonNames
        )
    }

    /// The name rule, used only for hits without a tax ID.
    private static nonisolated func legacyNameMatchesQueriedTaxon(
        hitOrganism: String,
        queriedTaxonName: String,
        acceptedTaxonNames: [String]
    ) -> Bool {
        if organismMatchesTaxon(hitOrganism: hitOrganism, queriedTaxonName: queriedTaxonName) {
            return true
        }
        let hitLower = hitOrganism.lowercased()
        guard !hitLower.isEmpty else { return false }
        return acceptedTaxonNames.contains { name in
            let nameLower = name.lowercased()
            return !nameLower.isEmpty && hitLower.contains(nameLower)
        }
    }

    /// Builds an array of ``BlastHitSummary`` from up to `maxCount` hits.
    ///
    /// Each summary uses the best HSP (first) from its hit for statistics.
    ///
    /// - Parameters:
    ///   - hits: All hits for one query
    ///   - queryLength: Length of the query sequence
    ///   - maxCount: Maximum number of summaries to produce
    /// - Returns: Array of hit summaries sorted by E-value (ascending)
    private nonisolated func buildHitSummaries(
        hits: [BlastHit],
        queryLength: Int,
        maxCount: Int
    ) -> [BlastHitSummary] {
        let limitedHits = hits.prefix(maxCount)
        return limitedHits.enumerated().compactMap { rank, hit in
            guard let bestHSP = hit.hsps.first else { return nil }
            return BlastHitSummary(
                rank: rank + 1,
                accession: hit.accession,
                organism: hit.organism,
                taxId: hit.taxId,
                percentIdentity: bestHSP.percentIdentity,
                queryCoverage: bestHSP.queryCoverage(queryLength: queryLength),
                eValue: bestHSP.evalue,
                bitScore: bestHSP.bitScore,
                alignmentLength: bestHSP.alignLength
            )
        }
    }

    /// The legacy name-only conflict rule: the top hits' organism names start
    /// with more than one distinct first word. Verdicts now use
    /// ``BlastTaxonMatching/hasConflictingOrganisms(hits:queriedTaxonName:context:)``,
    /// which prefers tax IDs and falls back to this rule.
    ///
    /// - Parameter hits: Hit summaries to inspect
    /// - Returns: `true` if multiple first words are present among the hits
    nonisolated func computeGenusDisagreement(hits: [BlastHitSummary]) -> Bool {
        BlastTaxonMatching.legacyGenusDisagreement(hits: hits)
    }

    /// Determines whether a BLAST hit organism matches the queried taxon by name.
    ///
    /// This is the fallback for hits without a tax ID. It uses a two-tier
    /// matching strategy:
    /// 1. **Genus match** (for binomial names): the first word of the hit organism
    ///    matches the first word of the queried taxon (case-insensitive).
    ///    Example: "Escherichia coli K-12" matches queried "Escherichia coli".
    ///    Host-prefixed virus names defeat this rule ("Human alphaherpesvirus 1"
    ///    and "Human gammaherpesvirus 4" share "Human"), which is why hits with
    ///    tax IDs never reach it.
    /// 2. **Containment match** (for virus names that are not binomial): the hit
    ///    organism contains the queried taxon name or vice versa (case-insensitive).
    ///    Example: "Oxbow virus isolate ABC" matches queried "Oxbow virus".
    ///
    /// - Parameters:
    ///   - hitOrganism: The organism name from the BLAST hit.
    ///   - queriedTaxonName: The taxon name from the Kraken2 classification.
    /// - Returns: `true` if the organisms are considered a match.
    static nonisolated func organismMatchesTaxon(
        hitOrganism: String,
        queriedTaxonName: String
    ) -> Bool {
        guard !hitOrganism.isEmpty, !queriedTaxonName.isEmpty else { return false }

        let hitLower = hitOrganism.lowercased()
        let queriedLower = queriedTaxonName.lowercased()

        // Strategy 1: Genus-level match (first word of binomial name)
        let hitGenus = hitLower.split(separator: " ").first.map(String.init) ?? hitLower
        let queriedGenus = queriedLower.split(separator: " ").first.map(String.init) ?? queriedLower

        if hitGenus == queriedGenus && !hitGenus.isEmpty {
            return true
        }

        // Strategy 2: Containment match (handles virus names like "Oxbow virus")
        if hitLower.contains(queriedLower) || queriedLower.contains(hitLower) {
            return true
        }

        return false
    }
}
