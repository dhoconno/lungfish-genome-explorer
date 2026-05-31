import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct FastqGenotypingSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "genotype",
        abstract: "Run platform-aware exact+indel amplicon genotyping for ONT or Illumina reads"
    )

    @Argument(help: "Input FASTQ file, folder, or .lungfishfastq bundle. Illumina mode accepts multiple prepared per-sample bundles created with the Illumina Amplicon Merge import recipe.")
    var inputs: [String]

    @Option(name: .customLong("mode"), help: "Genotyping mode: auto, ont-barcode-demux, or illumina-paired")
    var mode: String = "auto"

    @Option(name: .customLong("read-type"), help: "Read type override: auto, ont, or illumina")
    var readType: String = "auto"

    static let referenceHelp = MHCReferenceBundleResolution.referenceHelp

    @Option(name: .customLong("reference"), help: ArgumentHelp(stringLiteral: referenceHelp))
    var reference: String

    @Option(name: .customLong("barcodes"), help: "CSV/TSV file containing sample ID and Fluidigm barcode sequence columns for ONT barcode-demux mode")
    var barcodes: String?

    @Option(name: .customLong("demux-manifest"), help: "Optional demux-manifest.json with total input/sample read counts for ONT barcode-demux mode")
    var demuxManifest: String?

    @Option(name: .customLong("output-dir"), help: "Directory for genotype CSV summaries, workbook, stats, and provenance")
    var outputDir: String

    @Option(name: .customLong("output-name"), help: "Output filename stem")
    var outputName: String = "amplicon-genotyping"

    @Option(name: .customLong("analysis-name"), help: "Label for this analysis in the workbook; defaults to --output-name")
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

    @Option(name: .customLong("haplotype-assay"), help: "Assay/amplicon set for haplotyping; disambiguates --haplotype-definition")
    var haplotypeAssay: String?

    @Option(name: .customLong("haplotype-species"), help: "Species code used to restrict compatible haplotype definitions, such as MCM or MAMU")
    var haplotypeSpecies: String?

    @Option(name: .customLong("haplotype-definition"), help: "Optional assay-scoped haplotype definition set ID; omit to skip haplotyping")
    var haplotypeDefinition: String?

    @Option(
        name: .customLong("extra-args"),
        parsing: .unconditional,
        help: "Advanced minimap2 arguments passed after the mapping preset"
    )
    var extraArgs: String = ""

    var threads: Int {
        max(1, globalOptions.threads ?? ProcessInfo.processInfo.activeProcessorCount)
    }

    func run() async throws {
        guard !inputs.isEmpty else {
            throw ValidationError("At least one input FASTQ or .lungfishfastq bundle is required.")
        }
        guard globalOptions.threads.map({ $0 > 0 }) ?? true else {
            throw ValidationError("--threads must be positive.")
        }
        guard sortThreads > 0 else {
            throw ValidationError("--sort-threads must be positive.")
        }
        guard minSupport > 0 else {
            throw ValidationError("--min-support must be positive.")
        }
        guard let parsedMode = AmpliconGenotypingMode(cliArgument: mode) else {
            throw ValidationError("Unknown --mode '\(mode)'. Use auto, ont-barcode-demux, or illumina-paired.")
        }
        guard let parsedReadType = AmpliconGenotypingReadType(cliArgument: readType) else {
            throw ValidationError("Unknown --read-type '\(readType)'. Use auto, ont, or illumina.")
        }
        let parsedExtraArguments: [String]
        do {
            parsedExtraArguments = try AdvancedCommandLineOptions.parse(extraArgs)
        } catch {
            throw ValidationError("Invalid --extra-args: \(error.localizedDescription)")
        }
        let referenceURL = URL(fileURLWithPath: reference)
        let bundledHaplotype = try Self.resolveBundleHaplotypeDefinition(
            referenceURL: referenceURL,
            explicitID: haplotypeDefinition
        )
        let effectiveHaplotypeDefinition = bundledHaplotype?.id ?? haplotypeDefinition
        let effectiveHaplotypeAssay = bundledHaplotype?.assayID ?? haplotypeAssay
        let effectiveHaplotypeSpecies = bundledHaplotype?.speciesCode ?? haplotypeSpecies

        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: inputs.map { URL(fileURLWithPath: $0) },
            referenceSourceURL: referenceURL,
            barcodeDefinitionsURL: barcodes.map { URL(fileURLWithPath: $0) },
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
            haplotypeAssayID: effectiveHaplotypeAssay,
            haplotypeSpeciesCode: effectiveHaplotypeSpecies,
            haplotypeDefinitionScope: .project,
            haplotypeDefinitionSetID: effectiveHaplotypeDefinition,
            extraArguments: parsedExtraArguments,
            mode: parsedMode,
            readType: parsedReadType
        )

        let result = try await ONTBarcodeDemuxGenotypingPipeline().run(
            request,
            progressHandler: { fraction, message in
                let percent = max(0, min(100, Int((fraction * 100).rounded())))
                FileHandle.standardError.write(Data("[\(String(format: "%3d%%", percent))] \(message)\n".utf8))
            }
        )
        let payload = FastqGenotypingPayload(
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

    /// Resolves the haplotype definition for a `.lungfishmhcref` reference bundle.
    ///
    /// Forwards to ``MHCReferenceBundleResolution/resolveBundleHaplotypeDefinition(referenceURL:explicitID:)``,
    /// which is shared with the sibling genotyping subcommands.
    static func resolveBundleHaplotypeDefinition(
        referenceURL: URL,
        explicitID: String?
    ) throws -> GenotypeHaplotypeDefinitionSet? {
        try MHCReferenceBundleResolution.resolveBundleHaplotypeDefinition(
            referenceURL: referenceURL,
            explicitID: explicitID
        )
    }
}

private struct FastqGenotypingPayload: Encodable {
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
