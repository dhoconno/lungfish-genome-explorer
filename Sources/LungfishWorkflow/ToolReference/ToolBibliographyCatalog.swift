import Foundation

public struct ToolCitation: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let aliases: [String]
    public let citation: String
    public let doi: String?
    public let url: String?

    public init(
        id: String,
        displayName: String,
        aliases: [String],
        citation: String,
        doi: String? = nil,
        url: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
        self.citation = citation
        self.doi = doi
        self.url = url
    }
}

public struct ProvenanceBibliographyResult: Codable, Equatable, Sendable {
    public struct UnmatchedTool: Codable, Equatable, Hashable, Sendable {
        public let toolName: String
        public let toolVersion: String

        public init(toolName: String, toolVersion: String) {
            self.toolName = toolName
            self.toolVersion = toolVersion
        }
    }

    public let citations: [ToolCitation]
    public let unmatchedTools: [UnmatchedTool]

    public init(citations: [ToolCitation], unmatchedTools: [UnmatchedTool]) {
        self.citations = citations
        self.unmatchedTools = unmatchedTools
    }
}

public enum ToolBibliographyCatalog {
    public static let citations: [ToolCitation] = [
        ToolCitation(
            id: "bedtools",
            displayName: "BEDTools",
            aliases: ["bedtools", "bedtools intersect", "bedtools getfasta"],
            citation: "Quinlan AR, Hall IM. BEDTools: a flexible suite of utilities for comparing genomic features. Bioinformatics. 2010.",
            doi: "10.1093/bioinformatics/btq033",
            url: "https://bedtools.readthedocs.io/"
        ),
        ToolCitation(
            id: "bbtools",
            displayName: "BBTools",
            aliases: ["bbtools", "bbmap", "reformat.sh", "bbduk"],
            citation: "Bushnell B. BBTools software package. Joint Genome Institute.",
            url: "https://sourceforge.net/projects/bbmap/"
        ),
        ToolCitation(
            id: "bowtie2",
            displayName: "Bowtie 2",
            aliases: ["bowtie2", "bowtie 2"],
            citation: "Langmead B, Salzberg SL. Fast gapped-read alignment with Bowtie 2. Nature Methods. 2012.",
            doi: "10.1038/nmeth.1923",
            url: "https://bowtie-bio.sourceforge.net/bowtie2/"
        ),
        ToolCitation(
            id: "bwa",
            displayName: "BWA",
            aliases: ["bwa", "bwa-mem", "bwa-mem2", "bwamem2"],
            citation: "Li H, Durbin R. Fast and accurate short read alignment with Burrows-Wheeler transform. Bioinformatics. 2009.",
            doi: "10.1093/bioinformatics/btp324",
            url: "https://github.com/lh3/bwa"
        ),
        ToolCitation(
            id: "bcftools",
            displayName: "BCFtools",
            aliases: ["bcftools"],
            citation: "Danecek P, Bonfield JK, Liddle J, et al. Twelve years of SAMtools and BCFtools. GigaScience. 2021.",
            doi: "10.1093/gigascience/giab008",
            url: "https://www.htslib.org/"
        ),
        ToolCitation(
            id: "cutadapt",
            displayName: "Cutadapt",
            aliases: ["cutadapt"],
            citation: "Martin M. Cutadapt removes adapter sequences from high-throughput sequencing reads. EMBnet.journal. 2011.",
            doi: "10.14806/ej.17.1.200",
            url: "https://cutadapt.readthedocs.io/"
        ),
        ToolCitation(
            id: "deacon",
            displayName: "Deacon",
            aliases: ["deacon"],
            citation: "Deacon host-depletion toolkit.",
            url: "https://github.com/bede/deacon"
        ),
        ToolCitation(
            id: "fastp",
            displayName: "fastp",
            aliases: ["fastp"],
            citation: "Chen S, Zhou Y, Chen Y, Gu J. fastp: an ultra-fast all-in-one FASTQ preprocessor. Bioinformatics. 2018.",
            doi: "10.1093/bioinformatics/bty560",
            url: "https://github.com/OpenGene/fastp"
        ),
        ToolCitation(
            id: "htslib",
            displayName: "HTSlib",
            aliases: ["htslib", "tabix", "bgzip"],
            citation: "Danecek P, Bonfield JK, Liddle J, et al. Twelve years of SAMtools and BCFtools. GigaScience. 2021.",
            doi: "10.1093/gigascience/giab008",
            url: "https://www.htslib.org/"
        ),
        ToolCitation(
            id: "iqtree",
            displayName: "IQ-TREE",
            aliases: ["iqtree", "iq-tree", "iqtree2", "iq-tree2"],
            citation: "Nguyen LT, Schmidt HA, von Haeseler A, Minh BQ. IQ-TREE: a fast and effective stochastic algorithm for estimating maximum-likelihood phylogenies. Molecular Biology and Evolution. 2015.",
            doi: "10.1093/molbev/msu300",
            url: "https://iqtree.github.io/"
        ),
        ToolCitation(
            id: "ivar",
            displayName: "iVar",
            aliases: ["ivar", "ivar trim", "ivar variants", "ivar consensus"],
            citation: "Grubaugh ND, Gangavarapu K, Quick J, et al. An amplicon-based sequencing framework for accurately measuring intrahost virus diversity using PrimalSeq and iVar. Genome Biology. 2019.",
            doi: "10.1186/s13059-018-1618-7",
            url: "https://andersen-lab.github.io/ivar/html/"
        ),
        ToolCitation(
            id: "kraken2",
            displayName: "Kraken 2",
            aliases: ["kraken2", "kraken 2"],
            citation: "Wood DE, Lu J, Langmead B. Improved metagenomic analysis with Kraken 2. Genome Biology. 2019.",
            doi: "10.1186/s13059-019-1891-0",
            url: "https://github.com/DerrickWood/kraken2"
        ),
        ToolCitation(
            id: "lofreq",
            displayName: "LoFreq",
            aliases: ["lofreq", "lofreq2"],
            citation: "Wilm A, Aw PPK, Bertrand D, et al. LoFreq: a sequence-quality aware, ultra-sensitive variant caller. Nucleic Acids Research. 2012.",
            doi: "10.1093/nar/gks918",
            url: "https://csb5.github.io/lofreq/"
        ),
        ToolCitation(
            id: "mafft",
            displayName: "MAFFT",
            aliases: ["mafft"],
            citation: "Katoh K, Misawa K, Kuma K, Miyata T. MAFFT: a novel method for rapid multiple sequence alignment based on fast Fourier transform. Nucleic Acids Research. 2002.",
            doi: "10.1093/nar/gkf436",
            url: "https://mafft.cbrc.jp/alignment/software/"
        ),
        ToolCitation(
            id: "medaka",
            displayName: "Medaka",
            aliases: ["medaka", "medaka consensus", "medaka variant"],
            citation: "Oxford Nanopore Technologies. Medaka sequence correction and consensus toolkit.",
            url: "https://github.com/nanoporetech/medaka"
        ),
        ToolCitation(
            id: "micromamba",
            displayName: "micromamba",
            aliases: ["micromamba", "mamba", "libmamba"],
            citation: "Mamba and micromamba package managers.",
            url: "https://mamba.readthedocs.io/"
        ),
        ToolCitation(
            id: "minimap2",
            displayName: "minimap2",
            aliases: ["minimap2", "minimap"],
            citation: "Li H. Minimap2: pairwise alignment for nucleotide sequences. Bioinformatics. 2018.",
            doi: "10.1093/bioinformatics/bty191",
            url: "https://github.com/lh3/minimap2"
        ),
        ToolCitation(
            id: "multiqc",
            displayName: "MultiQC",
            aliases: ["multiqc", "multi qc"],
            citation: "Ewels P, Magnusson M, Lundin S, Kaller M. MultiQC: summarize analysis results for multiple tools and samples in a single report. Bioinformatics. 2016.",
            doi: "10.1093/bioinformatics/btw354",
            url: "https://multiqc.info/"
        ),
        ToolCitation(
            id: "nextclade",
            displayName: "Nextclade",
            aliases: ["nextclade"],
            citation: "Aksamentov I, Roemer C, Hodcroft EB, Neher RA. Nextclade: clade assignment, mutation calling and quality control for viral genomes. Journal of Open Source Software. 2021.",
            doi: "10.21105/joss.03773",
            url: "https://docs.nextstrain.org/projects/nextclade/"
        ),
        ToolCitation(
            id: "nextflow",
            displayName: "Nextflow",
            aliases: ["nextflow", "nf-core"],
            citation: "Di Tommaso P, Chatzou M, Floden EW, et al. Nextflow enables reproducible computational workflows. Nature Biotechnology. 2017.",
            doi: "10.1038/nbt.3820",
            url: "https://www.nextflow.io/"
        ),
        ToolCitation(
            id: "pangolin",
            displayName: "Pangolin",
            aliases: ["pangolin", "pango lineage", "pango"],
            citation: "O'Toole A, Scher E, Underwood A, et al. Assignment of epidemiological lineages in an emerging pandemic using the pangolin tool. Virus Evolution. 2021.",
            doi: "10.1093/ve/veab064",
            url: "https://github.com/cov-lineages/pangolin"
        ),
        ToolCitation(
            id: "pigz",
            displayName: "pigz",
            aliases: ["pigz", "unpigz"],
            citation: "Adler M. pigz: a parallel implementation of gzip.",
            url: "https://zlib.net/pigz/"
        ),
        ToolCitation(
            id: "samtools",
            displayName: "SAMtools",
            aliases: ["samtools"],
            citation: "Danecek P, Bonfield JK, Liddle J, et al. Twelve years of SAMtools and BCFtools. GigaScience. 2021.",
            doi: "10.1093/gigascience/giab008",
            url: "https://www.htslib.org/"
        ),
        ToolCitation(
            id: "seqkit",
            displayName: "SeqKit",
            aliases: ["seqkit"],
            citation: "Shen W, Le S, Li Y, Hu F. SeqKit: a cross-platform and ultrafast toolkit for FASTA/Q file manipulation. PLOS ONE. 2016.",
            doi: "10.1371/journal.pone.0163962",
            url: "https://bioinf.shenwei.me/seqkit/"
        ),
        ToolCitation(
            id: "snakemake",
            displayName: "Snakemake",
            aliases: ["snakemake"],
            citation: "Moelder F, Jablonski KP, Letcher B, et al. Sustainable data analysis with Snakemake. F1000Research. 2021.",
            doi: "10.12688/f1000research.29032.2",
            url: "https://snakemake.github.io/"
        ),
        ToolCitation(
            id: "sra-tools",
            displayName: "SRA Tools",
            aliases: ["sra-tools", "fasterq-dump", "prefetch", "sra toolkit"],
            citation: "NCBI Sequence Read Archive Toolkit.",
            url: "https://github.com/ncbi/sra-tools"
        ),
        ToolCitation(
            id: "ucsc-bigbed-bigwig",
            displayName: "UCSC bigWig tools",
            aliases: ["ucsc-bedgraphtobigwig", "bedgraphtobigwig", "bigwig"],
            citation: "Kent WJ, Zweig AS, Barber G, Hinrichs AS, Karolchik D. BigWig and BigBed: enabling browsing of large distributed datasets. Bioinformatics. 2010.",
            doi: "10.1093/bioinformatics/btq351",
            url: "https://genome.ucsc.edu/goldenPath/help/bigBed.html"
        ),
        ToolCitation(
            id: "viralrecon",
            displayName: "nf-core/viralrecon",
            aliases: ["nf-core/viralrecon", "viralrecon", "viral recon"],
            citation: "Patel H, Varona S, Monzon S, et al. nf-core/viralrecon: assembly and intrahost/low-frequency variant calling for viral samples.",
            doi: "10.5281/zenodo.3901628",
            url: "https://github.com/nf-core/viralrecon"
        ),
        ToolCitation(
            id: "vsearch",
            displayName: "VSEARCH",
            aliases: ["vsearch"],
            citation: "Rognes T, Flouri T, Nichols B, Quince C, Mahe F. VSEARCH: a versatile open source tool for metagenomics. PeerJ. 2016.",
            doi: "10.7717/peerj.2584",
            url: "https://github.com/torognes/vsearch"
        ),
    ]

    public static func bibliography(for run: WorkflowRun) -> ProvenanceBibliographyResult {
        var matched: [String: ToolCitation] = [:]
        var unmatched = Set<ProvenanceBibliographyResult.UnmatchedTool>()

        for step in run.steps {
            if let citation = citation(for: step.toolName) {
                matched[citation.id] = citation
            } else {
                unmatched.insert(
                    ProvenanceBibliographyResult.UnmatchedTool(
                        toolName: step.toolName,
                        toolVersion: step.toolVersion
                    )
                )
            }
        }

        return ProvenanceBibliographyResult(
            citations: matched.values.sorted(by: compareCitations),
            unmatchedTools: unmatched.sorted(by: compareUnmatchedTools)
        )
    }

    public static func citation(for toolName: String) -> ToolCitation? {
        let query = normalized(toolName)
        guard !query.isEmpty else { return nil }

        let scored = citations.compactMap { citation -> (ToolCitation, Int)? in
            guard let score = matchScore(citation: citation, query: query) else { return nil }
            return (citation, score)
        }

        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return compareCitations(lhs.0, rhs.0)
        }.first?.0
    }

    private static func matchScore(citation: ToolCitation, query: String) -> Int? {
        let aliases = ([citation.id, citation.displayName] + citation.aliases).map(normalized)

        if aliases.contains(query) {
            return 0
        }

        for alias in aliases where !alias.isEmpty {
            if query.contains(alias) || alias.contains(query) {
                return 1
            }
        }

        let queryTokens = Set(query.split(separator: " ").map(String.init))
        for alias in aliases {
            let aliasTokens = Set(alias.split(separator: " ").map(String.init))
            if !queryTokens.isDisjoint(with: aliasTokens) {
                return 2
            }
        }

        return nil
    }

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func compareCitations(_ lhs: ToolCitation, _ rhs: ToolCitation) -> Bool {
        let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private static func compareUnmatchedTools(
        _ lhs: ProvenanceBibliographyResult.UnmatchedTool,
        _ rhs: ProvenanceBibliographyResult.UnmatchedTool
    ) -> Bool {
        let nameOrder = lhs.toolName.localizedCaseInsensitiveCompare(rhs.toolName)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.toolVersion < rhs.toolVersion
    }
}
