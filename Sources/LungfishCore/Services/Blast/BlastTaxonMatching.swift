// BlastTaxonMatching.swift - Taxonomy-ID-first matching of BLAST hits to a queried clade
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Hit Relation

/// How a BLAST hit relates to the taxon the user asked BLAST to check.
public enum BlastHitRelation: String, Sendable, Codable, CaseIterable {
    /// The hit's organism is the queried taxon or one of its descendants.
    case clade
    /// The hit's organism shares the queried taxon's genus but lies outside
    /// the queried clade (for example HSV-2 when HSV-1 was selected).
    case relative
    /// The hit's organism lies outside the queried taxon's genus.
    case outside
}

// MARK: - Taxonomy Context

/// The taxonomy BLAST verdicts are judged against.
///
/// Callers build this from the classifier's taxonomy tree. The clade is the
/// selected taxon plus every descendant in the tree. The related set is the
/// rest of the selected taxon's genus that the tree knows about.
public struct BlastTaxonomyContext: Sendable, Codable, Equatable {

    /// Tax IDs of the queried taxon and its descendants.
    public var cladeTaxIds: Set<Int>

    /// Names of the queried taxon and its descendants.
    public var cladeNames: [String]

    /// Tax IDs in the queried taxon's genus but outside the clade.
    public var relatedTaxIds: Set<Int>

    /// Names in the queried taxon's genus but outside the clade, including
    /// the genus name itself.
    public var relatedNames: [String]

    public init(
        cladeTaxIds: Set<Int> = [],
        cladeNames: [String] = [],
        relatedTaxIds: Set<Int> = [],
        relatedNames: [String] = []
    ) {
        self.cladeTaxIds = cladeTaxIds
        self.cladeNames = cladeNames
        self.relatedTaxIds = relatedTaxIds.subtracting(cladeTaxIds)
        self.relatedNames = relatedNames
    }

    /// Whether the context carries clade tax IDs, which switches matching
    /// from the organism-name rule to the tax ID rule.
    public var hasTaxIds: Bool { !cladeTaxIds.isEmpty }
}

// MARK: - Matching Rules

/// Decides whether BLAST hits support, neighbour, or contradict a queried taxon.
///
/// ## Rule order
///
/// 1. A hit that reports a tax ID is judged by tax ID. A tax ID in the clade
///    is `.clade`, one in the related set is `.relative`.
/// 2. A tax ID the classifier's tree does not contain (NCBI nt often files
///    records under strain-level tax IDs such as 10299, HSV-1 strain 17, that
///    a Kraken 2 report never lists) is judged by name: whole-phrase
///    containment of a clade name makes it `.clade`, a genus name or a
///    sibling in a numbered virus series ("Human alphaherpesvirus 2" beside
///    "Human alphaherpesvirus 1") makes it `.relative`, anything else is
///    `.outside`. The first-word "genus" rule is never used here, because
///    host-prefixed virus names ("Human alphaherpesvirus 1", "Human
///    gammaherpesvirus 4") share a first word without sharing a genus.
/// 3. Only when the hit has no tax ID, or the caller supplied no clade tax
///    IDs, does the legacy name rule apply (first word as genus, or name
///    containment).
public enum BlastTaxonMatching {

    /// The relation of one hit to the queried taxon, or `nil` when the hit
    /// carries no tax ID (or the context has none), so only the legacy name
    /// rule can judge it.
    public static func relation(
        hitOrganism: String?,
        hitTaxId: Int?,
        queriedTaxonName: String,
        context: BlastTaxonomyContext
    ) -> BlastHitRelation? {
        guard context.hasTaxIds, let hitTaxId else { return nil }
        if context.cladeTaxIds.contains(hitTaxId) { return .clade }
        if context.relatedTaxIds.contains(hitTaxId) { return .relative }

        let organism = hitOrganism ?? ""
        let cladeNames = context.cladeNames + [queriedTaxonName]
        if cladeNames.contains(where: { containsPhrase(organism, $0) }) {
            return .clade
        }
        if context.relatedNames.contains(where: { containsPhrase(organism, $0) }) {
            return .relative
        }
        if cladeNames.contains(where: { isNumberedSeriesSibling(organism, of: $0) }) {
            return .relative
        }
        return .outside
    }

    /// Whether a read's top hits name conflicting organisms.
    ///
    /// With tax IDs on every hit, a read conflicts when its hits mix the
    /// queried genus (clade or relatives) with organisms outside it. When no
    /// hit falls in the queried genus, or any hit lacks a tax ID, the legacy
    /// first-word genus comparison decides.
    public static func hasConflictingOrganisms(
        hits: [BlastHitSummary],
        queriedTaxonName: String,
        context: BlastTaxonomyContext
    ) -> Bool {
        let relations = hits.map {
            relation(hitOrganism: $0.organism, hitTaxId: $0.taxId, queriedTaxonName: queriedTaxonName, context: context)
        }
        if !relations.isEmpty, relations.allSatisfy({ $0 != nil }) {
            let inGenus = relations.contains { $0 == .clade || $0 == .relative }
            let outside = relations.contains { $0 == .outside }
            if inGenus { return outside }
        }
        return legacyGenusDisagreement(hits: hits)
    }

    /// The legacy rule: top hits disagree when their organism names start
    /// with more than one distinct first word.
    public static func legacyGenusDisagreement(hits: [BlastHitSummary]) -> Bool {
        let genera = Set(hits.compactMap { $0.organism?.split(separator: " ").first.map(String.init) })
        return genera.count > 1
    }

    // MARK: - Name helpers

    /// Case-insensitive containment of `phrase` in `text` on word boundaries,
    /// so "Human alphaherpesvirus 1" does not match "Human alphaherpesvirus 10".
    static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        let haystack = text.lowercased()
        let needle = phrase.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, !haystack.isEmpty else { return false }
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            let beforeOK = found.lowerBound == haystack.startIndex
                || !isWordCharacter(haystack[haystack.index(before: found.lowerBound)])
            let afterOK = found.upperBound == haystack.endIndex
                || !isWordCharacter(haystack[found.upperBound])
            if beforeOK && afterOK { return true }
            searchRange = haystack.index(after: found.lowerBound)..<haystack.endIndex
        }
        return false
    }

    /// Whether `organism` is another member of a numbered virus series that
    /// `name` belongs to, such as "Human alphaherpesvirus 2" for
    /// "Human alphaherpesvirus 1". Needs at least two stem words, the last
    /// of which names a virus, and a different number.
    static func isNumberedSeriesSibling(_ organism: String, of name: String) -> Bool {
        let nameWords = name.lowercased().split(separator: " ").map(String.init)
        guard nameWords.count >= 3,
              let last = nameWords.last, last.allSatisfy(\.isNumber),
              nameWords[nameWords.count - 2].contains("virus") else { return false }
        let stem = nameWords.dropLast()
        let organismWords = organism.lowercased().split(separator: " ").map(String.init)
        guard organismWords.count > stem.count,
              Array(organismWords.prefix(stem.count)) == Array(stem) else { return false }
        let number = organismWords[stem.count]
        return number.allSatisfy(\.isNumber) && number != last
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
