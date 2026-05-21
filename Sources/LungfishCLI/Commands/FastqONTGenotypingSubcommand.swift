import ArgumentParser
import Foundation
import LungfishWorkflow

struct FastqONTGenotypingSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ont-genotype",
        abstract: "Genotype ONT amplicon FASTQ bundles by short-read mapping and pysam filtering"
    )

    @Argument(help: "Input FASTQ files or .lungfishfastq bundles. Multiple demultiplexed bundles are supported.")
    var inputs: [String]

    @Option(name: .customLong("reference"), help: "Reference FASTA file or .lungfishref bundle used as the mapping target")
    var reference: String

    @Option(name: .customLong("output-dir"), help: "Directory for filtered BAMs, indexes, report CSV, and workflow provenance")
    var outputDir: String

    @Option(name: .customLong("output-name"), help: "Report filename stem")
    var outputName: String = "ont-genotyping-report"

    @Option(name: .customLong("project"), help: "Project directory; external FASTA references are imported here before mapping")
    var project: String?

    @OptionGroup var globalOptions: GlobalOptions

    var threads: Int {
        max(1, globalOptions.threads ?? ProcessInfo.processInfo.activeProcessorCount)
    }

    @Option(name: .customLong("min-support"), help: "Minimum filtered read support required for a genotype row in the report")
    var minSupport: Int = 1

    @Option(
        name: .customLong("extra-args"),
        parsing: .unconditional,
        help: "Advanced minimap2 arguments passed after the simple mapping settings"
    )
    var extraArgs: String = ""

    func run() async throws {
        guard !inputs.isEmpty else {
            throw ValidationError("Provide at least one FASTQ file or .lungfishfastq bundle.")
        }
        guard globalOptions.threads.map({ $0 > 0 }) ?? true else {
            throw ValidationError("--threads must be positive.")
        }
        guard minSupport > 0 else {
            throw ValidationError("--min-support must be positive.")
        }

        let parsedExtraArguments: [String]
        do {
            parsedExtraArguments = try AdvancedCommandLineOptions.parse(extraArgs)
        } catch {
            throw ValidationError("Invalid --extra-args: \(error.localizedDescription)")
        }

        let request = ONTGenotypingRunRequest(
            inputFASTQURLs: inputs.map { URL(fileURLWithPath: $0) },
            referenceSourceURL: URL(fileURLWithPath: reference),
            outputDirectory: URL(fileURLWithPath: outputDir, isDirectory: true),
            outputName: outputName,
            projectURL: project.map { URL(fileURLWithPath: $0, isDirectory: true) },
            threads: threads,
            minSupport: minSupport,
            extraArguments: parsedExtraArguments
        )
        let result = try await ONTGenotypingPipeline().run(request)
        let payload = FastqONTGenotypingPayload(
            reportCSVPath: result.reportCSVURL.path,
            outputDirectory: result.outputDirectory.path,
            referenceFASTAPath: result.referenceFASTAURL.path,
            sourceReferenceBundlePath: result.sourceReferenceBundleURL?.path,
            sampleResults: result.sampleResults.map {
                FastqONTGenotypingSamplePayload(
                    inputFASTQPath: $0.inputFASTQURL.path,
                    sampleName: $0.sampleName,
                    mappingBAMPath: $0.mappingResult.bamURL.path,
                    mappingBAIPath: $0.mappingResult.baiURL.path,
                    filteredBAMPath: $0.filterResult.outputBAMURL.path,
                    filteredBAIPath: $0.filterResult.outputBAIURL.path,
                    totalReads: $0.mappingResult.totalReads,
                    filteredAlignments: $0.filterResult.passedAlignments
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private struct FastqONTGenotypingPayload: Encodable {
    let reportCSVPath: String
    let outputDirectory: String
    let referenceFASTAPath: String
    let sourceReferenceBundlePath: String?
    let sampleResults: [FastqONTGenotypingSamplePayload]
}

private struct FastqONTGenotypingSamplePayload: Encodable {
    let inputFASTQPath: String
    let sampleName: String
    let mappingBAMPath: String
    let mappingBAIPath: String
    let filteredBAMPath: String
    let filteredBAIPath: String
    let totalReads: Int
    let filteredAlignments: Int
}
