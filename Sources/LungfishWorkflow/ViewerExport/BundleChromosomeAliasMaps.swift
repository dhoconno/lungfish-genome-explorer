// BundleChromosomeAliasMaps.swift - Chromosome alias groups, built on the first lookup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The chromosome alias groups `AnnotationSearchIndex` uses to find annotation and
/// variant rows filed under another spelling of a bundle's chromosome name, such as
/// `NC_041760.1` and `7`, in either direction.
///
/// The groups are built on the first lookup that reads them, and never for a bundle
/// without annotation or variant tracks, whose lookups never read them. Building them
/// whenever a bundle opened cost a reference with 905,628 sequences 5.5 seconds and
/// 1,264 MB.
package struct BundleChromosomeAliasMaps {

    /// Alias groups keyed by exact lowercase token.
    package private(set) var byExactToken: [String: Set<String>] = [:]

    /// Alias groups keyed by canonical chromosome token.
    package private(set) var byCanonicalToken: [String: Set<String>] = [:]

    /// How many times the groups were built. Tests read it.
    package private(set) var buildCount = 0

    /// The chromosomes the next lookup groups, `nil` when there is nothing to build.
    private var pendingChromosomes: [ChromosomeInfo]?

    package init() {}

    /// Drops the groups. The next lookup builds them from `chromosomes`, and `nil`
    /// leaves them empty.
    package mutating func reset(chromosomes: [ChromosomeInfo]?) {
        byExactToken = [:]
        byCanonicalToken = [:]
        pendingChromosomes = chromosomes
    }

    /// Builds the groups on the first lookup after ``reset(chromosomes:)``. Each
    /// chromosome's name and aliases, with their common spellings, form one group
    /// that every member token finds.
    package mutating func prepare() {
        guard let chromosomes = pendingChromosomes else { return }
        pendingChromosomes = nil
        buildCount += 1
        for chromosome in chromosomes {
            var group = Set<String>()
            group.insert(chromosome.name)
            group.formUnion(chromosome.aliases)

            // Expand common representation variants for each alias token.
            let expanded = group.flatMap { Self.aliasExpansions(for: $0) }
            group.formUnion(expanded)

            for token in group {
                let lower = token.lowercased()
                byExactToken[lower, default: []].formUnion(group)
                let canonical = canonicalVariantChromosomeLookupKey(token)
                byCanonicalToken[canonical, default: []].formUnion(group)
            }
        }
    }

    /// Generates simple equivalent alias forms:
    /// - with/without `chr` prefix
    /// - with/without dotted version suffix
    private static func aliasExpansions(for token: String) -> [String] {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results = Set<String>()
        results.insert(trimmed)

        let lower = trimmed.lowercased()
        if lower.hasPrefix("chr") {
            results.insert(String(trimmed.dropFirst(3)))
        } else {
            results.insert("chr\(trimmed)")
        }

        if let dot = trimmed.firstIndex(of: ".") {
            let withoutVersion = String(trimmed[..<dot])
            results.insert(withoutVersion)
            if withoutVersion.lowercased().hasPrefix("chr") {
                results.insert(String(withoutVersion.dropFirst(3)))
            } else {
                results.insert("chr\(withoutVersion)")
            }
        }

        return Array(results)
    }
}
