import Foundation
import LungfishCore

extension SequenceViewerView {
    /// Keep each CDS's gene, product and accession together, including overlapping products.
    static func codingFeatureLabel(for cds: SequenceAnnotation) -> String {
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

    func codingFeatureText(chromosome: String, position: Int, referenceLength: Int) -> String? {
        var labels: [String] = []
        for cds in cachedBundleAnnotations where cds.type == .cds
            && consequenceChromosomeName(cds.chromosome ?? chromosome) == consequenceChromosomeName(chromosome)
            && cds.overlaps(start: position, end: position + max(1, referenceLength)) {
            let label = Self.codingFeatureLabel(for: cds)
            if !labels.contains(label) { labels.append(label) }
        }
        return labels.isEmpty ? nil : labels.joined(separator: "; ")
    }

    func variantTableExportResolverSnapshot() -> VariantTableExportResolverSnapshot {
        let features = cachedBundleAnnotations.compactMap { annotation -> VariantTableExportResolverSnapshot.CodingFeature? in
            guard annotation.type == .cds else { return nil }
            let chromosome = consequenceChromosomeName(
                annotation.chromosome ?? viewController?.referenceFrame?.chromosome ?? ""
            )
            let context = cachedCDSCodingContexts[annotation.id]
            return VariantTableExportResolverSnapshot.CodingFeature(
                chromosome: chromosome,
                intervals: annotation.intervals,
                label: Self.codingFeatureLabel(for: annotation),
                isReverse: annotation.strand == .reverse,
                codingBases: context?.codingBases,
                codingGenomePositions: context?.codingGenomePositions,
                phaseOffset: context?.phaseOffset ?? 0,
                codonTable: context?.codonTable ?? .standard
            )
        }
        var referenceAliases: [String: String] = [:]
        for chromosome in currentReferenceBundle?.manifest.genome?.chromosomes ?? [] {
            for alias in chromosome.aliases where referenceAliases[alias] == nil {
                referenceAliases[alias] = chromosome.name
            }
        }
        return VariantTableExportResolverSnapshot(
            features: features,
            variantChromosomeAliasMap: variantChromosomeAliasMap,
            referenceChromosomeAliases: referenceAliases,
            referenceBundle: currentReferenceBundle,
            cachedSequence: cachedBundleSequence,
            cachedSequenceRegion: cachedSequenceRegion
        )
    }
}

extension AnnotationTableDrawerView {
    func variantCodingFeatureText(for row: AnnotationSearchIndex.SearchResult) -> String {
        if let label = delegate?.annotationDrawer(self, codingFeatureFor: row), !label.isEmpty { return label }
        let info = row.infoDict ?? [:]
        let gene = ["CSQ_SYMBOL", "ANN_Gene_Name", "GENE", "SYMBOL"].compactMap { info[$0] }.first { !$0.isEmpty && $0 != "." }
        let protein = ["protein_name", "product", "protein_id", "CSQ_ENSP"].compactMap { info[$0] }.first { !$0.isEmpty && $0 != "." }
        return [gene, protein].compactMap { $0 }.joined(separator: " • ")
    }
}
