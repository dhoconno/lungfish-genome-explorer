import Foundation
import LungfishIO

public struct PBAANextflowWorkflowFiles: Sendable, Equatable {
    public let mainNFURL: URL
    public let configURL: URL
    public let paramsURL: URL

    public init(mainNFURL: URL, configURL: URL, paramsURL: URL) {
        self.mainNFURL = mainNFURL
        self.configURL = configURL
        self.paramsURL = paramsURL
    }
}

public struct PBAANextflowParameters: Codable, Sendable, Equatable {
    public let guide: String
    public let reads: String
    public let readsFormat: String
    public let outdir: String
    public let prefix: String
    public let threads: Int
    public let seed: Int
    public let extraArguments: [String]

    public init(
        guide: String,
        reads: String,
        readsFormat: String = "fastq",
        outdir: String,
        prefix: String,
        threads: Int,
        seed: Int,
        extraArguments: [String]
    ) {
        self.guide = guide
        self.reads = reads
        self.readsFormat = readsFormat
        self.outdir = outdir
        self.prefix = prefix
        self.threads = threads
        self.seed = seed
        self.extraArguments = extraArguments
    }

    private enum CodingKeys: String, CodingKey {
        case guide
        case reads
        case readsFormat = "reads_format"
        case outdir
        case prefix
        case threads
        case seed
        case extraArguments
    }
}

public struct PBAANextflowWorkflowWriter: Sendable {
    public init() {}

    public func writeWorkflow(
        for request: PBAAClusteringRunRequest,
        to directory: URL
    ) throws -> PBAANextflowWorkflowFiles {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mainURL = directory.appendingPathComponent("main.nf")
        let configURL = directory.appendingPathComponent("nextflow.config")
        let paramsURL = directory.appendingPathComponent("params.json")

        try mainNF(readsFormat: request.inputFormat).write(to: mainURL, atomically: true, encoding: .utf8)
        try config(pins: request.containerPins).write(to: configURL, atomically: true, encoding: .utf8)

        let params = PBAANextflowParameters(
            guide: request.guideSourceURL.path,
            reads: request.inputFASTQURL.path,
            readsFormat: request.inputFormat.rawValue,
            outdir: request.rawPBAAOutputDirectory.path,
            prefix: request.prefix,
            threads: request.threads,
            seed: request.seed,
            extraArguments: request.extraArguments
        )
        let data = try JSONEncoder.pbaaPrettyPrinted.encode(params)
        try data.write(to: paramsURL, options: .atomic)

        return PBAANextflowWorkflowFiles(mainNFURL: mainURL, configURL: configURL, paramsURL: paramsURL)
    }

    private func mainNF(readsFormat: SequenceFormat) -> String {
        let readsFilename = readsFormat == .fasta ? "reads.fasta" : "reads.fastq"
        let indexCommand = readsFormat == .fasta
            ? "samtools faidx reads.fasta"
            : "samtools fqidx reads.fastq"
        return #"""
        nextflow.enable.dsl = 2

        process INDEX_GUIDE {
          tag "guide"
          container params.samtools_container
          input:
          path guide
          output:
          tuple path("guide.fasta"), path("guide.fasta.fai")
          script:
          """
          if [[ "${guide}" == *.gz ]]; then
            gzip -dc "${guide}" > guide.fasta
          else
            cp "${guide}" guide.fasta
          fi
          samtools faidx guide.fasta
          """
        }

        process INDEX_READS {
          tag "reads"
          container params.samtools_container
          input:
          path reads
          output:
          tuple path("\#(readsFilename)"), path("\#(readsFilename).fai")
          script:
          """
          cp "${reads}" \#(readsFilename)
          \#(indexCommand)
          """
        }

        process PBAA_CLUSTER {
          tag params.prefix
          container params.pbaa_container
          publishDir params.outdir, mode: 'copy', overwrite: true
          input:
          tuple path(guide), path(guide_index)
          tuple path(reads), path(reads_index)
          output:
          path "${params.prefix}_*"
          script:
          def shellQuote = { value -> "'" + value.toString().replace("'", "'\\''") + "'" }
          def extra = (params.extraArguments ?: []).collect { shellQuote(it) }.join(' ')
          """
          pbaa cluster -j ${params.threads} --seed ${params.seed} ${extra} guide.fasta \#(readsFilename) ${params.prefix}
          """
        }

        workflow {
          guide_ch = Channel.fromPath(params.guide)
          reads_ch = Channel.fromPath(params.reads)
          indexed_guide = INDEX_GUIDE(guide_ch)
          indexed_reads = INDEX_READS(reads_ch)
          PBAA_CLUSTER(indexed_guide, indexed_reads)
        }
        """#
    }

    private func config(pins: PBAAContainerPins) -> String {
        """
        process.executor = 'local'
        docker.enabled = true
        process.containerOptions = '--platform linux/amd64'
        params.pbaa_container = '\(pins.pbaa.pinnedReference)'
        params.samtools_container = '\(pins.samtools.pinnedReference)'
        params.reads_format = 'fastq'
        params.extraArguments = []
        """
    }
}

private extension JSONEncoder {
    static var pbaaPrettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
