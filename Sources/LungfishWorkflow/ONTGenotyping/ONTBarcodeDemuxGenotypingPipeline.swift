import Foundation
import Darwin
import LungfishCore
import LungfishIO

struct GenotypeReviewableReferenceAuthority: Sendable {
    let records: [MHCReferenceRecord]
    let descriptors: [ProvenanceFileDescriptor]
    let snapshots: [GenotypeReviewAuthorityFileSnapshot]

    func requireUnchanged() throws {
        for snapshot in snapshots {
            try snapshot.requireUnchanged()
        }
    }
}

enum GenotypeReviewableReferenceAuthorityPhase: Equatable, Sendable {
    case afterSnapshotBeforeSemanticLoad
    case beforeFinalVerification
}

private struct GenotypeReviewableReferenceManifestProjection: Decodable {
    struct Genome: Decodable {
        let path: String
    }

    struct RecordStore: Decodable {
        let databasePath: String

        enum CodingKeys: String, CodingKey {
            case databasePath = "database_path"
        }
    }

    let genome: Genome?
    let recordStore: RecordStore?

    enum CodingKeys: String, CodingKey {
        case genome
        case recordStore = "record_store"
    }
}

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
    public let keepIntermediates: Bool
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
    public let resultWorkflowKind: GenotypeResultWorkflowKind?
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
        keepIntermediates: Bool = false,
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
        resultWorkflowKind: GenotypeResultWorkflowKind? = nil,
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
            keepIntermediates: keepIntermediates,
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
            resultWorkflowKind: resultWorkflowKind,
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
        keepIntermediates: Bool = false,
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
        resultWorkflowKind: GenotypeResultWorkflowKind? = nil,
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
        self.keepIntermediates = keepIntermediates
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
        self.resultWorkflowKind = resultWorkflowKind
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
            keepIntermediates: keepIntermediates,
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
            resultWorkflowKind: resultWorkflowKind,
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
        if keepIntermediates {
            values += ["--keep-intermediates"]
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
    case processTimedOut(tool: String, seconds: TimeInterval, stderr: String)
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
        case .processTimedOut(let tool, let seconds, let stderr):
            let detail = stderr.isEmpty ? "" : ": \(stderr)"
            return "\(tool) timed out after \(Int(seconds)) seconds\(detail)"
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

enum ONTGenotypingProcessWaitError: Error, Equatable, Sendable {
    case timedOut(tool: String, seconds: TimeInterval)
    case exitedNonzero(tool: String, status: Int32)
}

final class ONTGenotypingProcessExitObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: Int32?

    var status: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return storedStatus
    }

    func record(status: Int32) {
        lock.lock()
        if storedStatus == nil {
            storedStatus = status
        }
        lock.unlock()
    }
}

struct ONTGenotypingProcessExitWaiter: Sendable {
    let pollInterval: TimeInterval

    init(pollInterval: TimeInterval = 0.025) {
        self.pollInterval = max(0.001, pollInterval)
    }

    func wait(
        tool: String,
        deadline: ONTGenotypingProcessDeadline,
        observation: ONTGenotypingProcessExitObservation,
        isRunning: @escaping @Sendable () -> Bool,
        terminationStatus: @escaping @Sendable () -> Int32,
        requestTermination: @escaping @Sendable () -> Void
    ) async throws -> Int32 {
        let pollNanoseconds = Self.nanoseconds(for: pollInterval)

        return try await withTaskCancellationHandler {
            do {
                while true {
                    try Task.checkCancellation()

                    if let status = observation.status {
                        return status
                    }
                    if !isRunning() {
                        return terminationStatus()
                    }
                    if deadline.hasExpired {
                        requestTermination()
                        throw ONTGenotypingProcessWaitError.timedOut(
                            tool: tool,
                            seconds: deadline.timeout
                        )
                    }

                    try await Task.sleep(nanoseconds: pollNanoseconds)
                }
            } catch is CancellationError {
                requestTermination()
                throw CancellationError()
            }
        } onCancel: {
            requestTermination()
        }
    }

    fileprivate static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        guard interval.isFinite else { return UInt64.max }
        let clamped = max(0, interval)
        let nanoseconds = clamped * 1_000_000_000
        guard nanoseconds < Double(UInt64.max) else { return UInt64.max }
        return UInt64(nanoseconds)
    }
}

struct ONTGenotypingProcessDeadline: Sendable {
    let timeout: TimeInterval
    private let deadlineNanoseconds: UInt64

    init(timeout: TimeInterval, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.timeout = timeout
        let duration = ONTGenotypingProcessExitWaiter.nanoseconds(for: timeout)
        let deadline = now.addingReportingOverflow(duration)
        self.deadlineNanoseconds = deadline.overflow ? UInt64.max : deadline.partialValue
    }

    var hasExpired: Bool {
        DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds
    }
}

private final class ONTGenotypingMappingProcessGroup: @unchecked Sendable {
    private let lock = NSLock()
    private let processes: [Process]
    private var terminationRequested = false

    init(processes: [Process]) {
        self.processes = processes
    }

    func requestTermination() {
        let processesToTerminate: [Process]
        lock.lock()
        if terminationRequested {
            processesToTerminate = []
        } else {
            terminationRequested = true
            processesToTerminate = processes
        }
        lock.unlock()

        for process in processesToTerminate where process.isRunning {
            ProcessTreeTerminator.terminate(rootProcess: process, gracePeriod: 0)
        }
    }
}

private struct AmpliconWorkDirectoryDisposition: Codable, Sendable {
    let path: String
    let disposition: String
    let error: String?
}

private struct AmpliconWorkDirectoryDispositionEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let runID: UUID
    let entries: [AmpliconWorkDirectoryDisposition]
}

private struct AmpliconFailureProvenancePreparationError: Error, LocalizedError {
    let inputPath: String
    let operation: String
    let underlyingDescription: String

    var errorDescription: String? {
        "Incomplete failure-provenance input preparation for \(inputPath): "
            + "\(operation) failed (\(underlyingDescription))"
    }
}

public struct ONTBarcodeDemuxGenotypingPipeline: Sendable {
    private let condaManager: CondaManager
    private let referenceImporter: ReferenceBundleImportService
    private let fileRemover: @Sendable (URL) throws -> Void
    private let cleanupJournalObserver:
        @Sendable (GenotypingCleanupJournalEvent) throws -> Void
    private let workDirectoryMarkerBinder:
        @Sendable (URL, OwnedWorkDirectoryCreationRequest) throws -> Void
    private let reviewableRowCatalogPublisher:
        @Sendable (
            GenotypeReviewableRowCatalogInputs,
            URL,
            @escaping @Sendable () throws -> Void
        ) throws -> GenotypeReviewableRowCatalogPublication
    private static let mappingProcessTimeout: TimeInterval = 86_400

    public init(
        condaManager: CondaManager = .shared,
        referenceImporter: ReferenceBundleImportService = .shared
    ) {
        self.condaManager = condaManager
        self.referenceImporter = referenceImporter
        self.fileRemover = { url in
            try FileManager.default.removeItem(at: url)
        }
        self.cleanupJournalObserver = { _ in }
        self.workDirectoryMarkerBinder = { directory, request in
            try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
                directory,
                request: request
            )
        }
        self.reviewableRowCatalogPublisher = {
            inputs, outputDirectory, authorityCheck in
            try GenotypeReviewableRowCatalogPublisher().publish(
                inputs,
                to: outputDirectory,
                postPublicationAuthorityCheck: authorityCheck
            )
        }
    }

    init(
        condaManager: CondaManager,
        referenceImporter: ReferenceBundleImportService = .shared,
        fileRemover: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        },
        cleanupJournalObserver:
            @escaping @Sendable (GenotypingCleanupJournalEvent) throws -> Void = { _ in },
        workDirectoryMarkerBinder:
            @escaping @Sendable (
                URL,
                OwnedWorkDirectoryCreationRequest
            ) throws -> Void = {
                try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
                    $0,
                    request: $1
                )
            },
        reviewableRowCatalogPublisher:
            @escaping @Sendable (
                GenotypeReviewableRowCatalogInputs,
                URL,
                @escaping @Sendable () throws -> Void
            ) throws -> GenotypeReviewableRowCatalogPublication = {
                try GenotypeReviewableRowCatalogPublisher().publish(
                    $0,
                    to: $1,
                    postPublicationAuthorityCheck: $2
                )
            }
    ) {
        self.condaManager = condaManager
        self.referenceImporter = referenceImporter
        self.fileRemover = fileRemover
        self.cleanupJournalObserver = cleanupJournalObserver
        self.workDirectoryMarkerBinder = workDirectoryMarkerBinder
        self.reviewableRowCatalogPublisher = reviewableRowCatalogPublisher
    }

    public func run(
        _ request: ONTBarcodeDemuxGenotypingRunRequest,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ONTBarcodeDemuxGenotypingResult {
        let startedAt = Date()
        let runID = UUID()
        let processIdentity = try OwnedProcessIdentity.current()
        let outputParent = request.outputDirectory.deletingLastPathComponent().standardizedFileURL
        try FileManager.default.createDirectory(at: outputParent, withIntermediateDirectories: true)
        let projectRoot = (request.projectURL ?? outputParent).standardizedFileURL
        let lockURL = outputParent.appendingPathComponent(
            ".\(request.outputDirectory.lastPathComponent).amplicon-genotyping-run.lock"
        )
        let runLock = try OwnedRunLock.acquire(at: lockURL)
        defer { runLock.release() }
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
        let failureScientificFASTQURLs = try request.inputFASTQURLs.flatMap {
            let resolved = try Self.resolveInputFASTQURLs(for: $0)
            guard !resolved.isEmpty else {
                throw ONTBarcodeDemuxGenotypingError.noFASTQSources($0)
            }
            return resolved
        }
        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        progressHandler?(0.04, "Preparing amplicon genotyping output workspace.")
        _ = try copySpecialistPromptSnapshotIfNeeded(for: request)
        let supportDirectory = request.outputDirectory
            .appendingPathComponent(".amplicon-genotyping", isDirectory: true)
        var failureCleanupDispositions: [AmpliconWorkDirectoryDisposition] = []
        var successfulCleanupPlan: GenotypingCleanupPlan?
        do {
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: false
        )
        try workDirectoryMarkerBinder(
            supportDirectory,
            OwnedWorkDirectoryCreationRequest(
                projectURL: projectRoot,
                parentDirectoryURL: request.outputDirectory,
                prefix: ".amplicon-genotyping-",
                runID: runID,
                processIdentity: processIdentity,
                state: .active,
                lockRelativePath: Self.projectRelativePath(
                    lockURL,
                    projectRoot: projectRoot
                ),
                keepIntermediates: request.keepIntermediates,
                toolName: Self.analysisToolName(for: resolvedMode),
                toolVersion: WorkflowRun.currentAppVersion
            )
        )
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
            pythonURL: pythonURL,
            progressHandler: progressHandler
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

        let finalizedResult: ONTBarcodeDemuxGenotypingResult
        let preserveRetainedEvidence: Bool
        do {
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
            try annotateStatsJSONWithInputPreparation(
                statsJSONURL: request.statsJSONURL,
                illuminaPreparation: inputPlan.illuminaPreparation
            )
            let scientificArtifactPublication: AmpliconGenotypeScientificArtifactPublication?
            if resolvedMode == .illuminaPaired {
                progressHandler?(0.78, "Publishing genotyping evidence and provisional exon 2 sequences.")
                scientificArtifactPublication =
                    try AmpliconGenotypeScientificArtifactPublisher().publish(
                        reportCSVURL: request.reportCSVURL,
                        referenceFASTAURL: reference.referenceFASTAURL,
                        retainedBAMURL: request.retainedBAMURL,
                        retainedBAIURL: request.retainedBAIURL,
                        outputDirectoryURL: request.outputDirectory
                    )
            } else {
                scientificArtifactPublication = nil
            }

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
            let referenceRecordStoreSnapshot = try await GenotypeReferenceRecordStoreSnapshot.publish(
                fromReferenceBundle: reference.sourceReferenceBundleURL ?? request.referenceSourceURL,
                toResultBundle: request.outputDirectory
            )
            let reviewableRowCatalogPublication =
                try publishReviewableRowCatalogIfNeeded(
                    request: request,
                    resolvedMode: resolvedMode,
                    reference: reference,
                    scientificArtifactPublication: scientificArtifactPublication
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
                referenceRecordStoreSnapshot: referenceRecordStoreSnapshot,
                scientificArtifactPublication: scientificArtifactPublication,
                reviewableRowCatalogPublication: reviewableRowCatalogPublication,
                startedAt: startedAt,
                completedAt: completedAt
            )
            try writeBundleManifest(
                request: request,
                resolvedMode: resolvedMode,
                provenanceURL: provenanceURL,
                workbookRevision: workbookCopy.revision,
                referenceRecordStore: referenceRecordStoreSnapshot?.info,
                scientificArtifactPublication: scientificArtifactPublication,
                reviewableRowCatalogPublication: reviewableRowCatalogPublication,
                completedAt: completedAt
            )
            preserveRetainedEvidence = scientificArtifactPublication != nil
            finalizedResult = ONTBarcodeDemuxGenotypingResult(
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
        } catch {
            var reportedError: Error = error
            if resolvedMode == .illuminaPaired {
                let dispositions = rollbackScientificOutputsAfterFinalizationFailure(
                    request: request,
                    mapping: mapping,
                    preserveReviewableRowCatalog:
                        error is GenotypeReviewableRowCatalogPublicationFailure
                )
                failureCleanupDispositions.append(contentsOf: dispositions)
                let cleanupFailures = dispositions.filter { $0.error != nil }
                if !cleanupFailures.isEmpty {
                    let details = cleanupFailures.map {
                        "\($0.path): \($0.error ?? "unknown cleanup error")"
                    }.joined(separator: "; ")
                    reportedError = ONTBarcodeDemuxGenotypingError.reportFailed(
                        status: 1,
                        stderr:
                            "\(error.localizedDescription); scientific-output rollback cleanup failed: \(details)"
                    )
                }
            }
            if let failure =
                error as? GenotypeReviewableRowCatalogPublicationFailure {
                do {
                    try ProvenanceWriter(signingProvider: nil).write(
                        failure.provenance,
                        to: request.outputDirectory
                    )
                } catch let provenanceError {
                    throw ONTBarcodeDemuxGenotypingError.reportFailed(
                        status: 1,
                        stderr:
                            "\(reportedError.localizedDescription); failed-run provenance also could not be written (\(provenanceError.localizedDescription))."
                    )
                }
            }
            throw reportedError
        }

        progressHandler?(0.97, "Removing regenerable alignment intermediates.")
        let cleanupPlan = try beginSuccessfulCleanupJournal(
            runID: runID,
            projectRoot: projectRoot,
            request: request,
            mapping: mapping,
            preserveRetainedEvidence: preserveRetainedEvidence,
            supportDirectory: supportDirectory
        )
        successfulCleanupPlan = cleanupPlan
        let alignmentDispositions = cleanupGeneratedAlignmentIntermediates(
            for: request,
            mapping: mapping,
            preserveRetainedEvidence: preserveRetainedEvidence,
            cleanupPlan: cleanupPlan
        )
        failureCleanupDispositions.append(contentsOf: alignmentDispositions)
        if let cleanupFailure = alignmentDispositions.first(where: {
            $0.error != nil
        }) {
            throw ONTBarcodeDemuxGenotypingError.reportFailed(
                status: 1,
                stderr:
                    "Automatic intermediate cleanup failed for "
                    + "\(cleanupFailure.path): "
                    + "\(cleanupFailure.error ?? "unknown cleanup error")"
            )
        }
        let supportPath = supportDirectory.standardizedFileURL.path
        if request.keepIntermediates {
            failureCleanupDispositions.append(
                identityBoundRetainedDisposition(
                    plan: cleanupPlan,
                    url: supportDirectory
                ) { detachedURL in
                    try OwnedWorkDirectoryMarkerStore.transition(
                        detachedURL,
                        expectedProjectURL: projectRoot,
                        expectedRunID: runID,
                        to: .completed
                    )
                }
            )
        } else {
            let disposition = identityBoundRemovalDisposition(
                plan: cleanupPlan,
                url: supportDirectory,
                successDisposition: "removed"
            ) { detachedURL in
                try OwnedWorkDirectoryMarkerStore.transition(
                    detachedURL,
                    expectedProjectURL: projectRoot,
                    expectedRunID: runID,
                    to: .completed
                )
                try fileRemover(detachedURL)
            }
            failureCleanupDispositions.append(disposition)
            if let error = disposition.error {
                throw ONTBarcodeDemuxGenotypingError.reportFailed(
                    status: 1,
                    stderr:
                        "Automatic support-directory cleanup failed for "
                        + "\(supportPath): \(error)"
                )
            }
        }
        try appendSuccessfulCleanupDisposition(
            runID: runID,
            projectRoot: projectRoot,
            outputBundleURL: request.outputDirectory,
            dispositions: failureCleanupDispositions
        )
        progressHandler?(0.98, "Finalizing amplicon genotyping outputs.")
        return finalizedResult
        } catch let journalError as GenotypingCleanupJournalError {
            throw journalError
        } catch {
            throw recordFailedRunAndCleanupSupportDirectory(
                originalError: error,
                request: request,
                runID: runID,
                projectRoot: projectRoot,
                supportDirectory: supportDirectory,
                startedAt: startedAt,
                resolvedMode: resolvedMode,
                resolvedReadType: resolvedReadType,
                failureScientificFASTQURLs: failureScientificFASTQURLs,
                cleanupPlan: successfulCleanupPlan,
                additionalDispositions: failureCleanupDispositions
            )
        }
    }

    private static func projectRelativePath(_ url: URL, projectRoot: URL) -> String? {
        let rootPath = projectRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func recordFailedRunAndCleanupSupportDirectory(
        originalError: Error,
        request: ONTBarcodeDemuxGenotypingRunRequest,
        runID: UUID,
        projectRoot: URL,
        supportDirectory: URL,
        startedAt: Date,
        resolvedMode: AmpliconGenotypingMode,
        resolvedReadType: AmpliconGenotypingReadType,
        failureScientificFASTQURLs: [URL],
        cleanupPlan: GenotypingCleanupPlan?,
        additionalDispositions: [AmpliconWorkDirectoryDisposition]
    ) -> Error {
        let historyWriter = ProjectOperationHistoryWriter(
            projectURL: projectRoot
        )
        var reportedError: Error = originalError
        do {
            try writeCompactFailureHistory(
                request: request,
                runID: runID,
                projectRoot: projectRoot,
                startedAt: startedAt,
                resolvedMode: resolvedMode,
                resolvedReadType: resolvedReadType,
                failureScientificFASTQURLs: failureScientificFASTQURLs,
                error: originalError
            )
        } catch let preparationError as AmpliconFailureProvenancePreparationError {
            reportedError = ONTBarcodeDemuxGenotypingError.reportFailed(
                status: 1,
                stderr:
                    "\(originalError.localizedDescription); "
                    + "\(preparationError.localizedDescription)"
            )
            do {
                let receipt = try failureProvenancePreparationReceiptData(
                    request: request,
                    runID: runID,
                    startedAt: startedAt,
                    resolvedMode: resolvedMode,
                    resolvedReadType: resolvedReadType,
                    originalError: originalError,
                    preparationError: preparationError
                )
                let cleanupPlanURL = historyWriter.operationDirectoryURL(
                    for: runID
                ).appendingPathComponent(
                    GenotypingCleanupJournal.planPayloadName
                )
                if FileManager.default.fileExists(
                    atPath: cleanupPlanURL.path
                ) {
                    try historyWriter.append(
                        receipt,
                        named:
                            "failure-provenance-preparation-error.json",
                        toOperation: runID
                    )
                } else {
                    _ = try historyWriter.createOperation(
                        operationID: runID,
                        payloads: [
                            "failure-provenance-preparation-error.json":
                                receipt,
                        ]
                    )
                }
            } catch {
                return ONTBarcodeDemuxGenotypingError.reportFailed(
                    status: 1,
                    stderr:
                        "\(reportedError.localizedDescription); incomplete "
                        + "failure-provenance preparation receipt could not be "
                        + "durably published (\(error.localizedDescription)); "
                        + "retained current-run support directory: "
                        + supportDirectory.standardizedFileURL.path
                )
            }
        } catch {
            return ONTBarcodeDemuxGenotypingError.reportFailed(
                status: 1,
                stderr:
                    "\(originalError.localizedDescription); failed-run provenance could not be durably published (\(error.localizedDescription)); retained current-run support directory: \(supportDirectory.standardizedFileURL.path)"
            )
        }

        let supportPath = supportDirectory.standardizedFileURL.path
        var supportDisposition = AmpliconWorkDirectoryDisposition(
            path: supportPath,
            disposition: "already-removed",
            error: nil
        )
        if FileManager.default.fileExists(atPath: supportPath)
            || cleanupPlan?.entry(for: supportDirectory) != nil {
            if let cleanupPlan {
                if request.keepIntermediates {
                    supportDisposition = identityBoundRetainedDisposition(
                        plan: cleanupPlan,
                        url: supportDirectory
                    ) { detachedURL in
                        try OwnedWorkDirectoryMarkerStore.transition(
                            detachedURL,
                            expectedProjectURL: projectRoot,
                            expectedRunID: runID,
                            to: .failed
                        )
                    }
                } else {
                    supportDisposition = identityBoundRemovalDisposition(
                        plan: cleanupPlan,
                        url: supportDirectory,
                        successDisposition: "removed"
                    ) { detachedURL in
                        try OwnedWorkDirectoryMarkerStore.transition(
                            detachedURL,
                            expectedProjectURL: projectRoot,
                            expectedRunID: runID,
                            to: .failed
                        )
                        try fileRemover(detachedURL)
                    }
                }
            } else {
                do {
                    let marker = try OwnedWorkDirectoryMarkerStore.load(
                        from: supportDirectory,
                        expectedProjectURL: projectRoot
                    )
                    if marker.state == .active {
                        try OwnedWorkDirectoryMarkerStore.transition(
                            supportDirectory,
                            expectedProjectURL: projectRoot,
                            expectedRunID: runID,
                            to: .failed
                        )
                    }
                    if request.keepIntermediates {
                        supportDisposition = .init(
                            path: supportPath,
                            disposition: "retained-by-request",
                            error: nil
                        )
                    } else {
                        try fileRemover(supportDirectory)
                        supportDisposition = .init(
                            path: supportPath,
                            disposition: "removed",
                            error: nil
                        )
                    }
                } catch {
                    supportDisposition = .init(
                        path: supportPath,
                        disposition: "retained-cleanup-failed",
                        error: error.localizedDescription
                    )
                }
            }
        }

        let dispositions = additionalDispositions + [supportDisposition]
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                AmpliconWorkDirectoryDispositionEnvelope(
                    schemaVersion: 1,
                    runID: runID,
                    entries: dispositions
                )
            )
            try historyWriter.append(
                data,
                named: "cleanup-disposition.json",
                toOperation: runID
            )
        } catch {
            return ONTBarcodeDemuxGenotypingError.reportFailed(
                status: 1,
                stderr:
                    "\(reportedError.localizedDescription); cleanup disposition for \(supportPath) could not be durably appended (\(error.localizedDescription))"
            )
        }

        let cleanupFailures = dispositions.filter { $0.error != nil }
        if !cleanupFailures.isEmpty {
            let details = cleanupFailures.map {
                "\($0.path): \($0.error ?? "unknown cleanup error")"
            }.joined(separator: "; ")
            return ONTBarcodeDemuxGenotypingError.reportFailed(
                status: 1,
                stderr:
                    "\(reportedError.localizedDescription); current-run cleanup failed: \(details)"
            )
        }
        return reportedError
    }

    private func failureProvenancePreparationReceiptData(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        runID: UUID,
        startedAt: Date,
        resolvedMode: AmpliconGenotypingMode,
        resolvedReadType: AmpliconGenotypingReadType,
        originalError: Error,
        preparationError: AmpliconFailureProvenancePreparationError
    ) throws -> Data {
        let completedAt = Date()
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "kind": "incomplete-failure-provenance-preparation",
            "runID": runID.uuidString.lowercased(),
            "workflowName": Self.workflowName(for: resolvedMode),
            "workflowVersion": "1",
            "toolName": "lungfish fastq genotype",
            "toolVersion": WorkflowRun.currentAppVersion,
            "argv": request.argv,
            "durableReplayArgv": request.argv,
            "reproducibleCommand":
                request.argv.map(shellEscape).joined(separator: " "),
            "resolvedOptions": failureResolvedOptions(
                request: request,
                resolvedMode: resolvedMode,
                resolvedReadType: resolvedReadType
            ),
            "resolvedDefaults": failureResolvedDefaults(),
            "runtimeIdentity": [
                "executablePath": CommandLine.arguments.first
                    ?? CLICommandIdentity.executableName,
                "operatingSystem":
                    ProcessInfo.processInfo.operatingSystemVersionString,
                "processIdentifier":
                    ProcessInfo.processInfo.processIdentifier,
                "condaRoot": condaManager.rootPrefix.path,
                "condaEnvironments": [
                    "minimap2", "samtools", "pysam", "openpyxl",
                ],
            ],
            "inputPath": preparationError.inputPath,
            "output": request.outputDirectory.path,
            "preparationError": preparationError.localizedDescription,
            "originalError": originalError.localizedDescription,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "completedAt": ISO8601DateFormatter().string(from: completedAt),
            "wallTimeSeconds": completedAt.timeIntervalSince(startedAt),
            "exitStatus": 1,
            "stderr": [
                originalError.localizedDescription,
                preparationError.localizedDescription,
            ].joined(separator: "\n"),
        ]
        return try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private func failureScientificInputDescriptors(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        failureScientificFASTQURLs: [URL]
    ) throws -> [[String: Any]] {
        let canonicalProvenanceURL = request.outputDirectory
            .appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let authoritativeDescriptors: [String: ProvenanceFileDescriptor]
        do {
            let envelope = try ProvenanceEnvelopeReader.load(
                from: request.outputDirectory
            )
            authoritativeDescriptors = (envelope?.files ?? []).reduce(
                into: [:]
            ) { result, descriptor in
                guard descriptor.checksumSHA256 != nil,
                      descriptor.fileSize != nil else {
                    return
                }
                let path = URL(fileURLWithPath: descriptor.path)
                    .standardizedFileURL.path
                result[path] = result[path] ?? descriptor
            }
        } catch {
            throw AmpliconFailureProvenancePreparationError(
                inputPath: canonicalProvenanceURL.path,
                operation: "load authoritative scientific-input descriptors",
                underlyingDescription: error.localizedDescription
            )
        }
        var candidates = failureScientificFASTQURLs.map { ($0, "input") }

        let referenceURL: URL
        if let bundledReference = MHCAmpliconReferenceBundle.referenceFASTAURL(
            in: request.referenceSourceURL
        ) {
            referenceURL = bundledReference
        } else if let primaryReference = SequenceInputResolver
            .resolvePrimarySequenceURL(for: request.referenceSourceURL) {
            referenceURL = primaryReference
        } else {
            referenceURL = request.referenceSourceURL
        }
        candidates.append((referenceURL, "reference"))
        for url in [
            request.barcodeDefinitionsURL,
            request.demuxManifestURL,
            request.comparisonWorkbookURL,
        ].compactMap({ $0 }) {
            candidates.append((url, "input"))
        }

        var seen = Set<String>()
        return try candidates.compactMap { candidate in
            let url = candidate.0.standardizedFileURL
            guard seen.insert(url.path).inserted else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue else {
                throw AmpliconFailureProvenancePreparationError(
                    inputPath: url.path,
                    operation: "locate required scientific input",
                    underlyingDescription: "file is missing or is not a regular file"
                )
            }
            do {
                let descriptor = try failureFileDescriptor(
                    url,
                    role: candidate.1
                )
                if let authoritative = authoritativeDescriptors[url.path],
                   (
                       descriptor["sha256"] as? String
                           != authoritative.checksumSHA256
                           || descriptor["fileSize"] as? UInt64
                               != authoritative.fileSize
                   ) {
                    throw AmpliconFailureProvenancePreparationError(
                        inputPath: url.path,
                        operation:
                            "verify scientific input against the finalized "
                            + "provenance authority",
                        underlyingDescription:
                            "the file changed after the successful provenance "
                            + "snapshot"
                    )
                }
                return descriptor
            } catch let preparationError
                as AmpliconFailureProvenancePreparationError {
                throw preparationError
            } catch {
                throw AmpliconFailureProvenancePreparationError(
                    inputPath: url.path,
                    operation: "hash required scientific input",
                    underlyingDescription: error.localizedDescription
                )
            }
        }
    }

    private func failureScientificOutputDescriptors(
        for request: ONTBarcodeDemuxGenotypingRunRequest
    ) throws -> [[String: Any]] {
        let canonicalProvenanceURL = request.outputDirectory
            .appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let sequenceDirectory = request.outputDirectory.appendingPathComponent(
            "artifacts/sequences",
            isDirectory: true
        )
        let candidates = [
            request.retainedBAMURL,
            request.retainedBAIURL,
            request.reportCSVURL,
            request.sampleSummaryCSVURL,
            request.statsJSONURL,
            request.workbookURL,
            request.currentWorkbookURL,
            request.reportProvenanceURL,
            request.currentWorkbookProvenanceURL,
            request.haplotypeAnalysisURL,
            request.currentHaplotypeAnalysisURL,
            request.specialistPromptSnapshotURL,
            request.provenanceURL,
            canonicalProvenanceURL,
            ProvenanceSigningConfiguration.signatureURL(
                for: canonicalProvenanceURL
            ),
            ProvenanceSigningConfiguration.publicKeyURL(
                for: canonicalProvenanceURL
            ),
            ONTGenotypeResultBundle.manifestURL(in: request.outputDirectory),
            request.outputDirectory.appendingPathComponent(
                GenotypeReferenceRecordStoreSnapshot.relativeDatabasePath
            ),
            sequenceDirectory.appendingPathComponent(
                "observed-provisional-exon2.json"
            ),
            sequenceDirectory.appendingPathComponent(
                "observed-provisional-exon2.fasta"
            ),
            request.outputDirectory.appendingPathComponent(
                "artifacts/projections/genotype-reviewable-rows.json"
            ),
        ]
        var seen = Set<String>()
        return try candidates.compactMap { candidate in
            let url = candidate.standardizedFileURL
            guard seen.insert(url.path).inserted else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue else {
                return nil
            }
            return try failureFileDescriptor(url, role: "output")
        }
    }

    private func failureFileDescriptor(
        _ url: URL,
        role: String
    ) throws -> [String: Any] {
        [
            "path": url.standardizedFileURL.path,
            "role": role,
            "fileSize": try ProvenanceFileHasher.fileSize(of: url),
            "sha256": try ProvenanceFileHasher.sha256(of: url),
        ]
    }

    private func failureResolvedOptions(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        resolvedMode: AmpliconGenotypingMode,
        resolvedReadType: AmpliconGenotypingReadType
    ) -> [String: Any] {
        let resultWorkflowKind = Self.resolvedResultWorkflowKind(
            for: request,
            resolvedMode: resolvedMode
        )
        let resultWorkflowMode = Self.resolvedResultWorkflowMode(
            for: request,
            resolvedMode: resolvedMode
        )
        return [
            "inputFASTQs": request.inputFASTQURLs.map(\.path),
            "referenceSource": request.referenceSourceURL.path,
            "barcodeDefinitions":
                request.barcodeDefinitionsURL?.path as Any? ?? NSNull(),
            "outputDirectory": request.outputDirectory.path,
            "outputName": request.outputName,
            "demuxManifest":
                request.demuxManifestURL?.path as Any? ?? NSNull(),
            "analysisName": request.analysisName,
            "comparisonWorkbook":
                request.comparisonWorkbookURL?.path as Any? ?? NSNull(),
            "comparisonName": request.comparisonName as Any? ?? NSNull(),
            "project": request.projectURL?.path as Any? ?? NSNull(),
            "threads": request.threads,
            "sortThreads": request.sortThreads,
            "minSupport": request.minSupport,
            "keepIntermediates": request.keepIntermediates,
            "haplotypeDropoutSampleFraction":
                request.haplotypeDropoutSampleFraction as Any? ?? NSNull(),
            "haplotypeDropoutLocusFraction":
                request.haplotypeDropoutLocusFraction as Any? ?? NSNull(),
            "haplotypeDropoutLocusFractionOverrides":
                request.haplotypeDropoutLocusFractionOverrides,
            "haplotypeAssayID":
                request.haplotypeAssayID as Any? ?? NSNull(),
            "haplotypeSpeciesCode":
                request.haplotypeSpeciesCode as Any? ?? NSNull(),
            "haplotypeDefinitionScope":
                request.haplotypeDefinitionScope?.rawValue as Any? ?? NSNull(),
            "haplotypeDefinitionSetID":
                request.haplotypeDefinitionSetID as Any? ?? NSNull(),
            "presetID": request.presetID as Any? ?? NSNull(),
            "presetVersion": request.presetVersion as Any? ?? NSNull(),
            "lockedReferenceSHA256":
                request.lockedReferenceSHA256 as Any? ?? NSNull(),
            "extraArguments": request.extraArguments,
            "mode": request.mode.rawValue,
            "resolvedMode": resolvedMode.rawValue,
            "readType": request.readType.rawValue,
            "resolvedReadType": resolvedReadType.rawValue,
            "resultWorkflowKind": resultWorkflowKind?.rawValue as Any? ?? NSNull(),
            "resultWorkflowMode": resultWorkflowMode?.rawValue as Any? ?? NSNull(),
            "aiSpecialistPresetID":
                request.aiSpecialistPresetID as Any? ?? NSNull(),
        ]
    }

    private func failureResolvedDefaults() -> [String: Any] {
        [
            "inputFASTQs": [],
            "referenceSource": NSNull(),
            "barcodeDefinitions": NSNull(),
            "outputDirectory": NSNull(),
            "outputName": "amplicon-genotyping",
            "demuxManifest": NSNull(),
            "analysisName": "amplicon-genotyping",
            "comparisonWorkbook": NSNull(),
            "comparisonName": "Illumina-31262",
            "project": NSNull(),
            "threads": max(1, ProcessInfo.processInfo.activeProcessorCount),
            "sortThreads": 4,
            "minSupport": 1,
            "keepIntermediates": false,
            "haplotypeDropoutSampleFraction": NSNull(),
            "haplotypeDropoutLocusFraction": NSNull(),
            "haplotypeDropoutLocusFractionOverrides": [:],
            "haplotypeAssayID": NSNull(),
            "haplotypeSpeciesCode": NSNull(),
            "haplotypeDefinitionScope": NSNull(),
            "haplotypeDefinitionSetID": NSNull(),
            "presetID": NSNull(),
            "presetVersion": NSNull(),
            "lockedReferenceSHA256": NSNull(),
            "extraArguments": [],
            "mode": AmpliconGenotypingMode.auto.rawValue,
            "resolvedMode": AmpliconGenotypingMode.auto.rawValue,
            "readType": AmpliconGenotypingReadType.auto.rawValue,
            "resolvedReadType": AmpliconGenotypingReadType.auto.rawValue,
            "resultWorkflowKind": NSNull(),
            "resultWorkflowMode": NSNull(),
            "aiSpecialistPresetID": NSNull(),
        ]
    }

    private func writeCompactFailureHistory(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        runID: UUID,
        projectRoot: URL,
        startedAt: Date,
        resolvedMode: AmpliconGenotypingMode,
        resolvedReadType: AmpliconGenotypingReadType,
        failureScientificFASTQURLs: [URL],
        error: Error
    ) throws {
        let completedAt = Date()
        let inputs = try failureScientificInputDescriptors(
            for: request,
            failureScientificFASTQURLs: failureScientificFASTQURLs
        )
        let outputs = try failureScientificOutputDescriptors(for: request)
        let resolvedOptions = failureResolvedOptions(
            request: request,
            resolvedMode: resolvedMode,
            resolvedReadType: resolvedReadType
        )
        let resolvedDefaults = failureResolvedDefaults()
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "runID": runID.uuidString.lowercased(),
            "toolName": "lungfish fastq genotype",
            "toolVersion": WorkflowRun.currentAppVersion,
            "workflowName": Self.workflowName(for: resolvedMode),
            "workflowVersion": "1",
            "argv": request.argv,
            "durableReplayArgv": request.argv,
            "reproducibleCommand": request.argv.map(shellEscape).joined(separator: " "),
            "resolvedOptions": resolvedOptions,
            "resolvedDefaults": resolvedDefaults,
            "runtimeIdentity": [
                "executablePath": CommandLine.arguments.first
                    ?? CLICommandIdentity.executableName,
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "processIdentifier": ProcessInfo.processInfo.processIdentifier,
                "condaRoot": condaManager.rootPrefix.path,
                "condaEnvironments": [
                    "minimap2",
                    "samtools",
                    "pysam",
                    "openpyxl",
                ],
            ],
            "inputs": inputs,
            "files": inputs + outputs,
            "outputs": outputs,
            "output": request.outputDirectory.path,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "completedAt": ISO8601DateFormatter().string(from: completedAt),
            "wallTimeSeconds": completedAt.timeIntervalSince(startedAt),
            "exitStatus": 1,
            "stderr": error.localizedDescription,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        let writer = ProjectOperationHistoryWriter(projectURL: projectRoot)
        let cleanupPlanURL = writer.operationDirectoryURL(
            for: runID
        ).appendingPathComponent(GenotypingCleanupJournal.planPayloadName)
        if FileManager.default.fileExists(atPath: cleanupPlanURL.path) {
            try writer.append(
                data,
                named: "failure-provenance.json",
                toOperation: runID
            )
        } else {
            _ = try writer.createOperation(
                operationID: runID,
                payloads: ["failure-provenance.json": data]
            )
        }
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
        /// The sample's reads as imported.
        let fastqURL: URL
        /// The reads actually handed to minimap2. Equals `fastqURL` unless the
        /// input held unmerged pairs, in which case it is the bbmerge output.
        /// See `IlluminaAmpliconPairMerger` for why merging is required before
        /// the full-reference-span filter can call the 244 bp DRB amplicons.
        var mappingFASTQURL: URL
        let prefixedFASTQURL: URL
        let readCount: Int
        let readCountSource: String
        /// How the reads were prepared for mapping, recorded in provenance.
        var mergeOutcome: IlluminaAmpliconPairMerger.Outcome?

        init(
            sampleID: String,
            sourceURL: URL,
            fastqURL: URL,
            prefixedFASTQURL: URL,
            readCount: Int,
            readCountSource: String,
            mappingFASTQURL: URL? = nil,
            mergeOutcome: IlluminaAmpliconPairMerger.Outcome? = nil
        ) {
            self.sampleID = sampleID
            self.sourceURL = sourceURL
            self.fastqURL = fastqURL
            self.mappingFASTQURL = mappingFASTQURL ?? fastqURL
            self.prefixedFASTQURL = prefixedFASTQURL
            self.readCount = readCount
            self.readCountSource = readCountSource
            self.mergeOutcome = mergeOutcome
        }
    }

    private struct IlluminaPreparation {
        let mode: AmpliconGenotypingMode
        let sampleManifestURL: URL
        let sampleDefinitionsURL: URL
        let samples: [IlluminaSampleInput]
        let sourceFASTQURLs: [URL]
        let mappingFASTQURLs: [URL]
        let requiresBothEndSoftclips: Bool
        let pairMerge: PairMergeProvenance
    }

    /// Whether this run merged read pairs itself, and with what outcome.
    ///
    /// A run-time merge means the inputs were imported without the Illumina
    /// Amplicon Merge recipe. That is a materially different provenance from a
    /// bundle merged at import, and the difference decides whether the DRB loci
    /// could be genotyped at all, so it has to survive the run rather than only
    /// appear in the progress feed. The same record is written into the sample
    /// manifest, the durable stats JSON, and the provenance envelope so no two
    /// artifacts can disagree.
    private struct PairMergeProvenance {
        let mergedSampleCount: Int
        let totalSampleCount: Int
        let mergedFragments: Int
        let unmergedReads: Int
        let mergedSamples: [[String: Any]]

        var performed: Bool { mergedSampleCount > 0 }

        init(samples: [IlluminaSampleInput]) {
            // Pair the sample with its outcome up front so the per-sample rows
            // below carry plain values: JSONSerialization throws on a wrapped
            // Optional, and this record must never be the thing that fails a run.
            let merged = samples.compactMap { sample -> (IlluminaSampleInput, IlluminaAmpliconPairMerger.Outcome)? in
                guard let outcome = sample.mergeOutcome, outcome.didMerge else { return nil }
                return (sample, outcome)
            }
            mergedSampleCount = merged.count
            totalSampleCount = samples.count
            mergedFragments = merged.reduce(0) { $0 + $1.1.mergedCount }
            unmergedReads = merged.reduce(0) { $0 + $1.1.unmergedReadCount }
            mergedSamples = merged.map { sample, outcome in
                [
                    "sample": sample.sampleID,
                    "disposition": outcome.disposition.rawValue,
                    "mergedFragments": outcome.mergedCount,
                    "unmergedReads": outcome.unmergedReadCount,
                    "mappedRecordCount": outcome.mappingReadCount,
                ]
            }
        }

        /// The keys to splice into any artifact that should carry the record.
        ///
        /// `pairMergePerformedDuringRun` is always present, including when it is
        /// false: an absent key would leave a reader unable to tell "did not
        /// merge" apart from "written by a build that did not record merging".
        func recordDictionary() -> [String: Any] {
            var record: [String: Any] = ["pairMergePerformedDuringRun": performed]
            guard performed else { return record }
            record["pairMergeSummary"] = [
                "mergedSampleCount": mergedSampleCount,
                "totalSampleCount": totalSampleCount,
                "mergedFragments": mergedFragments,
                "unmergedReads": unmergedReads,
                "reason": "inputs were not merged at import; run the Illumina Amplicon Merge recipe to merge at import time",
                "tool": "bbmerge.sh",
                "mergedSamples": mergedSamples,
            ]
            return record
        }
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
        pythonURL: URL,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
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
                pythonURL: pythonURL,
                progressHandler: progressHandler
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
        pythonURL: URL,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> IlluminaPreparation {
        let inputsDirectory = supportDirectory.appendingPathComponent("inputs", isDirectory: true)
        let isONTSampleBundles = mode == .ontSampleBundles
        let stagedDirectory = supportDirectory.appendingPathComponent(
            isONTSampleBundles ? "ont-sample-fastqs" : "illumina-sample-fastqs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: inputsDirectory, withIntermediateDirectories: true)

        var samples = try await Self.resolveIlluminaSampleInputs(
            from: request.inputFASTQURLs,
            stagingDirectory: stagedDirectory
        )
        _ = pythonURL
        // Illumina pairs must be merged before mapping: the retained-read filter
        // requires a full-reference-span exact match, which a single 251 bp mate
        // cannot achieve against the 244 bp DRB amplicons. Without this the DRB
        // loci silently genotype as zero. See `IlluminaAmpliconPairMerger`.
        if mode == .illuminaPaired {
            samples = try await Self.mergeIlluminaPairsIfNeeded(
                samples: samples,
                supportDirectory: supportDirectory,
                threads: request.threads,
                condaManager: condaManager,
                progressHandler: progressHandler
            )
        }
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
            var item: [String: Any] = [
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
            if let merge = sample.mergeOutcome {
                item["pairMerge"] = [
                    "disposition": merge.disposition.rawValue,
                    "mergedFragments": merge.mergedCount,
                    "unmergedReads": merge.unmergedReadCount,
                    "mappedRecordCount": merge.mappingReadCount,
                    "mappingFASTQ": sample.mappingFASTQURL.path,
                    "arguments": merge.arguments,
                ]
            }
            return item
        }
        // Surface pair merging at the top level, not only per sample: a reader
        // checking whether reads were merged should not have to scan every
        // sample entry to find out.
        let pairMerge = PairMergeProvenance(samples: samples)
        var manifest: [String: Any] = [
            "mode": mode.rawValue,
            "inputReadCount": samples.reduce(0) { $0 + $1.readCount },
            "requiresBothEndSoftclips": requiresBothEndSoftclips,
            "samples": sampleItems,
        ]
        manifest.merge(pairMerge.recordDictionary()) { _, new in new }
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: sampleManifestURL, options: .atomic)

        return IlluminaPreparation(
            mode: mode,
            sampleManifestURL: sampleManifestURL,
            sampleDefinitionsURL: sampleDefinitionsURL,
            samples: samples,
            sourceFASTQURLs: samples.map(\.fastqURL),
            mappingFASTQURLs: samples.map(\.mappingFASTQURL),
            requiresBothEndSoftclips: requiresBothEndSoftclips,
            pairMerge: pairMerge
        )
    }

    /// Merges each Illumina sample's read pairs so the retained-read filter can
    /// see full-length amplicons.
    ///
    /// Samples whose FASTQ is already single-end/merged are returned unchanged,
    /// so pre-merged bundles keep their existing behaviour and cost nothing.
    /// A sample is only rewritten to point at merged reads when bbmerge ran and
    /// produced records.
    private static func mergeIlluminaPairsIfNeeded(
        samples: [IlluminaSampleInput],
        supportDirectory: URL,
        threads: Int,
        condaManager: CondaManager,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> [IlluminaSampleInput] {
        // Probe first so a fully pre-merged cohort never needs the bbtools env.
        var pairedIndices: [Int] = []
        for (index, sample) in samples.enumerated() {
            if try await IlluminaAmpliconPairMerger.fastqIsInterleavedPairs(at: sample.fastqURL) {
                pairedIndices.append(index)
            }
        }
        guard !pairedIndices.isEmpty else { return samples }

        // Say so loudly. Reaching here means the inputs were imported without
        // the Illumina Amplicon Merge recipe, and the run's read counts and
        // provenance will differ from a merged-on-import bundle. Silence here
        // is what let a whole locus class (DRB) report zero unnoticed.
        progressHandler?(
            0.23,
            """
            \(pairedIndices.count) of \(samples.count) Illumina inputs contain unmerged read pairs. \
            Merging overlapping pairs before mapping so full-length amplicons \
            (including the 244 bp DRB loci) can be genotyped. Import with the \
            Illumina Amplicon Merge recipe to do this at import time instead.
            """
        )
        let bbmergeURL = try await condaManager.toolPath(name: "bbmerge.sh", environment: "bbtools")
        let mergeDirectory = supportDirectory.appendingPathComponent("illumina-merged-fastqs", isDirectory: true)
        var updated = samples
        for index in pairedIndices {
            let sample = samples[index]
            let outcome = try await IlluminaAmpliconPairMerger.prepareForMapping(
                fastqURL: sample.fastqURL,
                bbmergeURL: bbmergeURL,
                workingDirectory: mergeDirectory,
                stem: safeFilenameStem(sample.sampleID),
                threads: threads
            )
            guard outcome.didMerge else { continue }
            updated[index].mappingFASTQURL = outcome.mappingFASTQURL
            updated[index].mergeOutcome = outcome
        }
        return updated
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
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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
            for try await record in reader.records(from: sample.mappingFASTQURL) {
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
        let indexStderr = try await runSamtoolsIndex(
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
                    inputFASTQURLs: [sample.mappingFASTQURL],
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
            mergeStderr = try await runSamtoolsMerge(
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
        let indexStderr = try await runSamtoolsIndex(
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
        let minimap2StderrHandle = try fileHandleForWriting(to: minimap2StderrURL)
        minimap2.standardError = minimap2StderrHandle

        let sort = Process()
        sort.executableURL = samtoolsURL
        sort.arguments = sortArguments
        sort.standardInput = stdoutPipe
        let sortStderrHandle = try fileHandleForWriting(to: sortStderrURL)
        sort.standardError = sortStderrHandle

        let minimap2Exit = ONTGenotypingProcessExitObservation()
        let sortExit = ONTGenotypingProcessExitObservation()
        minimap2.terminationHandler = { terminatedProcess in
            minimap2Exit.record(status: terminatedProcess.terminationStatus)
        }
        sort.terminationHandler = { terminatedProcess in
            sortExit.record(status: terminatedProcess.terminationStatus)
        }
        let processes = ONTGenotypingMappingProcessGroup(processes: [minimap2, sort])
        let requestTermination: @Sendable () -> Void = {
            processes.requestTermination()
        }
        let processWaiter = ONTGenotypingProcessExitWaiter()
        let processDeadline = ONTGenotypingProcessDeadline(timeout: Self.mappingProcessTimeout)

        defer {
            minimap2.terminationHandler = nil
            sort.terminationHandler = nil
            try? minimap2StderrHandle.close()
            try? sortStderrHandle.close()
        }

        try Task.checkCancellation()
        try sort.run()
        do {
            try minimap2.run()
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            stdoutPipe.fileHandleForReading.closeFile()
            requestTermination()
            throw error
        }
        stdoutPipe.fileHandleForWriting.closeFile()
        stdoutPipe.fileHandleForReading.closeFile()
        async let streamedInputCount: Int? = {
            guard let streamedSampleInputs, let stdinPipe else { return nil }
            do {
                let count = try await Self.writeSamplePrefixedFASTQStream(
                    samples: streamedSampleInputs,
                    to: stdinPipe.fileHandleForWriting
                )
                try stdinPipe.fileHandleForWriting.close()
                return count
            } catch {
                try? stdinPipe.fileHandleForWriting.close()
                throw error
            }
        }()

        let processStatuses: [String: Int32]
        let streamedInputError: Error?
        do {
            processStatuses = try await withThrowingTaskGroup(
                of: (tool: String, status: Int32).self
            ) { group in
                group.addTask {
                    let status = try await processWaiter.wait(
                        tool: "minimap2",
                        deadline: processDeadline,
                        observation: minimap2Exit,
                        isRunning: { minimap2.isRunning },
                        terminationStatus: { minimap2.terminationStatus },
                        requestTermination: requestTermination
                    )
                    return ("minimap2", status)
                }
                group.addTask {
                    let status = try await processWaiter.wait(
                        tool: "samtools sort",
                        deadline: processDeadline,
                        observation: sortExit,
                        isRunning: { sort.isRunning },
                        terminationStatus: { sort.terminationStatus },
                        requestTermination: requestTermination
                    )
                    return ("samtools sort", status)
                }

                var statuses: [String: Int32] = [:]
                var firstFailure: (tool: String, status: Int32)?
                while let exit = try await group.next() {
                    statuses[exit.tool] = exit.status
                    if exit.status != 0 {
                        if firstFailure == nil {
                            firstFailure = exit
                        }
                        requestTermination()
                    }
                }
                if var failure = firstFailure {
                    let minimap2TerminationSignals = Set<Int32>([SIGPIPE, SIGTERM, SIGKILL])
                    if failure.tool == "minimap2",
                       minimap2TerminationSignals.contains(failure.status),
                       let sortStatus = statuses["samtools sort"],
                       sortStatus != 0,
                       !minimap2TerminationSignals.contains(sortStatus) {
                        failure = ("samtools sort", sortStatus)
                    }
                    throw ONTGenotypingProcessWaitError.exitedNonzero(
                        tool: failure.tool,
                        status: failure.status
                    )
                }
                return statuses
            }
            do {
                _ = try await streamedInputCount
                streamedInputError = nil
            } catch {
                streamedInputError = error
            }
        } catch let waitError as ONTGenotypingProcessWaitError {
            requestTermination()
            _ = try? await streamedInputCount
            try? minimap2StderrHandle.close()
            try? sortStderrHandle.close()
            let tool: String
            let publicError: ONTBarcodeDemuxGenotypingError
            switch waitError {
            case .timedOut(let timedOutTool, let timedOutSeconds):
                tool = timedOutTool
                let stderrURL = tool == "minimap2" ? minimap2StderrURL : sortStderrURL
                let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
                publicError = .processTimedOut(
                    tool: tool,
                    seconds: timedOutSeconds,
                    stderr: stderr
                )
            case .exitedNonzero(let failedTool, let status):
                tool = failedTool
                let stderrURL = tool == "minimap2" ? minimap2StderrURL : sortStderrURL
                let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
                publicError = .processFailed(tool: tool, status: status, stderr: stderr)
            }
            throw publicError
        } catch {
            requestTermination()
            _ = try? await streamedInputCount
            throw error
        }
        try? minimap2StderrHandle.close()
        try? sortStderrHandle.close()

        let minimap2Stderr = (try? String(contentsOf: minimap2StderrURL, encoding: .utf8)) ?? ""
        let sortStderr = (try? String(contentsOf: sortStderrURL, encoding: .utf8)) ?? ""
        let minimap2Status = processStatuses["minimap2"] ?? minimap2.terminationStatus
        let sortStatus = processStatuses["samtools sort"] ?? sort.terminationStatus
        guard minimap2Status == 0 else {
            throw ONTBarcodeDemuxGenotypingError.processFailed(
                tool: "minimap2",
                status: minimap2Status,
                stderr: minimap2Stderr
            )
        }
        guard sortStatus == 0 else {
            throw ONTBarcodeDemuxGenotypingError.processFailed(
                tool: "samtools sort",
                status: sortStatus,
                stderr: sortStderr
            )
        }
        if let streamedInputError {
            throw streamedInputError
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
    ) async throws -> String {
        try await runSamtoolsProcess(
            tool: "samtools merge",
            samtoolsURL: samtoolsURL,
            arguments: arguments,
            stderrURL: stderrURL
        )
    }

    private func runSamtoolsIndex(
        samtoolsURL: URL,
        arguments: [String],
        stderrURL: URL
    ) async throws -> String {
        try await runSamtoolsProcess(
            tool: "samtools index",
            samtoolsURL: samtoolsURL,
            arguments: arguments,
            stderrURL: stderrURL
        )
    }

    private func runSamtoolsProcess(
        tool: String,
        samtoolsURL: URL,
        arguments: [String],
        stderrURL: URL
    ) async throws -> String {
        let process = Process()
        process.executableURL = samtoolsURL
        process.arguments = arguments
        let stderrHandle = try fileHandleForWriting(to: stderrURL)
        process.standardError = stderrHandle

        let exit = ONTGenotypingProcessExitObservation()
        process.terminationHandler = { terminatedProcess in
            exit.record(status: terminatedProcess.terminationStatus)
        }
        let processes = ONTGenotypingMappingProcessGroup(processes: [process])
        let requestTermination: @Sendable () -> Void = {
            processes.requestTermination()
        }

        defer {
            process.terminationHandler = nil
            try? stderrHandle.close()
        }

        try Task.checkCancellation()
        try process.run()

        let status: Int32
        do {
            status = try await ONTGenotypingProcessExitWaiter().wait(
                tool: tool,
                deadline: ONTGenotypingProcessDeadline(timeout: Self.mappingProcessTimeout),
                observation: exit,
                isRunning: { process.isRunning },
                terminationStatus: { process.terminationStatus },
                requestTermination: requestTermination
            )
        } catch let waitError as ONTGenotypingProcessWaitError {
            requestTermination()
            try? stderrHandle.close()
            let seconds: TimeInterval
            switch waitError {
            case .timedOut(_, let timedOutSeconds):
                seconds = timedOutSeconds
            case .exitedNonzero(_, let status):
                let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
                throw ONTBarcodeDemuxGenotypingError.processFailed(
                    tool: tool,
                    status: status,
                    stderr: stderr
                )
            }
            let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            throw ONTBarcodeDemuxGenotypingError.processTimedOut(
                tool: tool,
                seconds: seconds,
                stderr: stderr
            )
        } catch {
            requestTermination()
            throw error
        }

        try? stderrHandle.close()
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        guard status == 0 else {
            throw ONTBarcodeDemuxGenotypingError.processFailed(
                tool: tool,
                status: status,
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
            kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
            workflowKind: .miSeqAmpliconMHCGenotype,
            workflowMode: .haplotyped,
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

    private func publishReviewableRowCatalogIfNeeded(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        resolvedMode: AmpliconGenotypingMode,
        reference: ReferenceResolution,
        scientificArtifactPublication: AmpliconGenotypeScientificArtifactPublication?
    ) throws -> GenotypeReviewableRowCatalogPublication? {
        guard resolvedMode == .illuminaPaired,
              request.haplotypeDefinitionSetID == nil,
              let scientificArtifactPublication else {
            return nil
        }
        let projectionManifest = ONTGenotypeResultBundleManifest(
            kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
            workflowKind: .miSeqAmpliconMHCGenotype,
            workflowMode: .genotypeOnly,
            outputName: request.outputName,
            analysisName: request.analysisName,
            primaryWorkbookPath: relativePath(
                from: request.outputDirectory,
                to: request.workbookURL
            ),
            longSummaryCSVPath: relativePath(
                from: request.outputDirectory,
                to: request.reportCSVURL
            ),
            sampleSummaryCSVPath: relativePath(
                from: request.outputDirectory,
                to: request.sampleSummaryCSVURL
            ),
            statsJSONPath: relativePath(
                from: request.outputDirectory,
                to: request.statsJSONURL
            ),
            provenancePath: relativePath(
                from: request.outputDirectory,
                to: request.provenanceURL
            )
        )
        let csvAuthority = try GenotypeReviewCSVSemanticAuthority.capture(
            sampleSummaryURL: request.sampleSummaryCSVURL,
            reportURL: request.reportCSVURL
        )
        let result = try ONTGenotypeResultBundle.loadResult(
            from: request.outputDirectory,
            manifest: projectionManifest
        )
        let expectedCalls = result.locusSummaries.flatMap(\.sharedCalls)
            .flatMap { call in
                call.sampleSupport.map { support in
                    ONTGenotypeCall(
                        sample: support.sample,
                        genotype: call.genotype,
                        passedAlignments: support.passedAlignments,
                        passedUniqueReads: support.passedUniqueReads,
                        sampleTotalReads: nil,
                        sampleUniqueRetainedReads: nil,
                        sampleUniqueRetainedPercent: nil,
                        overallInputReads: nil,
                        overallUniqueRetainedReads: nil,
                        overallUniqueRetainedPercent: nil
                    )
                }
            }
        try csvAuthority.requireMatches(
            expectedRoster: result.sampleNames,
            expectedCalls: expectedCalls
        )
        let referenceAuthority = try Self.reviewableReferenceAuthority(
            referenceFASTAURL: reference.referenceFASTAURL,
            sourceReferenceBundleURL: reference.sourceReferenceBundleURL
        )
        let referenceRecords = referenceAuthority.records.filter {
            !$0.alleleName.localizedCaseInsensitiveContains("_nov")
        }
        let candidateSnapshot = try scientificArtifactPublication.catalogJSONURL.map {
            try GenotypeReviewAuthorityFileSnapshot.capture($0)
        }
        let exactCandidateDocument = try candidateSnapshot.map {
            try JSONDecoder().decode(
                ONTGenotypeProvisionalExon2Document.self,
                from: $0.data
            )
        }
        guard exactCandidateDocument
            == scientificArtifactPublication.provisionalExon2Document else {
            throw GenotypeReviewableRowCatalogPublisherError.authorityChanged(
                scientificArtifactPublication.catalogJSONURL?.path
                    ?? "missing provisional exon 2 authority"
            )
        }
        let candidates = exactCandidateDocument?.records.map(
            GenotypeReviewableRowCandidate.init(provisionalExon2:)
        ) ?? []
        struct CallIdentity: Hashable {
            let locus: String
            let genotype: String
        }
        let groupedCalls = Dictionary(
            grouping: csvAuthority.calls,
            by: { CallIdentity(locus: $0.locusGroup, genotype: $0.genotype) }
        )
        let exactCalls = try groupedCalls.map { identity, calls in
            ONTGenotypeSharedCall(
                locus: identity.locus,
                genotype: identity.genotype,
                sampleSupport: try Dictionary(grouping: calls, by: \.sample)
                    .map { sample, rows in
                        ONTGenotypeSampleSupport(
                            sample: sample,
                            passedAlignments: try checkedSupportSum(
                                rows.map(\.passedAlignments),
                                sample: sample
                            ),
                            passedUniqueReads: try checkedSupportSum(
                                rows.map(\.passedUniqueReads),
                                sample: sample
                            )
                        )
                    }
            )
        }
        let outputURL = request.outputDirectory
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("projections", isDirectory: true)
            .appendingPathComponent("genotype-reviewable-rows.json")
        let argv = [
            "lungfish-internal", "publish-genotype-reviewable-rows",
            "--reference-fasta", reference.referenceFASTAURL.path,
            "--sample-roster", request.sampleSummaryCSVURL.path,
            "--calls", request.reportCSVURL.path,
            "--provisional-exon-2",
            scientificArtifactPublication.catalogJSONURL?.path ?? "none",
            "--output", outputURL.path,
            "--support-metric", "passed-unique-reads",
        ]
        var descriptors = referenceAuthority.descriptors + [
            csvAuthority.sampleSnapshot.descriptor(format: .text, role: .input),
            csvAuthority.reportSnapshot.descriptor(format: .text, role: .input),
        ]
        if let candidateSnapshot {
            descriptors.append(
                candidateSnapshot.descriptor(format: .json, role: .input)
            )
        }
        let publication = try reviewableRowCatalogPublisher(
            GenotypeReviewableRowCatalogInputs(
                referenceRecords: referenceRecords,
                authoritativeSamples: csvAuthority.roster,
                calls: exactCalls,
                candidates: candidates,
                inputDescriptors: descriptors,
                workflowName: Self.workflowName(for: resolvedMode),
                workflowVersion: "1",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: argv,
                userVisibleOptions: [
                    "workflowMode": .string(GenotypeResultWorkflowMode.genotypeOnly.rawValue),
                    "candidateDesignation": .string("provisional-exon-2"),
                ],
                resolvedDefaults: [
                    "supportMetric": .string("passed-unique-reads"),
                    "referenceRowScope": .string("all-exact-run-reference-records"),
                    "candidateDatabaseResolution": .boolean(false),
                ],
                runtimeIdentity: ProvenanceRuntimeIdentity(
                    appVersion: WorkflowRun.currentAppVersion,
                    executablePath: CommandLine.arguments.first
                        ?? ProvenanceRuntimeIdentity.currentExecutablePath,
                    operatingSystemVersion: WorkflowRun.currentHostOS,
                    user: NSUserName(),
                    condaEnvironment: "lungfish-managed-tools",
                    condaPrefix: condaManager.rootPrefix.path
                )
            ),
            request.outputDirectory,
            {
                try csvAuthority.requireUnchanged()
                try referenceAuthority.requireUnchanged()
                try candidateSnapshot?.requireUnchanged()
            }
        )
        return publication
    }

    private func checkedSupportSum(
        _ values: [Int],
        sample: String
    ) throws -> Int {
        var result = 0
        for value in values {
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else {
                throw GenotypeReviewableRowCatalogPublisherError
                    .invalidSupport(sample: sample, value: Int.max)
            }
            result = addition.partialValue
        }
        return result
    }

    static func reviewableReferenceAuthority(
        referenceFASTAURL: URL,
        sourceReferenceBundleURL: URL?,
        authorityObserver:
            @Sendable (GenotypeReviewableReferenceAuthorityPhase) throws -> Void = { _ in }
    ) throws -> GenotypeReviewableReferenceAuthority {
        let catalogBundleURL: URL?
        var authorityURLs = [referenceFASTAURL.standardizedFileURL]
        var preCapturedSnapshots:
            [String: GenotypeReviewAuthorityFileSnapshot] = [:]
        if let source = sourceReferenceBundleURL,
           MHCAmpliconReferenceBundle.isBundleURL(source) {
            authorityURLs.append(
                MHCAmpliconReferenceBundle.manifestURL(in: source)
                    .standardizedFileURL
            )
            catalogBundleURL = MHCAmpliconReferenceBundle.referenceBundleURL(in: source)
        } else if sourceReferenceBundleURL?.pathExtension.lowercased()
            == "lungfishref" {
            catalogBundleURL = sourceReferenceBundleURL
        } else {
            catalogBundleURL = nil
        }
        if let catalogBundleURL {
            let manifestURL = catalogBundleURL
                .appendingPathComponent(BundleManifest.filename)
                .standardizedFileURL
            let manifestSnapshot = try GenotypeReviewAuthorityFileSnapshot.capture(
                manifestURL
            )
            preCapturedSnapshots[manifestURL.path] = manifestSnapshot
            let manifest = try JSONDecoder().decode(
                GenotypeReviewableReferenceManifestProjection.self,
                from: manifestSnapshot.data
            )
            authorityURLs.append(manifestURL)
            if let genomePath = manifest.genome?.path {
                authorityURLs.append(try BundleManifest.validatedBundleMemberURL(
                    for: genomePath,
                    in: catalogBundleURL,
                    field: "genome.path"
                ))
            }
            if let databasePath = manifest.recordStore?.databasePath {
                authorityURLs.append(try BundleManifest.validatedBundleMemberURL(
                    for: databasePath,
                    in: catalogBundleURL,
                    field: "record_store.database_path"
                ))
            }
        }
        var seenPaths = Set<String>()
        let snapshots = try authorityURLs
            .map(\.standardizedFileURL)
            .filter { seenPaths.insert($0.path).inserted }
            .map {
                if let captured = preCapturedSnapshots[$0.path] {
                    return captured
                }
                return try GenotypeReviewAuthorityFileSnapshot.capture($0)
            }
        try authorityObserver(.afterSnapshotBeforeSemanticLoad)
        let records: [MHCReferenceRecord]
        if let catalogBundleURL {
            records = try recordsFromRetainedCatalogSnapshots(
                snapshots,
                catalogBundleURL: catalogBundleURL
            )
        } else {
            guard let fastaSnapshot = snapshots.first(where: {
                $0.url.standardizedFileURL
                    == referenceFASTAURL.standardizedFileURL
            }) else {
                throw GenotypeReviewableRowCatalogPublisherError
                    .invalidInputDescriptor(referenceFASTAURL.path)
            }
            records = try recordsFromRetainedFASTASnapshot(fastaSnapshot)
        }
        try authorityObserver(.beforeFinalVerification)
        for snapshot in snapshots {
            try snapshot.requireUnchanged()
        }
        let descriptors = snapshots.map {
            $0.descriptor(
                    format: $0.url.pathExtension.lowercased() == "json"
                        ? .json
                        : ($0.url.pathExtension.lowercased().contains("fa") ? .fasta : nil),
                    role: .reference
                )
        }
        return GenotypeReviewableReferenceAuthority(
            records: records,
            descriptors: descriptors,
            snapshots: snapshots
        )
    }

    private static func recordsFromRetainedCatalogSnapshots(
        _ snapshots: [GenotypeReviewAuthorityFileSnapshot],
        catalogBundleURL: URL
    ) throws -> [MHCReferenceRecord] {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "lungfish-review-reference-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let bundleRoot = catalogBundleURL.standardizedFileURL
        let bundlePrefix = bundleRoot.path.hasSuffix("/")
            ? bundleRoot.path
            : bundleRoot.path + "/"
        for snapshot in snapshots {
            let sourcePath = snapshot.url.standardizedFileURL.path
            guard sourcePath.hasPrefix(bundlePrefix) else { continue }
            let relativePath = String(sourcePath.dropFirst(bundlePrefix.count))
            guard !relativePath.isEmpty else { continue }
            let destination = temporaryRoot.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try snapshot.data.write(to: destination, options: .atomic)
        }
        return try MHCReferenceRecordCatalog.load(from: temporaryRoot).records
    }

    private static func recordsFromRetainedFASTASnapshot(
        _ snapshot: GenotypeReviewAuthorityFileSnapshot
    ) throws -> [MHCReferenceRecord] {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "lungfish-review-fasta-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let fastaURL = temporaryRoot.appendingPathComponent(
            snapshot.url.lastPathComponent
        )
        try snapshot.data.write(to: fastaURL, options: .atomic)
        return try FASTAReader(url: fastaURL).readAllSync().map {
                let locus = ONTGenotypeCall(
                    sample: "catalog-projection",
                    genotype: $0.name,
                    passedAlignments: 0,
                    passedUniqueReads: 0,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    overallInputReads: nil,
                    overallUniqueRetainedReads: nil,
                    overallUniqueRetainedPercent: nil
                ).locusGroup
                return MHCReferenceRecord(
                    sequenceID: $0.name,
                    alleleName: $0.name,
                    locus: locus,
                    moleculeClass: .genomicDNA,
                    classEvidence: .lengthThresholdFallback,
                    sequenceLength: $0.length
                )
            }
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

    /// Copies the run's input-preparation record into the durable stats JSON.
    ///
    /// The filter script writes the stats file from what it can see, which is
    /// the scratch sample manifest under `.amplicon-genotyping`. That directory
    /// is deleted on success, so anything recorded only there is lost, and the
    /// `sampleManifest` path the script wrote dangles. This lifts the merge
    /// record into the stats file, which is a first-class bundle output, and
    /// drops the dangling path so nobody is sent chasing a deleted file.
    ///
    /// The stats file is rewritten before provenance is recorded, so the
    /// checksum in the envelope covers the annotated content.
    private func annotateStatsJSONWithInputPreparation(
        statsJSONURL: URL,
        illuminaPreparation: IlluminaPreparation?
    ) throws {
        let data = try Data(contentsOf: statsJSONURL)
        guard var stats = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        stats.removeValue(forKey: "sampleManifest")
        if let illuminaPreparation {
            stats.merge(illuminaPreparation.pairMerge.recordDictionary()) { _, new in new }
        }
        let annotated = try JSONSerialization.data(
            withJSONObject: stats,
            options: [.prettyPrinted, .sortedKeys]
        )
        try annotated.write(to: statsJSONURL, options: .atomic)
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
            kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
            workflowKind: .miSeqAmpliconMHCGenotype,
            workflowMode: .haplotyped,
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
        referenceRecordStoreSnapshot: GenotypeReferenceRecordStoreSnapshot.PublishedSnapshot?,
        scientificArtifactPublication: AmpliconGenotypeScientificArtifactPublication?,
        reviewableRowCatalogPublication: GenotypeReviewableRowCatalogPublication?,
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
            // `internalMergePerformed` was fixed at false back when merging could
            // only happen at import. The pipeline now merges unmerged pairs
            // itself, so reporting false would hide the very thing a reader
            // consults this key to learn.
            var preparationRecord: [String: Any] = [
                "mode": preparation.mode.rawValue,
                "sourceFASTQs": preparation.sourceFASTQURLs.map(\.path),
                "mappingFASTQs": preparation.mappingFASTQURLs.map(\.path),
                "mappingInputTransport": "stdin-sample-prefixed-fastq",
                "sampleDefinitions": preparation.sampleDefinitionsURL.path,
                "sampleManifest": preparation.sampleManifestURL.path,
                "requiresBothEndSoftclips": preparation.requiresBothEndSoftclips,
                "internalMergePerformed": preparation.pairMerge.performed,
            ]
            preparationRecord.merge(preparation.pairMerge.recordDictionary()) { _, new in new }
            return preparationRecord
        } as Any? ?? NSNull()
        let illuminaInputPreparation: Any = resolvedMode == .illuminaPaired
            ? sampleBundleInputPreparation
            : NSNull()
        let requireBothEndSoftclips = illuminaPreparation?.requiresBothEndSoftclips
            ?? (resolvedMode == .ontBarcodeDemux)
        let resultWorkflowKind = Self.resolvedResultWorkflowKind(
            for: request,
            resolvedMode: resolvedMode
        )
        let resultWorkflowMode = Self.resolvedResultWorkflowMode(
            for: request,
            resolvedMode: resolvedMode
        )
        let options: [String: Any] = [
            "inputFASTQ": request.inputFASTQURL.path,
            "inputFASTQs": request.inputFASTQURLs.map(\.path),
            "mode": request.mode.rawValue,
            "resolvedMode": resolvedMode.rawValue,
            "readType": request.readType.rawValue,
            "resolvedReadType": resolvedReadType.rawValue,
            "resultWorkflowKind": resultWorkflowKind?.rawValue as Any? ?? NSNull(),
            "resultWorkflowMode": resultWorkflowMode?.rawValue as Any? ?? NSNull(),
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
            "keepIntermediates": request.keepIntermediates,
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
            "resultWorkflowKind": NSNull(),
            "resultWorkflowMode": NSNull(),
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
            "keepIntermediates": false,
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
        let recordStoreInputs = referenceRecordStoreSnapshot.map {
            [fileDescriptorDictionary(url: $0.sourceURL, role: "reference-metadata")]
        } ?? []
        let recordStoreOutputs = referenceRecordStoreSnapshot.map {
            [fileDescriptorDictionary(url: $0.destinationURL, role: "reference-metadata-snapshot")]
        } ?? []
        let scientificArtifactOutputs = scientificArtifactPublication?.outputURLs.map {
            fileDescriptorDictionary(url: $0, role: $0.pathExtension.lowercased() == "json" ? "report" : "output")
        } ?? []
        let reviewableRowCatalogOutputs = reviewableRowCatalogPublication.map {
            [fileDescriptorDictionary(url: $0.outputURL, role: "report")]
        } ?? []
        let durableAlignmentOutputs: [[String: Any]] = scientificArtifactPublication == nil
            ? []
            : [
                fileDescriptorDictionary(url: request.retainedBAMURL, role: "output"),
                fileDescriptorDictionary(url: request.retainedBAIURL, role: "index"),
            ]
        var provenanceInputs: [[String: Any]] = inputs
        provenanceInputs += mappingInputs
        provenanceInputs += [
            fileDescriptorDictionary(url: reference.referenceFASTAURL, role: "reference"),
            fileDescriptorDictionary(url: demuxManifestURL, role: "input"),
            fileDescriptorDictionary(url: scriptURL, role: "input"),
            fileDescriptorDictionary(url: reportScriptURL, role: "input"),
        ]
        provenanceInputs += request.barcodeDefinitionsURL.map {
            [fileDescriptorDictionary(url: $0, role: "input")]
        } ?? []
        provenanceInputs += comparisonInputs
        provenanceInputs += stagedInputs
        provenanceInputs += haplotypeDefinitionInputs
        provenanceInputs += specialistPromptInputs
        provenanceInputs += recordStoreInputs
        var transientAlignmentOutputs: [[String: Any]] = [
            fileDescriptorDictionary(url: request.mappingBAMURL, role: "intermediate"),
            fileDescriptorDictionary(url: request.mappingBAIURL, role: "intermediate-index"),
        ] + mapping.transientBAMURLs.map { fileDescriptorDictionary(url: $0, role: "intermediate") }
        if scientificArtifactPublication == nil {
            transientAlignmentOutputs += [
                fileDescriptorDictionary(url: request.retainedBAMURL, role: "intermediate"),
                fileDescriptorDictionary(url: request.retainedBAIURL, role: "intermediate-index"),
            ]
        }
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
        ] + currentWorkbookProvenanceOutputs
            + specialistPromptOutputs
            + recordStoreOutputs
            + durableAlignmentOutputs
            + scientificArtifactOutputs
            + reviewableRowCatalogOutputs
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
        let recordStoreSteps: [[String: Any]] = referenceRecordStoreSnapshot.map { snapshot in
            [[
                "toolName": "lungfish genotype reference metadata snapshot",
                "toolVersion": WorkflowRun.currentAppVersion,
                "argv": ["copy", snapshot.sourceURL.path, snapshot.destinationURL.path],
                "inputs": [fileDescriptorDictionary(url: snapshot.sourceURL, role: "reference-metadata")],
                "outputs": [fileDescriptorDictionary(url: snapshot.destinationURL, role: "reference-metadata-snapshot")],
                "exitStatus": 0,
                "wallClockSeconds": snapshot.completedAt.timeIntervalSince(snapshot.startedAt),
                "wallTimeSeconds": snapshot.completedAt.timeIntervalSince(snapshot.startedAt),
            ]]
        } ?? []
        let scientificArtifactSteps: [[String: Any]] = scientificArtifactPublication.map { publication in
            [[
                "toolName": "Lungfish Provisional exon 2 artifact publisher",
                "toolVersion": WorkflowRun.currentAppVersion,
                "argv": publication.argv,
                "durableReplayArgv": publication.argv,
                "reproducibleCommand": publication.argv.map(shellEscape).joined(separator: " "),
                "resolvedOptions": [
                    "identifierRule": "case-insensitive-_nov",
                    "sampleScope": "assigned-only",
                    "fastaWrap": 80,
                    "databaseResolution": false,
                ],
                "runtimeIdentity": [
                    "appVersion": WorkflowRun.currentAppVersion,
                    "executablePath": CommandLine.arguments.first ?? "",
                    "operatingSystemVersion": WorkflowRun.currentHostOS,
                    "user": NSUserName(),
                ],
                "inputs": [
                    fileDescriptorDictionary(url: request.reportCSVURL, role: "report"),
                    fileDescriptorDictionary(url: reference.referenceFASTAURL, role: "reference"),
                    fileDescriptorDictionary(url: request.retainedBAMURL, role: "output"),
                    fileDescriptorDictionary(url: request.retainedBAIURL, role: "index"),
                ],
                "outputs": scientificArtifactOutputs,
                "exitStatus": 0,
                "wallClockSeconds": publication.completedAt.timeIntervalSince(publication.startedAt),
                "wallTimeSeconds": publication.completedAt.timeIntervalSince(publication.startedAt),
                "stderr": "",
                "startedAt": ISO8601DateFormatter().string(from: publication.startedAt),
                "completedAt": ISO8601DateFormatter().string(from: publication.completedAt),
            ]]
        } ?? []
        let reviewableRowCatalogSteps: [[String: Any]] =
            reviewableRowCatalogPublication.map { publication in
                [[
                    "toolName": publication.provenance.toolName,
                    "toolVersion": publication.provenance.toolVersion,
                    "argv": publication.provenance.argv,
                    "durableReplayArgv": publication.provenance.durableReplayArgv
                        ?? publication.provenance.argv,
                    "reproducibleCommand": publication.provenance.reproducibleCommand,
                    "outputs": reviewableRowCatalogOutputs,
                    "exitStatus": publication.provenance.exitStatus ?? 0,
                    "wallTimeSeconds": publication.provenance.wallTimeSeconds ?? 0,
                    "stderr": publication.provenance.stderr ?? "",
                ]]
            } ?? []
        var steps: [[String: Any]] = mappingProcessSteps
        steps += mergeStep
        steps += [
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
        ]
        steps += scientificArtifactSteps
        steps += reviewableRowCatalogSteps
        steps += haplotypeSteps
        steps += currentHaplotypeSteps
        steps += specialistPromptSteps
        steps += recordStoreSteps
        steps += [
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
            referenceRecordStoreSnapshot: referenceRecordStoreSnapshot,
            scientificArtifactPublication: scientificArtifactPublication,
            reviewableRowCatalogPublication: reviewableRowCatalogPublication,
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
        referenceRecordStoreSnapshot: GenotypeReferenceRecordStoreSnapshot.PublishedSnapshot?,
        scientificArtifactPublication: AmpliconGenotypeScientificArtifactPublication?,
        reviewableRowCatalogPublication: GenotypeReviewableRowCatalogPublication?,
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
        let recordStoreInput = try referenceRecordStoreSnapshot.map {
            try canonicalFileDescriptor(url: $0.sourceURL, role: .reference)
        }
        var allCanonicalInputs = fastqInputs
        allCanonicalInputs += mappingFastqInputs
        allCanonicalInputs += [referenceInput, demuxInput, filterScriptInput, reportScriptInput]
        allCanonicalInputs += barcodeInput.map { [$0] } ?? []
        allCanonicalInputs += comparisonInputs
        allCanonicalInputs += stagedInputs
        allCanonicalInputs += haplotypeDefinitionInput.map { [$0] } ?? []
        allCanonicalInputs += specialistPromptSource.map { [$0] } ?? []
        allCanonicalInputs += recordStoreInput.map { [$0] } ?? []
        let canonicalInputs = deduplicated(allCanonicalInputs)

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
        let recordStoreOutput = try referenceRecordStoreSnapshot.map {
            try canonicalFileDescriptor(url: $0.destinationURL, role: .output)
        }
        let scientificArtifactOutputs = try scientificArtifactPublication?.outputURLs.map {
            try canonicalFileDescriptor(
                url: $0,
                role: $0.pathExtension.lowercased() == "json" ? .report : .output
            )
        } ?? []
        let reviewableRowCatalogOutputs =
            reviewableRowCatalogPublication?.provenance.outputs ?? []
        let durableAlignmentOutputs = scientificArtifactPublication == nil
            ? []
            : [retainedBAM, retainedBAI]
        var allCanonicalOutputs = [genotypeCSV, sampleCSV, statsJSON]
        allCanonicalOutputs += haplotypeOutput.map { [$0] } ?? []
        allCanonicalOutputs += currentHaplotypeOutput.map { [$0] } ?? []
        allCanonicalOutputs += [workbook, currentWorkbook, reportProvenance, legacyProvenance]
        allCanonicalOutputs += currentWorkbookProvenance.map { [$0] } ?? []
        allCanonicalOutputs += specialistPromptOutput.map { [$0] } ?? []
        allCanonicalOutputs += recordStoreOutput.map { [$0] } ?? []
        allCanonicalOutputs += durableAlignmentOutputs
        allCanonicalOutputs += scientificArtifactOutputs
        allCanonicalOutputs += reviewableRowCatalogOutputs
        let canonicalOutputs = deduplicated(allCanonicalOutputs)
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
        canonicalSteps += reviewableRowCatalogPublication?.provenance.steps ?? []
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
        if let publication = scientificArtifactPublication {
            canonicalSteps.append(
                ProvenanceStep(
                    toolName: "Lungfish Provisional exon 2 artifact publisher",
                    toolVersion: WorkflowRun.currentAppVersion,
                    argv: publication.argv,
                    durableReplayArgv: publication.argv,
                    resolvedOptions: [
                        "identifierRule": .string("case-insensitive-_nov"),
                        "sampleScope": .string("assigned-only"),
                        "fastaWrap": .integer(80),
                        "databaseResolution": .boolean(false),
                    ],
                    runtimeIdentity: ProvenanceRuntimeIdentity(
                        appVersion: WorkflowRun.currentAppVersion,
                        executablePath: CommandLine.arguments.first
                            ?? ProvenanceRuntimeIdentity.currentExecutablePath,
                        operatingSystemVersion: WorkflowRun.currentHostOS,
                        user: NSUserName()
                    ),
                    inputs: [genotypeCSV, referenceInput, retainedBAM, retainedBAI],
                    outputs: scientificArtifactOutputs,
                    exitStatus: 0,
                    wallTimeSeconds: publication.completedAt.timeIntervalSince(publication.startedAt),
                    stderr: "",
                    startedAt: publication.startedAt,
                    completedAt: publication.completedAt
                )
            )
        }
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
        if let snapshot = referenceRecordStoreSnapshot,
           let recordStoreInput,
           let recordStoreOutput {
            canonicalSteps.append(
                ProvenanceStep(
                    toolName: "lungfish genotype reference metadata snapshot",
                    toolVersion: WorkflowRun.currentAppVersion,
                    argv: ["copy", snapshot.sourceURL.path, snapshot.destinationURL.path],
                    inputs: [recordStoreInput],
                    outputs: [recordStoreOutput],
                    exitStatus: 0,
                    wallTimeSeconds: snapshot.completedAt.timeIntervalSince(snapshot.startedAt),
                    startedAt: snapshot.startedAt,
                    completedAt: snapshot.completedAt
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

        let canonicalStepFiles: [ProvenanceFileDescriptor] = canonicalSteps.flatMap { step in
            step.inputs + step.outputs
        }
        let canonicalFiles = deduplicated(canonicalInputs + canonicalOutputs + canonicalStepFiles)

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
            files: canonicalFiles,
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
        referenceRecordStore: ONTGenotypeReferenceRecordStoreInfo?,
        scientificArtifactPublication: AmpliconGenotypeScientificArtifactPublication?,
        reviewableRowCatalogPublication: GenotypeReviewableRowCatalogPublication?,
        completedAt: Date
    ) throws {
        let resolvedHaplotypeDefinitionSet = try resolveHaplotypeDefinitionSet(for: request)
        let resultWorkflowKind = Self.resolvedResultWorkflowKind(
            for: request,
            resolvedMode: resolvedMode
        )
        let resultWorkflowMode = Self.resolvedResultWorkflowMode(
            for: request,
            resolvedMode: resolvedMode
        )
        let manifest = ONTGenotypeResultBundleManifest(
            kind: resultWorkflowKind?.rawValue ?? "ont-barcode-genotype",
            workflowKind: resultWorkflowKind,
            workflowMode: resultWorkflowMode,
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
            createdAt: ISO8601DateFormatter().string(from: completedAt),
            referenceRecordStore: referenceRecordStore,
            alignmentArtifacts: scientificArtifactPublication?.alignmentArtifacts,
            provisionalExon2Artifacts: scientificArtifactPublication?.provisionalExon2Artifacts,
            reviewableRowCatalog: reviewableRowCatalogPublication?.artifact
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

    private static func resolvedResultWorkflowKind(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        resolvedMode: AmpliconGenotypingMode
    ) -> GenotypeResultWorkflowKind? {
        request.resultWorkflowKind
            ?? (resolvedMode == .illuminaPaired ? .miSeqAmpliconMHCGenotype : nil)
    }

    private static func resolvedResultWorkflowMode(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        resolvedMode: AmpliconGenotypingMode
    ) -> GenotypeResultWorkflowMode? {
        guard resolvedResultWorkflowKind(for: request, resolvedMode: resolvedMode) != nil else {
            return nil
        }
        return request.haplotypeDefinitionSetID == nil ? .genotypeOnly : .haplotyped
    }

    private func generatedAlignmentIntermediateURLs(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        mapping: MappingStepResult,
        preserveRetainedEvidence: Bool
    ) -> [URL] {
        var removableURLs = [
            request.mappingBAMURL,
            request.mappingBAIURL,
        ] + mapping.transientBAMURLs
        if !preserveRetainedEvidence {
            removableURLs += [
                request.retainedBAMURL,
                request.retainedBAIURL,
            ]
        }
        return removableURLs
    }

    private func cleanupGeneratedAlignmentIntermediates(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        mapping: MappingStepResult,
        preserveRetainedEvidence: Bool,
        cleanupPlan: GenotypingCleanupPlan
    ) -> [AmpliconWorkDirectoryDisposition] {
        let removableURLs = generatedAlignmentIntermediateURLs(
            for: request,
            mapping: mapping,
            preserveRetainedEvidence: preserveRetainedEvidence
        )
        var seen = Set<String>()
        var dispositions: [AmpliconWorkDirectoryDisposition] = []
        for url in removableURLs.map(\.standardizedFileURL)
        where seen.insert(url.path).inserted
            && cleanupPlan.entry(for: url) != nil {
            if request.keepIntermediates {
                dispositions.append(
                    identityBoundRetainedDisposition(
                        plan: cleanupPlan,
                        url: url,
                        mutation: { _ in }
                    )
                )
                continue
            }
            dispositions.append(
                identityBoundRemovalDisposition(
                    plan: cleanupPlan,
                    url: url,
                    successDisposition: "removed",
                    remover: fileRemover
                )
            )
        }
        return dispositions
    }

    private func beginSuccessfulCleanupJournal(
        runID: UUID,
        projectRoot: URL,
        request: ONTBarcodeDemuxGenotypingRunRequest,
        mapping: MappingStepResult,
        preserveRetainedEvidence: Bool,
        supportDirectory: URL
    ) throws -> GenotypingCleanupPlan {
        var candidates: [
            (
                url: URL,
                intendedAction: GenotypingCleanupIntendedAction
            )
        ] = generatedAlignmentIntermediateURLs(
            for: request,
            mapping: mapping,
            preserveRetainedEvidence: preserveRetainedEvidence
        ).map {
            (
                url: $0,
                intendedAction:
                    request.keepIntermediates
                        ? .retainByRequest
                        : .removeRegenerableAlignmentIntermediate
            )
        }
        candidates.append(
            (
                url: supportDirectory,
                intendedAction:
                    request.keepIntermediates
                        ? .retainByRequestAfterMarkerCompletion
                        : .removeOwnedSupportDirectoryAfterMarkerCompletion
            )
        )
        do {
            let entries = try GenotypingCleanupJournal.planEntries(candidates)
            try cleanupJournalObserver(.beforeInitialCreation)
            let writer = ProjectOperationHistoryWriter(
                projectURL: projectRoot
            )
            _ = try writer.createOperation(
                operationID: runID,
                payloads: [
                    GenotypingCleanupJournal.planPayloadName:
                        try GenotypingCleanupJournal.planData(
                            runID: runID,
                            entries: entries
                        ),
                ]
            )
            let plan = GenotypingCleanupPlan(
                runID: runID,
                operationURL: writer.operationDirectoryURL(for: runID),
                outputBundleURL: request.outputDirectory,
                entriesByPath: Dictionary(
                    uniqueKeysWithValues: entries.map { ($0.path, $0) }
                )
            )
            try cleanupJournalObserver(
                .afterInitialCreationBeforeMutation
            )
            return plan
        } catch {
            let operationURL = ProjectOperationHistoryWriter(
                projectURL: projectRoot
            ).operationDirectoryURL(for: runID)
            throw GenotypingCleanupJournalError(
                runID: runID,
                operationPath: operationURL.path,
                cleanupPlanPath: operationURL.appendingPathComponent(
                    GenotypingCleanupJournal.planPayloadName
                ).path,
                outputBundlePath: request.outputDirectory.path,
                phase: .initialCreation,
                publishedArtifactsValid: true,
                retainedRootPaths: candidates.map {
                    $0.url.standardizedFileURL.path
                },
                underlyingDescription: error.localizedDescription
            )
        }
    }

    private func appendSuccessfulCleanupDisposition(
        runID: UUID,
        projectRoot: URL,
        outputBundleURL: URL,
        dispositions: [AmpliconWorkDirectoryDisposition]
    ) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                AmpliconWorkDirectoryDispositionEnvelope(
                    schemaVersion: 1,
                    runID: runID,
                    entries: dispositions
                )
            )
            try cleanupJournalObserver(.beforeTerminalAppend)
            try ProjectOperationHistoryWriter(
                projectURL: projectRoot
            ).append(
                data,
                named: GenotypingCleanupJournal.terminalPayloadName,
                toOperation: runID
            )
        } catch {
            throw GenotypingCleanupJournalError(
                runID: runID,
                operationPath: ProjectOperationHistoryWriter(
                    projectURL: projectRoot
                ).operationDirectoryURL(for: runID).path,
                cleanupPlanPath: ProjectOperationHistoryWriter(
                    projectURL: projectRoot
                ).operationDirectoryURL(for: runID).appendingPathComponent(
                    GenotypingCleanupJournal.planPayloadName
                ).path,
                outputBundlePath: outputBundleURL.path,
                phase: .terminalAppend,
                publishedArtifactsValid: true,
                retainedRootPaths: dispositions.filter {
                    $0.disposition != "removed"
                }.map(\.path),
                underlyingDescription: error.localizedDescription
            )
        }
    }

    private func identityBoundRemovalDisposition(
        plan: GenotypingCleanupPlan,
        url: URL,
        successDisposition: String,
        remover: (URL) throws -> Void
    ) -> AmpliconWorkDirectoryDisposition {
        let path = url.standardizedFileURL.path
        guard let entry = plan.entry(for: url) else {
            return .init(
                path: path,
                disposition: "retained-identity-mismatch",
                error: "No immutable cleanup-plan identity exists for \(path)."
            )
        }
        switch GenotypingIdentityBoundCleanup.remove(entry, remover: remover) {
        case .removed:
            return .init(
                path: path,
                disposition: successDisposition,
                error: nil
            )
        case .identityMismatch(let detail):
            return .init(
                path: path,
                disposition: "retained-identity-mismatch",
                error: detail
            )
        case .failed(let detail):
            return .init(
                path: path,
                disposition: "retained-cleanup-failed",
                error: detail
            )
        case .retained(let quarantinePath):
            return .init(
                path: path,
                disposition: "retained-cleanup-failed",
                error: quarantinePath.map {
                    "Unexpectedly retained at \($0)."
                } ?? "Unexpectedly retained."
            )
        }
    }

    private func identityBoundRetainedDisposition(
        plan: GenotypingCleanupPlan,
        url: URL,
        mutation: (URL) throws -> Void
    ) -> AmpliconWorkDirectoryDisposition {
        let path = url.standardizedFileURL.path
        guard let entry = plan.entry(for: url) else {
            return .init(
                path: path,
                disposition: "retained-identity-mismatch",
                error: "No immutable cleanup-plan identity exists for \(path)."
            )
        }
        switch GenotypingIdentityBoundCleanup.mutateAndRetain(
            entry,
            mutation: mutation
        ) {
        case .retained:
            return .init(
                path: path,
                disposition: "retained-by-request",
                error: nil
            )
        case .identityMismatch(let detail):
            return .init(
                path: path,
                disposition: "retained-identity-mismatch",
                error: detail
            )
        case .failed(let detail):
            return .init(
                path: path,
                disposition: "retained-cleanup-failed",
                error: detail
            )
        case .removed(let quarantinePath):
            return .init(
                path: path,
                disposition: "retained-cleanup-failed",
                error: "Unexpectedly removed via \(quarantinePath)."
            )
        }
    }

    private func rollbackScientificOutputsAfterFinalizationFailure(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        mapping: MappingStepResult,
        preserveReviewableRowCatalog: Bool
    ) -> [AmpliconWorkDirectoryDisposition] {
        let alignmentURLs = [
            request.mappingBAMURL,
            request.mappingBAIURL,
            request.retainedBAMURL,
            request.retainedBAIURL,
        ] + mapping.transientBAMURLs
        let sequenceDirectory = request.outputDirectory
            .appendingPathComponent("artifacts/sequences", isDirectory: true)
        let canonicalProvenanceURL = request.outputDirectory
            .appendingPathComponent(ProvenanceWriter.provenanceFilename)
        var removableURLs = alignmentURLs + [
            request.reportCSVURL,
            request.sampleSummaryCSVURL,
            request.statsJSONURL,
            request.workbookURL,
            request.currentWorkbookURL,
            request.reportProvenanceURL,
            request.currentWorkbookProvenanceURL,
            request.haplotypeAnalysisURL,
            request.currentHaplotypeAnalysisURL,
            request.specialistPromptSnapshotURL,
            request.provenanceURL,
            canonicalProvenanceURL,
            ProvenanceSigningConfiguration.signatureURL(for: canonicalProvenanceURL),
            ProvenanceSigningConfiguration.publicKeyURL(for: canonicalProvenanceURL),
            ONTGenotypeResultBundle.manifestURL(in: request.outputDirectory),
            request.outputDirectory.appendingPathComponent(
                GenotypeReferenceRecordStoreSnapshot.relativeDatabasePath
            ),
            sequenceDirectory.appendingPathComponent(
                "observed-provisional-exon2.json"
            ),
            sequenceDirectory.appendingPathComponent(
                "observed-provisional-exon2.fasta"
            ),
            request.outputDirectory.appendingPathComponent(
                ProvenanceWriter.bundleProvenanceDirectoryName,
                isDirectory: true
            ),
        ]
        if !preserveReviewableRowCatalog {
            removableURLs.append(
                request.outputDirectory.appendingPathComponent(
                    "artifacts/projections/genotype-reviewable-rows.json"
                )
            )
        }
        var dispositions: [AmpliconWorkDirectoryDisposition] = []
        var seen = Set<String>()
        for url in removableURLs.map(\.standardizedFileURL)
            where seen.insert(url.path).inserted
                && FileManager.default.fileExists(atPath: url.path) {
            do {
                try fileRemover(url)
                dispositions.append(.init(
                    path: url.path,
                    disposition: "removed",
                    error: nil
                ))
            } catch {
                dispositions.append(.init(
                    path: url.path,
                    disposition: "retained-cleanup-failed",
                    error: error.localizedDescription
                ))
            }
        }
        return dispositions
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
        Self.managedToolDescriptors(ids: ids, manifest: ManagedToolLock.bundled)
    }

    /// Builds provenance descriptors for the tools this pipeline invokes.
    ///
    /// Managed (required-pack) tools resolve through `manifest.tools`; optional pack
    /// tools such as minimap2 resolve through `manifest.packTools` by tool id, so the
    /// recorded `packageSpec` is always the manifest's build-pinned spec.
    static func managedToolDescriptors(ids: [String], manifest: ManagedToolLock) -> [[String: Any]] {
        ids.compactMap { id in
            if let tool = manifest.tool(named: id) {
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
            if let packTool = manifest.packTools.first(where: { $0.toolID == id }) {
                return [
                    "id": packTool.toolID,
                    "packID": packTool.packID,
                    "environment": packTool.environment,
                    "packageSpec": packTool.packageSpec,
                    "executables": packTool.executables,
                    "version": packTool.version,
                    "license": packTool.license as Any? ?? NSNull(),
                    "sourceUrl": packTool.sourceUrl as Any? ?? NSNull(),
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
