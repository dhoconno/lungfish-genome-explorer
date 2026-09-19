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
