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

        let bam = existing("variants/bowtie2/\(sampleName).sorted.bam")
        let bai = existing("variants/bowtie2/\(sampleName).sorted.bam.bai")
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
        for relative in ["multiqc/multiqc_report.html", "fastp/\(sampleName).fastp.html"] {
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
