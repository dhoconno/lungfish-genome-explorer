import Foundation

/// The outputs of one sample in a Viral Recon results directory.
///
/// Every field is optional because a pipeline can complete with a step skipped
/// or failed. A missing output is a reduced result, not a fatal condition.
public struct ViralReconResultInventory: Sendable, Equatable {
    public let sampleName: String
    public let sortedBAM: URL?
    public let bamIndex: URL?
    public let variantVCF: URL?
    public let consensusFASTA: URL?
    public let lineageFiles: [URL]
    public let reportFiles: [URL]

    public init(
        sampleName: String,
        sortedBAM: URL?,
        bamIndex: URL?,
        variantVCF: URL?,
        consensusFASTA: URL?,
        lineageFiles: [URL],
        reportFiles: [URL]
    ) {
        self.sampleName = sampleName
        self.sortedBAM = sortedBAM
        self.bamIndex = bamIndex
        self.variantVCF = variantVCF
        self.consensusFASTA = consensusFASTA
        self.lineageFiles = lineageFiles
        self.reportFiles = reportFiles
    }

    public static func discover(in resultsDirectory: URL, sampleName: String) -> ViralReconResultInventory {
        let fileManager = FileManager.default
        func existing(_ relative: String) -> URL? {
            let url = resultsDirectory.appendingPathComponent(relative)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }

        // An amplicon run trims primers, and the trimmed alignment is the one
        // the variant caller used. Publishing the untrimmed BAM beside those
        // calls puts the two views in silent disagreement: primer-derived
        // sequence survives at amplicon ends and reads as low-frequency
        // variation that iVar trim exists to remove. Metagenomic runs never
        // produce the trimmed file, so the plain alignment stands.
        let trimmedBAM = existing("variants/bowtie2/\(sampleName).ivar_trim.sorted.bam")
        let bam = trimmedBAM ?? existing("variants/bowtie2/\(sampleName).sorted.bam")
        let bai = bam.flatMap { alignment in
            existing("variants/bowtie2/\(alignment.lastPathComponent).bai")
        }
        let vcf = existing("variants/ivar/\(sampleName).vcf.gz")
        let consensusRoot = "variants/ivar/consensus/bcftools"
        let consensus = existing("\(consensusRoot)/\(sampleName).consensus.fa")

        var lineage: [URL] = []
        for relative in ["\(consensusRoot)/pangolin", "\(consensusRoot)/nextclade", "variants/freyja/demix"] {
            let directory = resultsDirectory.appendingPathComponent(relative, isDirectory: true)
            let contents = (try? fileManager.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: nil)) ?? []
            lineage.append(contentsOf: contents.filter { !$0.hasDirectoryPath })
        }

        var reports: [URL] = []
        // Per-amplicon coverage is what distinguishes "no variants here" from
        // "no data here". Amplicon dropout produces no variant records at all,
        // so without it the variant track looks cleanest exactly where the
        // sequencing failed. The QC summary is the single per-sample row that
        // says whether the run is trustworthy at all.
        for relative in ["multiqc/multiqc_report.html",
                         "multiqc/summary_variants_metrics_mqc.csv",
                         "fastp/\(sampleName).fastp.html",
                         "variants/bowtie2/mosdepth/amplicon/\(sampleName).mosdepth.coverage.tsv",
                         "variants/bowtie2/mosdepth/genome/\(sampleName).mosdepth.coverage.tsv"] {
            if let url = existing(relative) { reports.append(url) }
        }

        return ViralReconResultInventory(
            sampleName: sampleName,
            sortedBAM: bam,
            bamIndex: bai,
            variantVCF: vcf,
            consensusFASTA: consensus,
            lineageFiles: lineage.sorted { $0.path < $1.path },
            reportFiles: reports)
    }
}
