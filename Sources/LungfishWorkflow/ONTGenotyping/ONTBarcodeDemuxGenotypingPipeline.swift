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
        extraArguments: [String] = []
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
            readType: .ont
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
        readType: AmpliconGenotypingReadType = .auto
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
            readType: readType
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
            "lungfish",
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
        let mapping = try runMapping(
            request: request,
            resolvedMode: resolvedMode,
            referenceFASTAURL: reference.referenceFASTAURL,
            inputFASTQURLs: mappingInputFASTQURLs,
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
            return manifest.files.map { entry in
                let bundleRelativeURL = standardized.appendingPathComponent(entry.filename).standardizedFileURL
                if FileManager.default.fileExists(atPath: bundleRelativeURL.path) {
                    return bundleRelativeURL
                }
                let originalURL = URL(fileURLWithPath: entry.originalPath).standardizedFileURL
                if FileManager.default.fileExists(atPath: originalURL.path) {
                    return originalURL
                }
                return bundleRelativeURL
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
            progressNoop()
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

    private func progressNoop() {}

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
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)

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
                "mappingFASTQ": sample.prefixedFASTQURL.path,
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
            sourceFASTQURLs: samples.map(\.fastqURL),
            mappingFASTQURLs: samples.map(\.prefixedFASTQURL),
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
                let readCount = try await writeSamplePrefixedFASTQ(
                    sourceURL: fastqURL,
                    destinationURL: prefixedFASTQURL,
                    sampleID: sampleID
                )
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

    private static func writeSamplePrefixedFASTQ(
        sourceURL: URL,
        destinationURL: URL,
        sampleID: String
    ) async throws -> Int {
        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: destinationURL)
        try writer.open()
        defer { try? writer.close() }

        var count = 0
        for try await record in reader.records(from: sourceURL) {
            let prefixed = FASTQRecord(
                identifier: "\(sampleID)|\(record.identifier)",
                description: record.description,
                sequence: record.sequence,
                quality: record.quality
            )
            try writer.write(prefixed)
            count += Self.readCountWeight(fromIdentifier: record.identifier, description: record.description)
        }
        return count
    }

    private static func readCountWeight(fromIdentifier identifier: String, description: String?) -> Int {
        for text in [identifier, description].compactMap({ $0 }) {
            for token in text.split(whereSeparator: { $0 == ";" || $0 == " " || $0 == "\t" || $0 == "|" }) {
                guard token.hasPrefix("size="),
                      let value = Int(token.dropFirst("size=".count)),
                      value > 0 else {
                    continue
                }
                return value
            }
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
            for try await _ in reader.records(from: url) {
                count += 1
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
        minimap2URL: URL,
        samtoolsURL: URL
    ) throws -> MappingStepResult {
        if resolvedMode == .illuminaPaired, inputFASTQURLs.count > 1 {
            return try runSampleBundleCohortMapping(
                request: request,
                resolvedMode: resolvedMode,
                referenceFASTAURL: referenceFASTAURL,
                inputFASTQURLs: inputFASTQURLs,
                minimap2URL: minimap2URL,
                samtoolsURL: samtoolsURL
            )
        }

        let startedAt = Date()
        let invocation = try runMappingInvocation(
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

    private func runSampleBundleCohortMapping(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        resolvedMode: AmpliconGenotypingMode,
        referenceFASTAURL: URL,
        inputFASTQURLs: [URL],
        minimap2URL: URL,
        samtoolsURL: URL
    ) throws -> MappingStepResult {
        let startedAt = Date()
        let mappingDirectory = request.outputDirectory
            .appendingPathComponent(".amplicon-genotyping", isDirectory: true)
            .appendingPathComponent("mapping", isDirectory: true)
        try FileManager.default.createDirectory(at: mappingDirectory, withIntermediateDirectories: true)

        var invocations: [MappingInvocationResult] = []
        for (index, fastqURL) in inputFASTQURLs.enumerated() {
            let stem = "\(String(format: "%03d", index + 1))-\(Self.safeFilenameStem(fastqURL.deletingPathExtension().lastPathComponent))"
            let sampleBAMURL = mappingDirectory.appendingPathComponent("\(stem).sorted.bam")
            let invocation = try runMappingInvocation(
                request: request,
                resolvedMode: resolvedMode,
                referenceFASTAURL: referenceFASTAURL,
                inputFASTQURLs: [fastqURL],
                outputBAMURL: sampleBAMURL,
                minimap2URL: minimap2URL,
                samtoolsURL: samtoolsURL,
                stderrStem: "\(request.outputName).\(stem)",
                readGroupID: "\(request.outputName)-\(index + 1)"
            )
            invocations.append(invocation)
        }

        let mergeStderrURL = request.outputDirectory.appendingPathComponent("\(request.outputName).samtools-merge.stderr.log")
        let mergeArguments = ["merge", "-f", request.mappingBAMURL.path] + invocations.map(\.outputBAMURL.path)
        let mergeStderr = try runSamtoolsMerge(
            samtoolsURL: samtoolsURL,
            arguments: mergeArguments,
            stderrURL: mergeStderrURL
        )
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
            transientBAMURLs: invocations.map(\.outputBAMURL)
        )
    }

    private func runMappingInvocation(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        resolvedMode: AmpliconGenotypingMode,
        referenceFASTAURL: URL,
        inputFASTQURLs: [URL],
        outputBAMURL: URL,
        minimap2URL: URL,
        samtoolsURL: URL,
        stderrStem: String,
        readGroupID: String
    ) throws -> MappingInvocationResult {
        let minimap2StderrURL = request.outputDirectory.appendingPathComponent("\(stderrStem).minimap2.stderr.log")
        let sortStderrURL = request.outputDirectory.appendingPathComponent("\(stderrStem).samtools-sort.stderr.log")
        let mappingPreset = Self.mappingPreset(for: resolvedMode)
        let platform = Self.mappingPlatform(for: resolvedMode)
        let readGroup = "@RG\\tID:\(readGroupID)\\tSM:\(readGroupID)\\tLB:\(request.outputName)\\tPL:\(platform)\\tPU:\(readGroupID)"
        let minimap2Arguments = [
            "-a",
            "-x", mappingPreset,
            "--MD",
            "-t", String(request.threads),
            "-R", readGroup,
        ] + request.extraArguments + [referenceFASTAURL.path] + inputFASTQURLs.map(\.path)
        let sortArguments = [
            "sort",
            "-@", String(request.sortThreads),
            "-o", outputBAMURL.path,
            "-",
        ]
        let startedAt = Date()

        try FileManager.default.createDirectory(at: outputBAMURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pipe = Pipe()
        let minimap2 = Process()
        minimap2.executableURL = minimap2URL
        minimap2.arguments = minimap2Arguments
        minimap2.standardOutput = pipe
        minimap2.standardError = try fileHandleForWriting(to: minimap2StderrURL)

        let sort = Process()
        sort.executableURL = samtoolsURL
        sort.arguments = sortArguments
        sort.standardInput = pipe
        sort.standardError = try fileHandleForWriting(to: sortStderrURL)

        try sort.run()
        try minimap2.run()
        minimap2.waitUntilExit()
        try? (minimap2.standardError as? FileHandle)?.close()
        pipe.fileHandleForWriting.closeFile()
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
            haplotypeAssayID: assayID
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
            haplotypeAssayID: definitionSet.assayID
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

    public static func writeFilterScript(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try filterScript.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func writeReportScript(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try reportScript.write(to: url, atomically: true, encoding: .utf8)
    }

}

private let filterScript = #"""
#!/usr/bin/env python3
import argparse
import csv
import gzip
import hashlib
import json
import os
import platform
import re
import sys
import time
import warnings
from collections import Counter, defaultdict
from datetime import datetime, timezone

import pysam


def parse_args():
    parser = argparse.ArgumentParser(description="Filter exact+indel/no-mismatch full-reference alignments and demultiplex retained BAM records by Fluidigm barcodes.")
    parser.add_argument("--input-bam", required=True)
    parser.add_argument("--reference-fasta", required=True)
    parser.add_argument("--barcodes")
    parser.add_argument("--demux-manifest", required=True)
    parser.add_argument("--sample-manifest")
    parser.add_argument("--assignment-mode", choices=["barcode", "query-prefix"], default="barcode")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--prefix", default="barcode08")
    parser.add_argument("--require-both-end-softclips", action="store_true")
    parser.add_argument("--max-mismatches", type=int, default=0)
    parser.add_argument("--min-support", type=int, default=1)
    parser.add_argument("--haplotype-min-sample-percent", type=float, default=0.0)
    parser.add_argument("--haplotype-min-locus-percent", type=float, default=0.0)
    parser.add_argument("--haplotype-min-locus-percent-override", action="append", default=[])
    parser.add_argument("--provenance-command", default=None)
    return parser.parse_args()


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def sha256(path, chunk_size=1024 * 1024):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(chunk_size)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path, role):
    try:
        stat = os.stat(path)
    except OSError:
        return {"path": path, "role": role, "exists": False}
    return {"path": path, "role": role, "exists": True, "sizeBytes": stat.st_size, "sha256": sha256(path)}


def open_text(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt")
    return open(path, "rt")


def load_reference_lengths(path):
    lengths = {}
    name = None
    length = 0
    with open_text(path) as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            if line.startswith(">"):
                if name is not None:
                    lengths[name] = length
                name = line[1:].split()[0]
                length = 0
            else:
                length += len(line)
    if name is not None:
        lengths[name] = length
    return lengths


def load_barcodes(path):
    entries = []
    with open(path, newline="") as handle:
        sample = handle.read(2048)
        handle.seek(0)
        delimiter = "\t" if "\t" in sample and sample.count("\t") >= sample.count(",") else ","
        reader = csv.reader(handle, delimiter=delimiter)
        for row in reader:
            if not row or len(row) < 2:
                continue
            first = row[0].strip().lstrip("\ufeff")
            second = row[1].strip()
            if not first or not second:
                continue
            if first.lower() in {"sample", "sample_id", "id", "barcodeid"}:
                continue
            entries.append({"sample": first, "barcode": second.upper().replace("U", "T")})
    if not entries:
        raise ValueError(f"No barcodes found in {path}")
    return entries


def load_demux_manifest(path):
    with open(path) as handle:
        payload = json.load(handle)
    sample_totals = {}
    for item in payload.get("barcodes", []):
        sample = item.get("barcodeID")
        if sample:
            sample_totals[sample] = item.get("readCount")
    for item in payload.get("samples", []):
        sample = item.get("sample") or item.get("sampleID")
        if sample:
            sample_totals[sample] = item.get("totalPairs") or item.get("readCount") or item.get("mergedPairs")
    return {"inputReadCount": payload.get("inputReadCount"), "sampleTotals": sample_totals}


def reverse_complement(sequence):
    table = str.maketrans("ACGTNacgtn", "TGCANtgcan")
    return sequence.translate(table)[::-1].upper()


def fraction_from_percent(value):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return 0.0
    if number <= 0:
        return 0.0
    return min(number, 100.0) / 100.0


def parse_locus_fraction_overrides(items):
    values = {}
    for item in items or []:
        if "=" not in item:
            raise ValueError("--haplotype-min-locus-percent-override must be LOCUS=PERCENT")
        locus, percent = item.split("=", 1)
        locus = locus.strip()
        if not locus:
            raise ValueError("--haplotype-min-locus-percent-override locus must not be empty")
        values[locus] = fraction_from_percent(percent)
    return {key: value for key, value in values.items() if value > 0}


def raw_locus_group_for_genotype(genotype):
    text = str(genotype or "").strip()
    if text.startswith("14_"):
        if "DQB" in text:
            return "MHC-DQB"
        return "MHC-DQA"
    if text.startswith("15_"):
        if "DPB" in text:
            return "MHC-DPB"
        return "MHC-DPA"
    if text.startswith("13_"):
        return "MHC-DRB"
    if text.startswith("12_") or text.startswith("B") or text.startswith("I_"):
        return "MHC-B"
    if text.startswith(("01_", "02_", "04_", "05_", "06_", "07_", "10_", "11_", "AG_", "A1_", "A2_", "A4_", "A5_", "E_")):
        return "MHC-A"
    return "MHC-UNKNOWN"


def canonical_locus_for_threshold(raw_locus):
    if raw_locus in {"MHC-DQA", "MHC-DQB"}:
        return "MHC-DQ"
    if raw_locus in {"MHC-DPA", "MHC-DPB"}:
        return "MHC-DP"
    return raw_locus


def barcode_regex(entries):
    pattern_to_sample = {}
    ordered_patterns = []
    for entry in entries:
        for pattern in (entry["barcode"], reverse_complement(entry["barcode"])):
            if pattern not in pattern_to_sample:
                pattern_to_sample[pattern] = entry
                ordered_patterns.append(pattern)
    return re.compile("|".join(re.escape(pattern) for pattern in ordered_patterns)), pattern_to_sample


def assign_barcode(sequence, regex, pattern_to_sample):
    if not sequence:
        return None
    match = regex.search(sequence.upper().replace("U", "T"))
    if match is None:
        return None
    entry = pattern_to_sample[match.group(0)]
    return entry["sample"], entry["barcode"], match.start()


def assign_query_prefix(query_name, sample_totals):
    if not query_name or "|" not in query_name:
        return None
    sample = query_name.split("|", 1)[0]
    if sample not in sample_totals:
        return None
    return sample, "", 0


def query_weight(query_name):
    if not query_name:
        return 1
    for token in re.split(r"[;|\s]+", query_name):
        if token.startswith("size="):
            try:
                value = int(token.split("=", 1)[1])
            except ValueError:
                continue
            if value > 0:
                return value
    return 1


def sequence_for_barcode_assignment(read):
    sequence = read.query_sequence
    if not sequence:
        return None
    try:
        is_reverse = read.is_reverse
    except AttributeError:
        is_reverse = False
    if is_reverse:
        return reverse_complement(sequence)
    return sequence


def weighted_query_count(query_names, query_weights):
    return sum(query_weights.get(name, query_weight(name)) for name in query_names)


def has_both_terminal_softclips(read):
    cigar = [item for item in (read.cigartuples or []) if item[0] != 5]
    return len(cigar) >= 3 and cigar[0][0] == 4 and cigar[-1][0] == 4


def reference_span_is_full(read, reference_lengths):
    ref_length = reference_lengths.get(read.reference_name)
    return ref_length is not None and read.reference_start == 0 and read.reference_end == ref_length


def md_mismatch_count(md):
    mismatches = 0
    i = 0
    while i < len(md):
        char = md[i]
        if char.isdigit():
            i += 1
            while i < len(md) and md[i].isdigit():
                i += 1
            continue
        if char == "^":
            i += 1
            while i < len(md) and md[i].isalpha():
                i += 1
            continue
        if char.isalpha():
            mismatches += 1
        i += 1
    return mismatches


def alignment_mismatch_count(read):
    try:
        return md_mismatch_count(read.get_tag("MD"))
    except KeyError:
        return None


def passes_filter(read, reference_lengths, args, counters):
    if read.is_unmapped:
        counters["unmapped"] += 1
        return False
    if not reference_span_is_full(read, reference_lengths):
        counters["not_full_reference_span"] += 1
        return False
    if args.require_both_end_softclips and not has_both_terminal_softclips(read):
        counters["missing_terminal_softclips"] += 1
        return False
    mismatches = alignment_mismatch_count(read)
    if mismatches is None:
        counters["missing_md_tag"] += 1
        return False
    if mismatches > args.max_mismatches:
        counters["too_many_mismatches"] += 1
        return False
    counters["passed"] += 1
    return True


def write_csv(path, rows, fieldnames):
    with open(path, "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def main():
    args = parse_args()
    start_time = time.time()
    started_at = utc_now()
    os.makedirs(args.output_dir, exist_ok=True)
    min_sample_fraction = fraction_from_percent(args.haplotype_min_sample_percent)
    min_locus_fraction = fraction_from_percent(args.haplotype_min_locus_percent)
    locus_fraction_overrides = parse_locus_fraction_overrides(args.haplotype_min_locus_percent_override)
    reference_lengths = load_reference_lengths(args.reference_fasta)
    manifest = load_demux_manifest(args.sample_manifest or args.demux_manifest)
    if args.assignment_mode == "barcode":
        if not args.barcodes:
            raise ValueError("--barcodes is required when --assignment-mode=barcode")
        barcode_entries = load_barcodes(args.barcodes)
        regex, pattern_to_sample = barcode_regex(barcode_entries)
    else:
        regex, pattern_to_sample = None, None
    total_input_reads = manifest["inputReadCount"]
    output_bam = os.path.join(args.output_dir, f"{args.prefix}.retained.demuxed.bam")
    output_bai = output_bam + ".bai"
    summary_csv = os.path.join(args.output_dir, f"{args.prefix}.retained_demux_genotypes.csv")
    sample_csv = os.path.join(args.output_dir, f"{args.prefix}.retained_demux_samples.csv")
    stats_json = os.path.join(args.output_dir, f"{args.prefix}.retained_demux_stats.json")
    provenance_json = os.path.join(args.output_dir, f"{args.prefix}.retained_demux_provenance.json")

    total_alignments = 0
    pass_counters = Counter()
    retained_query_names = set()
    with pysam.AlignmentFile(args.input_bam, "rb") as source:
        for read in source.fetch(until_eof=True):
            total_alignments += 1
            if passes_filter(read, reference_lengths, args, pass_counters):
                retained_query_names.add(read.query_name)

    barcode_cache = {}
    barcode_cache_counts = Counter()
    sequence_records_seen = 0
    retained_sequence_records_seen = 0
    with pysam.AlignmentFile(args.input_bam, "rb") as source:
        for read in source.fetch(until_eof=True):
            sequence = sequence_for_barcode_assignment(read)
            if not sequence:
                continue
            sequence_records_seen += 1
            if read.query_name not in retained_query_names:
                continue
            retained_sequence_records_seen += 1
            if read.query_name in barcode_cache:
                continue
            if args.assignment_mode == "query-prefix":
                assignment = assign_query_prefix(read.query_name, manifest["sampleTotals"])
            else:
                assignment = assign_barcode(sequence, regex, pattern_to_sample)
            if assignment is not None:
                sample, barcode, start = assignment
                barcode_cache[read.query_name] = (sample, barcode, start)
                barcode_cache_counts[sample] += query_weight(read.query_name)

    genotype_alignment_counts = Counter()
    genotype_unique_reads = defaultdict(set)
    sample_locus_unique_reads = defaultdict(set)
    sample_alignment_counts = Counter()
    sample_unique_reads = defaultdict(set)
    retained_unique_reads = set()
    unassigned_unique_reads = set()
    query_weights = {}
    write_filter_counters = Counter()
    with pysam.AlignmentFile(args.input_bam, "rb") as source:
        header = source.header.to_dict()
        comments = header.get("CO", [])
        comments.append(f"Filtered by lungfish fastq genotype: full-reference MD-tag mismatches <= max-mismatches; indels allowed; sample assignment mode={args.assignment_mode}; sample in LF tag.")
        header["CO"] = comments
        with pysam.AlignmentFile(output_bam, "wb", header=header) as dest:
            for read in source.fetch(until_eof=True):
                if not passes_filter(read, reference_lengths, args, write_filter_counters):
                    continue
                assignment = barcode_cache.get(read.query_name)
                if assignment is None:
                    sample = "unassigned"
                    barcode = ""
                    unassigned_unique_reads.add(read.query_name)
                else:
                    sample, barcode, _ = assignment
                    read.set_tag("LF", sample, value_type="Z")
                    read.set_tag("BC", barcode, value_type="Z")
                    sample_unique_reads[sample].add(read.query_name)
                weight = query_weight(read.query_name)
                query_weights[read.query_name] = weight
                retained_unique_reads.add(read.query_name)
                key = (sample, read.reference_name)
                genotype_alignment_counts[key] += weight
                genotype_unique_reads[key].add(read.query_name)
                locus_group = raw_locus_group_for_genotype(read.reference_name)
                sample_locus_unique_reads[(sample, locus_group)].add(read.query_name)
                sample_alignment_counts[sample] += weight
                dest.write(read)
    pysam.index(output_bam)

    retained_unique_count = weighted_query_count(retained_unique_reads, query_weights)
    assigned_unique_count = sum(
        weighted_query_count(values, query_weights)
        for sample, values in sample_unique_reads.items()
        if sample != "unassigned"
    )
    unassigned_unique_count = weighted_query_count(unassigned_unique_reads, query_weights)
    retained_percent = (retained_unique_count / total_input_reads * 100.0) if total_input_reads else None

    genotype_rows = []
    for (sample, genotype), count in sorted(genotype_alignment_counts.items(), key=lambda item: (item[0][0], -item[1], item[0][1])):
        unique_read_count = weighted_query_count(genotype_unique_reads[(sample, genotype)], query_weights)
        sample_total = manifest["sampleTotals"].get(sample)
        sample_unique_count = (
            weighted_query_count(sample_unique_reads.get(sample, set()), query_weights)
            if sample != "unassigned"
            else unassigned_unique_count
        )
        genotype_rows.append({
            "sample": sample,
            "genotype": genotype,
            "passed_alignments": count,
            "passed_unique_reads": unique_read_count,
            "sample_total_reads": sample_total if sample_total is not None else "",
            "sample_unique_retained_reads": sample_unique_count,
            "sample_unique_retained_percent": f"{(sample_unique_count / sample_total * 100.0):.6f}" if sample_total else "",
            "overall_input_reads": total_input_reads,
            "overall_unique_retained_reads": retained_unique_count,
            "overall_unique_retained_percent": f"{retained_percent:.6f}" if retained_percent is not None else "",
        })
    write_csv(summary_csv, genotype_rows, ["sample", "genotype", "passed_alignments", "passed_unique_reads", "sample_total_reads", "sample_unique_retained_reads", "sample_unique_retained_percent", "overall_input_reads", "overall_unique_retained_reads", "overall_unique_retained_percent"])

    sample_rows = []
    all_samples = sorted(set(sample_alignment_counts) | set(manifest["sampleTotals"]))
    for sample in all_samples:
        sample_total = manifest["sampleTotals"].get(sample)
        unique_count = (
            weighted_query_count(sample_unique_reads.get(sample, set()), query_weights)
            if sample != "unassigned"
            else unassigned_unique_count
        )
        sample_rows.append({
            "sample": sample,
            "passed_alignments": sample_alignment_counts.get(sample, 0),
            "passed_unique_reads": unique_count,
            "sample_total_reads": sample_total if sample_total is not None else "",
            "sample_unique_retained_percent": f"{(unique_count / sample_total * 100.0):.6f}" if sample_total else "",
            "overall_input_reads": total_input_reads,
            "overall_unique_retained_percent": f"{retained_percent:.6f}" if retained_percent is not None else "",
        })
    write_csv(sample_csv, sample_rows, ["sample", "passed_alignments", "passed_unique_reads", "sample_total_reads", "sample_unique_retained_percent", "overall_input_reads", "overall_unique_retained_percent"])

    completed_at = utc_now()
    stats = {
        "tool": "lungfish fastq ont-barcode-genotype retained-read filter",
        "version": "1",
        "startedAt": started_at,
        "completedAt": completed_at,
        "wallClockSeconds": time.time() - start_time,
        "inputBAM": args.input_bam,
        "referenceFasta": args.reference_fasta,
        "barcodes": args.barcodes,
        "demuxManifest": args.demux_manifest,
        "sampleManifest": args.sample_manifest,
        "assignmentMode": args.assignment_mode,
        "outputBAM": output_bam,
        "outputBAI": output_bai,
        "summaryCSV": summary_csv,
        "sampleCSV": sample_csv,
        "totalInputReads": total_input_reads,
        "totalAlignments": total_alignments,
        "sequenceRecordsSeen": sequence_records_seen,
        "retainedSequenceRecordsSeen": retained_sequence_records_seen,
        "retainedQueryNamesBeforeDemux": len(retained_query_names),
        "barcodeCacheReadCount": len(barcode_cache),
        "barcodeCacheCounts": dict(barcode_cache_counts),
        "passCounters": dict(pass_counters),
        "writeFilterCounters": dict(write_filter_counters),
        "passedAlignments": pass_counters["passed"],
        "retainedUniqueReads": retained_unique_count,
        "retainedUniquePercentOfTotalReads": retained_percent,
        "assignedUniqueRetainedReads": assigned_unique_count,
        "unassignedUniqueRetainedReads": unassigned_unique_count,
        "requireBothEndSoftclips": args.require_both_end_softclips,
        "requireFullReferenceSpan": True,
        "allowIndels": True,
        "maxMismatches": args.max_mismatches,
        "demuxRetainedReadsOnly": args.assignment_mode == "barcode",
        "minSupport": args.min_support,
        "haplotypeMinSamplePercent": args.haplotype_min_sample_percent,
        "haplotypeMinLocusPercent": args.haplotype_min_locus_percent,
        "haplotypeMinLocusPercentOverrides": args.haplotype_min_locus_percent_override,
    }
    with open(stats_json, "w") as handle:
        json.dump(stats, handle, indent=2, sort_keys=True)
        handle.write("\n")

    provenance = {
        "toolName": "lungfish fastq ont-barcode-genotype retained-read filter",
        "toolVersion": "1",
        "argv": sys.argv,
        "reproducibleCommand": args.provenance_command or " ".join(sys.argv),
        "options": vars(args),
        "resolvedDefaults": {
            "maxMismatches": args.max_mismatches,
            "requireBothEndSoftclips": args.require_both_end_softclips,
            "minSupport": args.min_support,
            "haplotypeMinSamplePercent": 0.0,
            "haplotypeMinLocusPercent": 0.0,
            "haplotypeMinLocusPercentOverrides": [],
            "demuxRetainedReadsOnly": args.assignment_mode == "barcode"
        },
        "runtimeIdentity": {"python": sys.version, "platform": platform.platform(), "pysam": pysam.__version__, "executable": sys.executable},
        "inputs": [record for record in [
            file_record(args.input_bam, "input"),
            file_record(args.reference_fasta, "input"),
            file_record(args.barcodes, "input") if args.barcodes else None,
            file_record(args.demux_manifest, "input"),
            file_record(args.sample_manifest, "input") if args.sample_manifest else None,
        ] if record is not None],
        "outputs": [file_record(output_bam, "output"), file_record(output_bai, "output"), file_record(summary_csv, "output"), file_record(sample_csv, "output"), file_record(stats_json, "output")],
        "exitStatus": 0,
        "wallClockSeconds": stats["wallClockSeconds"],
        "stderr": "",
        "startedAt": started_at,
        "completedAt": completed_at,
    }
    with open(provenance_json, "w") as handle:
        json.dump(provenance, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(json.dumps(stats, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
"""#

private let reportScript = #"""
#!/usr/bin/env python3
import argparse
import csv
import gzip
import hashlib
import json
import os
import platform
import re
import sys
import time
import warnings
from collections import defaultdict
from copy import copy, deepcopy
from datetime import datetime, timezone

import openpyxl
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter


GENE_PREFIXES = (
    "DQB1",
    "DQA1",
    "DPB1",
    "DPA1",
    "DRB1",
    "DRB",
    "B11L",
    "B17",
    "B20",
    "A1",
    "A2",
    "A3",
    "A4",
    "AG",
    "B",
    "E",
    "F",
    "G",
    "I",
)


def parse_args():
    parser = argparse.ArgumentParser(description="Write ONT retained-demux genotype CSVs to an Excel workbook.")
    parser.add_argument("--genotypes-csv", required=True)
    parser.add_argument("--samples-csv", required=True)
    parser.add_argument("--stats-json", required=True)
    parser.add_argument("--reference-fasta", required=True)
    parser.add_argument("--barcode-definitions", required=True)
    parser.add_argument("--output-xlsx", required=True)
    parser.add_argument("--provenance-json", required=True)
    parser.add_argument("--analysis-name")
    parser.add_argument("--run-name", default="ont-barcode-genotyping")
    parser.add_argument("--comparison-workbook")
    parser.add_argument("--comparison-name", default="Illumina-31262")
    parser.add_argument("--haplotype-analysis-json")
    parser.add_argument("--client-current-workbook", action="store_true")
    parser.add_argument("--haplotype-definition-json")
    parser.add_argument("--primary-workbook")
    parser.add_argument("--provenance-command")
    args = parser.parse_args()
    if not args.analysis_name:
        args.analysis_name = args.run_name
    return args


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def sha256(path, chunk_size=1024 * 1024):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(chunk_size)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path, role):
    try:
        stat = os.stat(path)
    except OSError:
        return {"path": path, "role": role, "exists": False}
    return {"path": path, "role": role, "exists": True, "sizeBytes": stat.st_size, "sha256": sha256(path)}


def clean_csv_text(value):
    if value is None:
        return ""
    return str(value).replace("\ufeff", "").strip()


def read_csv(path):
    with open(path, newline="") as handle:
        reader = csv.DictReader(handle)
        fieldnames = [clean_csv_text(field) for field in (reader.fieldnames or [])]
        rows = [
            {
                clean_csv_text(key): clean_csv_text(value)
                for key, value in row.items()
                if key is not None
            }
            for row in reader
        ]
        return fieldnames, rows


def as_number(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return value
    text = str(value).strip()
    if not text:
        return None
    try:
        number = float(text)
    except ValueError:
        return None
    if number.is_integer():
        return int(number)
    return number


def display_value(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return value
    text = str(value).strip()
    if text == "":
        return None
    number = as_number(text)
    return number if number is not None else text


def load_genotype_counts(rows):
    counts = defaultdict(dict)
    for row in rows:
        sample = row.get("sample", "").strip()
        genotype = row.get("genotype", "").strip()
        if not sample or not genotype:
            continue
        count = as_number(row.get("passed_alignments"))
        if count is None:
            count = 0
        counts[sample][genotype] = counts[sample].get(genotype, 0) + int(count)
    return counts


def load_sample_stats(rows):
    stats = {}
    for row in rows:
        sample = row.get("sample", "").strip()
        if sample:
            stats[sample] = row
    return stats


def has_positive_retained_reads(row):
    for key in ("passed_alignments", "passed_unique_reads", "sample_unique_retained_reads"):
        value = as_number(row.get(key))
        if value is not None and value > 0:
            return True
    return False


def report_sample_names(sample_rows, genotype_counts):
    names = []
    seen = set()

    for row in sample_rows:
        sample = row.get("sample", "").strip()
        if not is_assigned_sample_name(sample) or sample in seen:
            continue
        genotype_total = sum(int(count) for count in genotype_counts.get(sample, {}).values())
        if has_positive_retained_reads(row) or genotype_total > 0:
            names.append(sample)
            seen.add(sample)

    for sample, counts in genotype_counts.items():
        if not is_assigned_sample_name(sample) or sample in seen:
            continue
        if sum(int(count) for count in counts.values()) > 0:
            names.append(sample)
            seen.add(sample)

    return names


def rows_for_samples(rows, samples):
    sample_set = set(samples)
    return [row for row in rows if row.get("sample", "").strip() in sample_set]


def is_assigned_sample_name(sample):
    text = str(sample or "").strip()
    return bool(text) and text.lower() != "unassigned"


def assigned_sample_rows(rows):
    return [row for row in rows if is_assigned_sample_name(row.get("sample"))]


def open_text(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt")
    return open(path, "rt")


def reference_names(path):
    names = []
    with open_text(path) as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if line.startswith(">"):
                names.append(line[1:].split()[0])
    return names


def clean_expected_part(part):
    part = re.sub(r"^\d+_", "", part)
    for prefix in GENE_PREFIXES:
        marker = f"_{prefix}_"
        if marker in part:
            part = part.split(marker, 1)[1]
            part = f"{prefix}_{part}"
            break
        if part.startswith(f"{prefix}_"):
            break
    else:
        part = re.sub(r"^M[0-9A-Za-z]+_", "", part)
    part = re.sub(r"_\d+bp$", "", part)
    return part


def tokens_for_expected(label):
    if label is None:
        return []
    tokens = []
    for raw_part in str(label).split(":"):
        token = clean_expected_part(raw_part.strip())
        if token:
            tokens.append(token)

    expanded = []
    for token in tokens:
        expanded.append(token)
        if token == "G_02_0508_g48c":
            expanded.append("G_02_05/08_g48c")
        if token == "AG_g3ex":
            expanded.append("AG_03g")
        if token == "AG_g6ex":
            expanded.append("AG_06g")
        if token in {"AG_06g1", "AG_06g2_t135a"}:
            expanded.append("AG_06g")
        if token == "B11L_01g2ex":
            expanded.append("B11L_01")
        if token == "DPA1_02_02":
            expanded.append("DPA1_02g")
        if token == "I_01g":
            expanded.extend(["I_01g1", "I_01g2", "I_01g3", "I_01g4"])
        if token == "B_098g":
            expanded.extend(["B_098g1", "B_098g2", "B_098g3"])

    deduped = []
    for token in expanded:
        if token and token not in deduped:
            deduped.append(token)
    return deduped


def matched_count(tokens, sample_counts):
    if not tokens:
        return 0, []
    total = 0
    names = []
    for genotype, count in sample_counts.items():
        if any(token in genotype for token in tokens):
            total += int(count)
            names.append(genotype)
    return total, names


def safe_sheet_title(workbook, desired, fallback):
    invalid = set("[]:*?/\\")
    title = "".join("_" if char in invalid else char for char in str(desired or fallback)).strip()
    title = title or fallback
    title = title[:31].rstrip()
    existing = {sheet.title for sheet in workbook.worksheets}
    if title not in existing:
        return title
    base = title
    index = 2
    while True:
        suffix = f" {index}"
        candidate = f"{base[:31 - len(suffix)]}{suffix}".rstrip()
        if candidate not in existing:
            return candidate
        index += 1


def remove_tables(ws):
    for name in list(ws.tables.keys()):
        del ws.tables[name]


def copy_conditional_formatting(source, destination):
    destination.conditional_formatting._cf_rules = deepcopy(source.conditional_formatting._cf_rules)


def sample_columns(ws):
    columns = []
    for col in range(4, ws.max_column + 1):
        value = ws.cell(2, col).value
        if value is None or str(value).strip() == "":
            continue
        columns.append((col, str(value).strip()))
    return columns


def formula_range(sample_cols, row):
    if not sample_cols:
        return None
    first = get_column_letter(sample_cols[0][0])
    last = get_column_letter(sample_cols[-1][0])
    return f"{first}{row}:{last}{row}"


def copy_cell_style(source, destination):
    if source.has_style:
        destination.font = copy(source.font)
        destination.fill = copy(source.fill)
        destination.border = copy(source.border)
        destination.alignment = copy(source.alignment)
        destination.number_format = source.number_format
        destination.protection = copy(source.protection)


def compact_analysis_sample_columns(ws, samples):
    start_col = 4
    target_count = len(samples)
    existing_count = max(0, ws.max_column - start_col + 1)

    if existing_count > target_count:
        ws.delete_cols(start_col + target_count, existing_count - target_count)
    elif existing_count < target_count:
        style_source_col = start_col + existing_count - 1 if existing_count > 0 else 3
        for col in range(start_col + existing_count, start_col + target_count):
            source_letter = get_column_letter(style_source_col)
            target_letter = get_column_letter(col)
            ws.column_dimensions[target_letter].width = ws.column_dimensions[source_letter].width
            for row in range(1, ws.max_row + 1):
                copy_cell_style(ws.cell(row, style_source_col), ws.cell(row, col))

    for offset, sample in enumerate(samples):
        col = start_col + offset
        ws.cell(1, col).value = sample
        ws.cell(2, col).value = sample

    return sample_columns(ws)


def copied_template_workbook(path, analysis_name, comparison_name):
    wb = load_workbook(path)
    while len(wb.worksheets) > 1:
        wb.remove(wb.worksheets[-1])
    analysis_ws = wb.worksheets[0]
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        comparison_ws = wb.copy_worksheet(analysis_ws)
    copy_conditional_formatting(analysis_ws, comparison_ws)
    analysis_ws.title = safe_sheet_title(wb, analysis_name, "ONT08")
    comparison_ws.title = safe_sheet_title(wb, comparison_name, "Illumina-31262")
    remove_tables(analysis_ws)
    remove_tables(comparison_ws)
    return wb, analysis_ws, comparison_ws


def row_looks_like_allele_call(ws, row):
    label = ws.cell(row, 1).value
    if row < 22 or not isinstance(label, str):
        return False
    b_value = ws.cell(row, 2).value
    c_value = ws.cell(row, 3).value
    if isinstance(b_value, str) and b_value.startswith("="):
        return True
    if isinstance(c_value, str) and c_value.startswith("="):
        return True
    if as_number(b_value) is not None or as_number(c_value) is not None:
        return True
    return False


def fill_formula_totals(ws, rows, sample_cols):
    for row in rows:
        cell_range = formula_range(sample_cols, row)
        if not cell_range:
            continue
        ws.cell(row, 2).value = f"=SUM({cell_range})"
        ws.cell(row, 3).value = f"=COUNT({cell_range})"


def sample_numbers(ws, row, sample_cols):
    values = []
    for col, _sample in sample_cols:
        number = as_number(ws.cell(row, col).value)
        if number is not None:
            values.append(number)
    return values


def fill_read_count_summary_values(ws, row, sample_cols):
    values = sample_numbers(ws, row, sample_cols)
    total = sum(values) if values else 0
    average = total / len(values) if values else 0
    ws.cell(row, 2).value = total
    ws.cell(row, 3).value = average


def fill_subtotal_observed_values(ws, rows, sample_cols):
    for row in rows:
        values = sample_numbers(ws, row, sample_cols)
        ws.cell(row, 2).value = sum(values) if values else 0
        ws.cell(row, 3).value = sum(1 for value in values if value > 0)


def clear_cells(ws, row, start_col=1):
    for col in range(start_col, ws.max_column + 1):
        ws.cell(row, col).value = None


def clear_analysis_template_sample_values(ws):
    if ws.max_row >= 5:
        ws.cell(3, 1).value = "Filtered exact-match read count"
        clear_cells(ws, 4)
        clear_cells(ws, 5)

    for row in range(6, min(ws.max_row, 19) + 1):
        clear_cells(ws, row, start_col=2)

    if ws.max_row >= 20 and ws.cell(20, 1).value == "Comments":
        ws.cell(20, 2).value = "Subtotal"
        ws.cell(20, 3).value = "# Obs."
        clear_cells(ws, 20, start_col=4)


def row_has_sample_count(ws, row, sample_cols):
    for col, _sample in sample_cols:
        count = as_number(ws.cell(row, col).value) or 0
        if count > 0:
            return True
    return False


def prune_zero_allele_rows(ws, allele_rows, sample_cols):
    for row in sorted(allele_rows, reverse=True):
        if not row_has_sample_count(ws, row, sample_cols):
            ws.delete_rows(row)


def is_locus_header_row(ws, row):
    label = ws.cell(row, 1).value
    return row >= 21 and isinstance(label, str) and not row_looks_like_allele_call(ws, row)


def prune_empty_locus_headers(ws):
    header_rows = [row for row in range(21, ws.max_row + 1) if is_locus_header_row(ws, row)]
    for index in range(len(header_rows) - 1, -1, -1):
        row = header_rows[index]
        next_header = header_rows[index + 1] if index + 1 < len(header_rows) else ws.max_row + 1
        has_allele = any(row_looks_like_allele_call(ws, candidate) for candidate in range(row + 1, next_header))
        if not has_allele:
            ws.delete_rows(row)


def fill_analysis_sheet(ws, genotype_counts, sample_stats, samples):
    cols = compact_analysis_sample_columns(ws, samples)
    clear_analysis_template_sample_values(ws)

    allele_rows = [row for row in range(1, ws.max_row + 1) if row_looks_like_allele_call(ws, row)]

    for col, sample in cols:
        stats = sample_stats.get(sample, {})
        ws.cell(3, col).value = display_value(stats.get("passed_alignments"))

    matched_by_row_sample = {}
    for row in allele_rows:
        label = ws.cell(row, 1).value
        tokens = tokens_for_expected(label)
        for col, sample in cols:
            count, names = matched_count(tokens, genotype_counts.get(sample, {}))
            ws.cell(row, col).value = count if count > 0 else None
            matched_by_row_sample[(row, sample)] = (count, names, tokens)
    prune_zero_allele_rows(ws, allele_rows, cols)
    prune_empty_locus_headers(ws)
    final_allele_rows = [row for row in range(1, ws.max_row + 1) if row_looks_like_allele_call(ws, row)]
    fill_read_count_summary_values(ws, 3, cols)
    fill_subtotal_observed_values(ws, final_allele_rows, cols)
    return cols, allele_rows, matched_by_row_sample


def style_tabular_sheet(ws):
    header_fill = PatternFill("solid", fgColor="4472C4")
    header_font = Font(color="FFFFFF", bold=True)
    thin_gray = Side(style="thin", color="D9E2F3")
    for cell in ws[1]:
        cell.fill = header_fill
        cell.font = header_font
        cell.alignment = Alignment(horizontal="center")
        cell.border = Border(bottom=thin_gray)
    ws.freeze_panes = "A2"
    if ws.max_row and ws.max_column:
        ws.auto_filter.ref = ws.dimensions
    for col in range(1, ws.max_column + 1):
        letter = get_column_letter(col)
        max_len = 0
        for row in range(1, min(ws.max_row, 200) + 1):
            value = ws.cell(row, col).value
            if value is not None:
                max_len = max(max_len, len(str(value)))
        ws.column_dimensions[letter].width = min(max(max_len + 2, 10), 48)


def write_csv_sheet(wb, title, headers, rows):
    ws = wb.create_sheet(title=safe_sheet_title(wb, title, title[:31] or "Sheet"))
    ws.append(headers)
    for row in rows:
        ws.append([display_value(row.get(header)) for header in headers])
    style_tabular_sheet(ws)
    return ws


def write_stats_sheet(wb, stats):
    ws = wb.create_sheet(title=safe_sheet_title(wb, "Run Stats", "Run Stats"))
    ws.append(["metric", "value"])
    for key in sorted(stats):
        value = stats[key]
        if isinstance(value, (dict, list)):
            value = json.dumps(value, sort_keys=True)
        ws.append([key, display_value(value)])
    style_tabular_sheet(ws)
    return ws


def load_haplotype_analysis(path):
    if not path:
        return None
    with open(path) as handle:
        return json.load(handle)


def load_haplotype_definition(path):
    if not path:
        return {}
    with open(path) as handle:
        return json.load(handle)


def haplotype_calls_by_sample_locus(haplotype_analysis):
    by_sample = {}
    if not haplotype_analysis:
        return by_sample
    for sample in haplotype_analysis.get("samples", []):
        sample_id = str(sample.get("sample", "")).strip()
        if not sample_id:
            continue
        locus_map = {}
        for call in sample.get("calls", []):
            locus = str(call.get("locus", "")).strip()
            if locus:
                locus_map[locus] = call
        by_sample[sample_id] = locus_map
    return by_sample


def haplotype_row_targets(ws):
    targets = []
    for row in range(1, min(ws.max_row, 40) + 1):
        value = ws.cell(row, 1).value
        if not isinstance(value, str):
            continue
        match = re.match(r"^(MHC-[A-Za-z0-9]+) Haplotype ([12])$", value.strip())
        if match:
            targets.append((row, match.group(1), int(match.group(2))))
    return targets


def noncalled_haplotype_summary(locus_calls):
    messages = []
    for locus in sorted(locus_calls):
        call = locus_calls[locus]
        status = call.get("status")
        if status in (None, "called"):
            continue
        left = call.get("haplotype1") or ""
        right = call.get("haplotype2") or ""
        label = left if left == right or not right else f"{left}/{right}"
        messages.append(f"{locus}: {label}")
    return "; ".join(messages)


def fill_haplotype_rows(ws, sample_cols, haplotype_analysis):
    by_sample = haplotype_calls_by_sample_locus(haplotype_analysis)
    if not by_sample:
        return
    for row, locus, index in haplotype_row_targets(ws):
        key = f"haplotype{index}"
        for col, sample in sample_cols:
            call = by_sample.get(sample, {}).get(locus)
            ws.cell(row, col).value = call.get(key) if call else None
    comments_row = None
    for row in range(1, min(ws.max_row, 40) + 1):
        if ws.cell(row, 1).value == "Comments":
            comments_row = row
            break
    if comments_row:
        for col, sample in sample_cols:
            summary = noncalled_haplotype_summary(by_sample.get(sample, {}))
            ws.cell(comments_row, col).value = summary or None


def haplotype_loci_for_report(haplotype_analysis):
    fallback = [
        "MHC-A",
        "MHC-B",
        "MHC-DRB",
        "MHC-DQA",
        "MHC-DQB",
        "MHC-DPA",
        "MHC-DPB",
    ]
    if not haplotype_analysis:
        return fallback
    loci = []
    seen = set()
    for sample in haplotype_analysis.get("samples", []):
        for call in sample.get("calls", []):
            locus = str(call.get("locus", "")).strip()
            if locus and locus not in seen:
                loci.append(locus)
                seen.add(locus)
    return loci if loci else fallback


def write_haplotype_sheet(wb, haplotype_analysis):
    if not haplotype_analysis:
        return None
    ws = wb.create_sheet(title=safe_sheet_title(wb, "Haplotype Calls", "Haplotype Calls"))
    headers = [
        "sample",
        "locus",
        "haplotype_1",
        "haplotype_2",
        "status",
        "observed_genotype_count",
        "matched_haplotypes",
        "observed_genotypes",
        "notes",
    ]
    ws.append(headers)
    for sample in haplotype_analysis.get("samples", []):
        sample_id = sample.get("sample")
        for call in sample.get("calls", []):
            ws.append([
                sample_id,
                call.get("locus"),
                call.get("haplotype1"),
                call.get("haplotype2"),
                call.get("status"),
                call.get("observedGenotypeCount"),
                ";".join(item.get("name", "") for item in call.get("matchedHaplotypes", [])),
                ";".join(call.get("observedGenotypes", [])),
                call.get("notes"),
            ])
    style_tabular_sheet(ws)
    return ws


MCM_CLIENT_SHEET_NAMES = [
    "Interpretation Guide",
    "MHC Alleles Per MHC Haplotype",
    "Abbreviated Haplotypes",
    "Full Sequencing Results 1",
    "Custom Sort",
]

MCM_FAMILIES = ["M1", "M2", "M3", "M4", "M5", "M6", "M7"]
MCM_REPORT_LOCI = ["MHC-A", "MHC-B", "MHC-DRB", "MHC-DQ", "MHC-DP"]
MCM_FULL_SUMMARY_LOCI = ["MHC-A", "MHC-B", "MHC-DRB", "MHC-DQA", "MHC-DQB", "MHC-DPA", "MHC-DPB"]
MCM_SUMMARY_DISPLAY_LOCI = [
    ("MHC-A", "MHC-A"),
    ("MHC-B", "MHC-B"),
    ("MHC-DRB", "MHC-DRB"),
    ("MHC-DQ", "MHC-DQA/B"),
    ("MHC-DP", "MHC-DPA/B"),
]
MCM_HAPLOTYPE_STYLES = {
    "M1": {"font": "000000"},
    "M2": {"font": "FF0000"},
    "M3": {"font": "0432FF"},
    "M4": {"font": "00B050"},
    "M5": {"font": "FFC000"},
    "M6": {"font": "595959"},
    "M7": {"font": "7030A0"},
}
MCM_ALLELE_SECTION_ORDER = [
    "Mafa-F alleles",
    "Mafa-G alleles",
    "Mafa-AG alleles",
    "Mafa-A major alleles",
    "Mafa-A minor alleles",
    "Mafa-70 alleles",
    "Mafa-E alleles",
    "Mafa-B alleles",
    "Mafa-DRB alleles",
    "Mafa-DQA/DQB alleles",
    "Mafa-DPA/DPB alleles",
]
MCM_ABBREVIATED_COLUMN_A_WIDTH = 17.33203125
MCM_CUSTOM_SORT_COLUMN_A_WIDTH = 16.83203125
MCM_FULL_COLUMN_A_WIDTH = 37.1640625


def mcm_family(value):
    if value is None:
        return None
    text = str(value).strip()
    if not text or text == "-" or text.startswith("ERR:"):
        return None
    match = re.search(r"\b(M[1-7])", text)
    return match.group(1) if match else None


def mcm_families(value):
    if value is None:
        return []
    seen = set()
    families = []
    for match in re.finditer(r"M[1-7]", str(value)):
        family = match.group(0)
        if family not in seen:
            families.append(family)
            seen.add(family)
    return families


def mcm_style_for_family(family):
    return MCM_HAPLOTYPE_STYLES.get(family, {})


def clear_cell_fill(cell):
    cell.fill = PatternFill(fill_type=None)


def apply_haplotype_cell_style(cell, value):
    family = mcm_family(value)
    clear_cell_fill(cell)
    if not family:
        if isinstance(value, str) and value.startswith("ERR:"):
            cell.font = Font(name="Calibri", size=11, color="9C0006", bold=True)
            cell.alignment = Alignment(horizontal="center", vertical="center")
        return
    style = mcm_style_for_family(family)
    if not style:
        return
    cell.font = Font(name="Calibri", size=11, color=style["font"], bold=True)
    cell.alignment = Alignment(horizontal="center", vertical="center")


def apply_basic_sheet_format(ws, freeze_panes=None, auto_filter=True):
    header_fill = PatternFill("solid", fgColor="D9EAF7")
    header_font = Font(name="Calibri", size=11, bold=True)
    body_font = Font(name="Calibri", size=11)
    thin_gray = Side(style="thin", color="D9D9D9")
    for row in ws.iter_rows():
        for cell in row:
            cell.border = Border(bottom=thin_gray)
            cell.font = body_font
            cell.alignment = Alignment(vertical="top", wrap_text=True)
    for cell in ws[1]:
        cell.fill = header_fill
        cell.font = header_font
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
    if freeze_panes:
        ws.freeze_panes = freeze_panes
    if auto_filter and ws.max_row and ws.max_column:
        ws.auto_filter.ref = ws.dimensions
    else:
        ws.auto_filter.ref = None
    for col in range(1, ws.max_column + 1):
        letter = get_column_letter(col)
        max_len = 0
        for row in range(1, min(ws.max_row, 120) + 1):
            value = ws.cell(row, col).value
            if value is not None:
                parts = str(value).splitlines() or [str(value)]
                max_len = max(max_len, max(len(part) for part in parts))
        ws.column_dimensions[letter].width = min(max(max_len + 2, 10), 36)


def set_row_label_style(ws, row):
    ws.cell(row, 1).font = Font(name="Calibri", size=11, bold=True)
    clear_cell_fill(ws.cell(row, 1))


def clear_mcm_sheet_fills(ws):
    for row in ws.iter_rows():
        for cell in row:
            clear_cell_fill(cell)


def is_mcm_full_summary_label(value):
    text = str(value or "").strip()
    if text in {
        "Client ID",
        "GS ID",
        "Mapped Read Count",
        "total_read_count",
        "percent_reads_unmapped",
        "Comments",
    }:
        return True
    return text.startswith("MHC-") and " Haplotype " in text


def mcm_allele_name_font(value):
    families = mcm_families(value)
    if len(families) == 1:
        style = mcm_style_for_family(families[0])
        if style:
            return Font(name="Calibri", size=11, color=style["font"], bold=False)
    return Font(name="Calibri", size=11, bold=False)


def apply_mcm_summary_sheet_format(ws, custom_sort=False):
    clear_mcm_sheet_fills(ws)
    ws.column_dimensions["A"].width = MCM_CUSTOM_SORT_COLUMN_A_WIDTH if custom_sort else MCM_ABBREVIATED_COLUMN_A_WIDTH
    for cell in ws[1]:
        cell.font = Font(name="Calibri", size=12 if custom_sort else 11, bold=True)
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
    section_labels = {
        "MHC homozygous MCM animals",
        "MHC heterozygous  MCM animals",
        "MHC recombinant  MCM animals",
        "Need to Repeat",
    }
    for row in range(2, ws.max_row + 1):
        first = ws.cell(row, 1).value
        if first in section_labels:
            ws.cell(row, 1).font = Font(name="Arial", size=14, bold=True)
            ws.cell(row, 1).alignment = Alignment(horizontal="left", vertical="center")
            continue
        if first not in (None, ""):
            ws.cell(row, 1).font = Font(name="Calibri", size=11, bold=True)
            ws.cell(row, 1).alignment = Alignment(horizontal="center", vertical="center")


def apply_mcm_full_sheet_format(ws):
    clear_mcm_sheet_fills(ws)
    ws.column_dimensions["A"].width = MCM_FULL_COLUMN_A_WIDTH
    for row in range(1, ws.max_row + 1):
        cell = ws.cell(row, 1)
        if cell.value not in (None, ""):
            if cell.value in MCM_ALLELE_SECTION_ORDER:
                cell.font = Font(name="Calibri", size=14, bold=True)
            elif is_mcm_full_summary_label(cell.value):
                cell.font = Font(name="Calibri", size=11, bold=True)
            else:
                cell.font = mcm_allele_name_font(cell.value)
            cell.alignment = Alignment(horizontal="left", vertical="center", wrap_text=True)


def ordered_loci_from_calls(calls_by_sample_locus):
    seen = set()
    ordered = []
    for locus in MCM_REPORT_LOCI:
        if any(report_call_for_locus(calls, locus) for calls in calls_by_sample_locus.values()):
            ordered.append(locus)
            seen.add(locus)
    for calls in calls_by_sample_locus.values():
        for locus in calls:
            normalized = summary_locus_for_call(locus)
            if normalized not in seen:
                ordered.append(normalized)
                seen.add(normalized)
    return ordered if ordered else MCM_REPORT_LOCI


def summary_locus_for_call(locus):
    if locus in ("MHC-DQA", "MHC-DQB"):
        return "MHC-DQ"
    if locus in ("MHC-DPA", "MHC-DPB"):
        return "MHC-DP"
    return locus


def report_call_for_locus(locus_calls, locus):
    if not locus_calls:
        return None
    if locus in locus_calls:
        return locus_calls.get(locus)
    if locus in ("MHC-DQA", "MHC-DQB", "MHC-DQ"):
        return locus_calls.get("MHC-DQ") or locus_calls.get("MHC-DQA") or locus_calls.get("MHC-DQB")
    if locus in ("MHC-DPA", "MHC-DPB", "MHC-DP"):
        return locus_calls.get("MHC-DP") or locus_calls.get("MHC-DPA") or locus_calls.get("MHC-DPB")
    return None


def call_value(call, index):
    if not call:
        return None
    value = call.get(f"haplotype{index}")
    if value is None:
        return None
    text = str(value).strip()
    return text if text else None


def inferred_homozygous_family(locus_calls, loci):
    families = []
    saw_called_locus = False
    for locus in loci:
        call = report_call_for_locus(locus_calls, locus)
        if not call:
            continue
        first = call_value(call, 1)
        second = call_value(call, 2)
        first_family = mcm_family(first)
        second_family = mcm_family(second)
        if first_family:
            saw_called_locus = True
            if first_family not in families:
                families.append(first_family)
        if second and second != "-":
            if not second_family:
                return None
            if second_family not in families:
                families.append(second_family)
        if isinstance(first, str) and first.startswith("ERR:"):
            return None
        if isinstance(second, str) and second.startswith("ERR:"):
            return None
    if saw_called_locus and len(families) == 1:
        return families[0]
    return None


def report_call_value(locus_calls, locus, index, loci):
    call = report_call_for_locus(locus_calls, locus)
    value = call_value(call, index)
    if index == 2 and value == "-":
        family = inferred_homozygous_family(locus_calls, loci)
        first = call_value(call, 1)
        if family and mcm_family(first) == family:
            return first
    return value


def whole_animal_haplotype(locus_calls, index, loci):
    families = []
    saw_nonempty = False
    for locus in loci:
        value = report_call_value(locus_calls, locus, index, loci)
        if value and value != "-":
            saw_nonempty = True
        family = mcm_family(value)
        if family and family not in families:
            families.append(family)
    if not saw_nonempty:
        return "?"
    if len(families) == 1:
        return families[0]
    if len(families) > 1:
        return "rec" + "".join(families)
    return "?"


def haplotype_comments(locus_calls):
    comments = []
    for locus in sorted(locus_calls):
        call = locus_calls[locus]
        status = call.get("status")
        notes = str(call.get("notes") or "").strip()
        values = [call_value(call, 1), call_value(call, 2)]
        if any(isinstance(value, str) and value.startswith("ERR:") for value in values if value):
            comments.append(f"{locus}: {'/'.join(value for value in values if value)}")
        elif status not in (None, "", "called"):
            comments.append(f"{locus}: {status}")
        if notes:
            comments.append(f"{locus}: {notes}")
    return "; ".join(comments)


def mcm_custom_sort_group(locus_calls, loci):
    h1 = whole_animal_haplotype(locus_calls, 1, loci)
    h2 = whole_animal_haplotype(locus_calls, 2, loci)
    comments = haplotype_comments(locus_calls)
    if h1 == "?" or h2 == "?" or "ERR:" in comments:
        return "Need to Repeat"
    if str(h1).startswith("rec") or str(h2).startswith("rec"):
        return "MHC recombinant  MCM animals"
    if h1 == h2:
        return "MHC homozygous MCM animals"
    return "MHC heterozygous  MCM animals"


def mcm_summary_values(sample, sample_stats, calls_by_sample_locus, loci):
    locus_calls = calls_by_sample_locus.get(sample, {})
    values = [
        sample,
        sample,
        read_count_for_sample(sample_stats, sample),
        whole_animal_haplotype(locus_calls, 1, loci),
        whole_animal_haplotype(locus_calls, 2, loci),
        None,
    ]
    for locus, _label in MCM_SUMMARY_DISPLAY_LOCI:
        values.append(report_call_value(locus_calls, locus, 1, loci))
    values.append(None)
    for locus, _label in MCM_SUMMARY_DISPLAY_LOCI:
        values.append(report_call_value(locus_calls, locus, 2, loci))
    values.append(haplotype_comments(locus_calls) or None)
    return values


def mcm_allele_section_label(genotype):
    text = str(genotype or "").strip()
    if text.startswith("01_"):
        return "Mafa-F alleles"
    if text.startswith("02_"):
        return "Mafa-G alleles"
    if text.startswith("04_") or text.startswith("AG_"):
        return "Mafa-AG alleles"
    if text.startswith("05_") or re.match(r"^A1_", text):
        return "Mafa-A major alleles"
    if text.startswith("06_") or re.match(r"^A[245]_", text):
        return "Mafa-A minor alleles"
    if text.startswith("07_") or text.startswith("10_"):
        return "Mafa-70 alleles"
    if text.startswith("11_") or text.startswith("E_"):
        return "Mafa-E alleles"
    if text.startswith("12_") or text.startswith("B") or text.startswith("I_"):
        return "Mafa-B alleles"
    if text.startswith("13_"):
        return "Mafa-DRB alleles"
    if text.startswith("14_"):
        return "Mafa-DQA/DQB alleles"
    if text.startswith("15_"):
        return "Mafa-DPA/DPB alleles"
    return "Mafa-DPA/DPB alleles"


def mcm_locus_for_allele_section(section):
    if section in {
        "Mafa-F alleles",
        "Mafa-G alleles",
        "Mafa-AG alleles",
        "Mafa-A major alleles",
        "Mafa-A minor alleles",
        "Mafa-70 alleles",
        "Mafa-E alleles",
    }:
        return "MHC-A"
    if section == "Mafa-B alleles":
        return "MHC-B"
    if section == "Mafa-DRB alleles":
        return "MHC-DRB"
    if section == "Mafa-DQA/DQB alleles":
        return "MHC-DQ"
    if section == "Mafa-DPA/DPB alleles":
        return "MHC-DP"
    return None


def sample_families_for_locus(locus_calls, locus):
    call = report_call_for_locus(locus_calls, locus)
    families = []
    for index in (1, 2):
        family = mcm_family(call_value(call, index))
        if family and family not in families:
            families.append(family)
    return families


def choose_count_style_family(genotype, locus_calls, section):
    genotype_families = mcm_families(genotype)
    if not genotype_families:
        return None
    locus = mcm_locus_for_allele_section(section)
    sample_families = sample_families_for_locus(locus_calls, locus)
    intersection = [family for family in MCM_FAMILIES if family in genotype_families and family in sample_families]
    if intersection:
        return intersection[0]
    if len(genotype_families) == 1:
        return genotype_families[0]
    return None


def apply_genotype_count_cell_style(cell, genotype, locus_calls, section):
    clear_cell_fill(cell)
    if cell.value in (None, ""):
        return
    family = choose_count_style_family(genotype, locus_calls, section)
    if family:
        style = mcm_style_for_family(family)
        cell.font = Font(name="Calibri", size=11, color=style.get("font", "000000"), bold=True)
    else:
        cell.font = Font(name="Calibri", size=11, bold=True)


def report_percent_value(value):
    if value is None or value == "":
        return "0%"
    try:
        number = float(value)
    except (TypeError, ValueError):
        text = str(value).strip()
        return text if text.endswith("%") else text
    if number.is_integer():
        return f"{int(number)}%"
    return f"{number:g}%"


def report_locus_percent_overrides(values):
    formatted = []
    for item in values or []:
        text = str(item or "").strip()
        if not text:
            continue
        if "=" not in text:
            formatted.append(text)
            continue
        locus, percent = text.split("=", 1)
        formatted.append(f"{locus.strip()}={report_percent_value(percent.strip())}")
    return "; ".join(formatted) if formatted else "None"


def write_interpretation_guide(ws, args, stats, haplotype_analysis, haplotype_definition):
    assay = (
        (haplotype_analysis or {}).get("assayID")
        or (haplotype_definition or {}).get("assayID")
        or ""
    )
    definition = (
        (haplotype_analysis or {}).get("definitionSetID")
        or (haplotype_definition or {}).get("id")
        or ""
    )
    rows = [
        ["Field", "Interpretation"],
        ["Client ID", "Client-provided sample identifier."],
        ["GS ID", "Genotyping sample identifier used in the run."],
        ["Mapped Read Count", "Filtered exact-match read count retained for the sample."],
        ["Haplotype 1 / Haplotype 2", "Whole-animal MCM haplotype assignment derived from per-locus calls."],
        ["recM", "Recombinant or mixed-family assignment across reported loci."],
        ["?", "No confident whole-animal haplotype assignment."],
        [None, None],
        ["Haplotype assay", assay],
        ["Haplotype definition", definition],
        ["Haplotype min reads", display_value(stats.get("minSupport"))],
        ["Haplotype min sample percent", report_percent_value(stats.get("haplotypeMinSamplePercent"))],
        ["Haplotype min locus percent", report_percent_value(stats.get("haplotypeMinLocusPercent"))],
        ["Haplotype locus percent overrides", report_locus_percent_overrides(stats.get("haplotypeMinLocusPercentOverrides"))],
        ["Haplotype filtering scope", "Read thresholds are used for haplotype assignment only; genotyping worksheets retain all observed reads."],
        ["Primary workbook", getattr(args, "primary_workbook", None) or ""],
        ["Report command", getattr(args, "provenance_command", None) or ""],
    ]
    for row in rows:
        ws.append(row)
    apply_basic_sheet_format(ws, auto_filter=False)


def definition_locus_rows(haplotype_definition):
    rows = []
    for locus in haplotype_definition.get("locusDefinitions", []) or []:
        locus_name = locus.get("sourceLocus") or locus.get("locus") or ""
        haplotypes = locus.get("haplotypes", []) or []
        name_by_family = {family: [] for family in MCM_FAMILIES}
        alleles_by_family = {family: [] for family in MCM_FAMILIES}
        for haplotype in haplotypes:
            name = haplotype.get("name")
            family = mcm_family(name)
            if not name or family not in name_by_family:
                continue
            name_by_family[family].append(str(name))
            alleles = [str(item) for item in haplotype.get("diagnosticAlleles", []) if item]
            alleles_by_family[family].extend(alleles)
        rows.append((locus_name, name_by_family, alleles_by_family))
    return rows


def write_mcm_alleles_per_haplotype(ws, haplotype_definition):
    ws.append(["Haplotype"] + MCM_FAMILIES)
    for locus_name, name_by_family, alleles_by_family in definition_locus_rows(haplotype_definition):
        ws.append([locus_name] + ["\n".join(name_by_family[family]) or None for family in MCM_FAMILIES])
        ws.append([f"{locus_name} diagnostic alleles"] + ["\n".join(alleles_by_family[family]) or None for family in MCM_FAMILIES])
    if ws.max_row == 1:
        ws.append(["No haplotype definition rows found"] + [None for _ in MCM_FAMILIES])
    apply_basic_sheet_format(ws, auto_filter=False)
    clear_mcm_sheet_fills(ws)
    for row in range(2, ws.max_row + 1):
        for col, family in enumerate(MCM_FAMILIES, start=2):
            value = ws.cell(row, col).value
            if value:
                apply_haplotype_cell_style(ws.cell(row, col), family)


def abbreviated_headers(loci):
    return (
        ["Client ID", "GS ID", "Mapped Read Count", "Haplotype 1", "Haplotype 2", None]
        + [f"{label} Haplotype 1" for _locus, label in MCM_SUMMARY_DISPLAY_LOCI]
        + [None]
        + [f"{label} Haplotype 2" for _locus, label in MCM_SUMMARY_DISPLAY_LOCI]
        + ["Comments"]
    )


def read_count_for_sample(sample_stats, sample):
    row = sample_stats.get(sample, {})
    return display_value(
        row.get("passed_alignments")
        or row.get("passed_unique_reads")
        or row.get("sample_unique_retained_reads")
    )


def write_abbreviated_haplotypes(ws, samples, sample_stats, calls_by_sample_locus, loci):
    headers = abbreviated_headers(loci)
    ws.append(headers)
    for sample in samples:
        ws.append(mcm_summary_values(sample, sample_stats, calls_by_sample_locus, loci))
    apply_basic_sheet_format(ws, auto_filter=False)
    apply_mcm_summary_sheet_format(ws)
    for row in range(2, ws.max_row + 1):
        for col in range(4, ws.max_column):
            apply_haplotype_cell_style(ws.cell(row, col), ws.cell(row, col).value)


def write_full_sequencing_results(ws, samples, sample_stats, genotype_counts, ordered_genotypes, calls_by_sample_locus, loci):
    ws.cell(1, 1).value = "Client ID"
    ws.cell(2, 1).value = "GS ID"
    ws.cell(3, 1).value = "Mapped Read Count"
    for offset, sample in enumerate(samples, start=4):
        ws.cell(1, offset).value = sample
        ws.cell(2, offset).value = sample
        ws.cell(3, offset).value = read_count_for_sample(sample_stats, sample)
    for row in range(1, 4):
        set_row_label_style(ws, row)

    row_index = 4
    ws.cell(row_index, 1).value = "total_read_count"
    for offset, sample in enumerate(samples, start=4):
        ws.cell(row_index, offset).value = display_value(sample_stats.get(sample, {}).get("sample_total_reads"))
    set_row_label_style(ws, row_index)
    row_index += 1
    ws.cell(row_index, 1).value = "percent_reads_unmapped"
    for offset, sample in enumerate(samples, start=4):
        retained = as_number(sample_stats.get(sample, {}).get("sample_unique_retained_percent"))
        ws.cell(row_index, offset).value = None if retained is None else max(0, 100 - retained)
    set_row_label_style(ws, row_index)
    row_index += 1

    summary_haplotype_rows = []
    for locus in MCM_FULL_SUMMARY_LOCI:
        for index in (1, 2):
            ws.cell(row_index, 1).value = f"{locus} Haplotype {index}"
            set_row_label_style(ws, row_index)
            for offset, sample in enumerate(samples, start=4):
                locus_calls = calls_by_sample_locus.get(sample, {})
                value = report_call_value(locus_calls, locus, index, loci)
                ws.cell(row_index, offset).value = value
            summary_haplotype_rows.append(row_index)
            row_index += 1

    while row_index < 20:
        row_index += 1
    ws.cell(row_index, 1).value = "Comments"
    ws.cell(row_index, 2).value = "Subtotal"
    ws.cell(row_index, 3).value = "# Obs."
    set_row_label_style(ws, row_index)
    for offset, sample in enumerate(samples, start=4):
        ws.cell(row_index, offset).value = haplotype_comments(calls_by_sample_locus.get(sample, {})) or None
    row_index += 1

    observed_genotypes_by_section = {section: [] for section in MCM_ALLELE_SECTION_ORDER}
    for genotype in ordered_genotypes:
        if not any(genotype_counts.get(sample, {}).get(genotype, 0) > 0 for sample in samples):
            continue
        section = mcm_allele_section_label(genotype)
        observed_genotypes_by_section.setdefault(section, []).append(genotype)

    allele_row_info = []
    for section in MCM_ALLELE_SECTION_ORDER:
        section_genotypes = observed_genotypes_by_section.get(section, [])
        if not section_genotypes:
            continue
        ws.cell(row_index, 1).value = section
        set_row_label_style(ws, row_index)
        row_index += 1
        for genotype in section_genotypes:
            ws.cell(row_index, 1).value = genotype
            total = 0
            observed = 0
            for offset, sample in enumerate(samples, start=4):
                count = genotype_counts.get(sample, {}).get(genotype, 0)
                if count > 0:
                    ws.cell(row_index, offset).value = count
                    total += count
                    observed += 1
            ws.cell(row_index, 2).value = total
            ws.cell(row_index, 3).value = observed
            allele_row_info.append((row_index, genotype, section))
            row_index += 1
    for section in sorted(observed_genotypes_by_section):
        if section in MCM_ALLELE_SECTION_ORDER or not observed_genotypes_by_section.get(section):
            continue
        ws.cell(row_index, 1).value = section
        set_row_label_style(ws, row_index)
        row_index += 1
        for genotype in observed_genotypes_by_section[section]:
            ws.cell(row_index, 1).value = genotype
            total = 0
            observed = 0
            for offset, sample in enumerate(samples, start=4):
                count = genotype_counts.get(sample, {}).get(genotype, 0)
                if count > 0:
                    ws.cell(row_index, offset).value = count
                    total += count
                    observed += 1
            ws.cell(row_index, 2).value = total
            ws.cell(row_index, 3).value = observed
            allele_row_info.append((row_index, genotype, section))
            row_index += 1

    apply_basic_sheet_format(ws, freeze_panes="D21", auto_filter=False)
    apply_mcm_full_sheet_format(ws)
    for row in summary_haplotype_rows:
        for col in range(4, ws.max_column + 1):
            apply_haplotype_cell_style(ws.cell(row, col), ws.cell(row, col).value)
    for row, genotype, section in allele_row_info:
        for col, sample in enumerate(samples, start=4):
            apply_genotype_count_cell_style(
                ws.cell(row, col),
                genotype,
                calls_by_sample_locus.get(sample, {}),
                section,
            )


def write_custom_sort(ws, samples, sample_stats, calls_by_sample_locus, loci):
    headers = abbreviated_headers(loci)
    headers[2] = "Mapped Read Counts"
    ws.append(headers)
    group_order = [
        "MHC homozygous MCM animals",
        "MHC heterozygous  MCM animals",
        "MHC recombinant  MCM animals",
        "Need to Repeat",
    ]
    grouped = {label: [] for label in group_order}
    for sample in samples:
        locus_calls = calls_by_sample_locus.get(sample, {})
        grouped[mcm_custom_sort_group(locus_calls, loci)].append(sample)
    for label in group_order:
        group_samples = grouped[label]
        if not group_samples:
            continue
        if ws.max_row > 1:
            ws.append([None for _ in headers])
        ws.append([label] + [None for _ in headers[1:]])
        sorted_samples = sorted(
            group_samples,
            key=lambda sample: (
                whole_animal_haplotype(calls_by_sample_locus.get(sample, {}), 1, loci),
                whole_animal_haplotype(calls_by_sample_locus.get(sample, {}), 2, loci),
                sample,
            ),
        )
        for sample in sorted_samples:
            ws.append(mcm_summary_values(sample, sample_stats, calls_by_sample_locus, loci))
    apply_basic_sheet_format(ws, auto_filter=False)
    apply_mcm_summary_sheet_format(ws, custom_sort=True)
    for row in range(2, ws.max_row + 1):
        for col in range(4, ws.max_column):
            apply_haplotype_cell_style(ws.cell(row, col), ws.cell(row, col).value)
        if ws.cell(row, 1).value in grouped:
            for col in range(1, ws.max_column + 1):
                ws.cell(row, col).border = Border()


def build_mcm_client_current_workbook(args, genotype_rows, sample_rows, stats, haplotype_analysis, haplotype_definition):
    wb = Workbook()
    ws = wb.active
    ws.title = MCM_CLIENT_SHEET_NAMES[0]
    genotype_counts = load_genotype_counts(genotype_rows)
    samples = report_sample_names(sample_rows, genotype_counts)
    genotype_rows = rows_for_samples(genotype_rows, samples)
    sample_rows = rows_for_samples(sample_rows, samples)
    genotype_counts = load_genotype_counts(genotype_rows)
    sample_stats = load_sample_stats(sample_rows)
    calls_by_sample_locus = haplotype_calls_by_sample_locus(haplotype_analysis)
    loci = ordered_loci_from_calls(calls_by_sample_locus)
    ordered_genotypes = []
    seen = set()
    for name in reference_names(args.reference_fasta):
        if name not in seen:
            ordered_genotypes.append(name)
            seen.add(name)
    for row in genotype_rows:
        genotype = row.get("genotype")
        if genotype and genotype not in seen:
            ordered_genotypes.append(genotype)
            seen.add(genotype)

    write_interpretation_guide(ws, args, stats, haplotype_analysis, haplotype_definition)
    write_mcm_alleles_per_haplotype(wb.create_sheet(title=MCM_CLIENT_SHEET_NAMES[1]), haplotype_definition)
    write_abbreviated_haplotypes(wb.create_sheet(title=MCM_CLIENT_SHEET_NAMES[2]), samples, sample_stats, calls_by_sample_locus, loci)
    write_full_sequencing_results(
        wb.create_sheet(title=MCM_CLIENT_SHEET_NAMES[3]),
        samples,
        sample_stats,
        genotype_counts,
        ordered_genotypes,
        calls_by_sample_locus,
        loci,
    )
    write_custom_sort(wb.create_sheet(title=MCM_CLIENT_SHEET_NAMES[4]), samples, sample_stats, calls_by_sample_locus, loci)
    wb.active = 0
    return wb, 0


def write_audit_sheet(wb, title, comparison_ws, sample_cols, allele_rows, matched_by_row_sample, comparison_name, analysis_name):
    ws = wb.create_sheet(title=safe_sheet_title(wb, title, "Audit"))
    headers = [
        "sample",
        "row",
        "expected_call",
        f"{comparison_name}_count",
        f"{analysis_name}_count",
        f"recovered_{comparison_name}_positive",
        "tokens",
        "matched_genotypes",
    ]
    ws.append(headers)
    audit_rows = 0
    comparison_sample_cols = {sample: col for col, sample in sample_columns(comparison_ws)}
    for row in allele_rows:
        expected_call = comparison_ws.cell(row, 1).value
        for col, sample in sample_cols:
            comparison_col = comparison_sample_cols.get(sample, col)
            comparison_count = as_number(comparison_ws.cell(row, comparison_col).value) or 0
            analysis_count, names, tokens = matched_by_row_sample.get((row, sample), (0, [], []))
            if analysis_count <= 0:
                continue
            recovered = None
            if comparison_count > 0:
                recovered = "yes" if analysis_count > 0 else "no"
            ws.append([
                sample,
                row,
                expected_call,
                comparison_count if comparison_count > 0 else None,
                analysis_count if analysis_count > 0 else None,
                recovered,
                ",".join(tokens),
                ";".join(names),
            ])
            audit_rows += 1
    style_tabular_sheet(ws)
    return ws, audit_rows


def build_template_workbook(args, genotype_headers, genotype_rows, sample_headers, sample_rows, stats, haplotype_analysis):
    wb, analysis_ws, comparison_ws = copied_template_workbook(
        args.comparison_workbook,
        args.analysis_name,
        args.comparison_name,
    )
    genotype_counts = load_genotype_counts(genotype_rows)
    samples = report_sample_names(sample_rows, genotype_counts)
    genotype_rows = rows_for_samples(genotype_rows, samples)
    sample_rows = rows_for_samples(sample_rows, samples)
    genotype_counts = load_genotype_counts(genotype_rows)
    sample_stats = load_sample_stats(sample_rows)
    sample_cols, allele_rows, matched = fill_analysis_sheet(analysis_ws, genotype_counts, sample_stats, samples)
    fill_haplotype_rows(analysis_ws, sample_cols, haplotype_analysis)
    write_csv_sheet(wb, f"{args.analysis_name} Long Summary", genotype_headers, genotype_rows)
    write_csv_sheet(wb, f"{args.analysis_name} Sample Summary", sample_headers, sample_rows)
    write_haplotype_sheet(wb, haplotype_analysis)
    _, audit_rows = write_audit_sheet(
        wb,
        f"{args.comparison_name} Audit",
        comparison_ws,
        sample_cols,
        allele_rows,
        matched,
        args.comparison_name,
        args.analysis_name,
    )
    write_stats_sheet(wb, stats)
    wb.active = 0
    return wb, audit_rows


def build_generic_workbook(args, genotype_headers, genotype_rows, sample_headers, sample_rows, stats, haplotype_analysis):
    wb = Workbook()
    ws = wb.active
    ws.title = safe_sheet_title(wb, args.analysis_name, "ONT08")
    genotype_counts = load_genotype_counts(genotype_rows)
    samples = report_sample_names(sample_rows, genotype_counts)
    genotype_rows = rows_for_samples(genotype_rows, samples)
    sample_rows = rows_for_samples(sample_rows, samples)
    genotype_counts = load_genotype_counts(genotype_rows)
    sample_stats = load_sample_stats(sample_rows)
    ordered_genotypes = []
    seen = set()
    for name in reference_names(args.reference_fasta):
        if name not in seen:
            ordered_genotypes.append(name)
            seen.add(name)
    for row in genotype_rows:
        genotype = row.get("genotype")
        if genotype and genotype not in seen:
            ordered_genotypes.append(genotype)
            seen.add(genotype)

    ws.append(["Animal ID", None, None] + samples)
    ws.append(["GS ID", "Total", "Average"] + samples)
    ws.append(["Filtered exact-match read count", None, None] + [display_value(sample_stats.get(sample, {}).get("passed_alignments")) for sample in samples])
    ws.append([])
    ws.append([])
    for locus in haplotype_loci_for_report(haplotype_analysis):
        ws.append([f"{locus} Haplotype 1", None, None] + [None for _sample in samples])
        ws.append([f"{locus} Haplotype 2", None, None] + [None for _sample in samples])
    ws.append(["Comments", "Subtotal", "# Obs."] + [None for _sample in samples])
    ws.append(["Genotype", "Total", "# Obs."] + samples)
    sample_cols = [(index + 4, sample) for index, sample in enumerate(samples)]
    fill_haplotype_rows(ws, sample_cols, haplotype_analysis)
    for genotype in ordered_genotypes:
        if not any(genotype_counts.get(sample, {}).get(genotype, 0) > 0 for sample in samples):
            continue
        row_index = ws.max_row + 1
        values = [genotype, None, None]
        for sample in samples:
            count = genotype_counts.get(sample, {}).get(genotype, 0)
            values.append(count if count > 0 else None)
        ws.append(values)
        fill_subtotal_observed_values(ws, [row_index], sample_cols)
    fill_read_count_summary_values(ws, 3, sample_cols)
    style_tabular_sheet(ws)
    write_csv_sheet(wb, f"{args.analysis_name} Long Summary", genotype_headers, genotype_rows)
    write_csv_sheet(wb, f"{args.analysis_name} Sample Summary", sample_headers, sample_rows)
    write_haplotype_sheet(wb, haplotype_analysis)
    write_stats_sheet(wb, stats)
    wb.active = 0
    return wb, 0


def write_provenance(args, start_time, started_at, completed_at, audit_rows):
    mode = "mcm-client-current" if args.client_current_workbook else "standard-report"
    inputs = [
        file_record(args.genotypes_csv, "input"),
        file_record(args.samples_csv, "input"),
        file_record(args.stats_json, "input"),
        file_record(args.reference_fasta, "input"),
        file_record(args.barcode_definitions, "input"),
    ]
    if args.comparison_workbook:
        inputs.append(file_record(args.comparison_workbook, "comparison"))
    if args.haplotype_analysis_json:
        inputs.append(file_record(args.haplotype_analysis_json, "analysis"))
    if args.haplotype_definition_json:
        inputs.append(file_record(args.haplotype_definition_json, "haplotype-definition"))
    if args.primary_workbook:
        inputs.append(file_record(args.primary_workbook, "primary-workbook"))
    payload = {
        "toolName": "lungfish fastq ont-barcode-genotype workbook report",
        "toolVersion": "1",
        "mode": mode,
        "argv": sys.argv,
        "reproducibleCommand": args.provenance_command or " ".join(sys.argv),
        "options": vars(args),
        "resolvedDefaults": {
            "analysisName": args.run_name,
            "comparisonName": "Illumina-31262",
            "haplotypeAnalysisJSON": None,
            "clientCurrentWorkbook": False,
            "haplotypeDefinitionJSON": None,
            "primaryWorkbook": None,
        },
        "runtimeIdentity": {
            "python": sys.version,
            "platform": platform.platform(),
            "openpyxl": openpyxl.__version__,
            "executable": sys.executable,
        },
        "inputs": inputs,
        "outputs": [
            file_record(args.output_xlsx, "report"),
            {"path": args.provenance_json, "role": "provenance", "exists": False},
        ],
        "primaryWorkbook": args.primary_workbook,
        "outputWorkbook": args.output_xlsx,
        "auditRows": audit_rows,
        "exitStatus": 0,
        "wallClockSeconds": time.time() - start_time,
        "stderr": "",
        "startedAt": started_at,
        "completedAt": completed_at,
    }
    with open(args.provenance_json, "w") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    payload["outputs"] = [
        file_record(args.output_xlsx, "report"),
        file_record(args.provenance_json, "provenance"),
    ]
    with open(args.provenance_json, "w") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def main():
    args = parse_args()
    start_time = time.time()
    started_at = utc_now()
    os.makedirs(os.path.dirname(args.output_xlsx) or ".", exist_ok=True)
    genotype_headers, genotype_rows = read_csv(args.genotypes_csv)
    sample_headers, sample_rows = read_csv(args.samples_csv)
    genotype_rows = assigned_sample_rows(genotype_rows)
    sample_rows = assigned_sample_rows(sample_rows)
    with open(args.stats_json) as handle:
        stats = json.load(handle)
    haplotype_analysis = load_haplotype_analysis(args.haplotype_analysis_json)

    if args.client_current_workbook:
        haplotype_definition = load_haplotype_definition(args.haplotype_definition_json)
        wb, audit_rows = build_mcm_client_current_workbook(
            args,
            genotype_rows,
            sample_rows,
            stats,
            haplotype_analysis,
            haplotype_definition,
        )
    elif args.comparison_workbook:
        wb, audit_rows = build_template_workbook(args, genotype_headers, genotype_rows, sample_headers, sample_rows, stats, haplotype_analysis)
    else:
        wb, audit_rows = build_generic_workbook(args, genotype_headers, genotype_rows, sample_headers, sample_rows, stats, haplotype_analysis)

    wb.save(args.output_xlsx)
    completed_at = utc_now()
    write_provenance(args, start_time, started_at, completed_at, audit_rows)
    summary = {
        "outputXLSX": args.output_xlsx,
        "provenanceJSON": args.provenance_json,
        "openpyxlVersion": openpyxl.__version__,
        "sheetNames": wb.sheetnames,
        "auditRows": audit_rows,
    }
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
"""#
