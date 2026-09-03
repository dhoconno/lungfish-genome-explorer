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

    /// Section order as presented, most interpreted result first.
    ///
    /// A user opening a finished run wants the answer (which lineage, what
    /// sequence) before the evidence (coverage, alignment), so the ordering is
    /// fixed here rather than left to whatever order files were discovered in.
    private static let sectionOrder = [
        Section.consensus,
        Section.lineage,
        Section.variants,
        Section.quality,
        Section.provenance,
    ]

    /// Builds the Inspector document for an ingested Viral Recon analysis.
    ///
    /// Returns nil when the bundle holds no outputs at all, so the Inspector
    /// falls through to the reference bundle's own metadata instead of showing
    /// a heading over nothing.
    static func state(
        forBundleAt bundleDirectory: URL,
        sampleName: String,
        fileManager: FileManager = .default
    ) -> ViralReconDocumentState? {
        let rows = rows(forBundleAt: bundleDirectory, fileManager: fileManager)
        guard !rows.isEmpty else { return nil }

        let sections = sectionOrder.compactMap { title -> ViralReconDocumentFileSection? in
            let matching = rows.filter { $0.section == title }
            guard !matching.isEmpty else { return nil }
            return ViralReconDocumentFileSection(
                title: title,
                rows: matching.map {
                    ViralReconDocumentFileRow(
                        label: $0.label,
                        detail: detail(for: $0.label),
                        fileURL: $0.fileURL)
                })
        }

        return ViralReconDocumentState(
            title: sampleName,
            subtitle: "Viral Recon • \(rows.count) output\(rows.count == 1 ? "" : "s")",
            sections: sections)
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
        if name.contains("demix") || name.contains("freyja") { return "Freyja Variant Mix" }
        return url.lastPathComponent
    }

    private static func reportLabel(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        // Checked before the generic MultiQC match: the metrics CSV is also
        // written by MultiQC but answers a different question, and labelling it
        // "Full Run Report" would give two rows the same name.
        if name.contains("summary_variants_metrics") { return "Run Quality Summary" }
        if name.contains("mosdepth") { return coverageLabel(for: url) }
        if name.contains("multiqc") { return "Full Run Report" }
        if name.contains("fastp") { return "Read Trimming Report" }
        if name.contains("fastqc") { return "Read Quality Report" }
        return url.lastPathComponent
    }

    /// Distinguishes the two mosdepth tables, which share a filename shape and
    /// differ only by the directory the pipeline wrote them to.
    private static func coverageLabel(for url: URL) -> String {
        let path = url.deletingLastPathComponent().path.lowercased()
        if path.contains("amplicon") { return "Coverage Depth by Amplicon" }
        if path.contains("genome") { return "Coverage Depth Across Genome" }
        return "Coverage Depth Table"
    }

    /// Plain-language explanation of what a row's file answers.
    ///
    /// Keyed off the label rather than the filename so the two stay in step: a
    /// label with no explanation here fails the Inspector's own test.
    private static func detail(for label: String) -> String {
        switch label {
        case "Consensus Sequence":
            return "The assembled genome sequence for this sample, ready to submit or align."
        case "Pangolin Lineage":
            return "The SARS-CoV-2 lineage assignment, with the confidence Pangolin reported."
        case "Nextclade Clade":
            return "An independent clade assignment plus per-sample quality flags."
        case "Freyja Variant Mix":
            return "The estimated mixture of variants in this sample, for pooled or wastewater material."
        case "Variant Calls":
            return "Every position where this sample differs from the reference genome."
        case "Run Quality Summary":
            return "One row per sample summarising read counts, coverage and variant totals."
        case "Coverage Depth by Amplicon":
            return "Read depth for each amplicon. Low values mark dropout, where absent variants mean no data rather than no change."
        case "Coverage Depth Across Genome":
            return "Read depth along the genome, showing which regions were sequenced well enough to trust."
        case "Coverage Depth Table":
            return "Read depth for this sample, showing which regions were sequenced well enough to trust."
        case "Full Run Report":
            return "The combined quality report for every step of the run. Opens in a browser."
        case "Read Trimming Report":
            return "How many reads survived quality and adapter trimming. Opens in a browser."
        case "Read Quality Report":
            return "Per-base quality of the raw reads before trimming. Opens in a browser."
        case "Sorted Alignment":
            return "The read alignment the consensus and variants were derived from."
        case "Alignment Index":
            return "The companion index that lets the alignment be read by position."
        default:
            // An unrecognised file still gets a row: withholding it would hide
            // an output the run genuinely produced.
            return "An additional file produced by this run."
        }
    }
}
