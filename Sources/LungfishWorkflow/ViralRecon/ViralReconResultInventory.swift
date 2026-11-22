import Foundation

/// An output the run's params say a sample should have, which its result does not hold, and what the run's own
/// evidence says about it (VR-INVENTORY). The raw values are the `absentOutputs` of `viralrecon-result.json`.
public enum ViralReconAbsentOutput: String, Sendable, Equatable, CaseIterable {
    /// The caller never reached the sample, so viralrecon dropped it for too few reads after trimming or mapping
    /// (`ViralReconRunOutcome.failedSamples`), and the sample has no output at all.
    case sampleFailed
    /// The caller reached the sample and found no variants, so viralrecon wrote no VCF
    /// (`subworkflows/local/variants_ivar/main.nf:43`, `variants_bcftools/main.nf:40`). With a BCFtools consensus,
    /// which reads that VCF (`workflows/viralrecon.nf:549-551`), it made no consensus or lineage tables either.
    case noVariantsNoConsensus
    /// The caller reached the sample and found no variants, so viralrecon wrote no VCF. The consensus does not read
    /// the VCF (an iVar consensus from the alignment, `workflows/viralrecon.nf:532-533`), or the run makes none.
    case noVariants
    /// The caller reached the sample, and its VCF is not where the run's params put it.
    case variantsNotWritten
    case consensusNotWritten
    case pangolinNotWritten
    case nextcladeNotWritten
    case freyjaNotWritten
}

/// The outputs of one sample in a Viral Recon results directory.
///
/// Every field is optional because a pipeline can complete with a step skipped
/// or failed. A missing output is a reduced result, not a fatal condition, and
/// `absentOutputs` names each one the run's params lead a reader to expect.
public struct ViralReconResultInventory: Sendable, Equatable {
    public let sampleName: String
    public let sortedBAM: URL?
    public let bamIndex: URL?
    public let variantVCF: URL?
    public let consensusFASTA: URL?
    public let lineageFiles: [URL]
    public let reportFiles: [URL]
    public let absentOutputs: [ViralReconAbsentOutput]

    public init(
        sampleName: String,
        sortedBAM: URL?,
        bamIndex: URL?,
        variantVCF: URL?,
        consensusFASTA: URL?,
        lineageFiles: [URL],
        reportFiles: [URL],
        absentOutputs: [ViralReconAbsentOutput] = []
    ) {
        self.sampleName = sampleName
        self.sortedBAM = sortedBAM
        self.bamIndex = bamIndex
        self.variantVCF = variantVCF
        self.consensusFASTA = consensusFASTA
        self.lineageFiles = lineageFiles
        self.reportFiles = reportFiles
        self.absentOutputs = absentOutputs
    }

    /// The sample's outputs, from the folders `params` (the run's effective params) send them to. The default is the
    /// run a new wizard starts.
    public static func discover(
        in resultsDirectory: URL,
        sampleName: String,
        params: [String: String] = ViralReconOutputLayout.defaultRunParams
    ) -> ViralReconResultInventory {
        let layout = ViralReconOutputLayout(params: params)
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
        let vcf = layout.variantFile(forSample: sampleName).flatMap(existing)
        let consensus = layout.consensusFile(forSample: sampleName).flatMap(existing)

        // The lineage folders hold one table per sample of the whole batch
        // (`<sample>.pangolin.csv`, Nextclade's bare `<sample>.csv`, Freyja's
        // bare `<sample>.tsv`), so only the table named for this sample is
        // taken. Copying the folders wholesale gave every sample every
        // sample's tables, and a match on the prefix `<sample>.` gave `S1`
        // the tables of `S1.1`.
        var lineage: [URL] = []
        var lineageTaken: Set<ViralReconLineageTool> = []
        for tool in ViralReconLineageTool.allCases {
            guard let folder = layout.lineageFolder(tool) else { continue }
            let relative = "\(folder)/\(tool.tableFileName(forSample: sampleName))"
            var isDirectory: ObjCBool = false
            let url = resultsDirectory.appendingPathComponent(relative)
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                lineage.append(url)
                lineageTaken.insert(tool)
            }
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
            reportFiles: reports,
            absentOutputs: absentOutputs(
                layout: layout, sampleName: sampleName, resultsDirectory: resultsDirectory, params: params,
                hasVCF: vcf != nil, hasConsensus: consensus != nil, lineageTaken: lineageTaken))
    }

    /// The outputs `layout` leads a reader to expect for the sample that the results do not hold. A missing VCF is
    /// read against the run's own evidence first (`ViralReconRunOutcome.failedSamples`): a sample the caller never
    /// reached failed, and one it reached with no variants has no VCF by design.
    private static func absentOutputs(
        layout: ViralReconOutputLayout,
        sampleName: String,
        resultsDirectory: URL,
        params: [String: String],
        hasVCF: Bool,
        hasConsensus: Bool,
        lineageTaken: Set<ViralReconLineageTool>
    ) -> [ViralReconAbsentOutput] {
        guard layout.variantCaller != nil else { return [] }
        var absent: [ViralReconAbsentOutput] = []
        if !hasVCF {
            let trace = NextflowTraceTask.newestTrace(
                in: resultsDirectory.appendingPathComponent("pipeline_info", isDirectory: true),
                writtenSince: .distantPast
            ).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            let failed = ViralReconRunOutcome.failedSamples(
                [sampleName], resultsDirectory: resultsDirectory, params: params, traceText: trace)
            if !failed.isEmpty { return [.sampleFailed] }
            if layout.isNanopore {
                absent.append(.variantsNotWritten)
            } else if layout.consensusCaller == "bcftools" {
                return [.noVariantsNoConsensus]
            } else {
                absent.append(.noVariants)
            }
        }
        if layout.consensusCaller != nil, !hasConsensus {
            absent.append(.consensusNotWritten)
        }
        for tool in layout.lineageTools where !lineageTaken.contains(tool) {
            switch tool {
            case .pangolin: absent.append(.pangolinNotWritten)
            case .nextclade: absent.append(.nextcladeNotWritten)
            case .freyja: absent.append(.freyjaNotWritten)
            }
        }
        return absent
    }
}
