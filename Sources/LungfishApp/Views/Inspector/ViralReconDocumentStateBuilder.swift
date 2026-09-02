import Foundation
import LungfishWorkflow

/// One catalogued Viral Recon output.
struct ViralReconDocumentRow: Equatable {
    let section: String
    let label: String
    let fileURL: URL
}

/// Catalogues the outputs of a Viral Recon run by scientific role.
///
/// The run produces many files and a flat file tree says nothing about what
/// they mean. Grouping by role answers the question a user actually has, which
/// is what was measured, not which directory the pipeline chose.
///
/// Only files that exist produce rows. An empty section heading would imply an
/// output was produced when it was not.
enum ViralReconDocumentStateBuilder {
    private enum Section {
        static let consensus = "Consensus"
        static let lineage = "Lineage"
        static let variants = "Variants"
        static let quality = "Quality"
        static let provenance = "Provenance"
    }

    static func rows(for inventory: ViralReconResultInventory) -> [ViralReconDocumentRow] {
        var rows: [ViralReconDocumentRow] = []

        if let consensus = inventory.consensusFASTA {
            rows.append(ViralReconDocumentRow(
                section: Section.consensus,
                label: "Consensus Sequence",
                fileURL: consensus))
        }

        for lineage in inventory.lineageFiles {
            rows.append(ViralReconDocumentRow(
                section: Section.lineage,
                label: lineageLabel(for: lineage),
                fileURL: lineage))
        }

        if let vcf = inventory.variantVCF {
            rows.append(ViralReconDocumentRow(
                section: Section.variants,
                label: "Variant Calls",
                fileURL: vcf))
        }

        for report in inventory.reportFiles {
            rows.append(ViralReconDocumentRow(
                section: Section.quality,
                label: reportLabel(for: report),
                fileURL: report))
        }

        // The alignment is the evidence the other outputs were derived from, so
        // it is catalogued as provenance rather than as a result in its own
        // right. It is already viewable as a track.
        if let bam = inventory.sortedBAM {
            rows.append(ViralReconDocumentRow(
                section: Section.provenance,
                label: "Sorted Alignment",
                fileURL: bam))
        }
        if let bai = inventory.bamIndex {
            rows.append(ViralReconDocumentRow(
                section: Section.provenance,
                label: "Alignment Index",
                fileURL: bai))
        }

        return rows
    }

    private static func lineageLabel(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.contains("pangolin") { return "Pangolin Lineage" }
        if name.contains("nextclade") { return "Nextclade Clade" }
        if name.contains("demix") || name.contains("freyja") { return "Freyja Abundances" }
        return url.lastPathComponent
    }

    private static func reportLabel(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.contains("multiqc") { return "MultiQC Report" }
        if name.contains("fastp") { return "fastp Report" }
        if name.contains("fastqc") { return "FastQC Report" }
        return url.lastPathComponent
    }
}
