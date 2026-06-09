import ArgumentParser
import Foundation
import LungfishWorkflow

struct FastqFullLengthONTMHCGenotypingSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "full-length-ont-mhc-genotype",
        abstract: "Run full-length ONT MHC genotyping from per-sample FASTQ bundles using pbAA clusters"
    )

    @Argument(help: "One or more per-sample ONT FASTQ files or .lungfishfastq bundles")
    var inputs: [String]

    @Option(name: .customLong("reference"), help: "MHC allele FASTA, .lungfishref bundle, or .lungfishmhcref bundle")
    var reference: String

    @Option(name: .customLong("guide"), help: "Guide FASTA file or .lungfishref bundle used by pbAA")
    var guide: String

    @Option(name: .customLong("orient-reference"), help: "Optional FASTA used by vsearch --orient")
    var orientReference: String?

    @Option(name: .customLong("forward-primer"), help: "Optional forward primer FASTA for 5-prime bbduk trimming")
    var forwardPrimer: String?

    @Option(name: .customLong("reverse-primer"), help: "Optional reverse primer FASTA for 3-prime bbduk trimming")
    var reversePrimer: String?

    @Option(name: .customLong("output-dir"), help: "Output .lungfishgenotype bundle directory")
    var outputDir: String

    @Option(name: .customLong("output-name"), help: "Output report stem")
    var outputName: String = "full-length-ont-mhc-genotyping"

    @Option(name: .customLong("project"), help: "Optional Lungfish project root for provenance context")
    var project: String?

    @Option(name: .customLong("threads"), help: "Worker threads for vsearch, minimap2, and pbAA")
    var threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)

    @Option(name: .customLong("sample-jobs"), help: "Concurrent sample workflows. Defaults to an automatic sample-level parallel strategy.")
    var sampleJobs: Int?

    @Option(name: .customLong("pbaa-threads-per-sample"), help: "pbAA threads per concurrently processed sample. Defaults to all threads for one sample and one thread per sample for batches.")
    var pbaaThreadsPerSample: Int?

    @Option(name: .customLong("min-length"), help: "Minimum post-primer read length retained for pbAA")
    var minLength: Int = 2_000

    @Option(name: .customLong("max-length"), help: "Maximum post-primer read length retained for pbAA")
    var maxLength: Int = 4_000

    @Option(name: .customLong("pbaa-seed"), help: "pbAA random seed")
    var pbaaSeed: Int = 1984

    @Option(name: .customLong("pbaa-extra-args"), parsing: .unconditional, help: "Additional pbAA arguments")
    var pbaaExtraArgs: String = FullLengthONTMHCGenotypingRunRequest.defaultPBAAExtraArgumentsText

    @Option(name: .customLong("min-unmatched-reads"), help: "Minimum pbaa cluster read count written to unmatched FASTA")
    var minUnmatchedReads: Int = 5

    @Option(name: .customLong("cdna-threshold"), help: "Alleles shorter than this length are treated as cDNA references")
    var cdnaThreshold: Int = 2_000

    func run() async throws {
        guard !inputs.isEmpty else {
            throw ValidationError("At least one FASTQ input is required.")
        }
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: inputs.map { URL(fileURLWithPath: $0) },
            referenceSourceURL: URL(fileURLWithPath: reference),
            guideSourceURL: URL(fileURLWithPath: guide),
            orientReferenceURL: orientReference.map { URL(fileURLWithPath: $0) },
            forwardPrimerURL: forwardPrimer.map { URL(fileURLWithPath: $0) },
            reversePrimerURL: reversePrimer.map { URL(fileURLWithPath: $0) },
            outputDirectory: URL(fileURLWithPath: outputDir, isDirectory: true),
            outputName: outputName,
            projectURL: project.map { URL(fileURLWithPath: $0, isDirectory: true) },
            threads: threads,
            minimumLength: minLength,
            maximumLength: maxLength,
            pbaaSeed: pbaaSeed,
            pbaaExtraArgumentsText: pbaaExtraArgs,
            minUnmatchedReads: minUnmatchedReads,
            cdnaThreshold: cdnaThreshold,
            sampleJobs: sampleJobs,
            pbaaThreadsPerSample: pbaaThreadsPerSample
        )
        let result = try await FullLengthONTMHCGenotypingPipeline().run(request) { fraction, message in
            let percent = Int((fraction * 100.0).rounded())
            FileHandle.standardError.write(Data("[\(percent)%] \(message)\n".utf8))
        }
        let payload = FastqFullLengthONTMHCGenotypingPayload(
            outputDirectory: result.outputDirectory.path,
            reportCSVPath: result.reportCSVURL.path,
            sampleSummaryCSVPath: result.sampleSummaryCSVURL.path,
            statsJSONPath: result.statsJSONURL.path,
            workbookPath: result.workbookURL.path,
            unmatchedClustersFASTAPath: result.unmatchedClustersFASTAURL.path,
            cdnaClustersFASTAPath: result.cdnaClustersFASTAURL.path,
            provenancePath: result.provenanceURL.path,
            referenceFASTAPath: result.referenceFASTAURL.path,
            guideFASTAPath: result.guideFASTAURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(payload))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private struct FastqFullLengthONTMHCGenotypingPayload: Encodable {
    let outputDirectory: String
    let reportCSVPath: String
    let sampleSummaryCSVPath: String
    let statsJSONPath: String
    let workbookPath: String
    let unmatchedClustersFASTAPath: String
    let cdnaClustersFASTAPath: String
    let provenancePath: String
    let referenceFASTAPath: String
    let guideFASTAPath: String
}
