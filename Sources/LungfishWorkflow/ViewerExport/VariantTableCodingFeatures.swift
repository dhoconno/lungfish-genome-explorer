// VariantTableCodingFeatures.swift - The coding features the variant table resolver reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The coding features the variant table resolver reads, built over values, so the viewer and the table export leaf
/// build one list (Phase 2.12 lane 12.39, ARCH ruling on 12.39 R1 item 5).
package enum VariantTableCodingFeatures {
    /// The coding bases a viewer already read for a CDS, which the resolver otherwise reads itself.
    package typealias Context = (
        codingBases: [Character], codingGenomePositions: [Int], phaseOffset: Int, codonTable: CodonTable,
        codonsBeforeFirstRead: Int
    )

    /// Keep each CDS's gene, product and accession together, including overlapping products.
    package static func label(for cds: SequenceAnnotation) -> String {
        let gene = cds.qualifier("gene") ?? cds.qualifier("gene_name") ?? cds.qualifier("locus_tag")
        let protein = cds.qualifier("product") ?? cds.qualifier("protein_name")
        let accession = cds.qualifier("protein_id") ?? cds.name
        var parts: [String] = []
        for value in [gene, protein, accession] {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value != ".", !parts.contains(value) else { continue }
            parts.append(value)
        }
        return parts.isEmpty ? cds.name : parts.joined(separator: " • ")
    }

    /// One resolver feature for each CDS of `annotations`, in order. A CDS with no chromosome takes
    /// `fallbackChromosome`, `chromosomeName` gives the reference's name for a chromosome, and `context` gives the
    /// coding bases already read for a CDS, or nil.
    package static func features(
        annotations: [SequenceAnnotation],
        fallbackChromosome: String,
        chromosomeName: (String) -> String,
        context: (SequenceAnnotation) -> Context?
    ) -> [VariantTableExportResolverSnapshot.CodingFeature] {
        annotations.compactMap { annotation -> VariantTableExportResolverSnapshot.CodingFeature? in
            guard annotation.type == .cds else { return nil }
            let chromosome = chromosomeName(annotation.chromosome ?? fallbackChromosome)
            let context = context(annotation)
            return VariantTableExportResolverSnapshot.CodingFeature(
                chromosome: chromosome,
                intervals: annotation.intervals,
                label: label(for: annotation),
                isReverse: annotation.strand == .reverse,
                codingBases: context?.codingBases,
                codingGenomePositions: context?.codingGenomePositions,
                phaseOffset: context?.phaseOffset ?? 0,
                codonTable: context?.codonTable ?? TranslationEngine.resolvedCodonTable(for: annotation),
                codonsBeforeFirstRead: context?.codonsBeforeFirstRead ?? 0
            )
        }
    }

    /// The reference's name for each alias its chromosomes declare, the first declaration winning.
    package static func referenceAliases(chromosomes: [ChromosomeInfo]) -> [String: String] {
        var aliases: [String: String] = [:]
        for chromosome in chromosomes {
            for alias in chromosome.aliases where aliases[alias] == nil {
                aliases[alias] = chromosome.name
            }
        }
        return aliases
    }
}
