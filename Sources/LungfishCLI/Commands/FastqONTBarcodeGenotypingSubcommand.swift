import ArgumentParser
import Foundation
import LungfishWorkflow

struct FastqONTBarcodeGenotypingSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ont-barcode-genotype",
        abstract: "Map an ONT barcode FASTQ once, retain exact+indel MHC alignments, and demultiplex retained reads"
    )

    @Argument(help: "Original ONT FASTQ file or multi-file .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("reference"), help: "Reference FASTA file or .lungfishref bundle used as the mapping target")
    var reference: String

    @Option(name: .customLong("barcodes"), help: "CSV/TSV file containing sample ID and Fluidigm barcode sequence columns")
    var barcodes: String

    @Option(name: .customLong("demux-manifest"), help: "Optional demux-manifest.json with total input/sample read counts; defaults to the input bundle manifest")
    var demuxManifest: String?

    @Option(name: .customLong("output-dir"), help: "Directory for mapped BAM, retained BAM, CSV summaries, stats, and provenance")
    var outputDir: String

    @Option(name: .customLong("output-name"), help: "Output filename stem")
    var outputName: String = "ont-barcode-genotyping"

    @Option(name: .customLong("analysis-name"), help: "Label for this ONT analysis in the workbook; defaults to --output-name")
    var analysisName: String?

    @Option(name: .customLong("comparison-workbook"), help: "Optional Excel workbook whose first sheet provides comparison layout and expected calls")
    var comparisonWorkbook: String?

    @Option(name: .customLong("comparison-name"), help: "Label for the comparison workbook sheet")
    var comparisonName: String = "Illumina-31262"

    @Option(name: .customLong("project"), help: "Project directory; external FASTA references are imported here before mapping")
    var project: String?

    @OptionGroup var globalOptions: GlobalOptions

    @Option(name: .customLong("sort-threads"), help: "Threads for samtools sort")
    var sortThreads: Int = 4

    @Option(name: .customLong("min-support"), help: "Minimum retained alignment support required for a genotype row in the report")
    var minSupport: Int = 1

    @Option(
        name: .customLong("extra-args"),
        parsing: .unconditional,
        help: "Advanced minimap2 arguments passed after --MD and before reference/input paths"
    )
    var extraArgs: String = ""

    var threads: Int {
        max(1, globalOptions.threads ?? ProcessInfo.processInfo.activeProcessorCount)
    }

    func run() async throws {
        guard globalOptions.threads.map({ $0 > 0 }) ?? true else {
            throw ValidationError("--threads must be positive.")
        }
        guard sortThreads > 0 else {
            throw ValidationError("--sort-threads must be positive.")
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

        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURL: URL(fileURLWithPath: input),
            referenceSourceURL: URL(fileURLWithPath: reference),
            barcodeDefinitionsURL: URL(fileURLWithPath: barcodes),
            outputDirectory: URL(fileURLWithPath: outputDir, isDirectory: true),
            outputName: outputName,
            demuxManifestURL: demuxManifest.map { URL(fileURLWithPath: $0) },
            analysisName: analysisName,
            comparisonWorkbookURL: comparisonWorkbook.map { URL(fileURLWithPath: $0) },
            comparisonName: comparisonName,
            projectURL: project.map { URL(fileURLWithPath: $0, isDirectory: true) },
            threads: threads,
            sortThreads: sortThreads,
            minSupport: minSupport,
            extraArguments: parsedExtraArguments
        )

        let result = try await ONTBarcodeDemuxGenotypingPipeline().run(request)
        let payload = FastqONTBarcodeGenotypingPayload(
            outputDirectory: result.outputDirectory.path,
            mappingBAMPath: result.mappingBAMURL.path,
            mappingBAIPath: result.mappingBAIURL.path,
            retainedBAMPath: result.retainedBAMURL.path,
            retainedBAIPath: result.retainedBAIURL.path,
            reportCSVPath: result.reportCSVURL.path,
            sampleSummaryCSVPath: result.sampleSummaryCSVURL.path,
            statsJSONPath: result.statsJSONURL.path,
            workbookPath: result.workbookURL.path,
            provenancePath: result.provenanceURL.path,
            referenceFASTAPath: result.referenceFASTAURL.path,
            sourceReferenceBundlePath: result.sourceReferenceBundleURL?.path,
            totalInputReads: result.totalInputReads,
            retainedUniqueReads: result.retainedUniqueReads,
            retainedUniquePercentOfTotalReads: result.retainedUniquePercentOfTotalReads,
            assignedUniqueRetainedReads: result.assignedUniqueRetainedReads,
            unassignedUniqueRetainedReads: result.unassignedUniqueRetainedReads
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private struct FastqONTBarcodeGenotypingPayload: Encodable {
    let outputDirectory: String
    let mappingBAMPath: String
    let mappingBAIPath: String
    let retainedBAMPath: String
    let retainedBAIPath: String
    let reportCSVPath: String
    let sampleSummaryCSVPath: String
    let statsJSONPath: String
    let workbookPath: String
    let provenancePath: String
    let referenceFASTAPath: String
    let sourceReferenceBundlePath: String?
    let totalInputReads: Int
    let retainedUniqueReads: Int
    let retainedUniquePercentOfTotalReads: Double
    let assignedUniqueRetainedReads: Int
    let unassignedUniqueRetainedReads: Int
}
