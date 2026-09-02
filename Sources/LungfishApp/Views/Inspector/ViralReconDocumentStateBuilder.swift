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
///
/// NOT YET WIRED INTO THE INSPECTOR. Every Inspector document type needs its
/// own state struct, its own `@Observable` property on
/// `DocumentSectionViewModel`, a `nil` assignment in each of the dozen sibling
/// `update...Document` methods that enforce mutual exclusion, and its own
/// SwiftUI section view. None of that exists for Viral Recon, and inventing it
/// is a larger piece of work than this catalogue. `rows(forBundleAt:)` is the
/// entry point a future Inspector section should call: it reads the ingested
/// bundle's own copies, so it keeps working after the raw nf-core tree is
/// moved or deleted.
enum ViralReconDocumentStateBuilder {
    private enum Section {
        static let consensus = "Consensus"
        static let lineage = "Lineage"
        static let variants = "Variants"
        static let quality = "Quality"
        static let provenance = "Provenance"
    }

    /// Catalogues an ingested Viral Recon analysis directory.
    ///
    /// Reads the bundle's own copies rather than the raw nf-core tree, so the
    /// catalogue still resolves after that tree is moved or cleaned up. Only
    /// files that are actually present produce rows.
    static func rows(
        forBundleAt bundleDirectory: URL,
        fileManager: FileManager = .default
    ) -> [ViralReconDocumentRow] {
        func files(in role: String) -> [URL] {
            let directory = bundleDirectory.appendingPathComponent(role, isDirectory: true)
            let contents = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return contents.filter { !$0.hasDirectoryPath }.sorted { $0.path < $1.path }
        }

        var rows: [ViralReconDocumentRow] = []
        for consensus in files(in: "consensus") {
            rows.append(ViralReconDocumentRow(
                section: Section.consensus,
                label: "Consensus Sequence",
                fileURL: consensus))
        }
        for lineage in files(in: "lineage") {
            rows.append(ViralReconDocumentRow(
                section: Section.lineage,
                label: lineageLabel(for: lineage),
                fileURL: lineage))
        }
        for report in files(in: "reports") {
            rows.append(ViralReconDocumentRow(
                section: Section.quality,
                label: reportLabel(for: report),
                fileURL: report))
        }
        return rows
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
