import Foundation
import LungfishCore
import LungfishIO

public struct ONTBarcodeDemuxGenotypingRunRequest: Sendable, Codable, Equatable {
    public let inputFASTQURL: URL
    public let inputFASTQURLs: [URL]
    public let referenceSourceURL: URL
    public let barcodeDefinitionsURL: URL?
    public let outputDirectory: URL
    public let outputName: String
    public let demuxManifestURL: URL?
    public let analysisName: String
    public let comparisonWorkbookURL: URL?
    public let comparisonName: String?
    public let projectURL: URL?
    public let threads: Int
    public let sortThreads: Int
    public let minSupport: Int
    public let haplotypeDropoutSampleFraction: Double?
    public let haplotypeDropoutLocusFraction: Double?
    public let haplotypeDropoutLocusFractionOverrides: [String: Double]
    public let haplotypeAssayID: String?
    public let haplotypeSpeciesCode: String?
    public let haplotypeDefinitionScope: HaplotypeDefinitionScope?
    public let haplotypeDefinitionSetID: String?
    public let presetID: String?
    public let presetVersion: String?
    public let lockedReferenceSHA256: String?
    public let extraArguments: [String]
    public let mode: AmpliconGenotypingMode
    public let readType: AmpliconGenotypingReadType
    public let aiSpecialistPresetID: String?

    public init(
        inputFASTQURL: URL,
        referenceSourceURL: URL,
        barcodeDefinitionsURL: URL,
        outputDirectory: URL,
        outputName: String = "ont-barcode-genotyping",
        demuxManifestURL: URL? = nil,
        analysisName: String? = nil,
        comparisonWorkbookURL: URL? = nil,
        comparisonName: String? = "Illumina-31262",
        projectURL: URL? = nil,
        threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        sortThreads: Int = 4,
        minSupport: Int = 1,
        haplotypeDropoutSampleFraction: Double? = nil,
        haplotypeDropoutLocusFraction: Double? = nil,
        haplotypeDropoutLocusFractionOverrides: [String: Double] = [:],
        haplotypeAssayID: String? = nil,
        haplotypeSpeciesCode: String? = nil,
        haplotypeDefinitionScope: HaplotypeDefinitionScope? = nil,
        haplotypeDefinitionSetID: String? = nil,
        presetID: String? = nil,
        presetVersion: String? = nil,
        lockedReferenceSHA256: String? = nil,
        extraArguments: [String] = [],
        aiSpecialistPresetID: String? = nil
    ) {
        self.init(
            inputFASTQURLs: [inputFASTQURL],
            referenceSourceURL: referenceSourceURL,
            barcodeDefinitionsURL: barcodeDefinitionsURL,
            outputDirectory: outputDirectory,
            outputName: outputName,
            demuxManifestURL: demuxManifestURL,
            analysisName: analysisName,
            comparisonWorkbookURL: comparisonWorkbookURL,
            comparisonName: comparisonName,
            projectURL: projectURL,
            threads: threads,
            sortThreads: sortThreads,
            minSupport: minSupport,
            haplotypeDropoutSampleFraction: haplotypeDropoutSampleFraction,
            haplotypeDropoutLocusFraction: haplotypeDropoutLocusFraction,
            haplotypeDropoutLocusFractionOverrides: haplotypeDropoutLocusFractionOverrides,
            haplotypeAssayID: haplotypeAssayID,
            haplotypeSpeciesCode: haplotypeSpeciesCode,
            haplotypeDefinitionScope: haplotypeDefinitionScope,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            presetID: presetID,
            presetVersion: presetVersion,
            lockedReferenceSHA256: lockedReferenceSHA256,
            extraArguments: extraArguments,
            mode: .ontBarcodeDemux,
            readType: .ont,
            aiSpecialistPresetID: aiSpecialistPresetID
        )
    }

    public init(
        inputFASTQURLs: [URL],
        referenceSourceURL: URL,
        barcodeDefinitionsURL: URL? = nil,
        outputDirectory: URL,
        outputName: String = "amplicon-genotyping",
        demuxManifestURL: URL? = nil,
        analysisName: String? = nil,
        comparisonWorkbookURL: URL? = nil,
        comparisonName: String? = "Illumina-31262",
        projectURL: URL? = nil,
        threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        sortThreads: Int = 4,
        minSupport: Int = 1,
        haplotypeDropoutSampleFraction: Double? = nil,
        haplotypeDropoutLocusFraction: Double? = nil,
        haplotypeDropoutLocusFractionOverrides: [String: Double] = [:],
        haplotypeAssayID: String? = nil,
        haplotypeSpeciesCode: String? = nil,
        haplotypeDefinitionScope: HaplotypeDefinitionScope? = nil,
        haplotypeDefinitionSetID: String? = nil,
        presetID: String? = nil,
        presetVersion: String? = nil,
        lockedReferenceSHA256: String? = nil,
        extraArguments: [String] = [],
        mode: AmpliconGenotypingMode = .auto,
        readType: AmpliconGenotypingReadType = .auto,
        aiSpecialistPresetID: String? = nil
    ) {
        let normalizedOutputName = Self.sanitizedOutputName(outputName)
        let standardizedInputURLs = inputFASTQURLs.isEmpty
            ? [URL(fileURLWithPath: "").standardizedFileURL]
            : inputFASTQURLs.map(\.standardizedFileURL)
        self.inputFASTQURL = standardizedInputURLs[0]
        self.inputFASTQURLs = standardizedInputURLs
        self.referenceSourceURL = referenceSourceURL.standardizedFileURL
        let standardizedBarcodeDefinitionsURL = barcodeDefinitionsURL?.standardizedFileURL
        let effectiveMode = Self.effectiveMode(
            requestedMode: mode,
            readType: readType,
            barcodeDefinitionsURL: standardizedBarcodeDefinitionsURL
        )
        let effectiveReadType = Self.effectiveReadType(
            requestedReadType: readType,
            mode: effectiveMode
        )
        self.barcodeDefinitionsURL = standardizedBarcodeDefinitionsURL
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.outputName = normalizedOutputName
        self.demuxManifestURL = demuxManifestURL?.standardizedFileURL
        self.analysisName = Self.sanitizedReportLabel(
            analysisName ?? normalizedOutputName,
            fallback: normalizedOutputName
        )
        self.comparisonWorkbookURL = comparisonWorkbookURL?.standardizedFileURL
        self.comparisonName = comparisonWorkbookURL == nil
            ? nil
            : Self.sanitizedReportLabel(comparisonName ?? "Illumina-31262", fallback: "Illumina-31262")
        self.projectURL = projectURL?.standardizedFileURL
        self.threads = max(1, threads)
        self.sortThreads = max(1, sortThreads)
        self.minSupport = max(1, minSupport)
        self.haplotypeDropoutSampleFraction = Self.normalizedFraction(haplotypeDropoutSampleFraction)
        self.haplotypeDropoutLocusFraction = Self.normalizedFraction(haplotypeDropoutLocusFraction)
        self.haplotypeDropoutLocusFractionOverrides = Self.normalizedFractionOverrides(haplotypeDropoutLocusFractionOverrides)
        let trimmedHaplotypeAssayID = haplotypeAssayID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.haplotypeAssayID = trimmedHaplotypeAssayID?.isEmpty == true
            ? nil
            : trimmedHaplotypeAssayID
        let trimmedHaplotypeSpeciesCode = haplotypeSpeciesCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.haplotypeSpeciesCode = trimmedHaplotypeSpeciesCode?.isEmpty == true
            ? nil
            : trimmedHaplotypeSpeciesCode
        self.haplotypeDefinitionScope = haplotypeDefinitionScope
        let trimmedHaplotypeDefinitionSetID = haplotypeDefinitionSetID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.haplotypeDefinitionSetID = trimmedHaplotypeDefinitionSetID?.isEmpty == true
            ? nil
            : trimmedHaplotypeDefinitionSetID
        let trimmedPresetID = presetID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.presetID = trimmedPresetID?.isEmpty == true ? nil : trimmedPresetID
        let trimmedPresetVersion = presetVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.presetVersion = trimmedPresetVersion?.isEmpty == true ? nil : trimmedPresetVersion
        let trimmedLockedReferenceSHA256 = lockedReferenceSHA256?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lockedReferenceSHA256 = trimmedLockedReferenceSHA256?.isEmpty == true
            ? nil
            : trimmedLockedReferenceSHA256
        self.extraArguments = extraArguments
        self.mode = effectiveMode
        self.readType = effectiveReadType
        let trimmedAISpecialistPresetID = aiSpecialistPresetID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.aiSpecialistPresetID = trimmedAISpecialistPresetID?.isEmpty == true ? nil : trimmedAISpecialistPresetID
    }

    public func replacingOutput(
        outputDirectory: URL,
        outputName: String,
        analysisName: String
    ) -> ONTBarcodeDemuxGenotypingRunRequest {
        ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: inputFASTQURLs,
            referenceSourceURL: referenceSourceURL,
            barcodeDefinitionsURL: barcodeDefinitionsURL,
            outputDirectory: outputDirectory,
            outputName: outputName,
            demuxManifestURL: demuxManifestURL,
            analysisName: analysisName,
            comparisonWorkbookURL: comparisonWorkbookURL,
            comparisonName: comparisonName,
            projectURL: projectURL,
            threads: threads,
            sortThreads: sortThreads,
            minSupport: minSupport,
            haplotypeDropoutSampleFraction: haplotypeDropoutSampleFraction,
            haplotypeDropoutLocusFraction: haplotypeDropoutLocusFraction,
            haplotypeDropoutLocusFractionOverrides: haplotypeDropoutLocusFractionOverrides,
            haplotypeAssayID: haplotypeAssayID,
            haplotypeSpeciesCode: haplotypeSpeciesCode,
            haplotypeDefinitionScope: haplotypeDefinitionScope,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            presetID: presetID,
            presetVersion: presetVersion,
            lockedReferenceSHA256: lockedReferenceSHA256,
            extraArguments: extraArguments,
            mode: mode,
            readType: readType,
            aiSpecialistPresetID: aiSpecialistPresetID
        )
    }

    private static func effectiveMode(
        requestedMode: AmpliconGenotypingMode,
        readType: AmpliconGenotypingReadType,
        barcodeDefinitionsURL: URL?
    ) -> AmpliconGenotypingMode {
        if requestedMode == .ontSampleBundles {
            return .ontSampleBundles
        }
        switch readType {
        case .ont:
            return .ontBarcodeDemux
        case .illumina:
            return .illuminaPaired
        case .auto:
            if requestedMode == .auto, barcodeDefinitionsURL != nil {
                return .ontBarcodeDemux
            }
            return requestedMode
        }
    }

    private static func effectiveReadType(
        requestedReadType: AmpliconGenotypingReadType,
        mode: AmpliconGenotypingMode
    ) -> AmpliconGenotypingReadType {
        if requestedReadType != .auto {
            return requestedReadType
        }
        switch mode {
        case .ontBarcodeDemux, .ontSampleBundles:
            return .ont
        case .illuminaPaired:
            return .illumina
        case .auto:
            return .auto
        }
    }

    private static func normalizedFraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return min(value, 1.0)
    }

    private static func normalizedFractionOverrides(_ values: [String: Double]) -> [String: Double] {
        var normalized: [String: Double] = [:]
        for (key, value) in values {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let fraction = normalizedFraction(value) else { continue }
            normalized[trimmed] = fraction
        }
        return normalized
    }

    public var haplotypeDropoutEvaluator: GenotypeDropoutEvaluator? {
        guard minSupport > 1
                || haplotypeDropoutSampleFraction != nil
                || haplotypeDropoutLocusFraction != nil
                || !haplotypeDropoutLocusFractionOverrides.isEmpty else {
            return nil
        }
        return GenotypeDropoutEvaluator(
            absolute: minSupport,
            sampleFraction: haplotypeDropoutSampleFraction,
            locusFraction: haplotypeDropoutLocusFraction,
            locusFractionOverrides: haplotypeDropoutLocusFractionOverrides
        )
    }

    public var mappingBAMURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).md.sorted.bam")
    }

    public var mappingBAIURL: URL {
        mappingBAMURL.appendingPathExtension("bai")
    }

    public var retainedBAMURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).retained.demuxed.bam")
    }

    public var retainedBAIURL: URL {
        retainedBAMURL.appendingPathExtension("bai")
    }

    public var reportCSVURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).retained-demux-genotypes.csv")
    }

    public var sampleSummaryCSVURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).retained-demux-samples.csv")
    }

    public var statsJSONURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).retained-demux-stats.json")
    }

    public var haplotypeAnalysisURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).haplotype-analysis.json")
    }

    public var currentHaplotypeAnalysisURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).current-haplotype-analysis.json")
    }

    public var reportProvenanceURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).report-workbook-provenance.json")
    }

    public var provenanceURL: URL {
        outputDirectory.appendingPathComponent("retained-demux-genotyping-provenance.json")
    }

    public var workbookURL: URL {
        let comparisonSuffix = comparisonName.map { "_vs_\($0)" } ?? ""
        let analysisSuffix = analysisName == outputName ? "" : "_\(analysisName)"
        return outputDirectory.appendingPathComponent("\(outputName)\(analysisSuffix)\(comparisonSuffix).xlsx")
    }

    public var currentWorkbookURL: URL {
        outputDirectory
            .appendingPathComponent("artifacts/workbooks", isDirectory: true)
            .appendingPathComponent("current.xlsx")
    }

    public var currentWorkbookProvenanceURL: URL {
        outputDirectory
            .appendingPathComponent("artifacts/workbooks", isDirectory: true)
            .appendingPathComponent("current-workbook-provenance.json")
    }

    public var specialistPromptSnapshotURL: URL {
        outputDirectory
            .appendingPathComponent("artifacts/ai-haplotyping/prompts", isDirectory: true)
            .appendingPathComponent("mcm-mhc-haplotyping-specialist-prompt.md")
    }

    public var cliSubcommand: String {
        let ontSampleBundleCohort = barcodeDefinitionsURL == nil && mode == .ontSampleBundles
        let illuminaCohort = inputFASTQURLs.count > 1
            && barcodeDefinitionsURL == nil
            && (mode == .illuminaPaired || (mode == .auto && readType == .illumina))
        return ontSampleBundleCohort || illuminaCohort ? "genotype-cohort" : "genotype"
    }

    public var argv: [String] {
        var values = [
            CLICommandIdentity.executableName,
            "fastq",
            cliSubcommand,
        ] + inputFASTQURLs.map(\.path) + [
            "--mode", mode.cliArgument,
            "--read-type", readType.cliArgument,
            "--output-dir", outputDirectory.path,
            "--output-name", outputName,
            "--threads", String(threads),
            "--sort-threads", String(sortThreads),
            "--min-support", String(minSupport),
            "--analysis-name", analysisName,
        ]
        if let presetID {
            values += ["--preset", presetID]
        } else {
            values += ["--reference", referenceSourceURL.path]
        }
        appendHaplotypeThresholdArguments(to: &values)
        if let barcodeDefinitionsURL {
            values += ["--barcodes", barcodeDefinitionsURL.path]
        }
        if let haplotypeDefinitionSetID {
            if let haplotypeAssayID {
                values += ["--haplotype-assay", haplotypeAssayID]
            }
            if let haplotypeSpeciesCode {
                values += ["--haplotype-species", haplotypeSpeciesCode]
            }
            if let haplotypeDefinitionScope {
                values += ["--haplotype-definition-scope", haplotypeDefinitionScope.rawValue]
            }
            values += ["--haplotype-definition", haplotypeDefinitionSetID]
        }
        if let demuxManifestURL {
            values += ["--demux-manifest", demuxManifestURL.path]
        }
        if let comparisonWorkbookURL {
            values += ["--comparison-workbook", comparisonWorkbookURL.path]
        }
        if let comparisonName {
            values += ["--comparison-name", comparisonName]
        }
        if let projectURL {
            values += ["--project", projectURL.path]
        }
        if !extraArguments.isEmpty {
            values += ["--extra-args", AdvancedCommandLineOptions.join(extraArguments)]
        }
        return values
    }

    public func appendHaplotypeThresholdArguments(to values: inout [String]) {
        if let haplotypeDropoutSampleFraction {
            values += [
                "--haplotype-min-sample-percent",
                Self.percentArgument(forFraction: haplotypeDropoutSampleFraction),
            ]
        }
        if let haplotypeDropoutLocusFraction {
            values += [
                "--haplotype-min-locus-percent",
                Self.percentArgument(forFraction: haplotypeDropoutLocusFraction),
            ]
        }
        for key in haplotypeDropoutLocusFractionOverrides.keys.sorted() {
            guard let fraction = haplotypeDropoutLocusFractionOverrides[key] else { continue }
            values += [
                "--haplotype-min-locus-percent-override",
                "\(key)=\(Self.percentArgument(forFraction: fraction))",
            ]
        }
    }

    private static func percentArgument(forFraction fraction: Double) -> String {
        String(format: "%g", fraction * 100.0)
    }

    private static func sanitizedOutputName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "amplicon-genotyping" : collapsed
    }

    private static func sanitizedReportLabel(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed.compactMap { character -> Character? in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            if character.isWhitespace {
                return nil
            }
            return "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? fallback : collapsed
    }
}

public struct ONTBarcodeDemuxGenotypingResult: Sendable, Codable, Equatable {
    public let outputDirectory: URL
    public let mappingBAMURL: URL
    public let mappingBAIURL: URL
    public let retainedBAMURL: URL
    public let retainedBAIURL: URL
    public let reportCSVURL: URL
    public let sampleSummaryCSVURL: URL
    public let statsJSONURL: URL
    public let haplotypeAnalysisURL: URL?
    public let workbookURL: URL
    public let reportProvenanceURL: URL
    public let provenanceURL: URL
    public let referenceFASTAURL: URL
    public let sourceReferenceBundleURL: URL?
    public let totalInputReads: Int
    public let retainedUniqueReads: Int
    public let retainedUniquePercentOfTotalReads: Double
    public let assignedUniqueRetainedReads: Int
    public let unassignedUniqueRetainedReads: Int
}

public enum ONTBarcodeDemuxGenotypingError: Error, LocalizedError, Sendable, Equatable {
    case missingInput(URL)
    case missingBarcodeDefinitions(URL)
    case missingBarcodeDefinitionsForONT
    case missingDemuxManifest(URL)
    case missingComparisonWorkbook(URL)
    case invalidReference(URL)
    case noFASTQSources(URL)
    case noInputFASTQs
    case unsupportedIlluminaInput(URL)
    case duplicateIlluminaSampleID(String)
    case duplicateIlluminaStagedFile(String)
    case ambiguousGenotypingMode
    case processFailed(tool: String, status: Int32, stderr: String)
    case filterFailed(status: Int32, stderr: String)
    case invalidFilterOutput(String)
    case invalidHaplotypeDefinition(String)
    case ambiguousHaplotypeDefinition(definitionID: String)
    case invalidHaplotypeDefinitionForAssay(definitionID: String, assayID: String)
    case lockedReferenceDigestMismatch(expected: String, actual: String)
    case reportFailed(status: Int32, stderr: String)
    case invalidReportOutput(String)

    public var errorDescription: String? {
        switch self {
        case .missingInput(let url):
            return "Input FASTQ bundle or file does not exist: \(url.path)"
        case .missingBarcodeDefinitions(let url):
            return "Barcode definitions file does not exist: \(url.path)"
        case .missingBarcodeDefinitionsForONT:
            return "ONT barcode-demux genotyping requires a barcode definition CSV/TSV file."
        case .missingDemuxManifest(let url):
            return "Demultiplex manifest does not exist: \(url.path)"
        case .missingComparisonWorkbook(let url):
            return "Comparison workbook does not exist: \(url.path)"
        case .invalidReference(let url):
            return "Reference source does not contain a readable FASTA payload: \(url.path)"
        case .noFASTQSources(let url):
            return "No constituent FASTQ files could be resolved from: \(url.path)"
        case .noInputFASTQs:
            return "No input FASTQ files could be resolved for genotyping."
        case .unsupportedIlluminaInput(let url):
            return "Illumina genotyping requires each input to be an already merged single-FASTQ sample bundle. Import paired R1/R2 reads with the Illumina Amplicon Merge recipe first: \(url.path)"
        case .duplicateIlluminaSampleID(let sampleID):
            return "Two Illumina input bundles resolved to the same sample identifier \(sampleID); rename the inputs so their sanitized names are distinct."
        case .duplicateIlluminaStagedFile(let filename):
            return "Two Illumina input bundles resolved to the same staged FASTQ filename \(filename); rename the inputs so their sanitized names are distinct."
        case .ambiguousGenotypingMode:
            return "Could not infer genotyping mode. Choose ONT barcode demux or Illumina sample bundles explicitly."
        case .processFailed(let tool, let status, let stderr):
            return "\(tool) failed with status \(status): \(stderr)"
        case .filterFailed(let status, let stderr):
            return "Retained-read demultiplex filter failed with status \(status): \(stderr)"
        case .invalidFilterOutput(let text):
            return "Retained-read demultiplex filter did not return valid JSON: \(text)"
        case .invalidHaplotypeDefinition(let id):
            return "Unknown haplotype definition set: \(id)"
        case .ambiguousHaplotypeDefinition(let definitionID):
            return "Haplotype definition set \(definitionID) exists in more than one assay; specify --haplotype-assay."
        case .invalidHaplotypeDefinitionForAssay(let definitionID, let assayID):
            return "Haplotype definition set \(definitionID) is not available for assay \(assayID)"
        case .lockedReferenceDigestMismatch(let expected, let actual):
            return "Locked preset reference digest mismatch: expected \(expected), observed \(actual)."
        case .reportFailed(let status, let stderr):
            return "ONT barcode genotype workbook report failed with status \(status): \(stderr)"
        case .invalidReportOutput(let text):
            return "ONT barcode genotype workbook report did not return valid JSON: \(text)"
        }
    }
}

public struct ONTBarcodeDemuxGenotypingPipeline: Sendable {
    private let condaManager: CondaManager
    private let referenceImporter: ReferenceBundleImportService

    public init(
        condaManager: CondaManager = .shared,
        referenceImporter: ReferenceBundleImportService = .shared
    ) {
        self.condaManager = condaManager
        self.referenceImporter = referenceImporter
    }

    public func run(
        _ request: ONTBarcodeDemuxGenotypingRunRequest,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ONTBarcodeDemuxGenotypingResult {
        let startedAt = Date()
        let resolvedMode = try resolveMode(for: request)
        let resolvedReadType = resolveReadType(for: request, mode: resolvedMode)
        progressHandler?(0.01, "Validating amplicon genotyping inputs.")
        for inputFASTQURL in request.inputFASTQURLs {
            guard FileManager.default.fileExists(atPath: inputFASTQURL.path) else {
                throw ONTBarcodeDemuxGenotypingError.missingInput(inputFASTQURL)
            }
        }
        if resolvedMode == .ontBarcodeDemux {
            guard let barcodeDefinitionsURL = request.barcodeDefinitionsURL else {
                throw ONTBarcodeDemuxGenotypingError.missingBarcodeDefinitionsForONT
            }
            guard FileManager.default.fileExists(atPath: barcodeDefinitionsURL.path) else {
                throw ONTBarcodeDemuxGenotypingError.missingBarcodeDefinitions(barcodeDefinitionsURL)
            }
        }
        if let comparisonWorkbookURL = request.comparisonWorkbookURL,
           !FileManager.default.fileExists(atPath: comparisonWorkbookURL.path) {
            throw ONTBarcodeDemuxGenotypingError.missingComparisonWorkbook(comparisonWorkbookURL)
        }
        _ = try resolveHaplotypeDefinitionSet(for: request)
        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        progressHandler?(0.04, "Preparing amplicon genotyping output workspace.")
        _ = try copySpecialistPromptSnapshotIfNeeded(for: request)
        let supportDirectory = request.outputDirectory
            .appendingPathComponent(".amplicon-genotyping", isDirectory: true)
        let scriptURL = supportDirectory.appendingPathComponent("filter-demux-retained-bam.py")
        try Self.writeFilterScript(to: scriptURL)
        let reportScriptURL = supportDirectory.appendingPathComponent("write-retained-demux-workbook.py")
        try Self.writeReportScript(to: reportScriptURL)

        progressHandler?(0.12, "Resolving reference and FASTQ inputs.")
        let reference = try await resolveReference(for: request)
        if let expectedSHA256 = request.lockedReferenceSHA256 {
            let actualSHA256 = try ProvenanceFileHasher.sha256(of: reference.referenceFASTAURL)
            guard actualSHA256 == expectedSHA256 else {
                throw ONTBarcodeDemuxGenotypingError.lockedReferenceDigestMismatch(
                    expected: expectedSHA256,
                    actual: actualSHA256
                )
            }
        }

        progressHandler?(0.18, "Resolving managed minimap2, samtools, pysam, and openpyxl tools.")
        let minimap2URL = try await condaManager.toolPath(name: "minimap2", environment: "minimap2")
        let samtoolsURL = try await condaManager.toolPath(name: "samtools", environment: "samtools")
        let pythonURL = try await condaManager.toolPath(name: "python", environment: "pysam")
        let reportPythonURL = try await condaManager.toolPath(name: "python", environment: "openpyxl")

        progressHandler?(0.22, "Preparing platform-specific read inputs.")
        let inputPlan = try await prepareInputPlan(
            request: request,
            resolvedMode: resolvedMode,
            supportDirectory: supportDirectory,
            pythonURL: pythonURL
        )
        let inputSnapshot = inputPlan.inputSnapshot
        let mappingInputFASTQURLs = inputPlan.mappingFASTQURLs
        guard !mappingInputFASTQURLs.isEmpty else {
            throw ONTBarcodeDemuxGenotypingError.noFASTQSources(request.inputFASTQURL)
        }

        progressHandler?(0.25, "Mapping amplicon reads with minimap2.")
        let mapping = try await runMapping(
            request: request,
            resolvedMode: resolvedMode,
            referenceFASTAURL: reference.referenceFASTAURL,
            inputFASTQURLs: mappingInputFASTQURLs,
            illuminaPreparation: inputPlan.illuminaPreparation,
            minimap2URL: minimap2URL,
            samtoolsURL: samtoolsURL
        )

        progressHandler?(0.58, "Filtering retained full-reference alignments and assigning samples.")
        let filter = try await runFilter(
            request: request,
            resolvedMode: resolvedMode,
            referenceFASTAURL: reference.referenceFASTAURL,
            barcodeDefinitionsURL: inputSnapshot.barcodeDefinitionsURL,
            demuxManifestURL: inputSnapshot.demuxManifestURL,
            requireBothEndSoftclips: inputPlan.illuminaPreparation?.requiresBothEndSoftclips
                ?? (resolvedMode == .ontBarcodeDemux),
            scriptURL: scriptURL,
            pythonURL: pythonURL
        )

        progressHandler?(0.76, "Writing retained-demux genotype summaries.")
        try copyFilterOutput(
            from: request.outputDirectory.appendingPathComponent("\(request.outputName).retained_demux_genotypes.csv"),
            to: request.reportCSVURL
        )
        try copyFilterOutput(
            from: request.outputDirectory.appendingPathComponent("\(request.outputName).retained_demux_samples.csv"),
            to: request.sampleSummaryCSVURL
        )
        try copyFilterOutput(
            from: request.outputDirectory.appendingPathComponent("\(request.outputName).retained_demux_stats.json"),
            to: request.statsJSONURL
        )

        progressHandler?(0.80, "Applying selected haplotype definition.")
        let haplotypeAnalysis = try writeHaplotypeAnalysisIfRequested(
            request: request,
            supportDirectory: supportDirectory,
            generatedAt: Date()
        )

        progressHandler?(0.84, "Writing Excel genotype workbook.")
        let report = try await runReport(
            request: request,
            referenceFASTAURL: reference.referenceFASTAURL,
            barcodeDefinitionsURL: inputSnapshot.barcodeDefinitionsURL,
            comparisonWorkbookURL: inputSnapshot.comparisonWorkbookURL,
            haplotypeAnalysisURL: haplotypeAnalysis == nil ? nil : request.haplotypeAnalysisURL,
            reportScriptURL: reportScriptURL,
            pythonURL: reportPythonURL
        )

        let workbookCopy = try await createInitialCurrentWorkbook(
            for: request,
            reportScriptURL: reportScriptURL,
            reportPythonURL: reportPythonURL,
            referenceFASTAURL: reference.referenceFASTAURL,
            barcodeDefinitionsURL: inputSnapshot.barcodeDefinitionsURL,
            haplotypeAnalysisURL: haplotypeAnalysis == nil ? nil : request.haplotypeAnalysisURL
        )
        let completedAt = Date()
        progressHandler?(0.93, "Writing reproducibility provenance and bundle manifest.")
        let provenanceURL = try writeProvenance(
            request: request,
            resolvedMode: resolvedMode,
            resolvedReadType: resolvedReadType,
            reference: reference,
            inputFASTQURLs: inputPlan.originalInputFASTQURLs,
            mappingInputFASTQURLs: mappingInputFASTQURLs,
            demuxManifestURL: inputPlan.manifestURL,
            inputSnapshot: inputSnapshot,
            illuminaPreparation: inputPlan.illuminaPreparation,
            scriptURL: scriptURL,
            reportScriptURL: reportScriptURL,
            minimap2URL: minimap2URL,
            samtoolsURL: samtoolsURL,
            pythonURL: pythonURL,
            reportPythonURL: reportPythonURL,
            mapping: mapping,
            filter: filter,
            report: report,
            workbookCopy: workbookCopy,
            haplotypeAnalysis: haplotypeAnalysis,
            startedAt: startedAt,
            completedAt: completedAt
        )
        try writeBundleManifest(
            request: request,
            resolvedMode: resolvedMode,
            provenanceURL: provenanceURL,
            workbookRevision: workbookCopy.revision,
            completedAt: completedAt
        )
        progressHandler?(0.97, "Removing regenerable alignment intermediates.")
        try removeGeneratedAlignmentIntermediates(for: request, mapping: mapping)
        progressHandler?(0.98, "Finalizing amplicon genotyping outputs.")

        return ONTBarcodeDemuxGenotypingResult(
            outputDirectory: request.outputDirectory,
            mappingBAMURL: request.mappingBAMURL,
            mappingBAIURL: request.mappingBAIURL,
            retainedBAMURL: request.retainedBAMURL,
            retainedBAIURL: request.retainedBAIURL,
            reportCSVURL: request.reportCSVURL,
            sampleSummaryCSVURL: request.sampleSummaryCSVURL,
            statsJSONURL: request.statsJSONURL,
            haplotypeAnalysisURL: haplotypeAnalysis == nil ? nil : request.haplotypeAnalysisURL,
            workbookURL: request.currentWorkbookURL,
            reportProvenanceURL: request.reportProvenanceURL,
            provenanceURL: provenanceURL,
            referenceFASTAURL: reference.referenceFASTAURL,
            sourceReferenceBundleURL: reference.sourceReferenceBundleURL,
            totalInputReads: filter.stats.totalInputReads,
            retainedUniqueReads: filter.stats.retainedUniqueReads,
            retainedUniquePercentOfTotalReads: filter.stats.retainedUniquePercentOfTotalReads,
            assignedUniqueRetainedReads: filter.stats.assignedUniqueRetainedReads,
            unassignedUniqueRetainedReads: filter.stats.unassignedUniqueRetainedReads
        )
    }

    public static func resolveInputFASTQURLs(for inputURL: URL) throws -> [URL] {
        let standardized = inputURL.standardizedFileURL
        if FASTQBundle.isFASTQFileURL(standardized) {
            return [standardized]
        }
        guard FASTQBundle.isBundleURL(standardized) else {
            if Self.urlIsDirectory(standardized) {
                return Self.resolveRawFASTQDirectoryURLs(for: standardized)
            }
            return FASTQBundle.resolveAllFASTQURLs(for: standardized)?.map(\.standardizedFileURL) ?? []
        }
        if FASTQSourceFileManifest.exists(in: standardized) {
            let manifest = try FASTQSourceFileManifest.load(from: standardized)
            return manifest.files.compactMap { entry in
                if let bundleRelativeURL = try? FASTQBundle.validatedBundleMemberURL(
                    for: entry.filename,
                    in: standardized,
                    field: "source-files[].filename",
                    allowExistingSymlinkEscape: true
                ), FileManager.default.fileExists(atPath: bundleRelativeURL.path) {
                    return bundleRelativeURL
                }
                let originalURL = URL(fileURLWithPath: entry.originalPath).standardizedFileURL
                if FileManager.default.fileExists(atPath: originalURL.path) {
                    return originalURL
                }
                return nil
            }
        }
        return FASTQBundle.resolveAllFASTQURLs(for: standardized)?.map(\.standardizedFileURL) ?? []
    }

    private static func urlIsDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func resolveRawFASTQDirectoryURLs(for directoryURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasPrefix("._") {
                continue
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                if url.pathExtension.lowercased() == FASTQBundle.directoryExtension {
                    enumerator.skipDescendants()
                }
                continue
            }
            if FASTQBundle.isFASTQFileURL(url) {
                urls.append(url.standardizedFileURL)
            }
        }
        return urls.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private struct ReferenceResolution {
        let referenceFASTAURL: URL
        let sourceReferenceBundleURL: URL?
    }

    private struct SmallInputSnapshot {
        let barcodeDefinitionsURL: URL
        let demuxManifestURL: URL
        let comparisonWorkbookURL: URL?
        let stagedInputURLs: [URL]
    }

    private struct InputPlan {
        let mappingFASTQURLs: [URL]
        let originalInputFASTQURLs: [URL]
        let manifestURL: URL
        let inputSnapshot: SmallInputSnapshot
        let illuminaPreparation: IlluminaPreparation?
    }

    struct IlluminaSampleInput {
        let sampleID: String
        let sourceURL: URL
        let fastqURL: URL
        let prefixedFASTQURL: URL
        let readCount: Int
        let readCountSource: String
    }

    private struct IlluminaPreparation {
        let mode: AmpliconGenotypingMode
        let sampleManifestURL: URL
        let sampleDefinitionsURL: URL
        let samples: [IlluminaSampleInput]
        let sourceFASTQURLs: [URL]
        let mappingFASTQURLs: [URL]
        let requiresBothEndSoftclips: Bool
    }

    private struct MappingStepResult {
        let minimap2Arguments: [String]
        let samtoolsSortArguments: [String]
        let samtoolsMergeArguments: [String]?
        let samtoolsIndexArguments: [String]
        let minimap2Stderr: String
        let samtoolsSortStderr: String
        let samtoolsMergeStderr: String
        let samtoolsIndexStderr: String
        let wallClockSeconds: TimeInterval
        let invocations: [MappingInvocationResult]
        let transientBAMURLs: [URL]
    }

    private struct MappingInvocationResult {
        let inputFASTQURLs: [URL]
        let outputBAMURL: URL
        let minimap2Arguments: [String]
        let samtoolsSortArguments: [String]
        let minimap2Stderr: String
        let samtoolsSortStderr: String
        let wallClockSeconds: TimeInterval
    }

    private struct FilterStepResult {
        let arguments: [String]
        let stdout: String
        let stderr: String
        let wallClockSeconds: TimeInterval
        let stats: RetainedDemuxStats
    }

    private struct ReportStepResult {
        let arguments: [String]
        let stdout: String
        let stderr: String
        let wallClockSeconds: TimeInterval
        let summary: ReportSummary
    }

    private struct RetainedDemuxStats: Decodable {
        let totalInputReads: Int
        let totalAlignments: Int
        let passedAlignments: Int
        let retainedQueryNamesBeforeDemux: Int?
        let retainedUniqueReads: Int
        let retainedUniquePercentOfTotalReads: Double
        let assignedUniqueRetainedReads: Int
        let unassignedUniqueRetainedReads: Int
    }

    private struct ReportSummary: Decodable {
        let outputXLSX: String
        let provenanceJSON: String
        let openpyxlVersion: String
        let sheetNames: [String]
        let auditRows: Int
    }

    private struct WorkbookCopyResult {
        let revision: ONTGenotypeWorkbookRevision
        let toolName: String
        let toolVersion: String
        let arguments: [String]
        let stderr: String
        let exitStatus: Int32
        let creationMode: String
        let summary: ReportSummary?
        let provenanceURL: URL?
        let currentHaplotypeAnalysisURL: URL?
        let wallClockSeconds: TimeInterval
    }

    private func resolveMode(for request: ONTBarcodeDemuxGenotypingRunRequest) throws -> AmpliconGenotypingMode {
        switch request.mode {
        case .ontBarcodeDemux, .ontSampleBundles, .illuminaPaired:
            return request.mode
        case .auto:
            if request.readType == .ont {
                if request.barcodeDefinitionsURL == nil, request.inputFASTQURLs.count > 1 {
                    return .ontSampleBundles
                }
                return .ontBarcodeDemux
            }
            if request.readType == .illumina {
                return .illuminaPaired
            }
            if request.barcodeDefinitionsURL != nil {
                return .ontBarcodeDemux
            }
            if request.inputFASTQURLs.count > 1 {
                return .illuminaPaired
            }
            guard let first = request.inputFASTQURLs.first else {
                throw ONTBarcodeDemuxGenotypingError.ambiguousGenotypingMode
            }
            let inputFASTQURLs = try Self.resolveInputFASTQURLs(for: first)
            let detected = inputFASTQURLs.compactMap { LungfishIO.SequencingPlatform.detect(fromFASTQ: $0) }
            if detected.contains(.illumina) {
                return .illuminaPaired
            }
            if detected.contains(.oxfordNanopore) {
                return request.barcodeDefinitionsURL == nil && request.inputFASTQURLs.count > 1
                    ? .ontSampleBundles
                    : .ontBarcodeDemux
            }
            throw ONTBarcodeDemuxGenotypingError.ambiguousGenotypingMode
        }
    }

    private func resolveReadType(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        mode: AmpliconGenotypingMode
    ) -> AmpliconGenotypingReadType {
        if request.readType != .auto {
            return request.readType
        }
        switch mode {
        case .ontBarcodeDemux, .ontSampleBundles:
            return .ont
        case .illuminaPaired:
            return .illumina
        case .auto:
            return .auto
        }
    }

    private func prepareInputPlan(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        resolvedMode: AmpliconGenotypingMode,
        supportDirectory: URL,
        pythonURL: URL
    ) async throws -> InputPlan {
        switch resolvedMode {
        case .ontBarcodeDemux:
            let inputFASTQURLs = try request.inputFASTQURLs.flatMap { inputURL in
                try Self.resolveInputFASTQURLs(for: inputURL)
            }
            guard !inputFASTQURLs.isEmpty else {
                throw ONTBarcodeDemuxGenotypingError.noInputFASTQs
            }
            let demuxManifestURL = try await resolveOrSynthesizeDemuxManifest(
                for: request,
                inputFASTQURLs: inputFASTQURLs,
                supportDirectory: supportDirectory
            )
            let inputSnapshot = try snapshotSmallInputs(
                for: request,
                demuxManifestURL: demuxManifestURL,
                supportDirectory: supportDirectory
            )
            return InputPlan(
                mappingFASTQURLs: inputFASTQURLs,
                originalInputFASTQURLs: inputFASTQURLs,
                manifestURL: demuxManifestURL,
                inputSnapshot: inputSnapshot,
                illuminaPreparation: nil
            )

        case .illuminaPaired, .ontSampleBundles:
            let preparation = try await prepareIlluminaInputs(
                request: request,
                mode: resolvedMode,
                supportDirectory: supportDirectory,
                pythonURL: pythonURL
            )
            let comparisonSnapshotURL = try request.comparisonWorkbookURL.map { comparisonURL in
                try copyInputSnapshot(
                    sourceURL: comparisonURL,
                    destinationURL: supportDirectory
                        .appendingPathComponent("inputs", isDirectory: true)
                        .appendingPathComponent(
                            "comparison-workbook.\(comparisonURL.pathExtension.isEmpty ? "xlsx" : comparisonURL.pathExtension)"
                        )
                )
            }
            let snapshot = SmallInputSnapshot(
                barcodeDefinitionsURL: preparation.sampleDefinitionsURL,
                demuxManifestURL: preparation.sampleManifestURL,
                comparisonWorkbookURL: comparisonSnapshotURL,
                stagedInputURLs: [preparation.sampleDefinitionsURL, preparation.sampleManifestURL]
                    + (comparisonSnapshotURL.map { [$0] } ?? [])
            )
            return InputPlan(
                mappingFASTQURLs: preparation.mappingFASTQURLs,
                originalInputFASTQURLs: preparation.sourceFASTQURLs,
                manifestURL: preparation.sampleManifestURL,
                inputSnapshot: snapshot,
                illuminaPreparation: preparation
            )

        case .auto:
            throw ONTBarcodeDemuxGenotypingError.ambiguousGenotypingMode
        }
    }

    private static func mappingPreset(for mode: AmpliconGenotypingMode) -> String {
        mode == .illuminaPaired ? "sr" : "map-ont"
    }

    private static func mappingPlatform(for mode: AmpliconGenotypingMode) -> String {
        mode == .illuminaPaired ? "ILLUMINA" : "ONT"
    }

    private static func workflowName(for mode: AmpliconGenotypingMode) -> String {
        switch mode {
        case .illuminaPaired:
            return "Illumina Paired Amplicon Genotyping"
        case .ontSampleBundles:
            return "ONT Sample Bundle Amplicon Genotyping"
        case .ontBarcodeDemux, .auto:
            return "ONT Barcode Demux Genotyping"
        }
    }

    private static func analysisToolName(for mode: AmpliconGenotypingMode) -> String {
        switch mode {
        case .illuminaPaired:
            return "illumina-amplicon-genotyping"
        case .ontSampleBundles:
            return "ont-sample-bundle-genotyping"
        case .ontBarcodeDemux, .auto:
            return "ont-genotyping"
        }
    }

    private func prepareIlluminaInputs(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        mode: AmpliconGenotypingMode,
        supportDirectory: URL,
        pythonURL: URL
    ) async throws -> IlluminaPreparation {
        let inputsDirectory = supportDirectory.appendingPathComponent("inputs", isDirectory: true)
        let isONTSampleBundles = mode == .ontSampleBundles
        let stagedDirectory = supportDirectory.appendingPathComponent(
            isONTSampleBundles ? "ont-sample-fastqs" : "illumina-sample-fastqs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: inputsDirectory, withIntermediateDirectories: true)

        let samples = try await Self.resolveIlluminaSampleInputs(
            from: request.inputFASTQURLs,
            stagingDirectory: stagedDirectory
        )
        _ = pythonURL
        let requiresBothEndSoftclips = isONTSampleBundles
            && samples.allSatisfy { Self.sampleInputRetainsFullReadContext($0.sourceURL) }

        let sampleDefinitionsURL = inputsDirectory.appendingPathComponent(
            isONTSampleBundles ? "ont-sample-bundle-definitions.csv" : "illumina-sample-definitions.csv"
        )
        let sampleDefinitionRows = ["sample,barcode"]
            + samples.map { "\($0.sampleID),\(isONTSampleBundles ? "ONT_SAMPLE" : "ILLUMINA_SAMPLE")" }
        try (sampleDefinitionRows.joined(separator: "\n") + "\n")
            .write(to: sampleDefinitionsURL, atomically: true, encoding: .utf8)

        let sampleManifestURL = inputsDirectory.appendingPathComponent(
            isONTSampleBundles ? "ont-sample-bundle-manifest.json" : "illumina-sample-manifest.json"
        )
        let sampleItems = samples.map { sample -> [String: Any] in
            [
                "sample": sample.sampleID,
                "inputBundle": sample.sourceURL.path,
                "fastq": sample.fastqURL.path,
                "mappingInput": "stdin-sample-prefixed-fastq",
                "mappingInputLabel": sample.prefixedFASTQURL.lastPathComponent,
                "readCount": sample.readCount,
                "readCountSource": sample.readCountSource,
                "retainsFullReadContext": isONTSampleBundles
                    ? Self.sampleInputRetainsFullReadContext(sample.sourceURL)
                    : false,
            ]
        }
        let manifest: [String: Any] = [
            "mode": mode.rawValue,
            "inputReadCount": samples.reduce(0) { $0 + $1.readCount },
            "requiresBothEndSoftclips": requiresBothEndSoftclips,
            "samples": sampleItems,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: sampleManifestURL, options: .atomic)

        return IlluminaPreparation(
            mode: mode,
            sampleManifestURL: sampleManifestURL,
            sampleDefinitionsURL: sampleDefinitionsURL,
            samples: samples,
            sourceFASTQURLs: samples.map(\.fastqURL),
            mappingFASTQURLs: samples.map(\.fastqURL),
            requiresBothEndSoftclips: requiresBothEndSoftclips
        )
    }

    private static func sampleInputRetainsFullReadContext(_ url: URL) -> Bool {
        guard FASTQBundle.isBundleURL(url),
              let manifest = FASTQBundle.loadDerivedManifest(in: url) else {
            return true
        }
        let filename = manifest.rootFASTQFilename.lowercased()
        if filename.contains("deduplicated-amplicons") {
            return false
        }
        if let notes = manifest.provenance?.notes?.lowercased(),
           notes.contains("cs1-cs2") || notes.contains("insert exemplar") {
            return false
        }
        return true
    }

    private static func resolveIlluminaSampleInputs(
        from urls: [URL],
        stagingDirectory: URL
    ) async throws -> [IlluminaSampleInput] {
        var samples: [IlluminaSampleInput] = []
        var assignedIDs = Set<String>()
        var assignedStems = Set<String>()
        for url in urls.map(\.standardizedFileURL) {
            let rawDirectoryInput = Self.urlIsDirectory(url) && !FASTQBundle.isBundleURL(url)
            let resolvedFASTQs: [URL]
            if FASTQBundle.isFASTQFileURL(url) {
                resolvedFASTQs = [url]
            } else if FASTQBundle.isBundleURL(url) {
                resolvedFASTQs = try Self.resolveInputFASTQURLs(for: url)
            } else if rawDirectoryInput {
                resolvedFASTQs = Self.resolveRawFASTQDirectoryURLs(for: url)
            } else {
                throw ONTBarcodeDemuxGenotypingError.unsupportedIlluminaInput(url)
            }
            guard !resolvedFASTQs.isEmpty else {
                throw ONTBarcodeDemuxGenotypingError.unsupportedIlluminaInput(url)
            }
            if !rawDirectoryInput, resolvedFASTQs.count != 1 {
                throw ONTBarcodeDemuxGenotypingError.unsupportedIlluminaInput(url)
            }
            for fastqURL in resolvedFASTQs {
                let sourceURL = rawDirectoryInput ? fastqURL : url
                let baseID = sampleID(from: sourceURL)
                let sampleID = Self.disambiguatedSampleID(baseID, existing: assignedIDs)
                assignedIDs.insert(sampleID)
                // The staged filename must be disambiguated independently of `sampleID`:
                // `safeFilenameStem` collapses runs of "-" (and folds other punctuation to
                // "-"), so two distinct sample IDs can still map to an identical stem (e.g.
                // "Sample-1" and "Sample--1" both yield "Sample-1"). Reusing the same numeric
                // suffix scheme keeps stems unique so one staged FASTQ never overwrites another.
                let stem = Self.disambiguatedSampleID(safeFilenameStem(sampleID), existing: assignedStems)
                assignedStems.insert(stem)
                let prefixedFASTQURL = stagingDirectory
                    .appendingPathComponent("\(stem).sample-prefixed.fastq")
                // Reads stay tagged by the unique `sampleID`; only the filename derives from `stem`.
                let readCount = try await countWeightedFASTQRecords(in: fastqURL)
                let effectiveReadCount = Self.importedSampleReadCount(
                    sourceURL: sourceURL,
                    fastqURL: fastqURL
                )
                samples.append(IlluminaSampleInput(
                    sampleID: sampleID,
                    sourceURL: sourceURL.standardizedFileURL,
                    fastqURL: fastqURL.standardizedFileURL,
                    prefixedFASTQURL: prefixedFASTQURL.standardizedFileURL,
                    readCount: effectiveReadCount?.count ?? readCount,
                    readCountSource: effectiveReadCount?.source ?? "fastq-weighted-record-count"
                ))
            }
        }
        // Defense-in-depth: the disambiguation above guarantees uniqueness, but verify
        // both the sample IDs and the staged filenames before returning so a regression
        // surfaces as a clear error rather than silent data loss.
        let ids = samples.map(\.sampleID)
        let firstDuplicateID = ids.first { id in ids.filter { $0 == id }.count > 1 }
        guard firstDuplicateID == nil else {
            throw ONTBarcodeDemuxGenotypingError.duplicateIlluminaSampleID(firstDuplicateID ?? "")
        }
        let stagedURLs = samples.map(\.prefixedFASTQURL)
        if Set(stagedURLs).count != samples.count {
            let firstDuplicateFile = stagedURLs.first { url in stagedURLs.filter { $0 == url }.count > 1 }
            throw ONTBarcodeDemuxGenotypingError.duplicateIlluminaStagedFile(
                firstDuplicateFile?.lastPathComponent ?? ""
            )
        }
        return samples
    }

    private static func importedSampleReadCount(sourceURL: URL, fastqURL: URL) -> (count: Int, source: String)? {
        if let readCount = parentRecipeManifestReadCount(for: sourceURL) {
            return (readCount, "parent-recipe-manifest-read-count")
        }
        if let readCount = parentRecipeManifestReadCount(for: fastqURL) {
            return (readCount, "parent-recipe-manifest-read-count")
        }
        if let bundleURL = enclosingFASTQBundleURL(for: sourceURL),
           let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL),
           manifest.cachedStatistics.readCount > 0 {
            return (manifest.cachedStatistics.readCount, "bundle-derived-manifest-cached-statistics")
        }
        if let metadata = FASTQMetadataStore.load(for: sourceURL),
           let readCount = metadata.computedStatistics?.readCount,
           readCount > 0 {
            return (readCount, "source-metadata-computed-statistics")
        }
        if sourceURL != fastqURL,
           let metadata = FASTQMetadataStore.load(for: fastqURL),
           let readCount = metadata.computedStatistics?.readCount,
           readCount > 0 {
            return (readCount, "fastq-metadata-computed-statistics")
        }
        return nil
    }

    private static func enclosingFASTQBundleURL(for url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        if FASTQBundle.isBundleURL(standardized) {
            return standardized
        }
        let parent = standardized.deletingLastPathComponent()
        if FASTQBundle.isBundleURL(parent) {
            return parent.standardizedFileURL
        }
        return nil
    }

    private static func parentRecipeManifestReadCount(for url: URL) -> Int? {
        guard let bundleURL = enclosingFASTQBundleURL(for: url) else { return nil }
        let parent = bundleURL.deletingLastPathComponent()
        let sampleID = bundleURL.deletingPathExtension().lastPathComponent
        let bundleName = bundleURL.lastPathComponent
        for filename in [
            ONTFluidigmAmpliconMaterializer.manifestFilename,
            ONTFluidigmSampleMaterializer.manifestFilename,
        ] {
            let manifestURL = parent.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: manifestURL),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let sampleTotals = payload["sampleTotals"] as? [String: Any],
               let count = positiveInt(sampleTotals[sampleID]) {
                return count
            }
            guard let samples = payload["samples"] as? [[String: Any]] else {
                continue
            }
            for sample in samples {
                let manifestSampleID = sample["sample"] as? String ?? sample["sampleID"] as? String
                let manifestBundle = sample["bundle"] as? String
                guard manifestSampleID == sampleID || manifestBundle == bundleName else {
                    continue
                }
                if let count = positiveInt(sample["readCount"]) {
                    return count
                }
                if let count = positiveInt(sample["totalPairs"]) {
                    return count
                }
                if let count = positiveInt(sample["mergedPairs"]) {
                    return count
                }
            }
        }
        return nil
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        switch value {
        case let int as Int where int > 0:
            return int
        case let double as Double where double > 0:
            return Int(double)
        case let string as String:
            guard let int = Int(string), int > 0 else { return nil }
            return int
        default:
            return nil
        }
    }

    /// Returns `base` when unused, otherwise the first `base-N` (N >= 2) not yet
    /// in `existing`, so two inputs that sanitize to the same ID stay distinct.
    private static func disambiguatedSampleID(_ base: String, existing: Set<String>) -> String {
        guard existing.contains(base) else { return base }
        var bump = 2
        var candidate = "\(base)-\(bump)"
        while existing.contains(candidate) {
            bump += 1
            candidate = "\(base)-\(bump)"
        }
        return candidate
    }

    /// Test seam exposing the private Illumina sample-input resolution so the
    /// disambiguation behavior can be exercised in isolation.
    static func resolveIlluminaSampleInputsForTesting(
        from urls: [URL],
        stagingDirectory: URL
    ) async throws -> [IlluminaSampleInput] {
        try await resolveIlluminaSampleInputs(from: urls, stagingDirectory: stagingDirectory)
    }

    private static func countWeightedFASTQRecords(in sourceURL: URL) async throws -> Int {
        let reader = FASTQReader(validateSequence: false)
        var count = 0
        for try await record in reader.records(from: sourceURL) {
            count += Self.readCountWeight(fromIdentifier: record.identifier, description: record.description)
        }
        return count
    }

    private static func writeSamplePrefixedFASTQStream(
        samples: [IlluminaSampleInput],
        to handle: FileHandle
    ) async throws -> Int {
        let reader = FASTQReader(validateSequence: false)
        var buffer = Data()
        let flushThreshold = 262_144
        var count = 0

        func flushIfNeeded(force: Bool = false) throws {
            guard !buffer.isEmpty, force || buffer.count >= flushThreshold else { return }
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }

        for sample in samples {
            for try await record in reader.records(from: sample.fastqURL) {
                let identifier = samplePrefixedIdentifier(for: record, sampleID: sample.sampleID)
                var text = "@\(identifier)"
                if let description = record.description {
                    text += " \(description)"
                }
                text += "\n\(record.sequence)\n+\n\(record.quality.toAscii())\n"
                buffer.append(Data(text.utf8))
                count += Self.readCountWeight(fromIdentifier: record.identifier, description: record.description)
                try flushIfNeeded()
            }
        }
        try flushIfNeeded(force: true)
        return count
    }

    private static func samplePrefixedIdentifier(for record: FASTQRecord, sampleID: String) -> String {
        var identifier = "\(sampleID)|\(record.identifier)"
        if readCountWeight(fromIdentifier: record.identifier, description: nil) == 1,
           let sizeToken = readCountWeightToken(in: record.description),
           !identifier.contains(sizeToken) {
            identifier += ";\(sizeToken)"
        }
        return identifier
    }

    private static func readCountWeightToken(in text: String?) -> String? {
        guard let text else { return nil }
        for token in text.split(whereSeparator: { $0 == ";" || $0 == " " || $0 == "\t" || $0 == "|" }) {
            guard token.hasPrefix("size="),
                  let value = Int(token.dropFirst("size=".count)),
                  value > 0 else {
                continue
            }
            return "size=\(value)"
        }
        return nil
    }

    private static func readCountWeight(fromIdentifier identifier: String, description: String?) -> Int {
        for text in [identifier, description].compactMap({ $0 }) {
            guard let token = readCountWeightToken(in: text),
                  let value = Int(token.dropFirst("size=".count)) else {
                continue
            }
            return value
        }
        return 1
    }

    private static func sampleID(from url: URL) -> String {
        let basename = url.deletingPathExtension().lastPathComponent
        let sanitized = basename.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        }
        let collapsed = String(sanitized)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        return collapsed.isEmpty ? "sample" : collapsed
    }

    private static func safeFilenameStem(_ value: String) -> String {
        let sanitized = value.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(sanitized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "sample" : collapsed
    }

    private func resolveDemuxManifest(for request: ONTBarcodeDemuxGenotypingRunRequest) throws -> URL {
        if let demuxManifestURL = request.demuxManifestURL {
            return demuxManifestURL
        }
        if FASTQBundle.isBundleURL(request.inputFASTQURL) {
            let candidate = request.inputFASTQURL.appendingPathComponent("demux-manifest.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let sibling = request.inputFASTQURL
            .deletingLastPathComponent()
            .appendingPathComponent("demux-manifest.json")
        return sibling
    }

    private func resolveOrSynthesizeDemuxManifest(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        inputFASTQURLs: [URL],
        supportDirectory: URL
    ) async throws -> URL {
        let demuxManifestURL = try resolveDemuxManifest(for: request)
        if FileManager.default.fileExists(atPath: demuxManifestURL.path) {
            return demuxManifestURL
        }
        if request.demuxManifestURL != nil {
            throw ONTBarcodeDemuxGenotypingError.missingDemuxManifest(demuxManifestURL)
        }
        return try await synthesizeDemuxManifest(
            for: request,
            inputFASTQURLs: inputFASTQURLs,
            supportDirectory: supportDirectory
        )
    }

    private func synthesizeDemuxManifest(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        inputFASTQURLs: [URL],
        supportDirectory: URL
    ) async throws -> URL {
        guard let barcodeDefinitionsURL = request.barcodeDefinitionsURL else {
            throw ONTBarcodeDemuxGenotypingError.missingBarcodeDefinitionsForONT
        }
        let inputsDirectory = supportDirectory.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputsDirectory, withIntermediateDirectories: true)
        let manifestURL = inputsDirectory.appendingPathComponent("demux-manifest.json")
        let readCount = try await Self.countFASTQRecords(in: inputFASTQURLs)
        let barcodes = try Self.barcodeSampleIDs(from: barcodeDefinitionsURL).map { sampleID in
            [
                "barcodeID": sampleID,
                "readCount": NSNull(),
            ] as [String: Any]
        }
        let payload: [String: Any] = [
            "inputReadCount": readCount,
            "barcodes": barcodes,
            "manifestSource": "synthesized-from-fastq-inputs",
            "sourceFASTQs": inputFASTQURLs.map(\.path),
            "barcodeDefinitions": barcodeDefinitionsURL.path,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
        return manifestURL
    }

    private static func countFASTQRecords(in urls: [URL]) async throws -> Int {
        let reader = FASTQReader(validateSequence: false)
        var count = 0
        for url in urls {
            for try await record in reader.records(from: url) {
                count += Self.readCountWeight(fromIdentifier: record.identifier, description: record.description)
            }
        }
        return count
    }

    private static func barcodeSampleIDs(from url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let delimiter: Character = text.prefix(2048).filter { $0 == "\t" }.count >= text.prefix(2048).filter { $0 == "," }.count
            ? "\t"
            : ","
        var seen = Set<String>()
        var sampleIDs: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let fields = parseDelimitedFields(String(rawLine), delimiter: delimiter)
            guard fields.count >= 2 else { continue }
            var sampleID = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if sampleID.unicodeScalars.first?.value == 0xfeff {
                sampleID.removeFirst()
            }
            guard !sampleID.isEmpty else { continue }
            if ["sample", "sample_id", "id", "barcodeid"].contains(sampleID.lowercased()) {
                continue
            }
            guard seen.insert(sampleID).inserted else { continue }
            sampleIDs.append(sampleID)
        }
        return sampleIDs
    }

    private static func parseDelimitedFields(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if inQuotes, next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    index = line.index(after: next)
                    continue
                }
                inQuotes.toggle()
            } else if character == delimiter, !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        fields.append(current)
        return fields
    }

    private func snapshotSmallInputs(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        demuxManifestURL: URL,
        supportDirectory: URL
    ) throws -> SmallInputSnapshot {
        let inputsDirectory = supportDirectory.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputsDirectory, withIntermediateDirectories: true)
        guard let barcodeDefinitionsURL = request.barcodeDefinitionsURL else {
            throw ONTBarcodeDemuxGenotypingError.missingBarcodeDefinitionsForONT
        }

        let barcodeSnapshotURL = try copyInputSnapshot(
            sourceURL: barcodeDefinitionsURL,
            destinationURL: inputsDirectory.appendingPathComponent(
                "barcode-definitions.\(barcodeDefinitionsURL.pathExtension.isEmpty ? "txt" : barcodeDefinitionsURL.pathExtension)"
            )
        )
        let demuxManifestSnapshotURL = try copyInputSnapshot(
            sourceURL: demuxManifestURL,
            destinationURL: inputsDirectory.appendingPathComponent("demux-manifest.json")
        )
        let comparisonSnapshotURL = try request.comparisonWorkbookURL.map { comparisonURL in
            try copyInputSnapshot(
                sourceURL: comparisonURL,
                destinationURL: inputsDirectory.appendingPathComponent(
                    "comparison-workbook.\(comparisonURL.pathExtension.isEmpty ? "xlsx" : comparisonURL.pathExtension)"
                )
            )
        }
        return SmallInputSnapshot(
            barcodeDefinitionsURL: barcodeSnapshotURL,
            demuxManifestURL: demuxManifestSnapshotURL,
            comparisonWorkbookURL: comparisonSnapshotURL,
            stagedInputURLs: [barcodeSnapshotURL, demuxManifestSnapshotURL] + (comparisonSnapshotURL.map { [$0] } ?? [])
        )
    }

    private func copyInputSnapshot(sourceURL: URL, destinationURL: URL) throws -> URL {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        if source == destination {
            return destination
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func resolveReference(for request: ONTBarcodeDemuxGenotypingRunRequest) async throws -> ReferenceResolution {
        let sourceURL = request.referenceSourceURL
        if MHCAmpliconReferenceBundle.isBundleURL(sourceURL) {
            guard let fastaURL = MHCAmpliconReferenceBundle.referenceFASTAURL(in: sourceURL) else {
                throw ONTBarcodeDemuxGenotypingError.invalidReference(sourceURL)
            }
            return ReferenceResolution(referenceFASTAURL: fastaURL.standardizedFileURL, sourceReferenceBundleURL: sourceURL)
        }

        if sourceURL.pathExtension.lowercased() == "lungfishref" {
            guard let fastaURL = SequenceInputResolver.resolvePrimarySequenceURL(for: sourceURL),
                  SequenceInputResolver.inputSequenceFormat(for: sourceURL) == .fasta else {
                throw ONTBarcodeDemuxGenotypingError.invalidReference(sourceURL)
            }
            return ReferenceResolution(referenceFASTAURL: fastaURL.standardizedFileURL, sourceReferenceBundleURL: sourceURL)
        }

        if let projectURL = request.projectURL,
           ReferenceBundleImportService.isStandaloneReferenceSource(sourceURL),
           !Self.url(sourceURL, isContainedIn: projectURL) {
            let referenceDirectory = projectURL.appendingPathComponent("Reference Sequences", isDirectory: true)
            let importResult = try await referenceImporter.importAsReferenceBundle(
                sourceURL: sourceURL,
                outputDirectory: referenceDirectory,
                preferredBundleName: sourceURL.deletingPathExtension().lastPathComponent
            )
            guard let fastaURL = SequenceInputResolver.resolvePrimarySequenceURL(for: importResult.bundleURL) else {
                throw ONTBarcodeDemuxGenotypingError.invalidReference(importResult.bundleURL)
            }
            return ReferenceResolution(referenceFASTAURL: fastaURL.standardizedFileURL, sourceReferenceBundleURL: importResult.bundleURL)
        }

        guard let fastaURL = SequenceInputResolver.resolvePrimarySequenceURL(for: sourceURL),
              (SequenceInputResolver.inputSequenceFormat(for: sourceURL) ?? SequenceFormat.from(url: fastaURL)) == .fasta else {
            throw ONTBarcodeDemuxGenotypingError.invalidReference(sourceURL)
        }
        return ReferenceResolution(
            referenceFASTAURL: fastaURL.standardizedFileURL,
            sourceReferenceBundleURL: MappingReferenceStager.enclosingReferenceBundleURL(for: sourceURL)
        )
    }

    private func runMapping(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        resolvedMode: AmpliconGenotypingMode,
        referenceFASTAURL: URL,
        inputFASTQURLs: [URL],
        illuminaPreparation: IlluminaPreparation?,
        minimap2URL: URL,
        samtoolsURL: URL
    ) async throws -> MappingStepResult {
        if let illuminaPreparation {
            return try await runSampleBundleMapping(
                request: request,
                resolvedMode: resolvedMode,
                referenceFASTAURL: referenceFASTAURL,
                preparation: illuminaPreparation,
                minimap2URL: minimap2URL,
                samtoolsURL: samtoolsURL
            )
        }

        let startedAt = Date()
        let invocation = try await runMappingInvocation(
            request: request,
            resolvedMode: resolvedMode,
            referenceFASTAURL: referenceFASTAURL,
            inputFASTQURLs: inputFASTQURLs,
            outputBAMURL: request.mappingBAMURL,
            minimap2URL: minimap2URL,
            samtoolsURL: samtoolsURL,
            stderrStem: request.outputName,
            readGroupID: request.outputName
        )
        let indexStderrURL = request.outputDirectory.appendingPathComponent("\(request.outputName).samtools-index.stderr.log")
        let indexArguments = ["index", request.mappingBAMURL.path]
        let indexStderr = try runSamtoolsIndex(
            samtoolsURL: samtoolsURL,
            arguments: indexArguments,
            stderrURL: indexStderrURL
        )

        return MappingStepResult(
            minimap2Arguments: invocation.minimap2Arguments,
            samtoolsSortArguments: invocation.samtoolsSortArguments,
            samtoolsMergeArguments: nil,
            samtoolsIndexArguments: indexArguments,
            minimap2Stderr: invocation.minimap2Stderr,
            samtoolsSortStderr: invocation.samtoolsSortStderr,
            samtoolsMergeStderr: "",
            samtoolsIndexStderr: indexStderr,
            wallClockSeconds: Date().timeIntervalSince(startedAt),
            invocations: [invocation],
            transientBAMURLs: []
        )
    }

    private func runSampleBundleMapping(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        resolvedMode: AmpliconGenotypingMode,
        referenceFASTAURL: URL,
        preparation: IlluminaPreparation,
        minimap2URL: URL,
        samtoolsURL: URL
    ) async throws -> MappingStepResult {
        let startedAt = Date()
        var invocations: [MappingInvocationResult] = []

        if resolvedMode == .illuminaPaired, preparation.samples.count > 1 {
            let mappingDirectory = request.outputDirectory
                .appendingPathComponent(".amplicon-genotyping", isDirectory: true)
                .appendingPathComponent("mapping", isDirectory: true)
            try FileManager.default.createDirectory(at: mappingDirectory, withIntermediateDirectories: true)

            for (index, sample) in preparation.samples.enumerated() {
                let stem = "\(String(format: "%03d", index + 1))-\(Self.safeFilenameStem(sample.sampleID))"
                let sampleBAMURL = mappingDirectory.appendingPathComponent("\(stem).sorted.bam")
                let invocation = try await runMappingInvocation(
                    request: request,
                    resolvedMode: resolvedMode,
                    referenceFASTAURL: referenceFASTAURL,
                    inputFASTQURLs: [sample.fastqURL],
                    streamedSampleInputs: [sample],
                    outputBAMURL: sampleBAMURL,
                    minimap2URL: minimap2URL,
                    samtoolsURL: samtoolsURL,
                    stderrStem: "\(request.outputName).\(stem)",
                    readGroupID: "\(request.outputName)-\(index + 1)"
                )
                invocations.append(invocation)
            }
        } else {
            let invocation = try await runMappingInvocation(
                request: request,
                resolvedMode: resolvedMode,
                referenceFASTAURL: referenceFASTAURL,
                inputFASTQURLs: preparation.sourceFASTQURLs,
                streamedSampleInputs: preparation.samples,
                outputBAMURL: request.mappingBAMURL,
                minimap2URL: minimap2URL,
                samtoolsURL: samtoolsURL,
                stderrStem: request.outputName,
                readGroupID: request.outputName
            )
            invocations.append(invocation)
        }

        let mergeArguments: [String]?
        let mergeStderr: String
        let transientBAMURLs: [URL]
        if resolvedMode == .illuminaPaired, preparation.samples.count > 1 {
            let mergeStderrURL = request.outputDirectory.appendingPathComponent("\(request.outputName).samtools-merge.stderr.log")
            let arguments = ["merge", "-f", request.mappingBAMURL.path] + invocations.map(\.outputBAMURL.path)
            mergeStderr = try runSamtoolsMerge(
                samtoolsURL: samtoolsURL,
                arguments: arguments,
                stderrURL: mergeStderrURL
            )
            mergeArguments = arguments
            transientBAMURLs = invocations.map(\.outputBAMURL)
        } else {
            mergeArguments = nil
            mergeStderr = ""
            transientBAMURLs = []
        }

        let indexStderrURL = request.outputDirectory.appendingPathComponent("\(request.outputName).samtools-index.stderr.log")
        let indexArguments = ["index", request.mappingBAMURL.path]
        let indexStderr = try runSamtoolsIndex(
            samtoolsURL: samtoolsURL,
            arguments: indexArguments,
            stderrURL: indexStderrURL
        )

        return MappingStepResult(
            minimap2Arguments: invocations.first?.minimap2Arguments ?? [],
            samtoolsSortArguments: invocations.first?.samtoolsSortArguments ?? [],
            samtoolsMergeArguments: mergeArguments,
            samtoolsIndexArguments: indexArguments,
            minimap2Stderr: invocations.map(\.minimap2Stderr).joined(separator: "\n"),
            samtoolsSortStderr: invocations.map(\.samtoolsSortStderr).joined(separator: "\n"),
            samtoolsMergeStderr: mergeStderr,
            samtoolsIndexStderr: indexStderr,
            wallClockSeconds: Date().timeIntervalSince(startedAt),
            invocations: invocations,
            transientBAMURLs: transientBAMURLs
        )
    }

    private func runMappingInvocation(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        resolvedMode: AmpliconGenotypingMode,
        referenceFASTAURL: URL,
        inputFASTQURLs: [URL],
        streamedSampleInputs: [IlluminaSampleInput]? = nil,
        outputBAMURL: URL,
        minimap2URL: URL,
        samtoolsURL: URL,
        stderrStem: String,
        readGroupID: String
    ) async throws -> MappingInvocationResult {
        let minimap2StderrURL = request.outputDirectory.appendingPathComponent("\(stderrStem).minimap2.stderr.log")
        let sortStderrURL = request.outputDirectory.appendingPathComponent("\(stderrStem).samtools-sort.stderr.log")
        let mappingPreset = Self.mappingPreset(for: resolvedMode)
        let platform = Self.mappingPlatform(for: resolvedMode)
        let readGroup = "@RG\\tID:\(readGroupID)\\tSM:\(readGroupID)\\tLB:\(request.outputName)\\tPL:\(platform)\\tPU:\(readGroupID)"
        let queryArguments = streamedSampleInputs == nil ? inputFASTQURLs.map(\.path) : ["-"]
        let minimap2Arguments = [
            "-a",
            "-x", mappingPreset,
            "--MD",
            "-t", String(request.threads),
            "-R", readGroup,
        ] + request.extraArguments + [referenceFASTAURL.path] + queryArguments
        let sortArguments = [
            "sort",
            "-@", String(request.sortThreads),
            "-o", outputBAMURL.path,
            "-",
        ]
        let startedAt = Date()

        try FileManager.default.createDirectory(at: outputBAMURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stdoutPipe = Pipe()
        let stdinPipe = streamedSampleInputs == nil ? nil : Pipe()
        let minimap2 = Process()
        minimap2.executableURL = minimap2URL
        minimap2.arguments = minimap2Arguments
        minimap2.standardOutput = stdoutPipe
        if let stdinPipe {
            minimap2.standardInput = stdinPipe
        }
        minimap2.standardError = try fileHandleForWriting(to: minimap2StderrURL)

        let sort = Process()
        sort.executableURL = samtoolsURL
        sort.arguments = sortArguments
        sort.standardInput = stdoutPipe
        sort.standardError = try fileHandleForWriting(to: sortStderrURL)

        try sort.run()
        do {
            try minimap2.run()
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            sort.terminate()
            sort.waitUntilExit()
            throw error
        }
        stdoutPipe.fileHandleForWriting.closeFile()
        if let streamedSampleInputs, let stdinPipe {
            do {
                _ = try await Self.writeSamplePrefixedFASTQStream(
                    samples: streamedSampleInputs,
                    to: stdinPipe.fileHandleForWriting
                )
                try stdinPipe.fileHandleForWriting.close()
            } catch {
                try? stdinPipe.fileHandleForWriting.close()
                minimap2.terminate()
                sort.terminate()
                minimap2.waitUntilExit()
                sort.waitUntilExit()
                try? (minimap2.standardError as? FileHandle)?.close()
                try? (sort.standardError as? FileHandle)?.close()
                throw error
            }
        }
        minimap2.waitUntilExit()
        try? (minimap2.standardError as? FileHandle)?.close()
        sort.waitUntilExit()
        try? (sort.standardError as? FileHandle)?.close()

        let minimap2Stderr = (try? String(contentsOf: minimap2StderrURL, encoding: .utf8)) ?? ""
        let sortStderr = (try? String(contentsOf: sortStderrURL, encoding: .utf8)) ?? ""
        guard minimap2.terminationStatus == 0 else {
            throw ONTBarcodeDemuxGenotypingError.processFailed(
                tool: "minimap2",
                status: minimap2.terminationStatus,
                stderr: minimap2Stderr
            )
        }
        guard sort.terminationStatus == 0 else {
            throw ONTBarcodeDemuxGenotypingError.processFailed(
                tool: "samtools sort",
                status: sort.terminationStatus,
                stderr: sortStderr
            )
        }

        return MappingInvocationResult(
            inputFASTQURLs: inputFASTQURLs,
            outputBAMURL: outputBAMURL,
            minimap2Arguments: minimap2Arguments,
            samtoolsSortArguments: sortArguments,
            minimap2Stderr: minimap2Stderr,
            samtoolsSortStderr: sortStderr,
            wallClockSeconds: Date().timeIntervalSince(startedAt)
        )
    }

    private func runSamtoolsMerge(
        samtoolsURL: URL,
        arguments: [String],
        stderrURL: URL
    ) throws -> String {
        let merge = Process()
        merge.executableURL = samtoolsURL
        merge.arguments = arguments
        merge.standardError = try fileHandleForWriting(to: stderrURL)
        try merge.run()
        merge.waitUntilExit()
        try? (merge.standardError as? FileHandle)?.close()
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        guard merge.terminationStatus == 0 else {
            throw ONTBarcodeDemuxGenotypingError.processFailed(
                tool: "samtools merge",
                status: merge.terminationStatus,
                stderr: stderr
            )
        }
        return stderr
    }

    private func runSamtoolsIndex(
        samtoolsURL: URL,
        arguments: [String],
        stderrURL: URL
    ) throws -> String {
        let index = Process()
        index.executableURL = samtoolsURL
        index.arguments = arguments
        index.standardError = try fileHandleForWriting(to: stderrURL)
        try index.run()
        index.waitUntilExit()
        try? (index.standardError as? FileHandle)?.close()
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        guard index.terminationStatus == 0 else {
            throw ONTBarcodeDemuxGenotypingError.processFailed(
                tool: "samtools index",
                status: index.terminationStatus,
                stderr: stderr
            )
        }
        return stderr
    }

    private func runFilter(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        resolvedMode: AmpliconGenotypingMode,
        referenceFASTAURL: URL,
        barcodeDefinitionsURL: URL,
        demuxManifestURL: URL,
        requireBothEndSoftclips: Bool,
        scriptURL: URL,
        pythonURL: URL
    ) async throws -> FilterStepResult {
        var arguments = [
            scriptURL.path,
            "--input-bam", request.mappingBAMURL.path,
            "--reference-fasta", referenceFASTAURL.path,
            "--demux-manifest", demuxManifestURL.path,
            "--output-dir", request.outputDirectory.path,
            "--prefix", request.outputName,
            "--max-mismatches", "0",
            "--min-support", String(request.minSupport),
            "--provenance-command", request.argv.map(shellEscape).joined(separator: " "),
        ]
        request.appendHaplotypeThresholdArguments(to: &arguments)
        switch resolvedMode {
        case .ontBarcodeDemux:
            arguments += [
                "--assignment-mode", "barcode",
                "--barcodes", barcodeDefinitionsURL.path,
            ]
        case .illuminaPaired, .ontSampleBundles:
            arguments += [
                "--assignment-mode", "query-prefix",
                "--sample-manifest", demuxManifestURL.path,
            ]
        case .auto:
            break
        }
        if requireBothEndSoftclips {
            arguments.append("--require-both-end-softclips")
        }
        let startedAt = Date()
        let result = try await condaManager.runTool(
            name: pythonURL.lastPathComponent,
            arguments: arguments,
            environment: "pysam",
            workingDirectory: request.outputDirectory,
            timeout: 86_400
        )
        guard result.exitCode == 0 else {
            throw ONTBarcodeDemuxGenotypingError.filterFailed(status: result.exitCode, stderr: result.stderr)
        }
        guard let data = result.stdout.data(using: .utf8),
              let stats = try? JSONDecoder().decode(RetainedDemuxStats.self, from: data) else {
            throw ONTBarcodeDemuxGenotypingError.invalidFilterOutput(result.stdout)
        }
        return FilterStepResult(
            arguments: arguments,
            stdout: result.stdout,
            stderr: result.stderr,
            wallClockSeconds: Date().timeIntervalSince(startedAt),
            stats: stats
        )
    }

    private func runReport(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        referenceFASTAURL: URL,
        barcodeDefinitionsURL: URL,
        comparisonWorkbookURL: URL?,
        haplotypeAnalysisURL: URL?,
        reportScriptURL: URL,
        pythonURL: URL
    ) async throws -> ReportStepResult {
        var arguments = [
            reportScriptURL.path,
            "--genotypes-csv", request.reportCSVURL.path,
            "--samples-csv", request.sampleSummaryCSVURL.path,
            "--stats-json", request.statsJSONURL.path,
            "--reference-fasta", referenceFASTAURL.path,
            "--barcode-definitions", barcodeDefinitionsURL.path,
            "--output-xlsx", request.workbookURL.path,
            "--provenance-json", request.reportProvenanceURL.path,
            "--analysis-name", request.analysisName,
            "--run-name", request.outputName,
            "--provenance-command", request.argv.map(shellEscape).joined(separator: " "),
        ]
        if let comparisonWorkbookURL {
            arguments += ["--comparison-workbook", comparisonWorkbookURL.path]
        }
        if let comparisonName = request.comparisonName {
            arguments += ["--comparison-name", comparisonName]
        }
        if let haplotypeAnalysisURL {
            arguments += ["--haplotype-analysis-json", haplotypeAnalysisURL.path]
        }

        let startedAt = Date()
        let result = try await condaManager.runTool(
            name: pythonURL.lastPathComponent,
            arguments: arguments,
            environment: "openpyxl",
            workingDirectory: request.outputDirectory,
            timeout: 3_600
        )
        guard result.exitCode == 0 else {
            throw ONTBarcodeDemuxGenotypingError.reportFailed(status: result.exitCode, stderr: result.stderr)
        }
        guard let data = result.stdout.data(using: .utf8),
              let summary = try? JSONDecoder().decode(ReportSummary.self, from: data) else {
            throw ONTBarcodeDemuxGenotypingError.invalidReportOutput(result.stdout)
        }
        return ReportStepResult(
            arguments: arguments,
            stdout: result.stdout,
            stderr: result.stderr,
            wallClockSeconds: Date().timeIntervalSince(startedAt),
            summary: summary
        )
    }

    private func writeHaplotypeAnalysisIfRequested(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        supportDirectory: URL,
        generatedAt: Date
    ) throws -> GenotypeHaplotypeAnalysis? {
        guard let definitionSetID = request.haplotypeDefinitionSetID else {
            return nil
        }
        guard let definitionSet = try resolveHaplotypeDefinitionSet(for: request) else {
            throw ONTBarcodeDemuxGenotypingError.invalidHaplotypeDefinition(definitionSetID)
        }
        let assayID = definitionSet.assayID
        try writeHaplotypeDefinitionSnapshot(definitionSet, supportDirectory: supportDirectory)

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: request.outputName,
            analysisName: request.analysisName,
            primaryWorkbookPath: relativePath(from: request.outputDirectory, to: request.workbookURL),
            longSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.reportCSVURL),
            sampleSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.sampleSummaryCSVURL),
            statsJSONPath: relativePath(from: request.outputDirectory, to: request.statsJSONURL),
            provenancePath: relativePath(from: request.outputDirectory, to: request.provenanceURL),
            haplotypeDefinitionSetID: definitionSetID,
            haplotypeAssayID: assayID,
            presetID: request.presetID,
            presetVersion: request.presetVersion
        )
        let result = try ONTGenotypeResultBundle.loadResult(from: request.outputDirectory, manifest: manifest)
        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: result.calls,
            definitionSet: definitionSet,
            generatedAt: ISO8601DateFormatter().string(from: generatedAt),
            dropoutFilter: request.haplotypeDropoutEvaluator
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(analysis)
        try data.write(to: request.haplotypeAnalysisURL, options: .atomic)
        return analysis
    }

    private func resolveHaplotypeDefinitionSet(
        for request: ONTBarcodeDemuxGenotypingRunRequest
    ) throws -> GenotypeHaplotypeDefinitionSet? {
        guard let definitionSetID = request.haplotypeDefinitionSetID else {
            return nil
        }
        if let bundledDefinition = try bundledHaplotypeDefinitionSet(
            for: request,
            definitionSetID: definitionSetID
        ) {
            return bundledDefinition
        }
        if request.haplotypeSpeciesCode != nil || request.haplotypeDefinitionScope != nil {
            let matchingRecords = haplotypeDefinitionLibrary(for: request)
                .activeRecords(
                    assayID: request.haplotypeAssayID,
                    speciesCode: request.haplotypeSpeciesCode,
                    scope: request.haplotypeDefinitionScope
                )
                .filter { $0.definitionSet.id == definitionSetID }
            if matchingRecords.count == 1 {
                return matchingRecords[0].definitionSet
            }
            if matchingRecords.isEmpty {
                throw ONTBarcodeDemuxGenotypingError.invalidHaplotypeDefinition(definitionSetID)
            }
            throw ONTBarcodeDemuxGenotypingError.ambiguousHaplotypeDefinition(definitionID: definitionSetID)
        }
        let registry = haplotypeDefinitionRegistry(for: request)
        if let assayID = request.haplotypeAssayID {
            guard registry.assay(id: assayID) != nil else {
                throw ONTBarcodeDemuxGenotypingError.invalidHaplotypeDefinitionForAssay(
                    definitionID: definitionSetID,
                    assayID: assayID
                )
            }
            guard let definitionSet = registry.definitionSet(id: definitionSetID, assayID: assayID) else {
                if registry.definitionSet(id: definitionSetID) == nil {
                    throw ONTBarcodeDemuxGenotypingError.invalidHaplotypeDefinition(definitionSetID)
                }
                throw ONTBarcodeDemuxGenotypingError.invalidHaplotypeDefinitionForAssay(
                    definitionID: definitionSetID,
                    assayID: assayID
                )
            }
            return definitionSet
        }

        let matchingSets = registry.definitionSets(id: definitionSetID)
        if matchingSets.count == 1 {
            return matchingSets[0]
        }
        if matchingSets.isEmpty {
            throw ONTBarcodeDemuxGenotypingError.invalidHaplotypeDefinition(definitionSetID)
        }
        throw ONTBarcodeDemuxGenotypingError.ambiguousHaplotypeDefinition(definitionID: definitionSetID)
    }

    private func bundledHaplotypeDefinitionSet(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        definitionSetID: String
    ) throws -> GenotypeHaplotypeDefinitionSet? {
        guard MHCAmpliconReferenceBundle.isBundleURL(request.referenceSourceURL) else {
            return nil
        }
        return try MHCAmpliconReferenceBundle.haplotypeDefinition(
            id: definitionSetID,
            assayID: request.haplotypeAssayID,
            speciesCode: request.haplotypeSpeciesCode,
            in: request.referenceSourceURL
        )
    }

    private func haplotypeDefinitionRegistry(
        for request: ONTBarcodeDemuxGenotypingRunRequest
    ) -> GenotypeHaplotypeDefinitionRegistry {
        haplotypeDefinitionLibrary(for: request).mergedRegistry()
    }

    private func haplotypeDefinitionLibrary(
        for request: ONTBarcodeDemuxGenotypingRunRequest
    ) -> HaplotypeDefinitionLibrary {
        HaplotypeDefinitionLibrary(projectRoot: request.projectURL)
    }

    private func haplotypeDefinitionSnapshotURL(for request: ONTBarcodeDemuxGenotypingRunRequest) -> URL {
        request.outputDirectory
            .appendingPathComponent(".amplicon-genotyping", isDirectory: true)
            .appendingPathComponent("inputs", isDirectory: true)
            .appendingPathComponent("haplotype-definition.json")
    }

    private func copySpecialistPromptSnapshotIfNeeded(
        for request: ONTBarcodeDemuxGenotypingRunRequest
    ) throws -> URL? {
        guard let sourceURL = try specialistPromptSourceURL(for: request) else {
            return nil
        }
        let destinationURL = request.specialistPromptSnapshotURL
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func specialistPromptSourceURL(
        for request: ONTBarcodeDemuxGenotypingRunRequest
    ) throws -> URL? {
        guard let preset = MCMHaplotypingPreset.preset(id: request.presetID) else {
            return nil
        }
        return try preset.bundledSpecialistPromptURL()
    }

    private func specialistPromptSnapshotIfPresent(
        for request: ONTBarcodeDemuxGenotypingRunRequest
    ) -> URL? {
        let url = request.specialistPromptSnapshotURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func copyFilterOutput(from source: URL, to destination: URL) throws {
        guard source != destination else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    @discardableResult
    private func writeHaplotypeDefinitionSnapshot(
        _ definitionSet: GenotypeHaplotypeDefinitionSet,
        supportDirectory: URL
    ) throws -> URL {
        let inputsDirectory = supportDirectory.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputsDirectory, withIntermediateDirectories: true)
        let url = inputsDirectory.appendingPathComponent("haplotype-definition.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(definitionSet)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func shouldCreateMCMDecoratedCurrentWorkbook(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        haplotypeAnalysisURL: URL?
    ) throws -> Bool {
        guard haplotypeAnalysisURL != nil,
              let definitionSet = try resolveHaplotypeDefinitionSet(for: request) else {
            return false
        }
        return definitionSet.speciesCode.caseInsensitiveCompare("MCM") == .orderedSame
    }

    private func createInitialCurrentWorkbook(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        reportScriptURL: URL,
        reportPythonURL: URL,
        referenceFASTAURL: URL,
        barcodeDefinitionsURL: URL,
        haplotypeAnalysisURL: URL?
    ) async throws -> WorkbookCopyResult {
        if try shouldCreateMCMDecoratedCurrentWorkbook(for: request, haplotypeAnalysisURL: haplotypeAnalysisURL) {
            return try await createInitialDecoratedMCMCurrentWorkbook(
                for: request,
                reportScriptURL: reportScriptURL,
                reportPythonURL: reportPythonURL,
                referenceFASTAURL: referenceFASTAURL,
                barcodeDefinitionsURL: barcodeDefinitionsURL,
                haplotypeAnalysisURL: haplotypeAnalysisURL
            )
        }
        return try createInitialCurrentWorkbookCopy(for: request)
    }

    private func createInitialCurrentWorkbookCopy(
        for request: ONTBarcodeDemuxGenotypingRunRequest
    ) throws -> WorkbookCopyResult {
        let startedAt = Date()
        let destinationURL = request.currentWorkbookURL
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: request.workbookURL, to: destinationURL)
        let createdAt = Date()
        let revision = ONTGenotypeWorkbookRevision(
            id: "initial-current-copy",
            role: .initialCurrentCopy,
            path: relativePath(from: request.outputDirectory, to: destinationURL),
            label: "Initial editable workbook",
            sourceFilename: request.workbookURL.lastPathComponent,
            createdAt: ISO8601DateFormatter().string(from: createdAt),
            user: NSUserName(),
            predecessorPath: relativePath(from: request.outputDirectory, to: request.workbookURL),
            sha256: try ProvenanceFileHasher.sha256(of: destinationURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: destinationURL)),
            provenancePath: nil
        )
        return WorkbookCopyResult(
            revision: revision,
            toolName: "lungfish genotype workbook initial-current-copy",
            toolVersion: WorkflowRun.currentAppVersion,
            arguments: request.argv + ["--create-current-workbook", request.currentWorkbookURL.path],
            stderr: "",
            exitStatus: 0,
            creationMode: "copy",
            summary: nil,
            provenanceURL: nil,
            currentHaplotypeAnalysisURL: nil,
            wallClockSeconds: createdAt.timeIntervalSince(startedAt)
        )
    }

    private func createInitialDecoratedMCMCurrentWorkbook(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        reportScriptURL: URL,
        reportPythonURL: URL,
        referenceFASTAURL: URL,
        barcodeDefinitionsURL: URL,
        haplotypeAnalysisURL: URL?
    ) async throws -> WorkbookCopyResult {
        let startedAt = Date()
        let destinationURL = request.currentWorkbookURL
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        if FileManager.default.fileExists(atPath: request.currentWorkbookProvenanceURL.path) {
            try FileManager.default.removeItem(at: request.currentWorkbookProvenanceURL)
        }
        let currentHaplotypeAnalysisURL = try writeCurrentWorkbookHaplotypeAnalysis(
            for: request,
            generatedAt: startedAt
        )

        var arguments = [
            reportScriptURL.path,
            "--client-current-workbook",
            "--genotypes-csv", request.reportCSVURL.path,
            "--samples-csv", request.sampleSummaryCSVURL.path,
            "--stats-json", request.statsJSONURL.path,
            "--reference-fasta", referenceFASTAURL.path,
            "--barcode-definitions", barcodeDefinitionsURL.path,
            "--output-xlsx", destinationURL.path,
            "--provenance-json", request.currentWorkbookProvenanceURL.path,
            "--analysis-name", request.analysisName,
            "--run-name", request.outputName,
            "--primary-workbook", request.workbookURL.path,
            "--haplotype-definition-json", haplotypeDefinitionSnapshotURL(for: request).path,
            "--provenance-command",
            (request.argv + ["--create-current-workbook", destinationURL.path]).map(shellEscape).joined(separator: " "),
        ]
        if let currentHaplotypeAnalysisURL {
            arguments += ["--haplotype-analysis-json", currentHaplotypeAnalysisURL.path]
        } else if let haplotypeAnalysisURL {
            arguments += ["--haplotype-analysis-json", haplotypeAnalysisURL.path]
        }

        let result = try await condaManager.runTool(
            name: reportPythonURL.lastPathComponent,
            arguments: arguments,
            environment: "openpyxl",
            workingDirectory: request.outputDirectory,
            timeout: 3_600
        )
        guard result.exitCode == 0 else {
            throw ONTBarcodeDemuxGenotypingError.reportFailed(status: result.exitCode, stderr: result.stderr)
        }
        guard let data = result.stdout.data(using: .utf8),
              let summary = try? JSONDecoder().decode(ReportSummary.self, from: data) else {
            throw ONTBarcodeDemuxGenotypingError.invalidReportOutput(result.stdout)
        }

        let createdAt = Date()
        let revision = ONTGenotypeWorkbookRevision(
            id: "initial-current-copy",
            role: .initialCurrentCopy,
            path: relativePath(from: request.outputDirectory, to: destinationURL),
            label: "Initial decorated MCM current workbook",
            sourceFilename: request.workbookURL.lastPathComponent,
            createdAt: ISO8601DateFormatter().string(from: createdAt),
            user: NSUserName(),
            predecessorPath: relativePath(from: request.outputDirectory, to: request.workbookURL),
            sha256: try ProvenanceFileHasher.sha256(of: destinationURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: destinationURL)),
            provenancePath: relativePath(from: request.outputDirectory, to: request.currentWorkbookProvenanceURL)
        )
        return WorkbookCopyResult(
            revision: revision,
            toolName: "openpyxl MCM current workbook report",
            toolVersion: summary.openpyxlVersion,
            arguments: [reportPythonURL.path] + arguments,
            stderr: result.stderr,
            exitStatus: result.exitCode,
            creationMode: "mcm-client-current",
            summary: summary,
            provenanceURL: request.currentWorkbookProvenanceURL,
            currentHaplotypeAnalysisURL: currentHaplotypeAnalysisURL,
            wallClockSeconds: createdAt.timeIntervalSince(startedAt)
        )
    }

    private func writeCurrentWorkbookHaplotypeAnalysis(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        generatedAt: Date
    ) throws -> URL? {
        guard request.haplotypeDefinitionSetID != nil,
              let definitionSet = try resolveHaplotypeDefinitionSet(for: request) else {
            return nil
        }
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: request.outputName,
            analysisName: request.analysisName,
            primaryWorkbookPath: relativePath(from: request.outputDirectory, to: request.workbookURL),
            longSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.reportCSVURL),
            sampleSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.sampleSummaryCSVURL),
            statsJSONPath: relativePath(from: request.outputDirectory, to: request.statsJSONURL),
            provenancePath: relativePath(from: request.outputDirectory, to: request.provenanceURL),
            haplotypeDefinitionSetID: definitionSet.id,
            haplotypeAssayID: definitionSet.assayID,
            presetID: request.presetID,
            presetVersion: request.presetVersion
        )
        let result = try ONTGenotypeResultBundle.loadResult(from: request.outputDirectory, manifest: manifest)
        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: result.calls,
            definitionSet: definitionSet,
            generatedAt: ISO8601DateFormatter().string(from: generatedAt),
            dropoutFilter: request.haplotypeDropoutEvaluator
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(analysis).write(to: request.currentHaplotypeAnalysisURL, options: .atomic)
        return request.currentHaplotypeAnalysisURL
    }

    private func writeProvenance(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        resolvedMode: AmpliconGenotypingMode,
        resolvedReadType: AmpliconGenotypingReadType,
        reference: ReferenceResolution,
        inputFASTQURLs: [URL],
        mappingInputFASTQURLs: [URL],
        demuxManifestURL: URL,
        inputSnapshot: SmallInputSnapshot,
        illuminaPreparation: IlluminaPreparation?,
        scriptURL: URL,
        reportScriptURL: URL,
        minimap2URL: URL,
        samtoolsURL: URL,
        pythonURL: URL,
        reportPythonURL: URL,
        mapping: MappingStepResult,
        filter: FilterStepResult,
        report: ReportStepResult,
        workbookCopy: WorkbookCopyResult,
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?,
        startedAt: Date,
        completedAt: Date
    ) throws -> URL {
        let provenanceURL = request.outputDirectory.appendingPathComponent("retained-demux-genotyping-provenance.json")
        let inputs = inputFASTQURLs
            .map { fileDescriptorDictionary(url: $0, role: "input-fastq") }
        let mappingInputs = mappingInputFASTQURLs
            .map { fileDescriptorDictionary(url: $0, role: "mapping-fastq") }
        let comparisonInputs = request.comparisonWorkbookURL
            .map { [fileDescriptorDictionary(url: $0, role: "comparison")] } ?? []
        let stagedInputs = inputSnapshot.stagedInputURLs
            .map { fileDescriptorDictionary(url: $0, role: "staged-input") }
        let haplotypeOutputs = haplotypeAnalysis == nil
            ? []
            : [fileDescriptorDictionary(url: request.haplotypeAnalysisURL, role: "analysis")]
        let currentHaplotypeOutputs = workbookCopy.currentHaplotypeAnalysisURL
            .map { [fileDescriptorDictionary(url: $0, role: "current-haplotype-analysis")] } ?? []
        let resolvedHaplotypeDefinitionSet = try? resolveHaplotypeDefinitionSet(for: request)
        let haplotypeDefinitionSnapshotURL = self.haplotypeDefinitionSnapshotURL(for: request)
        let haplotypeDefinitionInputs = haplotypeAnalysis == nil
            ? []
            : [fileDescriptorDictionary(url: haplotypeDefinitionSnapshotURL, role: "haplotype-definition")]
        let haplotypeDefinitionSHA256 = (try? ProvenanceFileHasher.sha256(of: haplotypeDefinitionSnapshotURL)) as Any? ?? NSNull()
        let specialistPromptSourceURL = try specialistPromptSourceURL(for: request)
        let specialistPromptSnapshotURL = specialistPromptSnapshotIfPresent(for: request)
        let specialistPromptInputs = specialistPromptSourceURL
            .map { [fileDescriptorDictionary(url: $0, role: "bundled-specialist-prompt")] } ?? []
        let specialistPromptOutputs = specialistPromptSnapshotURL
            .map { [fileDescriptorDictionary(url: $0, role: "specialist-prompt")] } ?? []
        let specialistPromptPath = specialistPromptSnapshotURL
            .map { relativePath(from: request.outputDirectory, to: $0) } as Any? ?? NSNull()
        let specialistPromptSHA256 = specialistPromptSnapshotURL
            .flatMap { try? ProvenanceFileHasher.sha256(of: $0) } as Any? ?? NSNull()
        let haplotypeSteps: [[String: Any]] = haplotypeAnalysis.map { analysis in
            [[
                "toolName": "deterministic genotype haplotype assignment",
                "argv": haplotypeAssignmentArgv(for: request, resolvedAssayID: analysis.assayID),
                "definitionSetID": analysis.definitionSetID,
                "definitionSetName": analysis.definitionSetName,
                "assayID": analysis.assayID,
                "speciesName": analysis.speciesName,
                "definitionInput": haplotypeDefinitionSnapshotURL.path,
                "definitionSHA256": haplotypeDefinitionSHA256,
                "output": request.haplotypeAnalysisURL.path,
                "sampleCount": analysis.samples.count,
                "exitStatus": 0,
                "wallTimeSeconds": 0,
            ]]
        } ?? []
        let specialistPromptSteps: [[String: Any]] = specialistPromptSnapshotURL.map { outputURL in
            [[
                "toolName": "MCM specialist prompt snapshot",
                "argv": [
                    "copy",
                    specialistPromptSourceURL?.path ?? "",
                    outputURL.path,
                ],
                "input": specialistPromptSourceURL?.path as Any? ?? NSNull(),
                "output": outputURL.path,
                "sha256": specialistPromptSHA256,
                "exitStatus": 0,
                "wallTimeSeconds": 0,
            ]]
        } ?? []
        let currentHaplotypeSteps: [[String: Any]] = workbookCopy.currentHaplotypeAnalysisURL.map { url in
            [[
                "toolName": "deterministic genotype haplotype assignment",
                "argv": haplotypeAssignmentArgv(for: request, resolvedAssayID: haplotypeAnalysis?.assayID) + [
                    "--dropout-locus-fraction", "MHC-DQ=0.05",
                    "--dropout-locus-fraction", "MHC-DP=0.05",
                    "--output", url.path,
                ],
                "definitionInput": haplotypeDefinitionSnapshotURL.path,
                "definitionSHA256": haplotypeDefinitionSHA256,
                "output": url.path,
                "exitStatus": 0,
                "wallTimeSeconds": 0,
            ]]
        } ?? []
        let sampleBundleInputPreparation: Any = illuminaPreparation.map { preparation in
            [
                "mode": preparation.mode.rawValue,
                "sourceFASTQs": preparation.sourceFASTQURLs.map(\.path),
                "mappingFASTQs": preparation.mappingFASTQURLs.map(\.path),
                "mappingInputTransport": "stdin-sample-prefixed-fastq",
                "sampleDefinitions": preparation.sampleDefinitionsURL.path,
                "sampleManifest": preparation.sampleManifestURL.path,
                "requiresBothEndSoftclips": preparation.requiresBothEndSoftclips,
                "internalMergePerformed": false,
            ] as [String: Any]
        } as Any? ?? NSNull()
        let illuminaInputPreparation: Any = resolvedMode == .illuminaPaired
            ? sampleBundleInputPreparation
            : NSNull()
        let requireBothEndSoftclips = illuminaPreparation?.requiresBothEndSoftclips
            ?? (resolvedMode == .ontBarcodeDemux)
        let options: [String: Any] = [
            "inputFASTQ": request.inputFASTQURL.path,
            "inputFASTQs": request.inputFASTQURLs.map(\.path),
            "mode": request.mode.rawValue,
            "resolvedMode": resolvedMode.rawValue,
            "readType": request.readType.rawValue,
            "resolvedReadType": resolvedReadType.rawValue,
            "reference": request.referenceSourceURL.path,
            "barcodes": request.barcodeDefinitionsURL?.path as Any? ?? NSNull(),
            "demuxManifest": demuxManifestURL.path,
            "outputDirectory": request.outputDirectory.path,
            "outputName": request.outputName,
            "analysisName": request.analysisName,
            "comparisonWorkbook": request.comparisonWorkbookURL?.path as Any? ?? NSNull(),
            "comparisonName": request.comparisonName as Any? ?? NSNull(),
            "haplotypeAssayID": resolvedHaplotypeDefinitionSet?.assayID as Any? ?? NSNull(),
            "haplotypeSpeciesCode": request.haplotypeSpeciesCode as Any? ?? NSNull(),
            "haplotypeDefinitionScope": request.haplotypeDefinitionScope?.rawValue as Any? ?? NSNull(),
            "haplotypeDefinitionSetID": request.haplotypeDefinitionSetID as Any? ?? NSNull(),
            "haplotypeDefinitionSHA256": haplotypeDefinitionSHA256,
            "specialistPromptPath": specialistPromptPath,
            "specialistPromptSHA256": specialistPromptSHA256,
            "presetID": request.presetID as Any? ?? NSNull(),
            "presetVersion": request.presetVersion as Any? ?? NSNull(),
            "lockedReferenceSHA256": request.lockedReferenceSHA256 as Any? ?? NSNull(),
            "threads": request.threads,
            "sortThreads": request.sortThreads,
            "minSupport": request.minSupport,
            "haplotypeDropoutSampleFraction": request.haplotypeDropoutSampleFraction as Any? ?? NSNull(),
            "haplotypeDropoutLocusFraction": request.haplotypeDropoutLocusFraction as Any? ?? NSNull(),
            "haplotypeDropoutLocusFractionOverrides": request.haplotypeDropoutLocusFractionOverrides,
            "mappingPreset": Self.mappingPreset(for: resolvedMode),
            "requireBothEndSoftclips": requireBothEndSoftclips,
            "requireFullReferenceSpan": true,
            "diagnosticPositionFilter": false,
            "diagnosticPositionStrictLoci": [],
            "allowIndels": true,
            "maxMismatches": 0,
            "demuxRetainedReadsOnly": resolvedMode == .ontBarcodeDemux,
            "illuminaMergeResults": NSNull(),
            "illuminaInputPreparation": illuminaInputPreparation,
            "sampleBundleInputPreparation": sampleBundleInputPreparation,
            "extraArguments": request.extraArguments,
        ]
        let resolvedDefaults: [String: Any] = [
            "analysisName": request.outputName,
            "comparisonName": "Illumina-31262",
            "mode": AmpliconGenotypingMode.auto.rawValue,
            "readType": AmpliconGenotypingReadType.auto.rawValue,
            "haplotypeAssayID": NSNull(),
            "haplotypeSpeciesCode": NSNull(),
            "haplotypeDefinitionScope": NSNull(),
            "haplotypeDefinitionSetID": NSNull(),
            "presetID": NSNull(),
            "presetVersion": NSNull(),
            "lockedReferenceSHA256": NSNull(),
            "specialistPromptPath": NSNull(),
            "specialistPromptSHA256": NSNull(),
            "sortThreads": 4,
            "minSupport": 1,
            "haplotypeDropoutSampleFraction": NSNull(),
            "haplotypeDropoutLocusFraction": NSNull(),
            "haplotypeDropoutLocusFractionOverrides": [:],
            "mappingPreset": Self.mappingPreset(for: resolvedMode),
            "requireBothEndSoftclips": requireBothEndSoftclips,
            "requireFullReferenceSpan": true,
            "diagnosticPositionFilter": false,
            "diagnosticPositionStrictLoci": [],
            "allowIndels": true,
            "maxMismatches": 0,
            "demuxRetainedReadsOnly": resolvedMode == .ontBarcodeDemux,
            "illuminaMergeResults": NSNull(),
            "illuminaInputPreparation": NSNull(),
            "sampleBundleInputPreparation": NSNull(),
            "extraArguments": [],
        ]
        let runtimeIdentity: [String: Any] = [
            "minimap2": minimap2URL.path,
            "samtools": samtoolsURL.path,
            "python": pythonURL.path,
            "reportPython": reportPythonURL.path,
            "openpyxl": report.summary.openpyxlVersion,
            "condaRoot": condaManager.rootPrefix.path,
        ]
        let provenanceInputs: [[String: Any]] = inputs + mappingInputs + [
            fileDescriptorDictionary(url: reference.referenceFASTAURL, role: "reference"),
            fileDescriptorDictionary(url: demuxManifestURL, role: "input"),
            fileDescriptorDictionary(url: scriptURL, role: "input"),
            fileDescriptorDictionary(url: reportScriptURL, role: "input"),
        ] + (request.barcodeDefinitionsURL.map { [fileDescriptorDictionary(url: $0, role: "input")] } ?? [])
            + comparisonInputs + stagedInputs + haplotypeDefinitionInputs + specialistPromptInputs
        let transientAlignmentOutputs: [[String: Any]] = [
            fileDescriptorDictionary(url: request.mappingBAMURL, role: "intermediate"),
            fileDescriptorDictionary(url: request.mappingBAIURL, role: "intermediate-index"),
            fileDescriptorDictionary(url: request.retainedBAMURL, role: "intermediate"),
            fileDescriptorDictionary(url: request.retainedBAIURL, role: "intermediate-index"),
        ] + mapping.transientBAMURLs.map { fileDescriptorDictionary(url: $0, role: "intermediate") }
        let currentWorkbookProvenanceOutputs = workbookCopy.provenanceURL
            .map { [fileDescriptorDictionary(url: $0, role: "current-report-provenance")] } ?? []
        let provenanceOutputs: [[String: Any]] = [
            fileDescriptorDictionary(url: request.reportCSVURL, role: "report"),
            fileDescriptorDictionary(url: request.sampleSummaryCSVURL, role: "report"),
            fileDescriptorDictionary(url: request.statsJSONURL, role: "output"),
        ] + haplotypeOutputs + currentHaplotypeOutputs + [
            fileDescriptorDictionary(url: request.workbookURL, role: "original-report"),
            fileDescriptorDictionary(url: request.currentWorkbookURL, role: "current-report"),
            fileDescriptorDictionary(url: request.reportProvenanceURL, role: "provenance"),
        ] + currentWorkbookProvenanceOutputs + specialistPromptOutputs
        let primaryOutput = fileDescriptorDictionary(url: request.outputDirectory, role: "output")
        let provenanceFiles = provenanceInputs + transientAlignmentOutputs + provenanceOutputs
        let statistics: [String: Any] = [
            "totalInputReads": filter.stats.totalInputReads,
            "totalAlignments": filter.stats.totalAlignments,
            "passedAlignments": filter.stats.passedAlignments,
            "retainedUniqueReads": filter.stats.retainedUniqueReads,
            "retainedUniquePercentOfTotalReads": filter.stats.retainedUniquePercentOfTotalReads,
            "assignedUniqueRetainedReads": filter.stats.assignedUniqueRetainedReads,
            "unassignedUniqueRetainedReads": filter.stats.unassignedUniqueRetainedReads,
        ]
        let mappingProcessSteps: [[String: Any]] = mapping.invocations.flatMap { invocation in
            [
                [
                    "toolName": "minimap2",
                    "argv": [minimap2URL.path] + invocation.minimap2Arguments,
                    "exitStatus": 0,
                    "wallClockSeconds": invocation.wallClockSeconds,
                    "wallTimeSeconds": invocation.wallClockSeconds,
                    "stderr": invocation.minimap2Stderr,
                ],
                [
                    "toolName": "samtools sort",
                    "argv": [samtoolsURL.path] + invocation.samtoolsSortArguments,
                    "exitStatus": 0,
                    "wallClockSeconds": invocation.wallClockSeconds,
                    "wallTimeSeconds": invocation.wallClockSeconds,
                    "stderr": invocation.samtoolsSortStderr,
                ],
            ]
        }
        let mergeStep: [[String: Any]] = mapping.samtoolsMergeArguments.map { mergeArguments in
            [[
                "toolName": "samtools merge",
                "argv": [samtoolsURL.path] + mergeArguments,
                "exitStatus": 0,
                "wallClockSeconds": mapping.wallClockSeconds,
                "wallTimeSeconds": mapping.wallClockSeconds,
                "stderr": mapping.samtoolsMergeStderr,
            ]]
        } ?? []
        let steps: [[String: Any]] = mappingProcessSteps + mergeStep + [
            [
                "toolName": "samtools index",
                "argv": [samtoolsURL.path] + mapping.samtoolsIndexArguments,
                "exitStatus": 0,
                "wallTimeSeconds": mapping.wallClockSeconds,
                "stderr": mapping.samtoolsIndexStderr,
            ],
            [
                "toolName": "pysam retained-read demux filter",
                "argv": [pythonURL.path] + filter.arguments,
                "exitStatus": 0,
                "wallClockSeconds": filter.wallClockSeconds,
                "wallTimeSeconds": filter.wallClockSeconds,
                "stderr": filter.stderr,
            ],
        ] + haplotypeSteps + currentHaplotypeSteps + specialistPromptSteps + [
            [
                "toolName": "openpyxl ONT genotype workbook report",
                "argv": [reportPythonURL.path] + report.arguments,
                "exitStatus": 0,
                "wallClockSeconds": report.wallClockSeconds,
                "wallTimeSeconds": report.wallClockSeconds,
                "stderr": report.stderr,
                "summary": [
                    "outputXLSX": report.summary.outputXLSX,
                    "provenanceJSON": report.summary.provenanceJSON,
                    "sheetNames": report.summary.sheetNames,
                    "auditRows": report.summary.auditRows,
                ],
            ],
            [
                "toolName": workbookCopy.toolName,
                "toolVersion": workbookCopy.toolVersion,
                "argv": workbookCopy.arguments,
                "exitStatus": Int(workbookCopy.exitStatus),
                "wallClockSeconds": workbookCopy.wallClockSeconds,
                "wallTimeSeconds": workbookCopy.wallClockSeconds,
                "stderr": workbookCopy.stderr,
                "summary": [
                    "mode": workbookCopy.creationMode,
                    "primaryWorkbook": request.workbookURL.path,
                    "currentWorkbook": request.currentWorkbookURL.path,
                    "provenanceJSON": workbookCopy.provenanceURL?.path as Any? ?? NSNull(),
                    "sheetNames": workbookCopy.summary?.sheetNames as Any? ?? NSNull(),
                    "sha256": workbookCopy.revision.sha256,
                    "sizeBytes": workbookCopy.revision.sizeBytes,
                ],
            ],
        ]
        let payload: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: completedAt),
            "toolName": "lungfish fastq genotype",
            "toolVersion": WorkflowRun.currentAppVersion,
            "workflowName": Self.workflowName(for: resolvedMode),
            "workflowVersion": "1",
            "argv": request.argv,
            "durableReplayArgv": request.argv,
            "reproducibleCommand": request.argv.map(shellEscape).joined(separator: " "),
            "options": options,
            "resolvedDefaults": resolvedDefaults,
            "runtimeIdentity": runtimeIdentity,
            "managedTools": managedToolDescriptors(ids: ["minimap2", "samtools", "pysam", "openpyxl"]),
            "inputs": provenanceInputs,
            "files": provenanceFiles,
            "transientAlignmentOutputs": transientAlignmentOutputs,
            "stagedInputs": [
                "barcodeDefinitions": inputSnapshot.barcodeDefinitionsURL.path,
                "demuxManifest": inputSnapshot.demuxManifestURL.path,
                "comparisonWorkbook": inputSnapshot.comparisonWorkbookURL?.path as Any? ?? NSNull(),
            ],
            "output": primaryOutput,
            "outputs": provenanceOutputs,
            "inputFileCount": inputFASTQURLs.count,
            "mappingInputFileCount": mappingInputFASTQURLs.count,
            "sourceReferenceBundle": reference.sourceReferenceBundleURL?.path ?? NSNull(),
            "statistics": statistics,
            "steps": steps,
            "exitStatus": 0,
            "wallClockSeconds": completedAt.timeIntervalSince(startedAt),
            "wallTimeSeconds": completedAt.timeIntervalSince(startedAt),
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "completedAt": ISO8601DateFormatter().string(from: completedAt),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: provenanceURL, options: .atomic)

        let canonicalEnvelope = try canonicalProvenanceEnvelope(
            request: request,
            resolvedMode: resolvedMode,
            resolvedReadType: resolvedReadType,
            reference: reference,
            inputFASTQURLs: inputFASTQURLs,
            mappingInputFASTQURLs: mappingInputFASTQURLs,
            demuxManifestURL: demuxManifestURL,
            inputSnapshot: inputSnapshot,
            illuminaPreparation: illuminaPreparation,
            scriptURL: scriptURL,
            reportScriptURL: reportScriptURL,
            minimap2URL: minimap2URL,
            samtoolsURL: samtoolsURL,
            pythonURL: pythonURL,
            reportPythonURL: reportPythonURL,
            mapping: mapping,
            filter: filter,
            report: report,
            workbookCopy: workbookCopy,
            haplotypeAnalysis: haplotypeAnalysis,
            legacyProvenanceURL: provenanceURL,
            options: options,
            resolvedDefaults: resolvedDefaults,
            startedAt: startedAt,
            completedAt: completedAt
        )
        return try ProvenanceWriter().write(canonicalEnvelope, to: request.outputDirectory)
    }

    private func canonicalProvenanceEnvelope(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        resolvedMode: AmpliconGenotypingMode,
        resolvedReadType: AmpliconGenotypingReadType,
        reference: ReferenceResolution,
        inputFASTQURLs: [URL],
        mappingInputFASTQURLs: [URL],
        demuxManifestURL: URL,
        inputSnapshot: SmallInputSnapshot,
        illuminaPreparation: IlluminaPreparation?,
        scriptURL: URL,
        reportScriptURL: URL,
        minimap2URL: URL,
        samtoolsURL: URL,
        pythonURL: URL,
        reportPythonURL: URL,
        mapping: MappingStepResult,
        filter: FilterStepResult,
        report: ReportStepResult,
        workbookCopy: WorkbookCopyResult,
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?,
        legacyProvenanceURL: URL,
        options: [String: Any],
        resolvedDefaults: [String: Any],
        startedAt: Date,
        completedAt: Date
    ) throws -> ProvenanceEnvelope {
        let fastqInputs = try inputFASTQURLs.map { try canonicalFileDescriptor(url: $0, role: .input) }
        let mappingFastqInputs = try mappingInputFASTQURLs.map { try canonicalFileDescriptor(url: $0, role: .input) }
        let referenceInput = try canonicalFileDescriptor(url: reference.referenceFASTAURL, role: .reference)
        let barcodeInput = try request.barcodeDefinitionsURL.map { try canonicalFileDescriptor(url: $0, role: .input) }
        let demuxInput = try canonicalFileDescriptor(url: demuxManifestURL, role: .input)
        let filterScriptInput = try canonicalFileDescriptor(url: scriptURL, role: .input)
        let reportScriptInput = try canonicalFileDescriptor(url: reportScriptURL, role: .input)
        let comparisonInputs = try request.comparisonWorkbookURL
            .map { [try canonicalFileDescriptor(url: $0, role: .input)] } ?? []
        let stagedInputs = try inputSnapshot.stagedInputURLs
            .map { try canonicalFileDescriptor(url: $0, role: .input) }
        let haplotypeDefinitionInput = try haplotypeAnalysis.map { _ in
            try canonicalFileDescriptor(url: haplotypeDefinitionSnapshotURL(for: request), role: .input)
        }
        let specialistPromptSource = try specialistPromptSourceURL(for: request).map {
            try canonicalFileDescriptor(url: $0, role: .input)
        }
        let specialistPromptOutput = try specialistPromptSnapshotIfPresent(for: request).map {
            try canonicalFileDescriptor(url: $0, role: .report)
        }
        let canonicalInputs = deduplicated(
            fastqInputs
                + mappingFastqInputs
                + [referenceInput, demuxInput, filterScriptInput, reportScriptInput]
                + (barcodeInput.map { [$0] } ?? [])
                + comparisonInputs
                + stagedInputs
                + (haplotypeDefinitionInput.map { [$0] } ?? [])
                + (specialistPromptSource.map { [$0] } ?? [])
        )

        let mappingBAM = try canonicalFileDescriptor(url: request.mappingBAMURL, role: .output)
        let mappingBAI = try canonicalFileDescriptor(url: request.mappingBAIURL, role: .index)
        let retainedBAM = try canonicalFileDescriptor(url: request.retainedBAMURL, role: .output)
        let retainedBAI = try canonicalFileDescriptor(url: request.retainedBAIURL, role: .index)
        let genotypeCSV = try canonicalFileDescriptor(url: request.reportCSVURL, role: .report)
        let sampleCSV = try canonicalFileDescriptor(url: request.sampleSummaryCSVURL, role: .report)
        let statsJSON = try canonicalFileDescriptor(url: request.statsJSONURL, role: .output)
        let haplotypeOutput = try haplotypeAnalysis.map { _ in
            try canonicalFileDescriptor(url: request.haplotypeAnalysisURL, role: .report)
        }
        let currentHaplotypeOutput = try workbookCopy.currentHaplotypeAnalysisURL.map {
            try canonicalFileDescriptor(url: $0, role: .report)
        }
        let workbook = try canonicalFileDescriptor(url: request.workbookURL, role: .report)
        let currentWorkbook = try canonicalFileDescriptor(url: request.currentWorkbookURL, role: .report)
        let reportProvenance = try canonicalFileDescriptor(url: request.reportProvenanceURL, role: .log)
        let currentWorkbookProvenance = try workbookCopy.provenanceURL.map {
            try canonicalFileDescriptor(url: $0, role: .log)
        }
        let legacyProvenance = try canonicalFileDescriptor(url: legacyProvenanceURL, role: .log)
        let canonicalOutputs = deduplicated(
            [
                genotypeCSV,
                sampleCSV,
                statsJSON,
            ]
                + (haplotypeOutput.map { [$0] } ?? [])
                + (currentHaplotypeOutput.map { [$0] } ?? [])
                + [workbook, currentWorkbook, reportProvenance, legacyProvenance]
                + (currentWorkbookProvenance.map { [$0] } ?? [])
                + (specialistPromptOutput.map { [$0] } ?? [])
        )
        let outputDirectory = ProvenanceFileDescriptor(
            path: request.outputDirectory.standardizedFileURL.path,
            role: .output
        )

        let invocationBAMs = try mapping.invocations.map {
            try canonicalFileDescriptor(url: $0.outputBAMURL, role: .output)
        }
        var canonicalSteps = try mapping.invocations.flatMap { invocation -> [ProvenanceStep] in
            let invocationInputs = try invocation.inputFASTQURLs.map {
                try canonicalFileDescriptor(url: $0, role: .input)
            }
            let invocationBAM = try canonicalFileDescriptor(url: invocation.outputBAMURL, role: .output)
            return [
                ProvenanceStep(
                    toolName: "minimap2",
                    toolVersion: "unknown",
                    argv: [minimap2URL.path] + invocation.minimap2Arguments,
                    inputs: invocationInputs + [referenceInput],
                    outputs: [invocationBAM],
                    exitStatus: 0,
                    wallTimeSeconds: invocation.wallClockSeconds,
                    stderr: invocation.minimap2Stderr
                ),
                ProvenanceStep(
                    toolName: "samtools sort",
                    toolVersion: "unknown",
                    argv: [samtoolsURL.path] + invocation.samtoolsSortArguments,
                    inputs: invocationInputs + [referenceInput],
                    outputs: [invocationBAM],
                    exitStatus: 0,
                    wallTimeSeconds: invocation.wallClockSeconds,
                    stderr: invocation.samtoolsSortStderr
                ),
            ]
        }
        if let mergeArguments = mapping.samtoolsMergeArguments {
            canonicalSteps.append(
                ProvenanceStep(
                    toolName: "samtools merge",
                    toolVersion: "unknown",
                    argv: [samtoolsURL.path] + mergeArguments,
                    inputs: invocationBAMs,
                    outputs: [mappingBAM],
                    exitStatus: 0,
                    wallTimeSeconds: mapping.wallClockSeconds,
                    stderr: mapping.samtoolsMergeStderr
                )
            )
        }
        canonicalSteps += [
            ProvenanceStep(
                toolName: "samtools index",
                toolVersion: "unknown",
                argv: [samtoolsURL.path] + mapping.samtoolsIndexArguments,
                inputs: [mappingBAM],
                outputs: [mappingBAI],
                exitStatus: 0,
                wallTimeSeconds: mapping.wallClockSeconds,
                stderr: mapping.samtoolsIndexStderr
            ),
            ProvenanceStep(
                toolName: "pysam retained-read demux filter",
                toolVersion: "unknown",
                argv: [pythonURL.path] + filter.arguments,
                inputs: [mappingBAM, demuxInput, filterScriptInput] + (barcodeInput.map { [$0] } ?? []),
                outputs: [retainedBAM, retainedBAI, genotypeCSV, sampleCSV, statsJSON, legacyProvenance],
                exitStatus: 0,
                wallTimeSeconds: filter.wallClockSeconds,
                stderr: filter.stderr
            ),
        ]
        if let haplotypeOutput {
            canonicalSteps.append(
                ProvenanceStep(
                    toolName: "deterministic genotype haplotype assignment",
                    toolVersion: WorkflowRun.currentAppVersion,
                    argv: haplotypeAssignmentArgv(for: request, resolvedAssayID: haplotypeAnalysis?.assayID),
                    inputs: [genotypeCSV] + (haplotypeDefinitionInput.map { [$0] } ?? []),
                    outputs: [haplotypeOutput],
                    exitStatus: 0,
                    wallTimeSeconds: 0
                )
            )
        }
        if let currentHaplotypeOutput {
            canonicalSteps.append(
                ProvenanceStep(
                    toolName: "deterministic genotype haplotype assignment",
                    toolVersion: WorkflowRun.currentAppVersion,
                    argv: haplotypeAssignmentArgv(for: request, resolvedAssayID: haplotypeAnalysis?.assayID) + [
                        "--dropout-locus-fraction", "MHC-DQ=0.05",
                        "--dropout-locus-fraction", "MHC-DP=0.05",
                        "--output", currentHaplotypeOutput.path,
                    ],
                    inputs: [genotypeCSV] + (haplotypeDefinitionInput.map { [$0] } ?? []),
                    outputs: [currentHaplotypeOutput],
                    exitStatus: 0,
                    wallTimeSeconds: 0
                )
            )
        }
        if let specialistPromptSource, let specialistPromptOutput {
            canonicalSteps.append(
                ProvenanceStep(
                    toolName: "MCM specialist prompt snapshot",
                    toolVersion: WorkflowRun.currentAppVersion,
                    argv: ["copy", specialistPromptSource.path, specialistPromptOutput.path],
                    inputs: [specialistPromptSource],
                    outputs: [specialistPromptOutput],
                    exitStatus: 0,
                    wallTimeSeconds: 0
                )
            )
        }
        canonicalSteps.append(
            ProvenanceStep(
                toolName: "openpyxl ONT genotype workbook report",
                toolVersion: report.summary.openpyxlVersion,
                argv: [reportPythonURL.path] + report.arguments,
                inputs: [genotypeCSV, sampleCSV, statsJSON, reportScriptInput]
                    + comparisonInputs
                    + (haplotypeOutput.map { [$0] } ?? []),
                outputs: [workbook, reportProvenance],
                exitStatus: 0,
                wallTimeSeconds: report.wallClockSeconds,
                stderr: report.stderr
            )
        )
        canonicalSteps.append(
            ProvenanceStep(
                toolName: workbookCopy.toolName,
                toolVersion: workbookCopy.toolVersion,
                argv: workbookCopy.arguments,
                inputs: workbookCopy.creationMode == "mcm-client-current"
                    ? [workbook, genotypeCSV, sampleCSV, statsJSON, referenceInput, reportScriptInput]
                        + (barcodeInput.map { [$0] } ?? [])
                        + (currentHaplotypeOutput.map { [$0] } ?? haplotypeOutput.map { [$0] } ?? [])
                        + (haplotypeDefinitionInput.map { [$0] } ?? [])
                    : [workbook],
                outputs: [currentWorkbook] + (currentWorkbookProvenance.map { [$0] } ?? []),
                exitStatus: Int(workbookCopy.exitStatus),
                wallTimeSeconds: workbookCopy.wallClockSeconds,
                stderr: workbookCopy.stderr
            )
        )

        return ProvenanceEnvelope(
            createdAt: completedAt,
            workflowName: Self.workflowName(for: resolvedMode),
            workflowVersion: "1",
            toolName: "lungfish fastq genotype",
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(
                name: "lungfish fastq genotype",
                version: WorkflowRun.currentAppVersion,
                kind: "cli"
            ),
            argv: request.argv,
            durableReplayArgv: request.argv,
            reproducibleCommand: request.argv.map(shellEscape).joined(separator: " "),
            options: ProvenanceOptions(
                explicit: parameterValues(from: options),
                resolvedDefaults: parameterValues(from: resolvedDefaults)
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(
                appVersion: WorkflowRun.currentAppVersion,
                executablePath: CommandLine.arguments.first ?? ProvenanceRuntimeIdentity.currentExecutablePath,
                operatingSystemVersion: WorkflowRun.currentHostOS,
                user: NSUserName(),
                condaEnvironment: "lungfish-managed-tools",
                condaPrefix: condaManager.rootPrefix.path
            ),
            files: deduplicated(
                canonicalInputs
                    + canonicalOutputs
                    + canonicalSteps.flatMap { $0.inputs + $0.outputs }
            ),
            output: outputDirectory,
            outputs: [outputDirectory] + canonicalOutputs,
            steps: canonicalSteps,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: 0
        )
    }

    private func writeBundleManifest(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        resolvedMode: AmpliconGenotypingMode,
        provenanceURL: URL,
        workbookRevision: ONTGenotypeWorkbookRevision,
        completedAt: Date
    ) throws {
        let resolvedHaplotypeDefinitionSet = try resolveHaplotypeDefinitionSet(for: request)
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: request.outputName,
            analysisName: request.analysisName,
            primaryWorkbookPath: relativePath(from: request.outputDirectory, to: request.workbookURL),
            currentWorkbookPath: relativePath(from: request.outputDirectory, to: request.currentWorkbookURL),
            workbookRevisions: [workbookRevision],
            longSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.reportCSVURL),
            sampleSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.sampleSummaryCSVURL),
            statsJSONPath: relativePath(from: request.outputDirectory, to: request.statsJSONURL),
            provenancePath: relativePath(from: request.outputDirectory, to: provenanceURL),
            haplotypeAnalysisPath: request.haplotypeDefinitionSetID == nil
                ? nil
                : relativePath(from: request.outputDirectory, to: request.haplotypeAnalysisURL),
            haplotypeDefinitionSetID: request.haplotypeDefinitionSetID,
            haplotypeAssayID: resolvedHaplotypeDefinitionSet?.assayID,
            presetID: request.presetID,
            presetVersion: request.presetVersion,
            createdAt: ISO8601DateFormatter().string(from: completedAt)
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: request.outputDirectory)

        if let projectURL = request.projectURL,
           request.outputDirectory.standardizedFileURL.path.hasPrefix(projectURL.standardizedFileURL.path) {
            try? AnalysesFolder.writeAnalysisMetadata(
                AnalysesFolder.AnalysisMetadata(
                    tool: Self.analysisToolName(for: resolvedMode),
                    isBatch: false,
                    created: completedAt
                ),
                to: request.outputDirectory
            )
        }
    }

    private func removeGeneratedAlignmentIntermediates(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        mapping: MappingStepResult
    ) throws {
        for url in [
            request.mappingBAMURL,
            request.mappingBAIURL,
            request.retainedBAMURL,
            request.retainedBAIURL,
        ] + mapping.transientBAMURLs where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func relativePath(from directoryURL: URL, to fileURL: URL) -> String {
        let directoryPath = directoryURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return filePath
    }

    private func haplotypeAssignmentArgv(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        resolvedAssayID: String? = nil
    ) -> [String] {
        guard let definitionSetID = request.haplotypeDefinitionSetID else { return [] }
        var argv: [String] = []
        if let assayID = request.haplotypeAssayID ?? resolvedAssayID {
            argv += ["--haplotype-assay", assayID]
        }
        if let speciesCode = request.haplotypeSpeciesCode {
            argv += ["--haplotype-species", speciesCode]
        }
        if let scope = request.haplotypeDefinitionScope {
            argv += ["--haplotype-definition-scope", scope.rawValue]
        }
        argv += ["--haplotype-definition", definitionSetID]
        return argv
    }

    private func canonicalFileDescriptor(url: URL, role: FileRole) throws -> ProvenanceFileDescriptor {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return ProvenanceFileDescriptor(path: standardized.path, role: role)
        }
        return try ProvenanceFileDescriptor.file(url: standardized, role: role)
    }

    private func parameterValues(from values: [String: Any]) -> [String: ParameterValue] {
        values.mapValues(parameterValue(from:))
    }

    private func parameterValue(from value: Any) -> ParameterValue {
        if value is NSNull {
            return .null
        }
        if let boolValue = value as? Bool {
            return .boolean(boolValue)
        }
        if let intValue = value as? Int {
            return .integer(intValue)
        }
        if let doubleValue = value as? Double {
            return .number(doubleValue)
        }
        if let numberValue = value as? NSNumber {
            let doubleValue = numberValue.doubleValue
            if doubleValue.rounded() == doubleValue {
                return .integer(numberValue.intValue)
            }
            return .number(doubleValue)
        }
        if let stringValue = value as? String {
            return .string(stringValue)
        }
        if let arrayValue = value as? [Any] {
            return .array(arrayValue.map(parameterValue(from:)))
        }
        if let dictionaryValue = value as? [String: Any] {
            return .dictionary(parameterValues(from: dictionaryValue))
        }
        return .string(String(describing: value))
    }

    private func deduplicated(_ descriptors: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        var result: [ProvenanceFileDescriptor] = []
        for descriptor in descriptors {
            let key = "\(descriptor.role.rawValue)\u{0}\(descriptor.path)"
            if seen.insert(key).inserted {
                result.append(descriptor)
            }
        }
        return result
    }

    private func fileDescriptorDictionary(url: URL, role: String) -> [String: Any] {
        var values: [String: Any] = [
            "path": url.path,
            "role": role,
        ]
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            values["exists"] = false
            return values
        }
        values["exists"] = true
        if let size = attributes[.size] as? NSNumber {
            values["sizeBytes"] = size.int64Value
        }
        if let digest = try? ProvenanceFileHasher.sha256(of: url) {
            values["sha256"] = digest
        }
        return values
    }

    private func managedToolDescriptors(ids: [String]) -> [[String: Any]] {
        let lock = try? ManagedToolLock.loadFromBundle()
        return ids.compactMap { id in
            if let tool = lock?.tool(named: id) {
                return [
                    "id": tool.id,
                    "environment": tool.environment,
                    "packageSpec": tool.packageSpec,
                    "executables": tool.executables,
                    "version": tool.version as Any? ?? NSNull(),
                    "license": tool.license as Any? ?? NSNull(),
                    "sourceUrl": tool.sourceUrl as Any? ?? NSNull(),
                ]
            }
            if id == "minimap2" {
                return [
                    "id": "minimap2",
                    "environment": "minimap2",
                    "packageSpec": "bioconda::minimap2=2.30",
                    "executables": ["minimap2"],
                    "version": "2.30",
                    "license": "MIT",
                    "sourceUrl": "https://github.com/lh3/minimap2",
                ]
            }
            return nil
        }
    }

    private func fileHandleForWriting(to url: URL) throws -> FileHandle {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
    }

    private static func url(_ child: URL, isContainedIn parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath == parentPath || childPath.hasPrefix(prefix)
    }

}
