import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct FastqFullLengthONTMHCGenotypingSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "full-length-ont-mhc-genotype",
        abstract: "Run full-length ONT MHC genotyping from per-sample FASTQ bundles using Savont clusters"
    )

    @Argument(help: "One or more per-sample ONT FASTQ files or .lungfishfastq bundles")
    var inputs: [String]

    @Option(name: .customLong("reference"), help: "MHC allele FASTA, .lungfishref bundle, or .lungfishmhcref bundle")
    var reference: String

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

    @OptionGroup var globalOptions: GlobalOptions

    var threads: Int {
        max(1, globalOptions.threads ?? ProcessInfo.processInfo.activeProcessorCount)
    }

    @Option(name: .customLong("sample-jobs"), help: "Concurrent sample workflows. Defaults to an automatic sample-level parallel strategy.")
    var sampleJobs: Int?

    @Option(name: .customLong("savont-threads-per-sample"), help: "Savont threads per concurrently processed sample. Defaults to an automatic batch-aware value.")
    var savontThreadsPerSample: Int?

    @Option(name: .customLong("min-length"), help: "Minimum post-primer read length retained for Savont")
    var minLength: Int = 2_000

    @Option(name: .customLong("max-length"), help: "Maximum post-primer read length retained for Savont")
    var maxLength: Int = 4_000

    @Option(name: .customLong("savont-quality-value-cutoff"), help: "Minimum estimated read accuracy percent retained for Savont clustering")
    var savontQualityValueCutoff: Int = FullLengthONTMHCGenotypingRunRequest.defaultSavontQualityValueCutoff

    @Option(name: .customLong("savont-min-cluster-size"), help: "Minimum number of reads required to keep a Savont cluster")
    var savontMinimumClusterSize: Int = FullLengthONTMHCGenotypingRunRequest.defaultSavontMinimumClusterSize

    @Option(name: .customLong("min-unmatched-reads"), help: "Minimum cluster read count written to unmatched FASTA")
    var minUnmatchedReads: Int = 5

    @Option(name: .customLong("cdna-threshold"), help: "Alleles shorter than this length are treated as cDNA references")
    var cdnaThreshold: Int = 2_000

    @Flag(name: .customLong("keep-intermediates"), help: "Preserve regenerable full-length ONT MHC workflow intermediates for debugging")
    var keepIntermediates: Bool = false

    @Flag(name: .customLong("reuse-compatible-checkpoints"), help: "Reuse compatible full-length ONT MHC sample checkpoints when present")
    var reuseCompatibleCheckpoints: Bool = false

    @Option(name: .customLong("haplotype-min-sample-percent"), help: "Drop genotype rows below this percent of retained genotyping reads for the sample; 0 disables")
    var haplotypeMinSamplePercent: Double = 0

    @Option(name: .customLong("haplotype-min-locus-percent"), help: "Drop genotype rows below this percent of retained genotyping reads for the sample/locus; 0 disables")
    var haplotypeMinLocusPercent: Double = 0

    @Option(name: .customLong("haplotype-min-locus-percent-override"), parsing: .upToNextOption, help: "Per-locus percent override such as MHC-A=10; may be repeated")
    var haplotypeMinLocusPercentOverrides: [String] = []

    @Option(name: .customLong("haplotype-assay"), help: "Assay/amplicon set for haplotyping; disambiguates --haplotype-definition")
    var haplotypeAssay: String?

    @Option(name: .customLong("haplotype-species"), help: "Species code used to restrict compatible haplotype definitions, such as MCM or MAMU")
    var haplotypeSpecies: String?

    @Option(name: .customLong("haplotype-definition-scope"), help: "Haplotype definition scope: project")
    var haplotypeDefinitionScope: String?

    @Option(name: .customLong("haplotype-definition"), help: "Optional assay-scoped haplotype definition set ID; omit to skip haplotyping")
    var haplotypeDefinition: String?

    func run() async throws {
        guard !inputs.isEmpty else {
            throw ValidationError("At least one FASTQ input is required.")
        }
        guard globalOptions.threads.map({ $0 > 0 }) ?? true else {
            throw ValidationError("--threads must be positive.")
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
        let parsedHaplotypeDefinitionScope = try FastqGenotypingSubcommand.parseHaplotypeDefinitionScope(
            haplotypeDefinitionScope
        )
        let referenceURL = URL(fileURLWithPath: reference)
        let bundledHaplotype = try MHCReferenceBundleResolution.resolveBundleHaplotypeDefinition(
            referenceURL: referenceURL,
            explicitID: haplotypeDefinition
        )
        let effectiveHaplotypeDefinition = bundledHaplotype?.id ?? haplotypeDefinition
        let effectiveHaplotypeAssay = bundledHaplotype?.assayID ?? haplotypeAssay
        let effectiveHaplotypeSpecies = bundledHaplotype?.speciesCode ?? haplotypeSpecies
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: inputs.map { URL(fileURLWithPath: $0) },
            referenceSourceURL: referenceURL,
            orientReferenceURL: orientReference.map { URL(fileURLWithPath: $0) },
            forwardPrimerURL: forwardPrimer.map { URL(fileURLWithPath: $0) },
            reversePrimerURL: reversePrimer.map { URL(fileURLWithPath: $0) },
            outputDirectory: URL(fileURLWithPath: outputDir, isDirectory: true),
            outputName: outputName,
            projectURL: project.map { URL(fileURLWithPath: $0, isDirectory: true) },
            threads: threads,
            minimumLength: minLength,
            maximumLength: maxLength,
            savontQualityValueCutoff: savontQualityValueCutoff,
            savontMinimumClusterSize: savontMinimumClusterSize,
            minUnmatchedReads: minUnmatchedReads,
            cdnaThreshold: cdnaThreshold,
            sampleJobs: sampleJobs,
            savontThreadsPerSample: savontThreadsPerSample,
            keepIntermediates: keepIntermediates,
            reuseCompatibleCheckpoints: reuseCompatibleCheckpoints,
            haplotypeDropoutSampleFraction: FastqGenotypingSubcommand.fraction(
                fromPercent: haplotypeMinSamplePercent
            ),
            haplotypeDropoutLocusFraction: FastqGenotypingSubcommand.fraction(
                fromPercent: haplotypeMinLocusPercent
            ),
            haplotypeDropoutLocusFractionOverrides: parsedLocusOverrides,
            haplotypeAssayID: effectiveHaplotypeAssay,
            haplotypeSpeciesCode: effectiveHaplotypeSpecies,
            haplotypeDefinitionScope: effectiveHaplotypeDefinition == nil
                ? nil
                : (parsedHaplotypeDefinitionScope ?? .project),
            haplotypeDefinitionSetID: effectiveHaplotypeDefinition
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
            primaryWorkbookPath: result.primaryWorkbookURL.path,
            haplotypeAnalysisPath: result.haplotypeAnalysisURL?.path,
            unmatchedClustersFASTAPath: result.unmatchedClustersFASTAURL.path,
            cdnaClustersFASTAPath: result.cdnaClustersFASTAURL.path,
            provenancePath: result.provenanceURL.path,
            referenceFASTAPath: result.referenceFASTAURL.path,
            genotypingEvidenceBAMPath: result.genotypingEvidenceBAMURL?.path,
            genotypingEvidenceBAIPath: result.genotypingEvidenceBAIURL?.path,
            cleanupWarnings: result.cleanupWarnings
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(payload))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

struct FastqFullLengthONTMHCGenotypingPayload: Encodable {
    let outputDirectory: String
    let reportCSVPath: String
    let sampleSummaryCSVPath: String
    let statsJSONPath: String
    let workbookPath: String
    let primaryWorkbookPath: String
    let haplotypeAnalysisPath: String?
    let unmatchedClustersFASTAPath: String
    let cdnaClustersFASTAPath: String
    let provenancePath: String
    let referenceFASTAPath: String
    let genotypingEvidenceBAMPath: String?
    let genotypingEvidenceBAIPath: String?
    let cleanupWarnings: [FullLengthONTMHCGenotypingCleanupWarning]
}
