import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct FastqGenotypingSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "genotype",
        abstract: "Run platform-aware exact+indel amplicon genotyping for ONT or Illumina reads"
    )

    @Argument(help: "Input FASTQ file, folder, or .lungfishfastq bundle. Sample-bundle modes accept multiple prepared per-sample bundles.")
    var inputs: [String]

    @Option(name: .customLong("mode"), help: "Genotyping mode: auto, ont-sample-bundles, illumina-paired, or deprecated ont-barcode-demux")
    var mode: String = "auto"

    @Option(name: .customLong("read-type"), help: "Read type override: auto, ont, or illumina")
    var readType: String = "auto"

    static let referenceHelp = MHCReferenceBundleResolution.referenceHelp

    @Option(name: .customLong("reference"), help: ArgumentHelp(stringLiteral: referenceHelp))
    var reference: String?

    @Option(name: .customLong("preset"), help: "Locked genotyping preset. Supported value: mcm-mhc-miseq.")
    var preset: String?

    @Option(name: .customLong("barcodes"), help: "Deprecated. CSV/TSV file containing sample ID and Fluidigm barcode sequence columns for ONT barcode-demux mode")
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

    @Option(name: .customLong("min-support"), help: "Minimum retained unique-read support required for a genotype row in the report and workbook")
    var minSupport: Int = 1

    @Option(name: .customLong("haplotype-min-sample-percent"), help: "Drop genotype rows below this percent of retained genotyping reads for the sample; 0 disables")
    var haplotypeMinSamplePercent: Double = 0

    @Option(name: .customLong("haplotype-min-locus-percent"), help: "Drop genotype rows below this percent of retained genotyping reads for the sample/locus; 0 disables")
    var haplotypeMinLocusPercent: Double = 0

    @Option(name: .customLong("haplotype-min-locus-percent-override"), parsing: .upToNextOption, help: "Per-locus percent override such as MHC-DQ=10; may be repeated")
    var haplotypeMinLocusPercentOverrides: [String] = []

    @Option(name: .customLong("haplotype-assay"), help: "Assay/amplicon set for haplotyping; disambiguates --haplotype-definition")
    var haplotypeAssay: String?

    @Option(name: .customLong("haplotype-species"), help: "Species code used to restrict compatible haplotype definitions, such as MCM or MAMU")
    var haplotypeSpecies: String?

    @Option(name: .customLong("haplotype-definition-scope"), help: "Haplotype definition scope: project")
    var haplotypeDefinitionScope: String?

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

    mutating func validate() throws {
        try Self.validateReferenceSelection(
            reference: reference,
            preset: preset,
            haplotypeAssay: haplotypeAssay,
            haplotypeSpecies: haplotypeSpecies,
            haplotypeDefinitionScope: haplotypeDefinitionScope,
            haplotypeDefinition: haplotypeDefinition
        )
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
        guard haplotypeMinSamplePercent >= 0 && haplotypeMinSamplePercent <= 100 else {
            throw ValidationError("--haplotype-min-sample-percent must be between 0 and 100.")
        }
        guard haplotypeMinLocusPercent >= 0 && haplotypeMinLocusPercent <= 100 else {
            throw ValidationError("--haplotype-min-locus-percent must be between 0 and 100.")
        }
        let parsedLocusOverrides = try Self.parseLocusPercentOverrides(haplotypeMinLocusPercentOverrides)
        guard let parsedMode = AmpliconGenotypingMode(cliArgument: mode) else {
            throw ValidationError("Unknown --mode '\(mode)'. Use auto, ont-barcode-demux, ont-sample-bundles, or illumina-paired.")
        }
        guard let parsedReadType = AmpliconGenotypingReadType(cliArgument: readType) else {
            throw ValidationError("Unknown --read-type '\(readType)'. Use auto, ont, or illumina.")
        }
        Self.writeDeprecatedBarcodeDemuxWarningIfNeeded(mode: parsedMode, barcodes: barcodes)
        let parsedHaplotypeDefinitionScope = try Self.parseHaplotypeDefinitionScope(haplotypeDefinitionScope)
        let parsedExtraArguments: [String]
        do {
            parsedExtraArguments = try AdvancedCommandLineOptions.parse(extraArgs)
        } catch {
            throw ValidationError("Invalid --extra-args: \(error.localizedDescription)")
        }
        let referenceConfiguration = try Self.resolvedReferenceConfiguration(
            reference: reference,
            preset: preset,
            haplotypeAssay: haplotypeAssay,
            haplotypeSpecies: haplotypeSpecies,
            haplotypeDefinitionScope: haplotypeDefinitionScope,
            haplotypeDefinition: haplotypeDefinition
        )

        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: inputs.map { URL(fileURLWithPath: $0) },
            referenceSourceURL: referenceConfiguration.referenceURL,
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
            haplotypeDropoutSampleFraction: Self.fraction(fromPercent: haplotypeMinSamplePercent),
            haplotypeDropoutLocusFraction: Self.fraction(fromPercent: haplotypeMinLocusPercent),
            haplotypeDropoutLocusFractionOverrides: parsedLocusOverrides,
            haplotypeAssayID: referenceConfiguration.haplotypeAssayID,
            haplotypeSpeciesCode: referenceConfiguration.haplotypeSpeciesCode,
            haplotypeDefinitionScope: referenceConfiguration.haplotypeDefinitionSetID == nil
                ? nil
                : (parsedHaplotypeDefinitionScope ?? .project),
            haplotypeDefinitionSetID: referenceConfiguration.haplotypeDefinitionSetID,
            presetID: referenceConfiguration.preset?.id,
            presetVersion: referenceConfiguration.preset?.version,
            lockedReferenceSHA256: referenceConfiguration.preset?.referenceFASTASHA256,
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

    struct ResolvedReferenceConfiguration: Equatable {
        let referenceURL: URL
        let preset: MCMHaplotypingPreset?
        let haplotypeAssayID: String?
        let haplotypeSpeciesCode: String?
        let haplotypeDefinitionSetID: String?
    }

    static func validateReferenceSelection(
        reference: String?,
        preset: String?,
        haplotypeAssay: String?,
        haplotypeSpecies: String?,
        haplotypeDefinitionScope: String?,
        haplotypeDefinition: String?
    ) throws {
        let trimmedPreset = preset?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedReference = reference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedPreset.isEmpty || !trimmedReference.isEmpty else {
            throw ValidationError("Provide --reference, or use --preset mcm-mhc-miseq.")
        }
        guard !trimmedPreset.isEmpty else { return }
        guard MCMHaplotypingPreset.preset(id: trimmedPreset) != nil else {
            throw ValidationError(MCMHaplotypingPresetError.unknownPreset(trimmedPreset).localizedDescription)
        }
        guard trimmedReference.isEmpty else {
            throw ValidationError(MCMHaplotypingPresetError.referenceOverrideNotAllowed(trimmedPreset).localizedDescription)
        }
        let hasHaplotypeOverride = [
            haplotypeAssay,
            haplotypeSpecies,
            haplotypeDefinitionScope,
            haplotypeDefinition,
        ].contains { value in
            !(value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }
        guard !hasHaplotypeOverride else {
            throw ValidationError(MCMHaplotypingPresetError.haplotypeOverrideNotAllowed(trimmedPreset).localizedDescription)
        }
    }

    static func resolvedReferenceConfiguration(
        reference: String?,
        preset: String?,
        haplotypeAssay: String?,
        haplotypeSpecies: String?,
        haplotypeDefinitionScope: String?,
        haplotypeDefinition: String?
    ) throws -> ResolvedReferenceConfiguration {
        try validateReferenceSelection(
            reference: reference,
            preset: preset,
            haplotypeAssay: haplotypeAssay,
            haplotypeSpecies: haplotypeSpecies,
            haplotypeDefinitionScope: haplotypeDefinitionScope,
            haplotypeDefinition: haplotypeDefinition
        )
        if let resolvedPreset = MCMHaplotypingPreset.preset(id: preset) {
            return ResolvedReferenceConfiguration(
                referenceURL: try resolvedPreset.bundledReferenceBundleURL(),
                preset: resolvedPreset,
                haplotypeAssayID: resolvedPreset.haplotypeAssayID,
                haplotypeSpeciesCode: resolvedPreset.haplotypeSpeciesCode,
                haplotypeDefinitionSetID: resolvedPreset.haplotypeDefinitionSetID
            )
        }
        guard let reference else {
            throw ValidationError("Provide --reference, or use --preset mcm-mhc-miseq.")
        }
        let referenceURL = URL(fileURLWithPath: reference)
        let bundledHaplotype = try resolveBundleHaplotypeDefinition(
            referenceURL: referenceURL,
            explicitID: haplotypeDefinition
        )
        return ResolvedReferenceConfiguration(
            referenceURL: referenceURL,
            preset: nil,
            haplotypeAssayID: bundledHaplotype?.assayID ?? haplotypeAssay,
            haplotypeSpeciesCode: bundledHaplotype?.speciesCode ?? haplotypeSpecies,
            haplotypeDefinitionSetID: bundledHaplotype?.id ?? haplotypeDefinition
        )
    }

    static func fraction(fromPercent percent: Double) -> Double? {
        guard percent.isFinite, percent > 0 else { return nil }
        return min(percent, 100) / 100
    }

    static let deprecatedBarcodeDemuxWarning = """
    warning: ONT barcode-demux genotyping is deprecated. Demultiplex with a FASTQ import recipe first, then run `lungfish-cli fastq genotype` or `lungfish-cli fastq genotype-cohort` on prepared per-sample bundles.

    """

    static func writeDeprecatedBarcodeDemuxWarningIfNeeded(
        mode: AmpliconGenotypingMode,
        barcodes: String?
    ) {
        let hasBarcodeDefinitions = !(barcodes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        guard mode == .ontBarcodeDemux || hasBarcodeDefinitions else { return }
        FileHandle.standardError.write(Data(deprecatedBarcodeDemuxWarning.utf8))
    }

    static func parseLocusPercentOverrides(_ rawValues: [String]) throws -> [String: Double] {
        var values: [String: Double] = [:]
        for rawValue in rawValues {
            let parts = rawValue.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw ValidationError("--haplotype-min-locus-percent-override must be LOCUS=PERCENT.")
            }
            let locus = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let percentText = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !locus.isEmpty,
                  let percent = Double(percentText),
                  percent >= 0,
                  percent <= 100 else {
                throw ValidationError("--haplotype-min-locus-percent-override must use a percent between 0 and 100.")
            }
            if let fraction = fraction(fromPercent: percent) {
                values[locus] = fraction
            }
        }
        return values
    }

    static func parseHaplotypeDefinitionScope(_ rawValue: String?) throws -> HaplotypeDefinitionScope? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        guard let scope = HaplotypeDefinitionScope(rawValue: rawValue) else {
            let allowed = HaplotypeDefinitionScope.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("--haplotype-definition-scope must be one of: \(allowed).")
        }
        return scope
    }
}

struct FastqGenotypingCohortSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "genotype-cohort",
        abstract: "Run cohort amplicon genotyping across multiple prepared per-sample FASTQ bundles"
    )

    @Argument(help: "Input .lungfishfastq bundles. Each bundle must contain one prepared per-sample FASTQ.")
    var inputs: [String]

    @Option(name: .customLong("mode"), help: "Genotyping mode: auto, ont-sample-bundles, illumina-paired, or deprecated ont-barcode-demux")
    var mode: String = "illumina-paired"

    @Option(name: .customLong("read-type"), help: "Read type override: auto, ont, or illumina")
    var readType: String = "illumina"

    static let referenceHelp = MHCReferenceBundleResolution.referenceHelp

    @Option(name: .customLong("reference"), help: ArgumentHelp(stringLiteral: referenceHelp))
    var reference: String?

    @Option(name: .customLong("preset"), help: "Locked genotyping preset. Supported value: mcm-mhc-miseq.")
    var preset: String?

    @Option(name: .customLong("barcodes"), help: "Deprecated. CSV/TSV file containing sample ID and Fluidigm barcode sequence columns for ONT barcode-demux mode")
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

    @Option(name: .customLong("min-support"), help: "Minimum retained unique-read support required for a genotype row in the report and workbook")
    var minSupport: Int = 1

    @Option(name: .customLong("haplotype-min-sample-percent"), help: "Drop genotype rows below this percent of retained genotyping reads for the sample; 0 disables")
    var haplotypeMinSamplePercent: Double = 0

    @Option(name: .customLong("haplotype-min-locus-percent"), help: "Drop genotype rows below this percent of retained genotyping reads for the sample/locus; 0 disables")
    var haplotypeMinLocusPercent: Double = 0

    @Option(name: .customLong("haplotype-min-locus-percent-override"), parsing: .upToNextOption, help: "Per-locus percent override such as MHC-DQ=10; may be repeated")
    var haplotypeMinLocusPercentOverrides: [String] = []

    @Option(name: .customLong("haplotype-assay"), help: "Assay/amplicon set for haplotyping; disambiguates --haplotype-definition")
    var haplotypeAssay: String?

    @Option(name: .customLong("haplotype-species"), help: "Species code used to restrict compatible haplotype definitions, such as MCM or MAMU")
    var haplotypeSpecies: String?

    @Option(name: .customLong("haplotype-definition-scope"), help: "Haplotype definition scope: project")
    var haplotypeDefinitionScope: String?

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

    mutating func validate() throws {
        try FastqGenotypingSubcommand.validateReferenceSelection(
            reference: reference,
            preset: preset,
            haplotypeAssay: haplotypeAssay,
            haplotypeSpecies: haplotypeSpecies,
            haplotypeDefinitionScope: haplotypeDefinitionScope,
            haplotypeDefinition: haplotypeDefinition
        )
    }

    func run() async throws {
        guard inputs.count > 1 else {
            throw ValidationError("At least two input FASTQ bundles are required for genotype-cohort.")
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
        guard haplotypeMinSamplePercent >= 0 && haplotypeMinSamplePercent <= 100 else {
            throw ValidationError("--haplotype-min-sample-percent must be between 0 and 100.")
        }
        guard haplotypeMinLocusPercent >= 0 && haplotypeMinLocusPercent <= 100 else {
            throw ValidationError("--haplotype-min-locus-percent must be between 0 and 100.")
        }
        let parsedLocusOverrides = try FastqGenotypingSubcommand.parseLocusPercentOverrides(
            haplotypeMinLocusPercentOverrides
        )
        guard let parsedMode = AmpliconGenotypingMode(cliArgument: mode) else {
            throw ValidationError("Unknown --mode '\(mode)'. Use auto, ont-barcode-demux, ont-sample-bundles, or illumina-paired.")
        }
        guard let parsedReadType = AmpliconGenotypingReadType(cliArgument: readType) else {
            throw ValidationError("Unknown --read-type '\(readType)'. Use auto, ont, or illumina.")
        }
        FastqGenotypingSubcommand.writeDeprecatedBarcodeDemuxWarningIfNeeded(mode: parsedMode, barcodes: barcodes)
        let parsedHaplotypeDefinitionScope = try FastqGenotypingSubcommand.parseHaplotypeDefinitionScope(
            haplotypeDefinitionScope
        )
        let parsedExtraArguments: [String]
        do {
            parsedExtraArguments = try AdvancedCommandLineOptions.parse(extraArgs)
        } catch {
            throw ValidationError("Invalid --extra-args: \(error.localizedDescription)")
        }
        let referenceConfiguration = try FastqGenotypingSubcommand.resolvedReferenceConfiguration(
            reference: reference,
            preset: preset,
            haplotypeAssay: haplotypeAssay,
            haplotypeSpecies: haplotypeSpecies,
            haplotypeDefinitionScope: haplotypeDefinitionScope,
            haplotypeDefinition: haplotypeDefinition
        )

        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: inputs.map { URL(fileURLWithPath: $0) },
            referenceSourceURL: referenceConfiguration.referenceURL,
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
            haplotypeDropoutSampleFraction: FastqGenotypingSubcommand.fraction(
                fromPercent: haplotypeMinSamplePercent
            ),
            haplotypeDropoutLocusFraction: FastqGenotypingSubcommand.fraction(
                fromPercent: haplotypeMinLocusPercent
            ),
            haplotypeDropoutLocusFractionOverrides: parsedLocusOverrides,
            haplotypeAssayID: referenceConfiguration.haplotypeAssayID,
            haplotypeSpeciesCode: referenceConfiguration.haplotypeSpeciesCode,
            haplotypeDefinitionScope: referenceConfiguration.haplotypeDefinitionSetID == nil
                ? nil
                : (parsedHaplotypeDefinitionScope ?? .project),
            haplotypeDefinitionSetID: referenceConfiguration.haplotypeDefinitionSetID,
            presetID: referenceConfiguration.preset?.id,
            presetVersion: referenceConfiguration.preset?.version,
            lockedReferenceSHA256: referenceConfiguration.preset?.referenceFASTASHA256,
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
