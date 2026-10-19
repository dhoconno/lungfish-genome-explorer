import Foundation
import LungfishCore
import LungfishIO
import LungfishOperations
import LungfishWorkflow

extension SequenceViewerView {
    /// Keep each CDS's gene, product and accession together, including overlapping products.
    static func codingFeatureLabel(for cds: SequenceAnnotation) -> String {
        VariantTableCodingFeatures.label(for: cds)
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
        let contexts = cachedCDSCodingContexts
        let features = VariantTableCodingFeatures.features(
            annotations: cachedBundleAnnotations,
            fallbackChromosome: viewController?.referenceFrame?.chromosome ?? "",
            chromosomeName: { self.consequenceChromosomeName($0) },
            context: { annotation in
                contexts[annotation.id].map {
                    ($0.codingBases, $0.codingGenomePositions, $0.phaseOffset, $0.codonTable, $0.codonsBeforeFirstRead)
                }
            }
        )
        var snapshot = VariantTableExportResolverSnapshot(
            features: features,
            variantChromosomeAliasMap: variantChromosomeAliasMap,
            referenceChromosomeAliases: VariantTableCodingFeatures.referenceAliases(
                chromosomes: currentReferenceBundle?.manifest.genome?.chromosomes ?? []
            ),
            referenceBundle: currentReferenceBundle,
            cachedSequence: cachedBundleSequence,
            cachedSequenceRegion: cachedSequenceRegion
        )
        snapshot.codingFeatureTrackIDs = Set(
            cachedBundleAnnotations.compactMap { $0.qualifier("annotation_db_track_id") }
        ).sorted()
        let trackIDs = snapshot.codingFeatureTrackIDs
        snapshot.codingFeatureRegion = cachedAnnotationRegion.map {
            AnnotationTableFeatureRegion(chromosome: $0.chromosome, start: $0.start, end: $0.end, trackIDs: trackIDs)
        }
        return snapshot
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
