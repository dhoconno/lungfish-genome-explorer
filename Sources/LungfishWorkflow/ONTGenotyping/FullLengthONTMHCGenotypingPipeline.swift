import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

public enum FullLengthONTPBAAClusterSourceMode: String, Sendable, Codable, Equatable, CaseIterable {
    case useCompatible = "use-compatible"
    case requireExisting = "require-existing"
    case rerunAll = "rerun-all"

    public init?(cliValue: String) {
        self.init(rawValue: cliValue)
    }
}

public struct FullLengthONTMHCGenotypingRunRequest: Sendable, Codable, Equatable {
    public static let defaultSavontQualityValueCutoff = 90
    public static let defaultSavontMinimumClusterSize = 3
    public static let savontToolVersion = "0.5.0"
    public static let savontCondaEnvironment = "savont"
    public static let savontPackageSpec = "bioconda::savont=0.5.0=ha819e4a_0"

    public let inputFASTQURLs: [URL]
    public let referenceSourceURL: URL
    public let orientReferenceURL: URL?
    public let forwardPrimerURL: URL?
    public let reversePrimerURL: URL?
    public let outputDirectory: URL
    public let outputName: String
    public let projectURL: URL?
    public let threads: Int
    public let minimumLength: Int
    public let maximumLength: Int
    public let savontQualityValueCutoff: Int
    public let savontMinimumClusterSize: Int
    public let minUnmatchedReads: Int
    public let cdnaThreshold: Int
    public let sampleJobs: Int?
    public let savontThreadsPerSample: Int?
    public let keepIntermediates: Bool
    public let reuseCompatibleCheckpoints: Bool
    public let haplotypeDropoutSampleFraction: Double?
    public let haplotypeDropoutLocusFraction: Double?
    public let haplotypeDropoutLocusFractionOverrides: [String: Double]
    public let haplotypeAssayID: String?
    public let haplotypeSpeciesCode: String?
    public let haplotypeDefinitionScope: HaplotypeDefinitionScope?
    public let haplotypeDefinitionSetID: String?

    public init(
        inputFASTQURLs: [URL],
        referenceSourceURL: URL,
        orientReferenceURL: URL? = nil,
        forwardPrimerURL: URL? = nil,
        reversePrimerURL: URL? = nil,
        outputDirectory: URL,
        outputName: String = "full-length-ont-mhc-genotyping",
        projectURL: URL? = nil,
        threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        minimumLength: Int = 2_000,
        maximumLength: Int = 4_000,
        savontQualityValueCutoff: Int = Self.defaultSavontQualityValueCutoff,
        savontMinimumClusterSize: Int = Self.defaultSavontMinimumClusterSize,
        minUnmatchedReads: Int = 5,
        cdnaThreshold: Int = 2_000,
        sampleJobs: Int? = nil,
        savontThreadsPerSample: Int? = nil,
        keepIntermediates: Bool = false,
        reuseCompatibleCheckpoints: Bool = false,
        haplotypeDropoutSampleFraction: Double? = nil,
        haplotypeDropoutLocusFraction: Double? = nil,
        haplotypeDropoutLocusFractionOverrides: [String: Double] = [:],
        haplotypeAssayID: String? = nil,
        haplotypeSpeciesCode: String? = nil,
        haplotypeDefinitionScope: HaplotypeDefinitionScope? = nil,
        haplotypeDefinitionSetID: String? = nil
    ) {
        let normalizedOutputName = Self.sanitizedOutputName(outputName)
        self.inputFASTQURLs = inputFASTQURLs.map(\.standardizedFileURL)
        self.referenceSourceURL = referenceSourceURL.standardizedFileURL
        self.orientReferenceURL = orientReferenceURL?.standardizedFileURL
        self.forwardPrimerURL = forwardPrimerURL?.standardizedFileURL
        self.reversePrimerURL = reversePrimerURL?.standardizedFileURL
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.outputName = normalizedOutputName
        self.projectURL = projectURL?.standardizedFileURL
        self.threads = max(1, threads)
        self.minimumLength = max(1, minimumLength)
        self.maximumLength = max(self.minimumLength, maximumLength)
        self.savontQualityValueCutoff = max(0, min(100, savontQualityValueCutoff))
        self.savontMinimumClusterSize = max(1, savontMinimumClusterSize)
        self.minUnmatchedReads = max(1, minUnmatchedReads)
        self.cdnaThreshold = max(1, cdnaThreshold)
        self.sampleJobs = sampleJobs.map { max(1, $0) }
        self.savontThreadsPerSample = savontThreadsPerSample.map { max(1, $0) }
        self.keepIntermediates = keepIntermediates
        self.reuseCompatibleCheckpoints = reuseCompatibleCheckpoints
        self.haplotypeDropoutSampleFraction = Self.normalizedFraction(haplotypeDropoutSampleFraction)
        self.haplotypeDropoutLocusFraction = Self.normalizedFraction(haplotypeDropoutLocusFraction)
        self.haplotypeDropoutLocusFractionOverrides = Self.normalizedFractionOverrides(
            haplotypeDropoutLocusFractionOverrides
        )
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
    }

    public var reportCSVURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).full-length-ont-mhc-genotypes.csv")
    }

    public var sampleSummaryCSVURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).full-length-ont-mhc-samples.csv")
    }

    public var statsJSONURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).full-length-ont-mhc-stats.json")
    }

    public var workbookURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).full-length-ont-mhc-genotypes.xlsx")
    }

    public var currentWorkbookURL: URL {
        outputDirectory
            .appendingPathComponent("artifacts/workbooks", isDirectory: true)
            .appendingPathComponent("current.xlsx")
    }

    public var haplotypeAnalysisURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).haplotype-analysis.json")
    }

    public var unmatchedClustersFASTAURL: URL {
        outputDirectory.appendingPathComponent("unmatched_clusters.fasta")
    }

    public var deduplicatedUnmatchedClustersFASTAURL: URL {
        outputDirectory.appendingPathComponent("deduplicated_unmatched_clusters.fasta")
    }

    public var cdnaClustersFASTAURL: URL {
        outputDirectory.appendingPathComponent("cdna_clusters.fasta")
    }

    public var provenanceURL: URL {
        outputDirectory.appendingPathComponent("full-length-ont-mhc-genotyping-provenance.json")
    }

    public var manifestURL: URL {
        ONTGenotypeResultBundle.manifestURL(in: outputDirectory)
    }

    public var argv: [String] {
        var values = [
            CLICommandIdentity.executableName,
            "fastq",
            "full-length-ont-mhc-genotype",
        ] + inputFASTQURLs.map(\.path) + [
            "--reference", referenceSourceURL.path,
            "--output-dir", outputDirectory.path,
            "--output-name", outputName,
            "--threads", String(threads),
            "--min-length", String(minimumLength),
            "--max-length", String(maximumLength),
            "--savont-quality-value-cutoff", String(savontQualityValueCutoff),
            "--savont-min-cluster-size", String(savontMinimumClusterSize),
            "--min-unmatched-reads", String(minUnmatchedReads),
            "--cdna-threshold", String(cdnaThreshold),
        ]
        appendHaplotypeThresholdArguments(to: &values)
        if let orientReferenceURL {
            values += ["--orient-reference", orientReferenceURL.path]
        }
        if let forwardPrimerURL {
            values += ["--forward-primer", forwardPrimerURL.path]
        }
        if let reversePrimerURL {
            values += ["--reverse-primer", reversePrimerURL.path]
        }
        if let projectURL {
            values += ["--project", projectURL.path]
        }
        if let sampleJobs {
            values += ["--sample-jobs", String(sampleJobs)]
        }
        if let savontThreadsPerSample {
            values += ["--savont-threads-per-sample", String(savontThreadsPerSample)]
        }
        if keepIntermediates {
            values += ["--keep-intermediates"]
        }
        if reuseCompatibleCheckpoints {
            values += ["--reuse-compatible-checkpoints"]
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
        return values
    }

    public var haplotypeDropoutEvaluator: GenotypeDropoutEvaluator? {
        guard haplotypeDropoutSampleFraction != nil
                || haplotypeDropoutLocusFraction != nil
                || !haplotypeDropoutLocusFractionOverrides.isEmpty else {
            return nil
        }
        return GenotypeDropoutEvaluator(
            absolute: 1,
            sampleFraction: haplotypeDropoutSampleFraction,
            locusFraction: haplotypeDropoutLocusFraction,
            locusFractionOverrides: haplotypeDropoutLocusFractionOverrides
        )
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

    public func replacingOutput(outputDirectory: URL, outputName: String) -> FullLengthONTMHCGenotypingRunRequest {
        FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: inputFASTQURLs,
            referenceSourceURL: referenceSourceURL,
            orientReferenceURL: orientReferenceURL,
            forwardPrimerURL: forwardPrimerURL,
            reversePrimerURL: reversePrimerURL,
            outputDirectory: outputDirectory,
            outputName: outputName,
            projectURL: projectURL,
            threads: threads,
            minimumLength: minimumLength,
            maximumLength: maximumLength,
            savontQualityValueCutoff: savontQualityValueCutoff,
            savontMinimumClusterSize: savontMinimumClusterSize,
            minUnmatchedReads: minUnmatchedReads,
            cdnaThreshold: cdnaThreshold,
            sampleJobs: sampleJobs,
            savontThreadsPerSample: savontThreadsPerSample,
            keepIntermediates: keepIntermediates,
            reuseCompatibleCheckpoints: reuseCompatibleCheckpoints,
            haplotypeDropoutSampleFraction: haplotypeDropoutSampleFraction,
            haplotypeDropoutLocusFraction: haplotypeDropoutLocusFraction,
            haplotypeDropoutLocusFractionOverrides: haplotypeDropoutLocusFractionOverrides,
            haplotypeAssayID: haplotypeAssayID,
            haplotypeSpeciesCode: haplotypeSpeciesCode,
            haplotypeDefinitionScope: haplotypeDefinitionScope,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID
        )
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
        return collapsed.isEmpty ? "full-length-ont-mhc-genotyping" : collapsed
    }
}

public enum FullLengthONTMHCGenotypingCleanupWarningKind: String, Sendable, Codable, Equatable {
    case retiredCohortPublicationDirectory
    case cohortAlignmentTemporaryWorkDirectory
    case cohortAlignmentWorkDirectory
    case workflowIntermediates
}

public struct FullLengthONTMHCGenotypingCleanupWarning: Sendable, Codable, Equatable {
    public let kind: FullLengthONTMHCGenotypingCleanupWarningKind
    public let path: String
    public let error: String
    public let publishedArtifactsRemainValid: Bool

    public init(
        kind: FullLengthONTMHCGenotypingCleanupWarningKind,
        path: String,
        error: String,
        publishedArtifactsRemainValid: Bool
    ) {
        self.kind = kind
        self.path = path
        self.error = error
        self.publishedArtifactsRemainValid = publishedArtifactsRemainValid
    }
}

public struct FullLengthONTMHCGenotypingResult: Sendable, Codable, Equatable {
    public let outputDirectory: URL
    public let reportCSVURL: URL
    public let sampleSummaryCSVURL: URL
    public let statsJSONURL: URL
    public let workbookURL: URL
    public let primaryWorkbookURL: URL
    public let haplotypeAnalysisURL: URL?
    public let unmatchedClustersFASTAURL: URL
    public let deduplicatedUnmatchedClustersFASTAURL: URL
    public let cdnaClustersFASTAURL: URL
    public let provenanceURL: URL
    public let referenceFASTAURL: URL
    public let genotypingEvidenceBAMURL: URL?
    public let genotypingEvidenceBAIURL: URL?
    public let cleanupWarnings: [FullLengthONTMHCGenotypingCleanupWarning]
}

extension FullLengthONTMHCGenotypingResult {
    private enum CodingKeys: String, CodingKey {
        case outputDirectory
        case reportCSVURL
        case sampleSummaryCSVURL
        case statsJSONURL
        case workbookURL
        case primaryWorkbookURL
        case haplotypeAnalysisURL
        case unmatchedClustersFASTAURL
        case deduplicatedUnmatchedClustersFASTAURL
        case cdnaClustersFASTAURL
        case provenanceURL
        case referenceFASTAURL
        case genotypingEvidenceBAMURL
        case genotypingEvidenceBAIURL
        case cleanupWarnings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outputDirectory = try container.decode(URL.self, forKey: .outputDirectory)
        reportCSVURL = try container.decode(URL.self, forKey: .reportCSVURL)
        sampleSummaryCSVURL = try container.decode(URL.self, forKey: .sampleSummaryCSVURL)
        statsJSONURL = try container.decode(URL.self, forKey: .statsJSONURL)
        workbookURL = try container.decode(URL.self, forKey: .workbookURL)
        primaryWorkbookURL = try container.decode(URL.self, forKey: .primaryWorkbookURL)
        haplotypeAnalysisURL = try container.decodeIfPresent(URL.self, forKey: .haplotypeAnalysisURL)
        unmatchedClustersFASTAURL = try container.decode(URL.self, forKey: .unmatchedClustersFASTAURL)
        deduplicatedUnmatchedClustersFASTAURL = try container.decode(
            URL.self,
            forKey: .deduplicatedUnmatchedClustersFASTAURL
        )
        cdnaClustersFASTAURL = try container.decode(URL.self, forKey: .cdnaClustersFASTAURL)
        provenanceURL = try container.decode(URL.self, forKey: .provenanceURL)
        referenceFASTAURL = try container.decode(URL.self, forKey: .referenceFASTAURL)
        genotypingEvidenceBAMURL = try container.decodeIfPresent(URL.self, forKey: .genotypingEvidenceBAMURL)
        genotypingEvidenceBAIURL = try container.decodeIfPresent(URL.self, forKey: .genotypingEvidenceBAIURL)
        cleanupWarnings = try container.decodeIfPresent(
            [FullLengthONTMHCGenotypingCleanupWarning].self,
            forKey: .cleanupWarnings
        ) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outputDirectory, forKey: .outputDirectory)
        try container.encode(reportCSVURL, forKey: .reportCSVURL)
        try container.encode(sampleSummaryCSVURL, forKey: .sampleSummaryCSVURL)
        try container.encode(statsJSONURL, forKey: .statsJSONURL)
        try container.encode(workbookURL, forKey: .workbookURL)
        try container.encode(primaryWorkbookURL, forKey: .primaryWorkbookURL)
        try container.encodeIfPresent(haplotypeAnalysisURL, forKey: .haplotypeAnalysisURL)
        try container.encode(unmatchedClustersFASTAURL, forKey: .unmatchedClustersFASTAURL)
        try container.encode(deduplicatedUnmatchedClustersFASTAURL, forKey: .deduplicatedUnmatchedClustersFASTAURL)
        try container.encode(cdnaClustersFASTAURL, forKey: .cdnaClustersFASTAURL)
        try container.encode(provenanceURL, forKey: .provenanceURL)
        try container.encode(referenceFASTAURL, forKey: .referenceFASTAURL)
        try container.encodeIfPresent(genotypingEvidenceBAMURL, forKey: .genotypingEvidenceBAMURL)
        try container.encodeIfPresent(genotypingEvidenceBAIURL, forKey: .genotypingEvidenceBAIURL)
        try container.encode(cleanupWarnings, forKey: .cleanupWarnings)
    }
}

public enum FullLengthONTMHCGenotypingError: Error, LocalizedError, Sendable, Equatable {
    case missingInput(String)
    case invalidReference(String)
    case invalidFASTQ(String)
    case invalidHaplotypeDefinition(String)
    case invalidHaplotypeDefinitionForAssay(definitionID: String, assayID: String)
    case ambiguousHaplotypeDefinition(definitionID: String)
    case processFailed(tool: String, status: Int32, stderr: String)
    case reportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingInput(let path):
            return "Input does not exist: \(path)"
        case .invalidReference(let path):
            return "Could not resolve an MHC reference FASTA from \(path)."
        case .invalidFASTQ(let path):
            return "Could not resolve a FASTQ payload from \(path)."
        case .invalidHaplotypeDefinition(let id):
            return "Could not find haplotype definition \(id)."
        case .invalidHaplotypeDefinitionForAssay(let definitionID, let assayID):
            return "Haplotype definition \(definitionID) is not registered for assay \(assayID)."
        case .ambiguousHaplotypeDefinition(let definitionID):
            return "Multiple haplotype definitions match \(definitionID); choose an assay, species, or scope."
        case .processFailed(let tool, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(tool) failed with exit status \(status)."
                : "\(tool) failed with exit status \(status): \(detail)"
        case .reportFailed(let reason):
            return "Could not write full-length ONT MHC genotyping report: \(reason)"
        }
    }
}

private final class FullLengthONTMHCProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latestFraction: Double = 0
    private let handler: (@Sendable (Double, String) -> Void)?

    init(_ handler: (@Sendable (Double, String) -> Void)?) {
        self.handler = handler
    }

    func emit(_ fraction: Double, _ message: String) {
        guard let handler else { return }
        let clampedFraction = min(1, max(0, fraction))
        lock.lock()
        let emittedFraction = max(latestFraction, clampedFraction)
        latestFraction = emittedFraction
        lock.unlock()
        handler(emittedFraction, message)
    }
}

private struct FullLengthONTMHCSavontPreset: Sendable, Equatable {
    let qualityValueCutoff: Int
    let minimumClusterSize: Int
    let label: String
    let directoryName: String

    static func requested(for request: FullLengthONTMHCGenotypingRunRequest) -> FullLengthONTMHCSavontPreset {
        let prefix = request.savontQualityValueCutoff == FullLengthONTMHCGenotypingRunRequest.defaultSavontQualityValueCutoff
            && request.savontMinimumClusterSize == FullLengthONTMHCGenotypingRunRequest.defaultSavontMinimumClusterSize
            ? "strict"
            : "requested"
        return FullLengthONTMHCSavontPreset(
            qualityValueCutoff: request.savontQualityValueCutoff,
            minimumClusterSize: request.savontMinimumClusterSize,
            label: "\(prefix)-qv\(request.savontQualityValueCutoff)-min\(request.savontMinimumClusterSize)",
            directoryName: "\(prefix)-qv\(request.savontQualityValueCutoff)-min\(request.savontMinimumClusterSize)"
        )
    }

    static let hiddenNoCallFallback = FullLengthONTMHCSavontPreset(
        qualityValueCutoff: FullLengthONTMHCGenotypingRunRequest.defaultSavontQualityValueCutoff,
        minimumClusterSize: 1,
        label: "fallback-qv90-min1",
        directoryName: "fallback-qv90-min1"
    )
}

private enum FullLengthONTMHCSavontSampleStatus: String, Sendable, Codable, Equatable {
    case called
    case noCall = "no-call"
    case handledSavontFailure = "handled-savont-failure"
}

public struct FullLengthONTMHCGenotypingPipeline: Sendable {
    private let nativeToolRunner: NativeToolRunner
    private let condaManager: CondaManager
    private let postPublicationWorkDirectoryCleaner: any FullLengthONTMHCWorkDirectoryCleaning

    public init(
        nativeToolRunner: NativeToolRunner = .shared,
        condaManager: CondaManager = .shared,
        postPublicationWorkDirectoryCleaner: any FullLengthONTMHCWorkDirectoryCleaning = DefaultFullLengthONTMHCWorkDirectoryCleaner()
    ) {
        self.nativeToolRunner = nativeToolRunner
        self.condaManager = condaManager
        self.postPublicationWorkDirectoryCleaner = postPublicationWorkDirectoryCleaner
    }

    public func run(
        _ request: FullLengthONTMHCGenotypingRunRequest,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> FullLengthONTMHCGenotypingResult {
        let progress = FullLengthONTMHCProgressRelay(progressHandler)
        let startedAt = Date()
        progress.emit(0.01, "Validating full-length ONT MHC genotyping inputs.")
        try validateInputs(request)
        let referenceFASTAURL = try resolveMHCReferenceFASTA(request.referenceSourceURL)
        let executionPlan = FullLengthONTMHCSampleExecutionPlan.automatic(
            totalThreads: request.threads,
            sampleCount: request.inputFASTQURLs.count,
            requestedSampleJobs: request.sampleJobs,
            requestedSavontThreadsPerSample: request.savontThreadsPerSample
        )

        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let workDirectory = request.outputDirectory.appendingPathComponent("workflow", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: request.outputDirectory.appendingPathComponent("samples", isDirectory: true),
            withIntermediateDirectories: true
        )
        try invalidatePublishedRunMetadata(request)

        try Data().write(to: request.unmatchedClustersFASTAURL, options: .atomic)
        try Data().write(to: request.cdnaClustersFASTAURL, options: .atomic)

        progress.emit(
            0.02,
            "Planning \(request.inputFASTQURLs.count) \(sampleLabel(request.inputFASTQURLs.count)): \(executionPlan.sampleJobs) concurrent sample \(jobLabel(executionPlan.sampleJobs)), Savont \(executionPlan.savontThreadsPerSample) thread/sample."
        )
        let stagedSamples = try stageSamples(
            request: request,
            workDirectory: workDirectory,
            progressHandler: { fraction, message in
                progress.emit(fraction, message)
            }
        )
        let orderedSamples = FullLengthONTMHCSampleScheduler.processingOrder(for: stagedSamples)
        let totalReadCount = stagedSamples.reduce(0) { $0 + max(1, $1.readCount) }
        progress.emit(
            FullLengthONTMHCSampleScheduler.processingStartProgress,
            "Processing \(orderedSamples.count) \(sampleLabel(orderedSamples.count)) largest-first across \(executionPlan.sampleJobs) concurrent sample \(jobLabel(executionPlan.sampleJobs))."
        )

        let sampleExecution = FullLengthONTMHCSampleExecutionConfiguration(
            workerThreads: executionPlan.workerThreadsPerSample,
            savontThreads: executionPlan.savontThreadsPerSample
        )
        var sampleResults: [FullLengthONTMHCSampleResult] = []
        var completedReadCount = 0
        var completedSampleCount = 0
        var nextSampleIndex = 0

        try await withThrowingTaskGroup(of: FullLengthONTMHCSampleResult.self) { group in
            func enqueueNextSample() {
                guard nextSampleIndex < orderedSamples.count else { return }
                let scheduled = orderedSamples[nextSampleIndex]
                let processingRank = nextSampleIndex + 1
                nextSampleIndex += 1
                progress.emit(
                    FullLengthONTMHCSampleScheduler.processingProgress(
                        completedReadCount: completedReadCount,
                        totalReadCount: totalReadCount
                    ),
                    "Started \(scheduled.sample) (\(processingRank)/\(orderedSamples.count), \(formattedReadCount(scheduled.readCount)) reads)."
                )
                let sampleProgressFraction = FullLengthONTMHCSampleScheduler.processingProgress(
                    completedReadCount: completedReadCount,
                    totalReadCount: totalReadCount
                )
                group.addTask {
                    try await processSample(
                        scheduled,
                        processingRank: processingRank,
                        request: request,
                        referenceFASTAURL: referenceFASTAURL,
                        execution: sampleExecution,
                        progressFraction: sampleProgressFraction,
                        progressHandler: { fraction, message in
                            progress.emit(fraction, message)
                        }
                    )
                }
            }

            for _ in 0..<min(executionPlan.sampleJobs, orderedSamples.count) {
                enqueueNextSample()
            }
            while let result = try await group.next() {
                sampleResults.append(result)
                completedReadCount += max(1, result.readCount)
                completedSampleCount += 1
                progress.emit(
                    FullLengthONTMHCSampleScheduler.processingProgress(
                        completedReadCount: completedReadCount,
                        totalReadCount: totalReadCount
                    ),
                    "Completed \(completedSampleCount)/\(orderedSamples.count): \(result.sample) (\(formattedReadCount(result.readCount)) reads)."
                )
                enqueueNextSample()
            }
        }

        let orderedResults = sampleResults.sorted { lhs, rhs in
            lhs.originalIndex < rhs.originalIndex
        }
        let minimap2ExecutableURL = try await condaManager.toolPath(
            name: "minimap2",
            environment: "minimap2"
        )
        let samtoolsExecutableURL = try await condaManager.toolPath(
            name: "samtools",
            environment: "samtools"
        )
        let cohortAlignmentBuilder = FullLengthONTMHCCohortAlignmentBuilder(
            minimap2ExecutableURL: minimap2ExecutableURL,
            samtoolsExecutableURL: samtoolsExecutableURL,
            workDirectoryCleaner: postPublicationWorkDirectoryCleaner
        )
        let cohortWorkDirectory = request.outputDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(".\(request.outputDirectory.lastPathComponent).cohort-alignment-work", isDirectory: true)
        try FileManager.default.createDirectory(at: cohortWorkDirectory, withIntermediateDirectories: true)
        let cohortAlignmentResult = try await cohortAlignmentBuilder.build(.init(
            samples: orderedResults.compactMap { result in
                guard !result.clusterRecords.isEmpty else { return nil }
                return FullLengthONTMHCSampleAlignmentInput(
                    sampleID: result.sample,
                    originalClustersFASTAURL: result.clustersFASTAURL,
                    clusterRecords: result.clusterRecords
                )
            },
            referenceAlleleFASTAURL: referenceFASTAURL,
            threads: request.threads,
            outputDirectoryURL: request.outputDirectory,
            workDirectoryURL: cohortWorkDirectory,
            keepIntermediates: request.keepIntermediates,
            deferTemporaryWorkDirectoryCleanup: true,
            allowEmptyCohort: orderedResults.allSatisfy(\.clusterRecords.isEmpty)
        ))
        let samtoolsVersion = cohortAlignmentResult.toolVersions.first {
            $0.toolName == "samtools"
        }?.version ?? "unknown"
        let bamView = try await cohortAlignmentBuilder.viewHeaderAndAlignments(
            in: cohortAlignmentResult.bamURL,
            temporaryWorkDirectoryURL: cohortAlignmentResult.temporaryWorkDirectoryURL,
            samtoolsVersion: samtoolsVersion
        )
        let summariesBySample = try genotypeSummariesFromFinalCohortBAM(
            orderedResults: orderedResults,
            samText: bamView.samText,
            referenceFASTAURL: referenceFASTAURL,
            request: request
        )
        let authoritativeResults = try orderedResults.map { result in
            guard let summary = summariesBySample[result.sample] else {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Final cohort BAM did not yield a summary for sample \(result.sample)."
                )
            }
            return result.applyingAuthoritativeGenotypingSummary(summary)
        }
        let allGenotypeRows = authoritativeResults.flatMap(\.genotypeRows)
        let sampleCounts = Dictionary(uniqueKeysWithValues: orderedResults.map { ($0.sample, $0.readCount) })
        let sampleSummaries = authoritativeResults.map(\.sampleSummary)
        var pipelineSteps = sampleResults
            .flatMap(\.steps)
            .sorted { lhs, rhs in lhs.startedAt < rhs.startedAt }
        let blastRescueDirectory = request.outputDirectory
            .appendingPathComponent(".full-length-ont-mhc", isDirectory: true)
            .appendingPathComponent("blast-rescue", isDirectory: true)
        let blastReferenceURL = try prepareBlastRescueReference(
            referenceFASTAURL,
            rescueDirectory: blastRescueDirectory
        )
        var rescueBySampleCluster: [String: FullLengthONTMHCBlastRescueMatch] = [:]
        for result in authoritativeResults {
            let closestClusters = Set(result.closestMatches.map(\.cluster))
            let rescueCandidates = result.unmatchedClusters.filter { !closestClusters.contains($0.name) }
            let sampleDirectory = request.outputDirectory
                .appendingPathComponent("samples", isDirectory: true)
                .appendingPathComponent(result.sample, isDirectory: true)
            let rescueMatches = try await rescueUnmatchedMHCMatches(
                sample: result.sample,
                records: rescueCandidates,
                referenceFASTAURL: blastReferenceURL,
                sampleDirectory: sampleDirectory,
                steps: &pipelineSteps
            )
            for match in rescueMatches {
                rescueBySampleCluster[sampleClusterKey(sample: match.sample, cluster: match.cluster)] = match
            }
        }
        let unmatchedClosestMatchRows = authoritativeResults.flatMap { result in
            let closestByCluster = Dictionary(uniqueKeysWithValues: result.closestMatches.map { ($0.cluster, $0) })
            return result.unmatchedClusters.map { record in
                FullLengthONTMHCUnmatchedSequenceNormalizer.workbookRow(
                    sample: result.sample,
                    record: record,
                    closestMatch: closestByCluster[record.name],
                    rescueMatch: rescueBySampleCluster[sampleClusterKey(sample: result.sample, cluster: record.name)]
                )
            }
        }
        for result in authoritativeResults {
            try append(records: result.unmatchedClusters, sample: result.sample, to: request.unmatchedClustersFASTAURL)
            try append(records: result.cdnaMatchedClusters, sample: result.sample, to: request.cdnaClustersFASTAURL)
        }
        try writeFASTARecords(
            FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder.deduplicatedFASTARecords(unmatchedClosestMatchRows),
            to: request.deduplicatedUnmatchedClustersFASTAURL
        )

        progress.emit(0.86, "Writing full-length ONT MHC genotype reports.")
        let reportRows = FullLengthONTMHCClusterReportBuilder.reportRows(
            genotypeRows: allGenotypeRows,
            sampleReadCounts: sampleCounts
        )
        try writeReportCSV(reportRows, to: request.reportCSVURL)
        try writeSampleSummaryCSV(sampleSummaries, to: request.sampleSummaryCSVURL)
        try writeStatsJSON(
            sampleSummaries: sampleSummaries,
            genotypeRows: allGenotypeRows,
            to: request.statsJSONURL
        )
        pipelineSteps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish final cohort BAM genotype parser",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-in-process", "parse-full-length-ont-mhc-final-bam",
                "--samtools-view", samtoolsExecutableURL.path,
                "--include-header",
                "--cdna-threshold", String(request.cdnaThreshold),
                "--min-unmatched-reads", String(request.minUnmatchedReads),
                cohortAlignmentResult.bamURL.path,
            ],
            inputs: [
                cohortAlignmentResult.bamURL,
                URL(fileURLWithPath: bamView.commandRecord.stdoutLogDescriptor.path),
                referenceFASTAURL,
            ] + authoritativeResults.map(\.clustersFASTAURL),
            outputs: [request.reportCSVURL, request.sampleSummaryCSVURL, request.statsJSONURL],
            exitStatus: 0,
            stderr: nil,
            startedAt: bamView.commandRecord.completedAt,
            completedAt: Date()
        ))
        let haplotypeAnalysis = try writeHaplotypeAnalysisIfRequested(
            request: request,
            supportDirectory: request.outputDirectory.appendingPathComponent(".full-length-ont-mhc", isDirectory: true),
            generatedAt: Date()
        )
        let orderedAlleles = try FullLengthONTMHCClusterGenotyper
            .readFASTARecords(from: referenceFASTAURL)
            .map(\.name)
        try writeWorkbook(
            request: request,
            reportRows: reportRows,
            sampleSummaries: sampleSummaries,
            genotypeRows: allGenotypeRows,
            unmatchedClosestMatchRows: unmatchedClosestMatchRows,
            orderedAlleles: orderedAlleles,
            haplotypeAnalysis: haplotypeAnalysis,
            to: request.workbookURL
        )
        let workbookCopy = try createInitialCurrentWorkbookCopy(for: request)
        pipelineSteps.append(workbookCopy.step)
        let evidenceArtifactPair = try validatedEvidenceArtifactPair(
            cohortAlignmentResult,
            bundleDirectoryURL: request.outputDirectory
        )
        let completedAt = Date()
        do {
            try writeManifest(
                request: request,
                workbookRevision: workbookCopy.revision,
                evidenceArtifactPair: evidenceArtifactPair,
                createdAt: completedAt
            )
            try writeProvenance(
                request: request,
                referenceFASTAURL: referenceFASTAURL,
                executionPlan: executionPlan,
                stagedSamples: stagedSamples,
                processingOrder: orderedSamples,
                steps: pipelineSteps,
                cohortAlignmentResult: cohortAlignmentResult,
                bamViewRecord: bamView.commandRecord,
                startedAt: startedAt,
                completedAt: completedAt
            )
        } catch {
            try? removePublishedRunMetadata(request)
            throw error
        }
        var cleanupWarnings = cohortAlignmentResult.cleanupDiagnostics.map(cleanupWarning)
        if request.keepIntermediates {
            progress.emit(0.98, "Preserving full-length ONT MHC workflow intermediates.")
        } else {
            progress.emit(0.98, "Removing regenerable full-length ONT MHC workflow intermediates.")
            let cohortCleanupDiagnostic = cohortAlignmentBuilder.cleanupTemporaryWorkDirectory(
                for: cohortAlignmentResult
            )
            if let cohortCleanupDiagnostic {
                cleanupWarnings.append(cleanupWarning(cohortCleanupDiagnostic))
            } else {
                do {
                    if FileManager.default.fileExists(atPath: cohortWorkDirectory.path),
                       try FileManager.default.contentsOfDirectory(atPath: cohortWorkDirectory.path).isEmpty {
                        try postPublicationWorkDirectoryCleaner.removeWorkDirectory(at: cohortWorkDirectory)
                    }
                } catch {
                    cleanupWarnings.append(FullLengthONTMHCGenotypingCleanupWarning(
                        kind: .cohortAlignmentWorkDirectory,
                        path: cohortWorkDirectory.standardizedFileURL.path,
                        error: cleanupErrorDescription(error),
                        publishedArtifactsRemainValid: true
                    ))
                }
            }
            do {
                try removeGeneratedWorkflowIntermediates(workDirectory)
            } catch {
                cleanupWarnings.append(FullLengthONTMHCGenotypingCleanupWarning(
                    kind: .workflowIntermediates,
                    path: workDirectory.standardizedFileURL.path,
                    error: cleanupErrorDescription(error),
                    publishedArtifactsRemainValid: true
                ))
            }
        }

        progress.emit(1.0, "Full-length ONT MHC genotyping complete.")
        return FullLengthONTMHCGenotypingResult(
            outputDirectory: request.outputDirectory,
            reportCSVURL: request.reportCSVURL,
            sampleSummaryCSVURL: request.sampleSummaryCSVURL,
            statsJSONURL: request.statsJSONURL,
            workbookURL: request.currentWorkbookURL,
            primaryWorkbookURL: request.workbookURL,
            haplotypeAnalysisURL: haplotypeAnalysis == nil ? nil : request.haplotypeAnalysisURL,
            unmatchedClustersFASTAURL: request.unmatchedClustersFASTAURL,
            deduplicatedUnmatchedClustersFASTAURL: request.deduplicatedUnmatchedClustersFASTAURL,
            cdnaClustersFASTAURL: request.cdnaClustersFASTAURL,
            provenanceURL: request.provenanceURL,
            referenceFASTAURL: referenceFASTAURL,
            genotypingEvidenceBAMURL: cohortAlignmentResult.bamURL,
            genotypingEvidenceBAIURL: cohortAlignmentResult.baiURL,
            cleanupWarnings: cleanupWarnings
        )
    }

    private func validateInputs(_ request: FullLengthONTMHCGenotypingRunRequest) throws {
        let paths = request.inputFASTQURLs + [
            request.referenceSourceURL,
        ] + [
            request.orientReferenceURL,
            request.forwardPrimerURL,
            request.reversePrimerURL,
        ].compactMap { $0 }
        for url in paths {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw FullLengthONTMHCGenotypingError.missingInput(url.path)
            }
        }
        guard !request.inputFASTQURLs.isEmpty else {
            throw FullLengthONTMHCGenotypingError.invalidFASTQ("No FASTQ bundles selected")
        }
    }

    private func resolveMHCReferenceFASTA(_ sourceURL: URL) throws -> URL {
        if MHCAmpliconReferenceBundle.isBundleURL(sourceURL),
           let fastaURL = MHCAmpliconReferenceBundle.referenceFASTAURL(in: sourceURL) {
            return fastaURL.standardizedFileURL
        }
        guard let fastaURL = SequenceInputResolver.resolvePrimarySequenceURL(for: sourceURL),
              (SequenceInputResolver.inputSequenceFormat(for: sourceURL) ?? SequenceFormat.from(url: fastaURL)) == .fasta else {
            throw FullLengthONTMHCGenotypingError.invalidReference(sourceURL.path)
        }
        return fastaURL.standardizedFileURL
    }

    private func materializeFASTQ(
        inputURL: URL,
        sample: String,
        sampleDirectory: URL
    ) throws -> URL {
        let outputURL = sampleDirectory.appendingPathComponent("00-input.fastq")
        _ = sample
        return try FullLengthONTMHCFASTQMaterializer.materializePlainFASTQ(
            inputURL: inputURL,
            outputURL: outputURL
        )
    }

    private func stageSamples(
        request: FullLengthONTMHCGenotypingRunRequest,
        workDirectory: URL,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) throws -> [FullLengthONTMHCScheduledSample] {
        var sampleNameCounts: [String: Int] = [:]
        var stagedSamples: [FullLengthONTMHCScheduledSample] = []
        let totalCount = request.inputFASTQURLs.count
        for (index, inputURL) in request.inputFASTQURLs.enumerated() {
            let sampleBaseName = sampleName(for: inputURL, fallbackIndex: index)
            let sampleOccurrence = (sampleNameCounts[sampleBaseName] ?? 0) + 1
            sampleNameCounts[sampleBaseName] = sampleOccurrence
            let sample = sampleOccurrence == 1 ? sampleBaseName : "\(sampleBaseName)-\(sampleOccurrence)"
            progressHandler?(
                FullLengthONTMHCSampleScheduler.stagingProgress(
                    stagedSampleCount: index,
                    totalSampleCount: totalCount
                ),
                "Staging FASTQ \(index + 1)/\(totalCount): \(sample)."
            )
            let sampleDirectory = workDirectory.appendingPathComponent(sample, isDirectory: true)
            try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)
            let materializedFASTQ = try materializeFASTQ(
                inputURL: inputURL,
                sample: sample,
                sampleDirectory: sampleDirectory
            )
            let readCount = fastqReadCount(materializedFASTQ)
            stagedSamples.append(FullLengthONTMHCScheduledSample(
                originalIndex: index,
                inputURL: inputURL,
                sample: sample,
                sampleDirectory: sampleDirectory,
                materializedFASTQURL: materializedFASTQ,
                readCount: readCount
            ))
            progressHandler?(
                FullLengthONTMHCSampleScheduler.stagingProgress(
                    stagedSampleCount: index + 1,
                    totalSampleCount: totalCount
                ),
                "Staged \(index + 1)/\(totalCount): \(sample) (\(formattedReadCount(readCount)) reads)."
            )
        }
        return stagedSamples
    }

    private func processSample(
        _ scheduled: FullLengthONTMHCScheduledSample,
        processingRank: Int,
        request: FullLengthONTMHCGenotypingRunRequest,
        referenceFASTAURL: URL,
        execution: FullLengthONTMHCSampleExecutionConfiguration,
        progressFraction: Double,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> FullLengthONTMHCSampleResult {
        var steps: [FullLengthONTMHCProvenanceStep] = []
        let preparedFASTQ = try await prepareReadsForSavont(
            inputFASTQ: scheduled.materializedFASTQURL,
            sample: scheduled.sample,
            sampleDirectory: scheduled.sampleDirectory,
            request: request,
            execution: execution,
            steps: &steps
        )
        if request.reuseCompatibleCheckpoints,
           let checkpoint = try loadCompatibleSampleCheckpoint(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                request: request,
                referenceFASTAURL: referenceFASTAURL,
                execution: execution
           ) {
            progressHandler?(
                progressFraction,
                "Reused compatible full-length ONT MHC checkpoint for \(scheduled.sample)."
            )
            return checkpoint.result.rehydrated(
                originalIndex: scheduled.originalIndex,
                processingRank: processingRank,
                readCount: scheduled.readCount,
                prepSteps: steps,
                reuseStep: sampleCheckpointReuseStep(
                    checkpointURL: checkpoint.url,
                    result: checkpoint.result
                )
            )
        }
        let selectedClustering = try await selectSavontClusters(
            scheduled: scheduled,
            preparedFASTQ: preparedFASTQ,
            request: request,
            execution: execution,
            progressFraction: progressFraction,
            progressHandler: progressHandler,
            steps: &steps
        )
        let clustersFASTAURL = selectedClustering.clustersFASTAURL
        let clusterRecords = try FullLengthONTMHCClusterGenotyper.readFASTARecords(
            from: clustersFASTAURL
        )
        guard !clusterRecords.isEmpty else {
            let sampleSummary = FullLengthONTMHCSampleSummary(
                sample: scheduled.sample,
                totalInputReads: scheduled.readCount,
                clusterCount: 0,
                clusteredReads: 0,
                assignedReads: 0,
                unmatchedClusters: 0,
                cdnaClusters: 0,
                savontPreset: selectedClustering.preset.label,
                savontStatus: selectedClustering.handledSavontFailure
                    ? .handledSavontFailure
                    : .noCall,
                savontFallbackReason: selectedClustering.fallbackReason
            )
            let result = FullLengthONTMHCSampleResult(
                originalIndex: scheduled.originalIndex,
                processingRank: processingRank,
                sample: scheduled.sample,
                readCount: scheduled.readCount,
                clustersFASTAURL: clustersFASTAURL,
                clusterRecords: clusterRecords,
                genotypeRows: [],
                sampleSummary: sampleSummary,
                unmatchedClusters: [],
                cdnaMatchedClusters: [],
                closestMatches: [],
                steps: steps
            )
            return try saveSampleCheckpoint(
                result: result,
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                request: request,
                referenceFASTAURL: referenceFASTAURL,
                execution: execution
            )
        }

        let sampleSummary = FullLengthONTMHCSampleSummary(
            sample: scheduled.sample,
            totalInputReads: scheduled.readCount,
            clusterCount: clusterRecords.count,
            clusteredReads: clusterRecords.reduce(0) { $0 + $1.readCount },
            assignedReads: 0,
            unmatchedClusters: 0,
            cdnaClusters: 0,
            savontPreset: selectedClustering.preset.label,
            savontStatus: .noCall,
            savontFallbackReason: selectedClustering.fallbackReason
        )
        let result = FullLengthONTMHCSampleResult(
            originalIndex: scheduled.originalIndex,
            processingRank: processingRank,
            sample: scheduled.sample,
            readCount: scheduled.readCount,
            clustersFASTAURL: clustersFASTAURL,
            clusterRecords: clusterRecords,
            genotypeRows: [],
            sampleSummary: sampleSummary,
            unmatchedClusters: [],
            cdnaMatchedClusters: [],
            closestMatches: [],
            steps: steps
        )
        return try saveSampleCheckpoint(
            result: result,
            scheduled: scheduled,
            preparedFASTQ: preparedFASTQ,
            request: request,
            referenceFASTAURL: referenceFASTAURL,
            execution: execution
        )
    }

    private func loadCompatibleSampleCheckpoint(
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        referenceFASTAURL: URL,
        execution: FullLengthONTMHCSampleExecutionConfiguration
    ) throws -> (url: URL, result: FullLengthONTMHCSampleResult)? {
        let checkpointURL = sampleCheckpointURL(for: scheduled.sample, request: request)
        guard FileManager.default.fileExists(atPath: checkpointURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let checkpoint = try? decoder.decode(
            FullLengthONTMHCSampleCheckpoint.self,
            from: Data(contentsOf: checkpointURL)
        ) else { return nil }
        guard checkpoint.schemaVersion == FullLengthONTMHCSampleCheckpoint.schemaVersion,
              checkpoint.signature == (try sampleCheckpointSignature(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                request: request,
                referenceFASTAURL: referenceFASTAURL,
                execution: execution
              )),
              durableSampleCheckpointOutputsExist(for: checkpoint.result) else {
            return nil
        }
        return (checkpointURL, checkpoint.result)
    }

    private func genotypeSummariesFromFinalCohortBAM(
        orderedResults: [FullLengthONTMHCSampleResult],
        samText: String,
        referenceFASTAURL: URL,
        request: FullLengthONTMHCGenotypingRunRequest
    ) throws -> [String: FullLengthONTMHCClusterGenotypingSummary] {
        let knownSamples = Set(orderedResults.map(\.sample))
        var readGroupSamples: [String: String] = [:]
        var alignmentLinesBySample: [String: [String]] = [:]

        for rawLine in samText.split(whereSeparator: \.isNewline).map(String.init) {
            if rawLine.hasPrefix("@RG\t") {
                let tags = rawLine.split(separator: "\t").dropFirst().reduce(into: [String: String]()) {
                    values, field in
                    let parts = field.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2 else { return }
                    values[String(parts[0])] = String(parts[1])
                }
                guard let readGroupID = tags["ID"],
                      let sample = tags["SM"],
                      knownSamples.contains(sample) else {
                    throw FullLengthONTMHCGenotypingError.reportFailed(
                        "Final cohort BAM contains an invalid or unknown @RG sample declaration."
                    )
                }
                if let existing = readGroupSamples[readGroupID], existing != sample {
                    throw FullLengthONTMHCGenotypingError.reportFailed(
                        "Final cohort BAM reuses read group \(readGroupID) for multiple samples."
                    )
                }
                readGroupSamples[readGroupID] = sample
                continue
            }
            guard !rawLine.hasPrefix("@") else { continue }
            var fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 11 else { continue }
            guard let flag = Int(fields[1]) else { continue }
            if flag & 4 != 0 || fields[2] == "*" { continue }
            let namespacedTarget = fields[2]
            let targetParts = namespacedTarget.split(
                separator: "|",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard targetParts.count == 2 else {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Final cohort BAM target is not namespaced: \(namespacedTarget)."
                )
            }
            let targetSample = String(targetParts[0])
            let cluster = String(targetParts[1])
            guard knownSamples.contains(targetSample), !cluster.isEmpty else {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Final cohort BAM target references an unknown sample: \(namespacedTarget)."
                )
            }
            let readGroupIDs = fields.dropFirst(11).compactMap { field -> String? in
                guard field.hasPrefix("RG:Z:") else { return nil }
                return String(field.dropFirst(5))
            }
            guard readGroupIDs.count == 1,
                  let readGroupID = readGroupIDs.first,
                  let readGroupSample = readGroupSamples[readGroupID],
                  readGroupSample == targetSample else {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Final cohort BAM alignment has missing or inconsistent RG/sample evidence for \(namespacedTarget)."
                )
            }
            fields[2] = cluster
            alignmentLinesBySample[targetSample, default: []].append(fields.joined(separator: "\t"))
        }

        return try Dictionary(uniqueKeysWithValues: orderedResults.map { result in
            let summary = try FullLengthONTMHCClusterGenotyper.genotypeSummary(
                sampleID: result.sample,
                clustersFASTAURL: result.clustersFASTAURL,
                referenceFASTAURL: referenceFASTAURL,
                samText: alignmentLinesBySample[result.sample, default: []].joined(separator: "\n"),
                cdnaThreshold: request.cdnaThreshold,
                minUnmatchedReads: request.minUnmatchedReads
            )
            return (result.sample, summary)
        })
    }

    private func saveSampleCheckpoint(
        result: FullLengthONTMHCSampleResult,
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        referenceFASTAURL: URL,
        execution: FullLengthONTMHCSampleExecutionConfiguration
    ) throws -> FullLengthONTMHCSampleResult {
        guard request.keepIntermediates || request.reuseCompatibleCheckpoints else {
            return result
        }
        let checkpointURL = sampleCheckpointURL(for: scheduled.sample, request: request)
        try FileManager.default.createDirectory(
            at: checkpointURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let checkpoint = FullLengthONTMHCSampleCheckpoint(
            signature: try sampleCheckpointSignature(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                request: request,
                referenceFASTAURL: referenceFASTAURL,
                execution: execution
            ),
            result: result,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(checkpoint).write(to: checkpointURL, options: .atomic)
        return result
    }

    private func sampleCheckpointURL(
        for sample: String,
        request: FullLengthONTMHCGenotypingRunRequest
    ) -> URL {
        request.outputDirectory
            .appendingPathComponent(".full-length-ont-mhc", isDirectory: true)
            .appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent("samples", isDirectory: true)
            .appendingPathComponent("\(sample).json")
    }

    private func sampleCheckpointSignature(
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        referenceFASTAURL: URL,
        execution: FullLengthONTMHCSampleExecutionConfiguration
    ) throws -> FullLengthONTMHCSampleCheckpointSignature {
        try FullLengthONTMHCSampleCheckpointSignature(
            sample: scheduled.sample,
            sourceFASTQ: .fingerprint(url: scheduled.inputURL),
            preparedFASTQ: .fingerprint(url: preparedFASTQ),
            referenceFASTA: .fingerprint(url: referenceFASTAURL),
            orientReference: request.orientReferenceURL.map { try .fingerprint(url: $0) },
            forwardPrimer: request.forwardPrimerURL.map { try .fingerprint(url: $0) },
            reversePrimer: request.reversePrimerURL.map { try .fingerprint(url: $0) },
            minimumLength: request.minimumLength,
            maximumLength: request.maximumLength,
            savontQualityValueCutoff: request.savontQualityValueCutoff,
            savontMinimumClusterSize: request.savontMinimumClusterSize,
            minUnmatchedReads: request.minUnmatchedReads,
            cdnaThreshold: request.cdnaThreshold,
            workerThreads: execution.workerThreads,
            savontThreads: execution.savontThreads,
            savontToolVersion: FullLengthONTMHCGenotypingRunRequest.savontToolVersion,
            savontCondaEnvironment: FullLengthONTMHCGenotypingRunRequest.savontCondaEnvironment,
            savontPackageSpec: FullLengthONTMHCGenotypingRunRequest.savontPackageSpec
        )
    }

    private func durableSampleCheckpointOutputsExist(
        for result: FullLengthONTMHCSampleResult
    ) -> Bool {
        let urls = result.steps
            .flatMap(\.outputs)
            .filter { $0.path.contains("/samples/\(result.sample)/") }
        return !urls.isEmpty && urls.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func sampleCheckpointReuseStep(
        checkpointURL: URL,
        result: FullLengthONTMHCSampleResult
    ) -> FullLengthONTMHCProvenanceStep {
        let completedAt = Date()
        let outputs = result.steps
            .flatMap(\.outputs)
            .filter { $0.path.contains("/samples/\(result.sample)/") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return FullLengthONTMHCProvenanceStep(
            toolName: "lungfish full-length ONT MHC sample checkpoint reuse",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: [
                CLICommandIdentity.executableName,
                "fastq",
                "full-length-ont-mhc-genotype",
                "reuse-sample-checkpoint",
                result.sample,
                "--checkpoint",
                checkpointURL.path,
            ],
            inputs: [checkpointURL],
            outputs: outputs,
            exitStatus: 0,
            stderr: nil,
            startedAt: completedAt,
            completedAt: completedAt
        )
    }

    private func selectSavontClusters(
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        execution: FullLengthONTMHCSampleExecutionConfiguration,
        progressFraction: Double,
        progressHandler: (@Sendable (Double, String) -> Void)?,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) async throws -> FullLengthONTMHCSavontSelectedClusters {
        let strictPreset = FullLengthONTMHCSavontPreset.requested(for: request)
        do {
            let strictClustering = try await runSavontClustering(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                request: request,
                execution: execution,
                preset: strictPreset,
                progressFraction: progressFraction,
                progressHandler: progressHandler,
                steps: &steps
            )
            let strictRecords = try FullLengthONTMHCClusterGenotyper.readFASTARecords(
                from: strictClustering.normalizedFASTAURL
            )
            guard strictRecords.isEmpty,
                  shouldRunHiddenSavontNoCallFallback(for: request) else {
                return try materializeSelectedSavontClusters(
                    strictClustering,
                    scheduled: scheduled,
                    preparedFASTQ: preparedFASTQ,
                    fallbackReason: nil,
                    handledSavontFailure: false,
                    steps: &steps
                )
            }
            progressHandler?(
                progressFraction,
                "No strict Savont ASVs for \(scheduled.sample); retrying with hidden QV90/min cluster size 1 fallback."
            )
            return try await runHiddenSavontNoCallFallback(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                request: request,
                execution: execution,
                progressFraction: progressFraction,
                progressHandler: progressHandler,
                fallbackReason: "strict-no-clusters",
                steps: &steps
            )
        } catch let error as FullLengthONTMHCGenotypingError {
            guard case .processFailed(let tool, _, _) = error,
                  tool == "savont",
                  shouldRunHiddenSavontNoCallFallback(for: request) else {
                throw error
            }
            progressHandler?(
                progressFraction,
                "Strict Savont failed for \(scheduled.sample); retrying with hidden QV90/min cluster size 1 fallback."
            )
            return try await runHiddenSavontNoCallFallback(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                request: request,
                execution: execution,
                progressFraction: progressFraction,
                progressHandler: progressHandler,
                fallbackReason: "strict-savont-failure",
                steps: &steps
            )
        }
    }

    private func runHiddenSavontNoCallFallback(
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        execution: FullLengthONTMHCSampleExecutionConfiguration,
        progressFraction: Double,
        progressHandler: (@Sendable (Double, String) -> Void)?,
        fallbackReason: String,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) async throws -> FullLengthONTMHCSavontSelectedClusters {
        let fallbackPreset = FullLengthONTMHCSavontPreset.hiddenNoCallFallback
        do {
            let fallbackClustering = try await runSavontClustering(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                request: request,
                execution: execution,
                preset: fallbackPreset,
                progressFraction: progressFraction,
                progressHandler: progressHandler,
                steps: &steps
            )
            return try materializeSelectedSavontClusters(
                fallbackClustering,
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                fallbackReason: fallbackReason,
                handledSavontFailure: false,
                steps: &steps
            )
        } catch FullLengthONTMHCGenotypingError.processFailed(let tool, _, let stderr) where tool == "savont" {
            progressHandler?(
                progressFraction,
                "Savont fallback failed for \(scheduled.sample); recording sample as a no-call."
            )
            return try writeHandledSavontFailureNoCall(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                preset: fallbackPreset,
                fallbackReason: fallbackReason,
                stderr: stderr,
                steps: &steps
            )
        }
    }

    private func shouldRunHiddenSavontNoCallFallback(for request: FullLengthONTMHCGenotypingRunRequest) -> Bool {
        request.savontQualityValueCutoff == FullLengthONTMHCGenotypingRunRequest.defaultSavontQualityValueCutoff
            && request.savontMinimumClusterSize == FullLengthONTMHCGenotypingRunRequest.defaultSavontMinimumClusterSize
    }

    private func runSavontClustering(
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        execution: FullLengthONTMHCSampleExecutionConfiguration,
        preset: FullLengthONTMHCSavontPreset,
        progressFraction: Double,
        progressHandler: (@Sendable (Double, String) -> Void)?,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) async throws -> FullLengthONTMHCSavontClusteringResult {
        let sampleOutputDirectory = request.outputDirectory
            .appendingPathComponent("samples", isDirectory: true)
            .appendingPathComponent(scheduled.sample, isDirectory: true)
            .appendingPathComponent("savont", isDirectory: true)
        let presetOutputDirectory = sampleOutputDirectory.appendingPathComponent(preset.directoryName, isDirectory: true)
        let rawOutputDirectory = presetOutputDirectory.appendingPathComponent("raw", isDirectory: true)
        if FileManager.default.fileExists(atPath: rawOutputDirectory.path) {
            try FileManager.default.removeItem(at: rawOutputDirectory)
        }
        try FileManager.default.createDirectory(at: presetOutputDirectory, withIntermediateDirectories: true)
        let normalizedFASTAURL = presetOutputDirectory
            .appendingPathComponent("\(scheduled.sample).\(preset.directoryName).savont-clusters.fasta")

        let firstAttempt = try await runSavontClusteringAttempt(
            scheduled: scheduled,
            preparedFASTQ: preparedFASTQ,
            sampleOutputDirectory: sampleOutputDirectory,
            finalRawOutputDirectory: rawOutputDirectory,
            request: request,
            preset: preset,
            savontThreads: max(1, execution.savontThreads),
            singleStrand: false,
            attempt: 1
        )
        if firstAttempt.exitCode == 0 {
            try finishSavontClusteringAttempt(
                firstAttempt,
                normalizedFASTAURL: normalizedFASTAURL,
                preparedFASTQ: preparedFASTQ,
                steps: &steps
            )
            return FullLengthONTMHCSavontClusteringResult(
                preset: preset,
                normalizedFASTAURL: normalizedFASTAURL,
                completedAttempt: firstAttempt
            )
        }
        steps.append(savontProvenanceStep(
            for: firstAttempt,
            preparedFASTQ: preparedFASTQ,
            outputs: []
        ))

        let retryDecision = FullLengthONTMHCSavontRunSupport.retryDecision(
            exitCode: firstAttempt.exitCode,
            attemptedThreads: firstAttempt.savontThreads,
            attemptedSingleStrand: firstAttempt.savontSingleStrand,
            stderr: firstAttempt.stderr
        )
        switch retryDecision {
        case .singleThread, .singleStrand:
            let retryThreads: Int
            let retrySingleStrand: Bool
            let retryDetail: String
            switch retryDecision {
            case .singleThread:
                retryThreads = 1
                retrySingleStrand = firstAttempt.savontSingleStrand
                retryDetail = "using 1 Savont thread"
            case .singleStrand:
                retryThreads = firstAttempt.savontThreads
                retrySingleStrand = true
                retryDetail = "using Savont --single-strand"
            case .none:
                retryThreads = firstAttempt.savontThreads
                retrySingleStrand = firstAttempt.savontSingleStrand
                retryDetail = "retrying"
            case .emptyClusters:
                retryThreads = firstAttempt.savontThreads
                retrySingleStrand = firstAttempt.savontSingleStrand
                retryDetail = "continuing with empty clusters"
            }
            progressHandler?(
                progressFraction,
                "Retrying \(scheduled.sample) after Savont exited with status \(firstAttempt.exitCode); \(retryDetail)."
            )
            let retryAttempt = try await runSavontClusteringAttempt(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                sampleOutputDirectory: sampleOutputDirectory,
                finalRawOutputDirectory: rawOutputDirectory,
                request: request,
                preset: preset,
                savontThreads: retryThreads,
                singleStrand: retrySingleStrand,
                attempt: 2
            )
            if retryAttempt.exitCode == 0 {
                try finishSavontClusteringAttempt(
                    retryAttempt,
                    normalizedFASTAURL: normalizedFASTAURL,
                    preparedFASTQ: preparedFASTQ,
                    steps: &steps
                )
                return FullLengthONTMHCSavontClusteringResult(
                    preset: preset,
                    normalizedFASTAURL: normalizedFASTAURL,
                    completedAttempt: retryAttempt
                )
            }
            steps.append(savontProvenanceStep(
                for: retryAttempt,
                preparedFASTQ: preparedFASTQ,
                outputs: []
            ))
            if FullLengthONTMHCSavontRunSupport.isLowCoverageNoClusterFailure(
                exitCode: retryAttempt.exitCode,
                attemptedSingleStrand: retryAttempt.savontSingleStrand,
                stderr: retryAttempt.stderr
            ) {
                try writeEmptySavontClusters(
                    normalizedFASTAURL: normalizedFASTAURL,
                    sample: scheduled.sample,
                    preparedFASTQ: preparedFASTQ,
                    stderr: retryAttempt.stderr,
                    steps: &steps
                )
                progressHandler?(
                    progressFraction,
                    "No Savont ASVs for \(scheduled.sample) after single-strand retry; continuing with empty cluster set."
                )
                return FullLengthONTMHCSavontClusteringResult(
                    preset: preset,
                    normalizedFASTAURL: normalizedFASTAURL,
                    completedAttempt: nil
                )
            }
            throw FullLengthONTMHCGenotypingError.processFailed(
                tool: "savont",
                status: retryAttempt.exitCode,
                stderr: retryAttempt.stderr
            )
        case .emptyClusters:
            try writeEmptySavontClusters(
                normalizedFASTAURL: normalizedFASTAURL,
                sample: scheduled.sample,
                preparedFASTQ: preparedFASTQ,
                stderr: firstAttempt.stderr,
                steps: &steps
            )
            progressHandler?(
                progressFraction,
                "No Savont ASVs for \(scheduled.sample); continuing with empty cluster set."
            )
            return FullLengthONTMHCSavontClusteringResult(
                preset: preset,
                normalizedFASTAURL: normalizedFASTAURL,
                completedAttempt: nil
            )
        case .none:
            break
        }

        throw FullLengthONTMHCGenotypingError.processFailed(
            tool: "savont",
            status: firstAttempt.exitCode,
            stderr: firstAttempt.stderr
        )
    }

    private func materializeSelectedSavontClusters(
        _ clustering: FullLengthONTMHCSavontClusteringResult,
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        fallbackReason: String?,
        handledSavontFailure: Bool,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) throws -> FullLengthONTMHCSavontSelectedClusters {
        let sampleOutputDirectory = clustering.normalizedFASTAURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let selectedClustersFASTAURL = sampleOutputDirectory
            .appendingPathComponent("\(scheduled.sample).savont-clusters.fasta")
        if FileManager.default.fileExists(atPath: selectedClustersFASTAURL.path) {
            try FileManager.default.removeItem(at: selectedClustersFASTAURL)
        }
        try FileManager.default.copyItem(at: clustering.normalizedFASTAURL, to: selectedClustersFASTAURL)

        var inputs = [clustering.normalizedFASTAURL]
        var outputs = [selectedClustersFASTAURL]
        let selectedRawOutputDirectory = sampleOutputDirectory.appendingPathComponent("raw", isDirectory: true)
        if let completedAttempt = clustering.completedAttempt {
            try FullLengthONTMHCSavontRunSupport.materializeCompletedRawOutput(
                from: completedAttempt.plan.finalRawOutputDirectory,
                to: selectedRawOutputDirectory
            )
            inputs += try retainedSavontOutputURLs(in: completedAttempt.plan.finalRawOutputDirectory)
            outputs += try retainedSavontOutputURLs(in: selectedRawOutputDirectory)
        } else if FileManager.default.fileExists(atPath: selectedRawOutputDirectory.path) {
            try FileManager.default.removeItem(at: selectedRawOutputDirectory)
        }

        let completedAt = Date()
        steps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish select Savont preset",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: [
                CLICommandIdentity.executableName,
                "fastq",
                "full-length-ont-mhc-genotype",
                "select-savont-preset",
                scheduled.sample,
                "--savont-preset",
                clustering.preset.label,
            ],
            inputs: inputs,
            outputs: outputs,
            exitStatus: 0,
            stderr: fallbackReason,
            startedAt: completedAt,
            completedAt: completedAt
        ))

        return FullLengthONTMHCSavontSelectedClusters(
            preset: clustering.preset,
            clustersFASTAURL: selectedClustersFASTAURL,
            fallbackReason: fallbackReason,
            handledSavontFailure: handledSavontFailure
        )
    }

    private func writeHandledSavontFailureNoCall(
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        preset: FullLengthONTMHCSavontPreset,
        fallbackReason: String,
        stderr: String,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) throws -> FullLengthONTMHCSavontSelectedClusters {
        let sampleOutputDirectory = scheduled.sampleDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("samples", isDirectory: true)
            .appendingPathComponent(scheduled.sample, isDirectory: true)
            .appendingPathComponent("savont", isDirectory: true)
        try FileManager.default.createDirectory(at: sampleOutputDirectory, withIntermediateDirectories: true)
        let selectedClustersFASTAURL = sampleOutputDirectory
            .appendingPathComponent("\(scheduled.sample).savont-clusters.fasta")
        let selectedRawOutputDirectory = sampleOutputDirectory.appendingPathComponent("raw", isDirectory: true)
        if FileManager.default.fileExists(atPath: selectedRawOutputDirectory.path) {
            try FileManager.default.removeItem(at: selectedRawOutputDirectory)
        }
        try Data().write(to: selectedClustersFASTAURL, options: .atomic)
        let completedAt = Date()
        steps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish handled Savont failure",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: [
                CLICommandIdentity.executableName,
                "fastq",
                "full-length-ont-mhc-genotype",
                "handled-savont-failure",
                scheduled.sample,
                "--savont-preset",
                preset.label,
            ],
            inputs: [preparedFASTQ],
            outputs: [selectedClustersFASTAURL],
            exitStatus: 0,
            stderr: stderr,
            startedAt: completedAt,
            completedAt: completedAt
        ))
        return FullLengthONTMHCSavontSelectedClusters(
            preset: preset,
            clustersFASTAURL: selectedClustersFASTAURL,
            fallbackReason: fallbackReason,
            handledSavontFailure: true
        )
    }

    private func runSavontClusteringAttempt(
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        sampleOutputDirectory: URL,
        finalRawOutputDirectory: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        preset: FullLengthONTMHCSavontPreset,
        savontThreads: Int,
        singleStrand: Bool,
        attempt: Int
    ) async throws -> FullLengthONTMHCSavontAttemptResult {
        let plan = FullLengthONTMHCSavontRunSupport.makePlan(
            sample: scheduled.sample,
            finalRawOutputDirectory: finalRawOutputDirectory,
            attempt: attempt
        )
        try FileManager.default.createDirectory(at: plan.scratchRootDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plan.scratchRootDirectory) }
        var arguments = [
            "asv",
            preparedFASTQ.path,
            "-o", plan.scratchRawOutputDirectory.path,
            "-t", String(max(1, savontThreads)),
            "--min-read-length", String(request.minimumLength),
            "--max-read-length", String(request.maximumLength),
            "--quality-value-cutoff", String(preset.qualityValueCutoff),
            "--min-cluster-size", String(preset.minimumClusterSize),
        ]
        if singleStrand {
            arguments.append("--single-strand")
        }
        let startedAt = Date()
        let result = try await condaManager.runTool(
            name: "savont",
            arguments: arguments,
            environment: FullLengthONTMHCGenotypingRunRequest.savontCondaEnvironment,
            workingDirectory: sampleOutputDirectory,
            timeout: 7_200
        )
        if result.exitCode == 0 {
            try FullLengthONTMHCSavontRunSupport.materializeCompletedRawOutput(
                from: plan.scratchRawOutputDirectory,
                to: plan.finalRawOutputDirectory
            )
        }
        return FullLengthONTMHCSavontAttemptResult(
            plan: plan,
            savontThreads: max(1, savontThreads),
            savontSingleStrand: singleStrand,
            arguments: arguments,
            stderr: result.stderr,
            exitCode: result.exitCode,
            startedAt: startedAt,
            completedAt: Date()
        )
    }

    private func finishSavontClusteringAttempt(
        _ attempt: FullLengthONTMHCSavontAttemptResult,
        normalizedFASTAURL: URL,
        preparedFASTQ: URL,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) throws {
        try FullLengthONTMHCSavontClusterNormalizer.normalize(
            savontFinalASVFASTAURL: attempt.plan.finalASVFASTAURL,
            outputFASTAURL: normalizedFASTAURL
        )
        steps.append(savontProvenanceStep(
            for: attempt,
            preparedFASTQ: preparedFASTQ,
            outputs: try retainedSavontOutputURLs(for: attempt) + [normalizedFASTAURL]
        ))
    }

    private func retainedSavontOutputURLs(for attempt: FullLengthONTMHCSavontAttemptResult) throws -> [URL] {
        try retainedSavontOutputURLs(in: attempt.plan.finalRawOutputDirectory)
    }

    private func retainedSavontOutputURLs(in rawOutputDirectory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let logs = try fileManager.contentsOfDirectory(
            at: rawOutputDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "log" }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return [rawOutputDirectory.appendingPathComponent("final_asvs.fasta")] + logs
    }

    private func savontProvenanceStep(
        for attempt: FullLengthONTMHCSavontAttemptResult,
        preparedFASTQ: URL,
        outputs: [URL]
    ) -> FullLengthONTMHCProvenanceStep {
        FullLengthONTMHCProvenanceStep(
            toolName: "savont",
            toolVersion: FullLengthONTMHCGenotypingRunRequest.savontToolVersion,
            argv: ["savont"] + attempt.arguments,
            inputs: [preparedFASTQ],
            outputs: outputs,
            exitStatus: attempt.exitCode,
            stderr: attempt.stderr,
            startedAt: attempt.startedAt,
            completedAt: attempt.completedAt
        )
    }

    private func writeEmptySavontClusters(
        normalizedFASTAURL: URL,
        sample: String,
        preparedFASTQ: URL,
        stderr: String,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) throws {
        try Data().write(to: normalizedFASTAURL, options: .atomic)
        let completedAt = Date()
        steps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish empty Savont clusters",
            toolVersion: FullLengthONTMHCGenotypingRunRequest.savontToolVersion,
            argv: [
                CLICommandIdentity.executableName,
                "fastq",
                "full-length-ont-mhc-genotype",
                "empty-savont-clusters",
                sample,
            ],
            inputs: [preparedFASTQ],
            outputs: [normalizedFASTAURL],
            exitStatus: 0,
            stderr: stderr,
            startedAt: completedAt,
            completedAt: completedAt
        ))
    }

    private func prepareReadsForSavont(
        inputFASTQ: URL,
        sample: String,
        sampleDirectory: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        execution: FullLengthONTMHCSampleExecutionConfiguration,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) async throws -> URL {
        var currentFASTQ = inputFASTQ
        if let orientReferenceURL = request.orientReferenceURL {
            let output = sampleDirectory.appendingPathComponent("01-oriented.fastq")
            let args = [
                "--orient", currentFASTQ.path,
                "--db", orientReferenceURL.path,
                "--fastqout", output.path,
                "--threads", String(execution.workerThreads),
            ]
            try await runNativeTool(
                .vsearch,
                arguments: args,
                inputs: [currentFASTQ, orientReferenceURL],
                outputs: [output],
                workingDirectory: sampleDirectory,
                provenanceOutputs: [],
                steps: &steps
            )
            currentFASTQ = output
        }

        if let forwardPrimerURL = request.forwardPrimerURL {
            let output = sampleDirectory.appendingPathComponent("02-forward-trimmed.fastq")
            let args = [
                "in=\(currentFASTQ.path)",
                "out=\(output.path)",
                "ref=\(forwardPrimerURL.path)",
                "k=15",
                "mink=11",
                "hdist=1",
                "ktrim=l",
                "rcomp=t",
                "threads=1",
            ]
            try await runNativeTool(
                .bbduk,
                arguments: args,
                inputs: [currentFASTQ, forwardPrimerURL],
                outputs: [output],
                workingDirectory: sampleDirectory,
                provenanceOutputs: [],
                steps: &steps
            )
            currentFASTQ = output
        }

        if let reversePrimerURL = request.reversePrimerURL {
            let output = sampleDirectory.appendingPathComponent("03-reverse-trimmed.fastq")
            let args = [
                "in=\(currentFASTQ.path)",
                "out=\(output.path)",
                "ref=\(reversePrimerURL.path)",
                "k=15",
                "mink=11",
                "hdist=1",
                "ktrim=r",
                "rcomp=t",
                "threads=1",
            ]
            try await runNativeTool(
                .bbduk,
                arguments: args,
                inputs: [currentFASTQ, reversePrimerURL],
                outputs: [output],
                workingDirectory: sampleDirectory,
                provenanceOutputs: [],
                steps: &steps
            )
            currentFASTQ = output
        }

        let filtered = sampleDirectory.appendingPathComponent("04-length-filtered.fastq")
        try await runNativeTool(
            .reformat,
            arguments: [
                "in=\(currentFASTQ.path)",
                "out=\(filtered.path)",
                "minlength=\(request.minimumLength)",
                "maxlength=\(request.maximumLength)",
                "threads=1",
            ],
            inputs: [currentFASTQ],
            outputs: [filtered],
            workingDirectory: sampleDirectory,
            provenanceOutputs: [],
            steps: &steps
        )

        _ = sample
        return filtered
    }

    private func runNativeTool(
        _ tool: NativeTool,
        arguments: [String],
        inputs: [URL],
        outputs: [URL],
        workingDirectory: URL,
        provenanceOutputs: [URL]? = nil,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) async throws {
        let startedAt = Date()
        let result = try await nativeToolRunner.run(
            tool,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: 3_600
        )
        let completedAt = Date()
        steps.append(FullLengthONTMHCProvenanceStep(
            toolName: tool.executableName,
            toolVersion: await nativeToolRunner.getToolVersion(tool) ?? "unknown",
            argv: result.arguments.isEmpty ? [tool.executableName] + arguments : result.arguments,
            inputs: inputs,
            outputs: provenanceOutputs ?? outputs,
            exitStatus: result.exitCode,
            stderr: result.stderr,
            startedAt: startedAt,
            completedAt: completedAt
        ))
        guard result.isSuccess else {
            throw FullLengthONTMHCGenotypingError.processFailed(
                tool: tool.executableName,
                status: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    private func prepareBlastRescueReference(
        _ referenceFASTAURL: URL,
        rescueDirectory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: rescueDirectory, withIntermediateDirectories: true)
        let outputURL = rescueDirectory.appendingPathComponent("reference.fa")
        let records = try FullLengthONTMHCClusterGenotyper.readFASTARecords(from: referenceFASTAURL)
        try writeFASTARecords(records, to: outputURL)
        return outputURL
    }

    private func rescueUnmatchedMHCMatches(
        sample: String,
        records: [FullLengthONTMHCClusterFASTARecord],
        referenceFASTAURL: URL,
        sampleDirectory: URL,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) async throws -> [FullLengthONTMHCBlastRescueMatch] {
        guard !records.isEmpty else { return [] }
        let rescueDirectory = sampleDirectory.appendingPathComponent("blast-rescue", isDirectory: true)
        try FileManager.default.createDirectory(at: rescueDirectory, withIntermediateDirectories: true)
        let queryURL = rescueDirectory.appendingPathComponent("\(sample).unmatched-no-closest.fasta")
        let tsvURL = rescueDirectory.appendingPathComponent("\(sample).unmatched-blast-rescue.tsv")
        try writeFASTARecords(records, to: queryURL)
        let outfmt = [
            "6",
            "qseqid",
            "sseqid",
            "pident",
            "length",
            "mismatch",
            "gapopen",
            "qstart",
            "qend",
            "sstart",
            "send",
            "evalue",
            "bitscore",
            "qlen",
            "slen",
        ].joined(separator: " ")
        let arguments = [
            "-query", queryURL.path,
            "-subject", referenceFASTAURL.path,
            "-task", "blastn",
            "-dust", "no",
            "-evalue", String(FullLengthONTMHCBlastRescueMatch.maximumEValue),
            "-outfmt", outfmt,
        ]
        let startedAt = Date()
        let result = try await nativeToolRunner.run(
            .blastn,
            arguments: arguments,
            workingDirectory: rescueDirectory,
            timeout: 3_600
        )
        try result.stdout.write(to: tsvURL, atomically: true, encoding: .utf8)
        let completedAt = Date()
        steps.append(FullLengthONTMHCProvenanceStep(
            toolName: "blastn",
            toolVersion: await nativeToolRunner.getToolVersion(.blastn) ?? "unknown",
            argv: result.arguments.isEmpty ? ["blastn"] + arguments : result.arguments,
            inputs: [queryURL, referenceFASTAURL],
            outputs: [tsvURL],
            exitStatus: result.exitCode,
            stderr: result.stderr,
            startedAt: startedAt,
            completedAt: completedAt
        ))
        guard result.exitCode == 0 else {
            throw FullLengthONTMHCGenotypingError.processFailed(
                tool: "blastn",
                status: result.exitCode,
                stderr: result.stderr
            )
        }
        let tsv = try String(contentsOf: tsvURL, encoding: .utf8)
        return try FullLengthONTMHCBlastRescueParser.acceptedMatches(
            sample: sample,
            recordsByCluster: Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0) }),
            tsv: tsv
        )
    }

    private func writeFASTARecords(
        _ records: [FullLengthONTMHCClusterFASTARecord],
        to url: URL
    ) throws {
        var text = ""
        for record in records {
            text += ">\(record.name)\n"
            var sequence = record.sequence
            while !sequence.isEmpty {
                let chunk = String(sequence.prefix(80))
                text += chunk + "\n"
                sequence.removeFirst(chunk.count)
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func sampleClusterKey(sample: String, cluster: String) -> String {
        "\(sample)\u{0}\(cluster)"
    }

    private func writeClusterGenotypeTSV(
        _ rows: [FullLengthONTMHCClusterGenotypeRow],
        to url: URL
    ) throws {
        var lines = ["sample\tcluster\tcluster_reads\tallele\tallele_length\taligned_bases\tscore"]
        lines += rows.map {
            [
                $0.sample,
                $0.cluster,
                String($0.clusterReads),
                $0.allele,
                String($0.alleleLength),
                String($0.alignedBases),
                String($0.score),
            ].joined(separator: "\t")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeReportCSV(
        _ rows: [FullLengthONTMHCReportRow],
        to url: URL
    ) throws {
        var lines = [
            [
                "sample",
                "genotype",
                "passed_alignments",
                "passed_unique_reads",
                "sample_total_reads",
                "sample_unique_retained_reads",
                "sample_unique_retained_percent",
                "overall_input_reads",
                "overall_unique_retained_reads",
                "overall_unique_retained_percent",
            ].joined(separator: ","),
        ]
        lines += rows.map {
            [
                csvEscape($0.sample),
                csvEscape($0.genotype),
                String($0.passedAlignments),
                String($0.passedUniqueReads),
                optionalString($0.sampleTotalReads),
                String($0.sampleUniqueRetainedReads),
                optionalString($0.sampleUniqueRetainedPercent),
                String($0.overallInputReads),
                String($0.overallUniqueRetainedReads),
                optionalString($0.overallUniqueRetainedPercent),
            ].joined(separator: ",")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeSampleSummaryCSV(
        _ rows: [FullLengthONTMHCSampleSummary],
        to url: URL
    ) throws {
        let header = [
            "sample",
            "passed_alignments",
            "passed_unique_reads",
            "sample_total_reads",
            "sample_unique_retained_reads",
            "sample_unique_retained_percent",
            "cluster_count",
            "clustered_reads",
            "unmatched_clusters",
            "cdna_clusters",
            "savont_preset",
            "savont_status",
            "savont_fallback_reason",
        ].joined(separator: ",")
        var lines = [header]
        lines += rows.sorted { $0.sample.localizedStandardCompare($1.sample) == .orderedAscending }.map { row in
            let percent = row.totalInputReads > 0
                ? Double(row.assignedReads) / Double(row.totalInputReads) * 100.0
                : nil
            return [
                csvEscape(row.sample),
                String(row.assignedReads),
                String(row.assignedReads),
                String(row.totalInputReads),
                String(row.assignedReads),
                optionalString(percent),
                String(row.clusterCount),
                String(row.clusteredReads),
                String(row.unmatchedClusters),
                String(row.cdnaClusters),
                csvEscape(row.savontPreset),
                csvEscape(row.savontStatus.rawValue),
                csvEscape(row.savontFallbackReason ?? ""),
            ].joined(separator: ",")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeStatsJSON(
        sampleSummaries: [FullLengthONTMHCSampleSummary],
        genotypeRows: [FullLengthONTMHCClusterGenotypeRow],
        to url: URL
    ) throws {
        let totalInput = sampleSummaries.reduce(0) { $0 + $1.totalInputReads }
        let assigned = genotypeRows.reduce(0) { $0 + $1.clusterReads }
        let clustered = sampleSummaries.reduce(0) { $0 + $1.clusteredReads }
        let object: [String: Any] = [
            "totalInputReads": totalInput,
            "totalAlignments": assigned,
            "passedAlignments": assigned,
            "retainedUniqueReads": assigned,
            "retainedUniquePercentOfTotalReads": totalInput > 0 ? Double(assigned) / Double(totalInput) * 100.0 : 0.0,
            "assignedUniqueRetainedReads": assigned,
            "unassignedUniqueRetainedReads": max(0, clustered - assigned),
            "clusteredReads": clustered,
            "clusterCount": sampleSummaries.reduce(0) { $0 + $1.clusterCount },
            "unmatchedClusters": sampleSummaries.reduce(0) { $0 + $1.unmatchedClusters },
            "cdnaClusters": sampleSummaries.reduce(0) { $0 + $1.cdnaClusters },
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func writeWorkbook(
        request: FullLengthONTMHCGenotypingRunRequest,
        reportRows: [FullLengthONTMHCReportRow],
        sampleSummaries: [FullLengthONTMHCSampleSummary],
        genotypeRows: [FullLengthONTMHCClusterGenotypeRow],
        unmatchedClosestMatchRows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow],
        orderedAlleles: [String],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?,
        to url: URL
    ) throws {
        try FullLengthONTMHCXLSXPackageWriter.write(
            sheets: [
                .init(
                    name: "Interpretation Guide",
                    rows: interpretationWorkbookRows(
                        request: request,
                        sampleSummaries: sampleSummaries,
                        haplotypeAnalysis: haplotypeAnalysis
                    )
                ),
                .init(name: "Samples", rows: sampleWorkbookRows(sampleSummaries)),
                .init(name: "Genotypes", rows: genotypeWorkbookRows(genotypeRows)),
                .init(
                    name: "Genotyping pivot",
                    rows: FullLengthONTMHCPivotWorkbookBuilder.buildRows(
                        reportRows: reportRows,
                        samples: sampleSummaries.map {
                            let retainedPercent = $0.totalInputReads > 0
                                ? Double($0.assignedReads) / Double($0.totalInputReads) * 100.0
                                : nil
                            return FullLengthONTMHCPivotSample(
                                sample: $0.sample,
                                mappedReadCount: $0.assignedReads,
                                totalReadCount: $0.totalInputReads,
                                retainedPercent: retainedPercent
                            )
                        },
                        orderedAlleles: orderedAlleles,
                        haplotypeAnalysis: haplotypeAnalysis
                    )
                ),
                .init(
                    name: "Unmatched Clusters",
                    rows: FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder.detailRows(unmatchedClosestMatchRows)
                ),
                .init(
                    name: "Unmatched Shared Pivot",
                    rows: FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder.pivotRows(
                        unmatchedClosestMatchRows,
                        sampleOrder: sampleSummaries.map(\.sample)
                    )
                ),
                .init(
                    name: "MHC-like Unmatched Clusters",
                    rows: FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder.mhcLikeDetailRows(
                        unmatchedClosestMatchRows
                    )
                ),
                .init(
                    name: "MHC-like Unmatched Pivot",
                    rows: FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder.mhcLikePivotRows(
                        unmatchedClosestMatchRows,
                        sampleOrder: sampleSummaries.map(\.sample)
                    )
                ),
                .init(
                    name: "Unified Genotype Pivot",
                    rows: FullLengthONTMHCUnifiedPivotWorkbookBuilder.buildRows(
                        reportRows: reportRows,
                        unmatchedRows: unmatchedClosestMatchRows,
                        sampleOrder: sampleSummaries.map(\.sample)
                    )
                ),
            ],
            to: url
        )
    }

    private func interpretationWorkbookRows(
        request: FullLengthONTMHCGenotypingRunRequest,
        sampleSummaries: [FullLengthONTMHCSampleSummary],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?
    ) -> [[String]] {
        [
            ["Field", "Interpretation"],
            ["Workflow", "Full-length ONT MHC genotyping"],
            ["Read preparation", "Input reads are materialized as plain FASTQ, optionally oriented and primer-trimmed, length-filtered, then clustered into Savont ASVs."],
            ["Savont settings", "quality_value_cutoff=\(request.savontQualityValueCutoff); min_cluster_size=\(request.savontMinimumClusterSize); min_length=\(request.minimumLength); max_length=\(request.maximumLength)"],
            ["Sample presets", sampleSummaries.map { "\($0.sample): \($0.savontPreset) (\($0.savontStatus.rawValue))" }.joined(separator: "; ")],
            ["Genotype call rule", "Exact genotype calls require zero SNP differences and zero indel bases."],
            ["Score formula", "score = aligned_bases - (100 * snp_differences) - (10 * indel_bases)"],
            ["Score interpretation", "Higher scores are better. Exact calls have score equal to aligned_bases; each SNP subtracts 100 and each indel base subtracts 10."],
            ["Unmatched closest match", "For unmatched clusters, closest-match fields describe the best non-exact mapped reference hit when one exists."],
            ["Unmatched normalization", "Unmatched cluster sequences are trimmed to their best minimap2 target interval and reverse-complemented when the best hit maps to the reverse strand before unmatched_sequence_id assignment."],
            ["Blank closest-match fields", "Blank closest-match fields mean the unmatched cluster had no mapped SAM hit."],
            ["MHC-like unmatched rescue", "Blank unmatched clusters are compared to the resolved MHC reference FASTA with local blastn; accepted rescue hits use match_source=local-blast-rescue."],
            ["MHC-like rescue thresholds", "query_coverage>=\(oneDecimalString(FullLengthONTMHCBlastRescueMatch.minimumQueryCoverage))%; aligned_bases>=\(FullLengthONTMHCBlastRescueMatch.minimumAlignedBases); percent_identity>=\(oneDecimalString(FullLengthONTMHCBlastRescueMatch.minimumPercentIdentity))%; evalue<=\(FullLengthONTMHCBlastRescueMatch.maximumEValue)"],
            ["Unmatched sequence ID", "A deterministic UUID derived from the normalized unmatched sequence links detail rows to the shared pivot."],
            ["Haplotype assay", haplotypeAnalysis?.assayID ?? request.haplotypeAssayID ?? ""],
            ["Haplotype definition", haplotypeAnalysis?.definitionSetID ?? request.haplotypeDefinitionSetID ?? ""],
            ["Haplotype filtering scope", "Haplotype thresholds affect haplotype assignment only; genotype and unmatched worksheets retain observed cluster evidence."],
            ["", ""],
            ["Samples worksheet", "One row per sample with input reads, retained/assigned read summaries, unmatched counts, cDNA counts, and Savont status."],
            ["Genotypes worksheet", "Cluster-level exact genotype evidence. Each row is one sample cluster assigned to one exact reference genotype."],
            ["Genotyping pivot worksheet", "Sample-by-genotype pivot formatted for review of full-length genotyping calls and haplotype summaries."],
            ["Unmatched Clusters worksheet", "One row per unmatched cluster with sequence, read support, deterministic unmatched_sequence_id, and closest-match metadata when available."],
            ["Unmatched Shared Pivot worksheet", "One row per unique unmatched sequence with occurrence count, total supporting reads, closest-match summary, and per-sample read counts."],
            ["MHC-like Unmatched Clusters worksheet", "One row per unmatched cluster with either genotyping SAM closest-match evidence or accepted local BLAST rescue evidence."],
            ["MHC-like Unmatched Pivot worksheet", "One row per unique MHC-like unmatched sequence with occurrence count, total supporting reads, best evidence summary, and per-sample read counts."],
            ["Unified Genotype Pivot worksheet", "One sample-by-call pivot combining exact reference genotypes and normalized novel MHC-like unmatched sequences."],
        ]
    }

    private func writeHaplotypeAnalysisIfRequested(
        request: FullLengthONTMHCGenotypingRunRequest,
        supportDirectory: URL,
        generatedAt: Date
    ) throws -> GenotypeHaplotypeAnalysis? {
        guard let definitionSetID = request.haplotypeDefinitionSetID else {
            return nil
        }
        guard let definitionSet = try resolveHaplotypeDefinitionSet(for: request) else {
            throw FullLengthONTMHCGenotypingError.invalidHaplotypeDefinition(definitionSetID)
        }
        try writeHaplotypeDefinitionSnapshot(definitionSet, supportDirectory: supportDirectory)

        let manifest = ONTGenotypeResultBundleManifest(
            kind: "full-length-ont-mhc-genotype",
            outputName: request.outputName,
            analysisName: request.outputName,
            primaryWorkbookPath: relativePath(from: request.outputDirectory, to: request.workbookURL),
            longSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.reportCSVURL),
            sampleSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.sampleSummaryCSVURL),
            statsJSONPath: relativePath(from: request.outputDirectory, to: request.statsJSONURL),
            provenancePath: relativePath(from: request.outputDirectory, to: request.provenanceURL),
            haplotypeDefinitionSetID: definitionSetID,
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
        try encoder.encode(analysis).write(to: request.haplotypeAnalysisURL, options: .atomic)
        return analysis
    }

    private func resolveHaplotypeDefinitionSet(
        for request: FullLengthONTMHCGenotypingRunRequest
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
                throw FullLengthONTMHCGenotypingError.invalidHaplotypeDefinition(definitionSetID)
            }
            throw FullLengthONTMHCGenotypingError.ambiguousHaplotypeDefinition(definitionID: definitionSetID)
        }
        let registry = haplotypeDefinitionRegistry(for: request)
        if let assayID = request.haplotypeAssayID {
            guard registry.assay(id: assayID) != nil else {
                throw FullLengthONTMHCGenotypingError.invalidHaplotypeDefinitionForAssay(
                    definitionID: definitionSetID,
                    assayID: assayID
                )
            }
            guard let definitionSet = registry.definitionSet(id: definitionSetID, assayID: assayID) else {
                if registry.definitionSet(id: definitionSetID) == nil {
                    throw FullLengthONTMHCGenotypingError.invalidHaplotypeDefinition(definitionSetID)
                }
                throw FullLengthONTMHCGenotypingError.invalidHaplotypeDefinitionForAssay(
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
            throw FullLengthONTMHCGenotypingError.invalidHaplotypeDefinition(definitionSetID)
        }
        throw FullLengthONTMHCGenotypingError.ambiguousHaplotypeDefinition(definitionID: definitionSetID)
    }

    private func bundledHaplotypeDefinitionSet(
        for request: FullLengthONTMHCGenotypingRunRequest,
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
        for request: FullLengthONTMHCGenotypingRunRequest
    ) -> GenotypeHaplotypeDefinitionRegistry {
        haplotypeDefinitionLibrary(for: request).mergedRegistry()
    }

    private func haplotypeDefinitionLibrary(
        for request: FullLengthONTMHCGenotypingRunRequest
    ) -> HaplotypeDefinitionLibrary {
        HaplotypeDefinitionLibrary(projectRoot: request.projectURL)
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
        try encoder.encode(definitionSet).write(to: url, options: .atomic)
        return url
    }

    private func createInitialCurrentWorkbookCopy(
        for request: FullLengthONTMHCGenotypingRunRequest
    ) throws -> FullLengthONTMHCWorkbookCopyResult {
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
        let completedAt = Date()
        let revision = ONTGenotypeWorkbookRevision(
            id: "initial-current-copy",
            role: .initialCurrentCopy,
            path: relativePath(from: request.outputDirectory, to: destinationURL),
            label: "Initial editable workbook",
            sourceFilename: request.workbookURL.lastPathComponent,
            createdAt: ISO8601DateFormatter().string(from: completedAt),
            user: NSUserName(),
            predecessorPath: relativePath(from: request.outputDirectory, to: request.workbookURL),
            sha256: try ProvenanceFileHasher.sha256(of: destinationURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: destinationURL)),
            provenancePath: nil
        )
        let step = FullLengthONTMHCProvenanceStep(
            toolName: "lungfish genotype workbook initial-current-copy",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: request.argv + ["--create-current-workbook", destinationURL.path],
            inputs: [request.workbookURL],
            outputs: [destinationURL],
            exitStatus: 0,
            stderr: nil,
            startedAt: startedAt,
            completedAt: completedAt
        )
        return FullLengthONTMHCWorkbookCopyResult(revision: revision, step: step)
    }

    private func writeManifest(
        request: FullLengthONTMHCGenotypingRunRequest,
        workbookRevision: ONTGenotypeWorkbookRevision,
        evidenceArtifactPair: ONTMHCBAMArtifactPair,
        createdAt: Date
    ) throws {
        let resolvedHaplotypeDefinitionSet = try resolveHaplotypeDefinitionSet(for: request)
        let manifest = ONTGenotypeResultBundleManifest(
            kind: "full-length-ont-mhc-genotype",
            outputName: request.outputName,
            analysisName: request.outputName,
            primaryWorkbookPath: relativePath(from: request.outputDirectory, to: request.workbookURL),
            currentWorkbookPath: relativePath(from: request.outputDirectory, to: request.currentWorkbookURL),
            workbookRevisions: [workbookRevision],
            longSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.reportCSVURL),
            sampleSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.sampleSummaryCSVURL),
            statsJSONPath: relativePath(from: request.outputDirectory, to: request.statsJSONURL),
            provenancePath: relativePath(from: request.outputDirectory, to: request.provenanceURL),
            deduplicatedUnmatchedClustersFASTAPath: relativePath(
                from: request.outputDirectory,
                to: request.deduplicatedUnmatchedClustersFASTAURL
            ),
            haplotypeAnalysisPath: request.haplotypeDefinitionSetID == nil
                ? nil
                : relativePath(from: request.outputDirectory, to: request.haplotypeAnalysisURL),
            haplotypeDefinitionSetID: request.haplotypeDefinitionSetID,
            haplotypeAssayID: resolvedHaplotypeDefinitionSet?.assayID,
            createdAt: ISO8601DateFormatter().string(from: createdAt),
            mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest(
                schemaVersion: 1,
                genotypingEvidence: evidenceArtifactPair,
                reciprocalEvidence: nil,
                candidateJSON: nil,
                candidateFASTA: nil,
                unnameableJSON: nil,
                unnameableFASTA: nil
            )
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: request.outputDirectory)
    }

    private func validatedEvidenceArtifactPair(
        _ result: FullLengthONTMHCCohortAlignmentResult,
        bundleDirectoryURL: URL
    ) throws -> ONTMHCBAMArtifactPair {
        guard let bamDescriptor = result.finalArtifactDescriptors.first(where: { $0.role == .evidenceBAM }),
              let baiDescriptor = result.finalArtifactDescriptors.first(where: { $0.role == .evidenceBAI }),
              bamDescriptor.phase == .final,
              baiDescriptor.phase == .final,
              bamDescriptor.path == result.bamURL.standardizedFileURL.path,
              baiDescriptor.path == result.baiURL.standardizedFileURL.path else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Cohort alignment builder did not return final BAM/BAI descriptors."
            )
        }
        let observedBAM = try FullLengthONTMHCArtifactDescriptor(
            url: result.bamURL,
            role: .evidenceBAM,
            phase: .final
        )
        let observedBAI = try FullLengthONTMHCArtifactDescriptor(
            url: result.baiURL,
            role: .evidenceBAI,
            phase: .final
        )
        guard observedBAM == bamDescriptor, observedBAI == baiDescriptor,
              bamDescriptor.byteSize <= UInt64(Int64.max),
              baiDescriptor.byteSize <= UInt64(Int64.max) else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Published cohort BAM/BAI does not match its immutable builder descriptors."
            )
        }
        return ONTMHCBAMArtifactPair(
            bam: ONTMHCArtifactReference(
                path: relativePath(from: bundleDirectoryURL, to: result.bamURL),
                sha256: bamDescriptor.sha256,
                sizeBytes: Int64(bamDescriptor.byteSize)
            ),
            bai: ONTMHCArtifactReference(
                path: relativePath(from: bundleDirectoryURL, to: result.baiURL),
                sha256: baiDescriptor.sha256,
                sizeBytes: Int64(baiDescriptor.byteSize)
            )
        )
    }

    private func invalidatePublishedRunMetadata(_ request: FullLengthONTMHCGenotypingRunRequest) throws {
        try removePublishedRunMetadata(request)
    }

    private func removePublishedRunMetadata(_ request: FullLengthONTMHCGenotypingRunRequest) throws {
        for url in [request.manifestURL, request.provenanceURL]
            where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func writeProvenance(
        request: FullLengthONTMHCGenotypingRunRequest,
        referenceFASTAURL: URL,
        executionPlan: FullLengthONTMHCSampleExecutionPlan,
        stagedSamples: [FullLengthONTMHCScheduledSample],
        processingOrder: [FullLengthONTMHCScheduledSample],
        steps: [FullLengthONTMHCProvenanceStep],
        cohortAlignmentResult: FullLengthONTMHCCohortAlignmentResult,
        bamViewRecord: FullLengthONTMHCCohortAlignmentCommandRecord,
        startedAt: Date,
        completedAt: Date
    ) throws {
        let defaults: [String: ParameterValue] = [
            "threads": .integer(max(1, ProcessInfo.processInfo.activeProcessorCount)),
            "minimumLength": .integer(2_000),
            "maximumLength": .integer(4_000),
            "savontQualityValueCutoff": .integer(FullLengthONTMHCGenotypingRunRequest.defaultSavontQualityValueCutoff),
            "savontMinimumClusterSize": .integer(FullLengthONTMHCGenotypingRunRequest.defaultSavontMinimumClusterSize),
            "hiddenSavontNoCallFallback": .string("qv90-min1"),
            "savontCondaEnvironment": .string(FullLengthONTMHCGenotypingRunRequest.savontCondaEnvironment),
            "savontPackageSpec": .string(FullLengthONTMHCGenotypingRunRequest.savontPackageSpec),
            "savontToolVersion": .string(FullLengthONTMHCGenotypingRunRequest.savontToolVersion),
            "minUnmatchedReads": .integer(5),
            "cdnaThreshold": .integer(2_000),
            "mhcLikeBlastRescue": .string("enabled"),
            "mhcLikeBlastRescueMinimumQueryCoverage": .number(FullLengthONTMHCBlastRescueMatch.minimumQueryCoverage),
            "mhcLikeBlastRescueMinimumAlignedBases": .integer(FullLengthONTMHCBlastRescueMatch.minimumAlignedBases),
            "mhcLikeBlastRescueMinimumPercentIdentity": .number(FullLengthONTMHCBlastRescueMatch.minimumPercentIdentity),
            "mhcLikeBlastRescueMaximumEValue": .number(FullLengthONTMHCBlastRescueMatch.maximumEValue),
            "sampleJobs": .string("auto"),
            "savontThreadsPerSample": .string("auto"),
            "haplotypeDropoutSampleFraction": .string("disabled"),
            "haplotypeDropoutLocusFraction": .string("disabled"),
            "haplotypeDropoutLocusFractionOverrides": .dictionary([:]),
            "haplotypeDefinition": .string("disabled"),
            "keepIntermediates": .boolean(false),
            "reuseCompatibleCheckpoints": .boolean(false),
            "mhcMappingPreset": .string("splice"),
            "minimap2CondaEnvironment": .string("minimap2"),
            "samtoolsCondaEnvironment": .string("samtools"),
        ]
        let resolved: [String: ParameterValue] = [
            "threads": .integer(request.threads),
            "minimumLength": .integer(request.minimumLength),
            "maximumLength": .integer(request.maximumLength),
            "savontQualityValueCutoff": .integer(request.savontQualityValueCutoff),
            "savontMinimumClusterSize": .integer(request.savontMinimumClusterSize),
            "hiddenSavontNoCallFallback": shouldRunHiddenSavontNoCallFallback(for: request)
                ? .string(FullLengthONTMHCSavontPreset.hiddenNoCallFallback.label)
                : .string("disabled"),
            "savontCondaEnvironment": .string(FullLengthONTMHCGenotypingRunRequest.savontCondaEnvironment),
            "savontPackageSpec": .string(FullLengthONTMHCGenotypingRunRequest.savontPackageSpec),
            "savontToolVersion": .string(FullLengthONTMHCGenotypingRunRequest.savontToolVersion),
            "minUnmatchedReads": .integer(request.minUnmatchedReads),
            "cdnaThreshold": .integer(request.cdnaThreshold),
            "mhcLikeBlastRescue": .string("enabled"),
            "mhcLikeBlastRescueMinimumQueryCoverage": .number(FullLengthONTMHCBlastRescueMatch.minimumQueryCoverage),
            "mhcLikeBlastRescueMinimumAlignedBases": .integer(FullLengthONTMHCBlastRescueMatch.minimumAlignedBases),
            "mhcLikeBlastRescueMinimumPercentIdentity": .number(FullLengthONTMHCBlastRescueMatch.minimumPercentIdentity),
            "mhcLikeBlastRescueMaximumEValue": .number(FullLengthONTMHCBlastRescueMatch.maximumEValue),
            "sampleJobs": .integer(executionPlan.sampleJobs),
            "savontThreadsPerSample": .integer(executionPlan.savontThreadsPerSample),
            "workerThreadsPerSample": .integer(executionPlan.workerThreadsPerSample),
            "haplotypeDropoutSampleFraction": request.haplotypeDropoutSampleFraction
                .map(ParameterValue.number) ?? .string("disabled"),
            "haplotypeDropoutLocusFraction": request.haplotypeDropoutLocusFraction
                .map(ParameterValue.number) ?? .string("disabled"),
            "haplotypeDropoutLocusFractionOverrides": .dictionary(
                request.haplotypeDropoutLocusFractionOverrides.mapValues(ParameterValue.number)
            ),
            "haplotypeDefinition": request.haplotypeDefinitionSetID
                .map(ParameterValue.string) ?? .string("disabled"),
            "keepIntermediates": .boolean(request.keepIntermediates),
            "reuseCompatibleCheckpoints": .boolean(request.reuseCompatibleCheckpoints),
            "mhcMappingPreset": .string("splice"),
            "mhcCohortAlignmentThreads": .integer(request.threads),
            "minimap2CondaEnvironment": .string("minimap2"),
            "samtoolsCondaEnvironment": .string("samtools"),
        ]
        var explicit = resolved
        explicit["requestedSampleJobs"] = request.sampleJobs.map(ParameterValue.integer) ?? .string("auto")
        explicit["requestedSavontThreadsPerSample"] = request.savontThreadsPerSample.map(ParameterValue.integer) ?? .string("auto")
        explicit["inputFASTQs"] = .array(request.inputFASTQURLs.map(ParameterValue.file))
        explicit["reference"] = .file(request.referenceSourceURL)
        explicit["resolvedReferenceFASTA"] = .file(referenceFASTAURL)
        explicit["outputDirectory"] = .file(request.outputDirectory)
        explicit["outputName"] = .string(request.outputName)
        explicit["currentWorkbook"] = .file(request.currentWorkbookURL)
        explicit["genotypingEvidenceBAM"] = .file(cohortAlignmentResult.bamURL)
        explicit["genotypingEvidenceBAI"] = .file(cohortAlignmentResult.baiURL)
        explicit["mhcCohortSampleMergeOrder"] = .array(
            cohortAlignmentResult.sampleMappings.map { .string($0.sampleID) }
        )
        explicit["mhcInProcessTransformationResolvedOptions"] = .array(
            cohortAlignmentResult.transformationRecords.map { transformation in
                .dictionary(transformation.resolvedOptions.mapValues(ParameterValue.string))
            }
        )
        if let minimap2ExecutableURL = cohortAlignmentResult.toolVersions.first(where: { $0.toolName == "minimap2" })?
            .discoveryCommand.executableURL {
            explicit["resolvedMinimap2Executable"] = .file(minimap2ExecutableURL)
            explicit["minimap2CondaPrefix"] = .file(
                minimap2ExecutableURL.deletingLastPathComponent().deletingLastPathComponent()
            )
        }
        if let samtoolsExecutableURL = cohortAlignmentResult.toolVersions.first(where: { $0.toolName == "samtools" })?
            .discoveryCommand.executableURL {
            explicit["resolvedSamtoolsExecutable"] = .file(samtoolsExecutableURL)
            explicit["samtoolsCondaPrefix"] = .file(
                samtoolsExecutableURL.deletingLastPathComponent().deletingLastPathComponent()
            )
        }
        explicit["sampleReadCounts"] = .dictionary(Dictionary(uniqueKeysWithValues: stagedSamples.map {
            ($0.sample, ParameterValue.integer($0.readCount))
        }))
        explicit["sampleProcessingOrder"] = .array(processingOrder.map { .string($0.sample) })
        if let haplotypeAssayID = request.haplotypeAssayID {
            explicit["haplotypeAssay"] = .string(haplotypeAssayID)
        }
        if let haplotypeSpeciesCode = request.haplotypeSpeciesCode {
            explicit["haplotypeSpecies"] = .string(haplotypeSpeciesCode)
        }
        if let haplotypeDefinitionScope = request.haplotypeDefinitionScope {
            explicit["haplotypeDefinitionScope"] = .string(haplotypeDefinitionScope.rawValue)
        }
        if request.haplotypeDefinitionSetID != nil {
            explicit["haplotypeAnalysis"] = .file(request.haplotypeAnalysisURL)
        }
        if let orientReferenceURL = request.orientReferenceURL {
            explicit["orientReference"] = .file(orientReferenceURL)
        }
        if let forwardPrimerURL = request.forwardPrimerURL {
            explicit["forwardPrimer"] = .file(forwardPrimerURL)
        }
        if let reversePrimerURL = request.reversePrimerURL {
            explicit["reversePrimer"] = .file(reversePrimerURL)
        }
        if let projectURL = request.projectURL {
            explicit["project"] = .file(projectURL)
        }

        var builder = try ProvenanceRunBuilder(
            workflowName: "lungfish fastq full-length-ont-mhc-genotype",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: CLICommandIdentity.executableName,
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(request.argv)
        .durableReplayArgv(request.argv)
        .reproducibleCommand(request.argv.map(shellEscape).joined(separator: " "))
        .options(explicit: explicit, defaults: defaults, resolved: resolved)
        .runtime(cohortAlignmentResult.runtimeIdentity)
        .input(referenceFASTAURL, format: .fasta, role: .reference)
        .output(request.reportCSVURL, format: .text, role: .report)
        .output(request.sampleSummaryCSVURL, format: .text, role: .report)
        .output(request.statsJSONURL, format: .json, role: .report)
        .output(request.workbookURL, format: .unknown, role: .report)
        .output(request.currentWorkbookURL, format: .unknown, role: .report)
        .output(request.manifestURL, format: .json, role: .output)
        .output(request.unmatchedClustersFASTAURL, format: .fasta, role: .output)
        .output(request.deduplicatedUnmatchedClustersFASTAURL, format: .fasta, role: .output)
        .output(request.cdnaClustersFASTAURL, format: .fasta, role: .output)
        .output(cohortAlignmentResult.bamURL, format: .bam, role: .output)
        .output(cohortAlignmentResult.baiURL, format: .unknown, role: .index)

        if request.haplotypeDefinitionSetID != nil {
            builder = try builder.output(request.haplotypeAnalysisURL, format: .json, role: .report)
        }

        for input in request.inputFASTQURLs where !isDirectory(input) {
            builder = try builder.input(input, format: .fastq, role: .input)
        }
        for primer in [request.orientReferenceURL, request.forwardPrimerURL, request.reversePrimerURL].compactMap({ $0 }) {
            builder = try builder.input(primer, format: .fasta, role: .reference)
        }
        var allProvenanceSteps = try steps.map { try $0.provenanceStep() }
        allProvenanceSteps += try cohortAlignmentProvenanceSteps(
            cohortAlignmentResult,
            bamViewRecord: bamViewRecord
        )
        allProvenanceSteps.sort {
            ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast)
        }
        for step in allProvenanceSteps {
            builder = builder.step(step)
        }

        let envelope = try builder.complete(
            exitStatus: 0,
            startedAt: startedAt,
            endedAt: completedAt
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: request.provenanceURL)
    }

    private func cohortAlignmentProvenanceSteps(
        _ result: FullLengthONTMHCCohortAlignmentResult,
        bamViewRecord: FullLengthONTMHCCohortAlignmentCommandRecord
    ) throws -> [ProvenanceStep] {
        var steps: [ProvenanceStep] = []
        for record in result.toolVersionDiscoveryRecords + result.commandRecords + [bamViewRecord] {
            steps.append(try provenanceStep(for: record))
        }
        for transformation in result.transformationRecords {
            steps.append(ProvenanceStep(
                toolName: transformation.workflowName,
                toolVersion: transformation.workflowVersion,
                argv: transformation.argv,
                durableReplayArgv: transformation.argv,
                reproducibleCommand: transformation.argv.map(shellEscape).joined(separator: " "),
                inputs: transformation.inputs.map {
                    provenanceDescriptor($0, forcedRole: .input)
                },
                outputs: transformation.outputs.map {
                    provenanceDescriptor($0, forcedRole: .output)
                },
                exitStatus: Int(transformation.exitStatus),
                wallTimeSeconds: transformation.wallTime,
                startedAt: transformation.startedAt,
                completedAt: transformation.completedAt
            ))
        }
        if let firstMapping = result.publicationMappings.first,
           let finalDirectory = result.publicationMappings.first?.finalDescriptor.path {
            let stagedDirectory = URL(fileURLWithPath: firstMapping.stagedDescriptor.path)
                .deletingLastPathComponent().path
            let destinationDirectory = URL(fileURLWithPath: finalDirectory)
                .deletingLastPathComponent().path
            let completedAt = result.commandRecords.last?.completedAt ?? Date()
            steps.append(ProvenanceStep(
                toolName: "lungfish-in-process:publish-mhc-cohort-evidence",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: [
                    "lungfish-in-process", "publish-mhc-cohort-evidence",
                    "--atomic-directory-exchange",
                    stagedDirectory,
                    destinationDirectory,
                ],
                inputs: result.publicationMappings.map {
                    provenanceDescriptor($0.stagedDescriptor, forcedRole: .input)
                },
                outputs: result.publicationMappings.map {
                    provenanceDescriptor($0.finalDescriptor, forcedRole: $0.finalDescriptor.role == .evidenceBAI ? .index : .output)
                },
                exitStatus: 0,
                wallTimeSeconds: 0,
                startedAt: completedAt,
                completedAt: completedAt
            ))
        }
        return steps
    }

    private func provenanceStep(
        for record: FullLengthONTMHCCohortAlignmentCommandRecord
    ) throws -> ProvenanceStep {
        guard record.descriptorCaptureErrors.isEmpty else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Could not rehydrate cohort command provenance: \(record.descriptorCaptureErrors.map(\.message).joined(separator: "; "))."
            )
        }
        var outputDescriptors = record.outputDescriptors
        outputDescriptors.append(record.stdoutLogDescriptor)
        outputDescriptors.append(record.stderrLogDescriptor)
        var seenOutputs = Set<String>()
        let uniqueOutputs = outputDescriptors.filter {
            seenOutputs.insert("\($0.path)\u{0}\($0.role.rawValue)").inserted
        }
        return ProvenanceStep(
            toolName: record.executableURL.lastPathComponent,
            toolVersion: record.toolVersion ?? "unknown",
            argv: record.argv,
            durableReplayArgv: record.argv,
            reproducibleCommand: record.argv.map(shellEscape).joined(separator: " "),
            inputs: record.inputDescriptors.map {
                provenanceDescriptor($0, forcedRole: .input)
            },
            outputs: uniqueOutputs.map {
                provenanceDescriptor(
                    $0,
                    forcedRole: $0.role == .commandStdoutLog || $0.role == .commandStderrLog ? .log : .output
                )
            },
            exitStatus: Int(record.exitStatus),
            wallTimeSeconds: record.wallTime,
            stderr: record.stderr,
            startedAt: record.startedAt,
            completedAt: record.completedAt
        )
    }

    private func provenanceDescriptor(
        _ descriptor: FullLengthONTMHCArtifactDescriptor,
        forcedRole: FileRole
    ) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: descriptor.path,
            checksumSHA256: descriptor.sha256,
            fileSize: descriptor.byteSize,
            format: provenanceFormat(for: descriptor),
            role: forcedRole
        )
    }

    private func provenanceFormat(
        for descriptor: FullLengthONTMHCArtifactDescriptor
    ) -> FileFormat {
        switch descriptor.role {
        case .referenceFASTA, .sourceClusterFASTA, .snapshotClusterFASTA, .namespacedClusterFASTA:
            return .fasta
        case .evidenceBAM:
            return .bam
        case .commandStdoutLog, .commandStderrLog:
            return descriptor.path.hasSuffix(".sam") ? .sam : .text
        case .evidenceBAI:
            return .unknown
        case .commandInput, .commandOutput:
            let path = descriptor.path.lowercased()
            if path.hasSuffix(".bam") { return .bam }
            if path.hasSuffix(".sam") { return .sam }
            if path.hasSuffix(".fa") || path.hasSuffix(".fasta") { return .fasta }
            return .unknown
        }
    }

    private func cleanupWarning(
        _ diagnostic: FullLengthONTMHCCleanupDiagnostic
    ) -> FullLengthONTMHCGenotypingCleanupWarning {
        let kind: FullLengthONTMHCGenotypingCleanupWarningKind
        switch diagnostic.kind {
        case .retiredPublicationDirectory:
            kind = .retiredCohortPublicationDirectory
        case .temporaryWorkDirectory:
            kind = .cohortAlignmentTemporaryWorkDirectory
        }
        return FullLengthONTMHCGenotypingCleanupWarning(
            kind: kind,
            path: diagnostic.retainedDirectoryURL.standardizedFileURL.path,
            error: diagnostic.message,
            publishedArtifactsRemainValid: diagnostic.publishedArtifactsRemainValid
        )
    }

    private func cleanupErrorDescription(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func removeGeneratedWorkflowIntermediates(_ workDirectory: URL) throws {
        if FileManager.default.fileExists(atPath: workDirectory.path) {
            try postPublicationWorkDirectoryCleaner.removeWorkDirectory(at: workDirectory)
        }
    }

    private func append(
        records: [FullLengthONTMHCClusterFASTARecord],
        sample: String,
        to url: URL
    ) throws {
        guard !records.isEmpty else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for record in records {
            let text = ">\(sample)_\(record.name)\n\(record.sequence)\n"
            if let data = text.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        }
    }

    private func fastqReadCount(_ url: URL) -> Int {
        var lineCount = 0
        do {
            try url.forEachLineAutoDecompressing { _ in
                lineCount += 1
            }
            return lineCount / 4
        } catch {
            return 0
        }
    }

    private func sampleName(for url: URL, fallbackIndex: Int) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "sample-\(fallbackIndex + 1)" : sanitizedSampleName(trimmed)
    }

    private func sanitizedSampleName(_ value: String) -> String {
        let replaced = value.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "sample" : collapsed
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private func optionalString<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? ""
    }

    private func oneDecimalString(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.1f", value)
    }

    private func formattedReadCount(_ value: Int) -> String {
        value.formatted(.number)
    }

    private func sampleLabel(_ count: Int) -> String {
        count == 1 ? "sample" : "samples"
    }

    private func jobLabel(_ count: Int) -> String {
        count == 1 ? "job" : "jobs"
    }

    private func relativePath(from baseURL: URL, to targetURL: URL) -> String {
        let basePath = baseURL.standardizedFileURL.path
        let normalizedBase = basePath.hasSuffix("/") ? basePath : basePath + "/"
        let targetPath = targetURL.standardizedFileURL.path
        guard targetPath.hasPrefix(normalizedBase) else { return targetPath }
        return String(targetPath.dropFirst(normalizedBase.count))
    }

    private func genotypeWorkbookRows(_ rows: [FullLengthONTMHCClusterGenotypeRow]) -> [[String]] {
        var result = [["sample", "genotype", "cluster", "cluster_reads", "allele_length", "aligned_bases", "score"]]
        result += rows.map {
            [
                $0.sample,
                $0.allele,
                $0.cluster,
                String($0.clusterReads),
                String($0.alleleLength),
                String($0.alignedBases),
                String($0.score),
            ]
        }
        return result
    }

    private func sampleWorkbookRows(_ rows: [FullLengthONTMHCSampleSummary]) -> [[String]] {
        let overallInputReads = rows.reduce(0) { $0 + $1.totalInputReads }
        let overallRetainedReads = rows.reduce(0) { $0 + $1.assignedReads }
        let overallRetainedPercent = overallInputReads > 0
            ? Double(overallRetainedReads) / Double(overallInputReads) * 100.0
            : nil
        var result = [[
            "sample",
            "total_input_reads",
            "cluster_count",
            "clustered_reads",
            "sample_unique_retained_reads",
            "sample_unique_retained_percent",
            "overall_input_reads",
            "overall_unique_retained_reads",
            "overall_unique_retained_percent",
            "unmatched_clusters",
            "cdna_clusters",
            "savont_preset",
            "savont_status",
            "savont_fallback_reason",
        ]]
        result += rows.map {
            let samplePercent = $0.totalInputReads > 0
                ? Double($0.assignedReads) / Double($0.totalInputReads) * 100.0
                : nil
            return [
                $0.sample,
                String($0.totalInputReads),
                String($0.clusterCount),
                String($0.clusteredReads),
                String($0.assignedReads),
                oneDecimalString(samplePercent),
                String(overallInputReads),
                String(overallRetainedReads),
                oneDecimalString(overallRetainedPercent),
                String($0.unmatchedClusters),
                String($0.cdnaClusters),
                $0.savontPreset,
                $0.savontStatus.rawValue,
                $0.savontFallbackReason ?? "",
            ]
        }
        return result
    }
}

struct FullLengthONTMHCPivotSample: Sendable, Equatable {
    let sample: String
    let mappedReadCount: Int?
    let totalReadCount: Int?
    let retainedPercent: Double?
}

enum FullLengthONTMHCPivotWorkbookBuilder {
    private static let canonicalLoci = [
        "MHC-A", "MHC-B", "MHC-DRB", "MHC-DQA", "MHC-DQB", "MHC-DPA", "MHC-DPB",
    ]

    private static let sectionSuffixOrder = [
        "-F alleles",
        "-G alleles",
        "-AG alleles",
        "-A major alleles",
        "-A minor alleles",
        "-70 alleles",
        "-L alleles",
        "-E alleles",
        "-B alleles",
        "-DRB alleles",
        "-DQA/DQB alleles",
        "-DPA/DPB alleles",
    ]

    static func buildRows(
        reportRows: [FullLengthONTMHCReportRow],
        samples: [FullLengthONTMHCPivotSample],
        orderedAlleles: [String],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?
    ) -> [[String]] {
        let pivotSamples = completeSamples(samples, with: reportRows)
        let sampleNames = pivotSamples.map(\.sample)
        let speciesPrefix = inferSpeciesPrefix(reportRows: reportRows, haplotypeAnalysis: haplotypeAnalysis)
        let callsBySampleLocus = haplotypeCallsBySampleLocus(haplotypeAnalysis)
        let countsBySampleAllele = alleleCounts(reportRows)
        let observedAlleles = Set(countsBySampleAllele.keys)
        let orderedObservedAlleles = orderedObservedAlleles(
            observedAlleles: observedAlleles,
            orderedAlleles: orderedAlleles
        )

        var rows: [[String]] = []
        rows.append(["Client ID", "", ""] + sampleNames)
        rows.append(["GS ID", "Total", "Average"] + sampleNames)

        let mappedCounts = pivotSamples.map(\.mappedReadCount)
        rows.append(
            ["Mapped Read Count", formatNumber(mappedCounts.compactMap { $0 }.reduce(0, +)), formatNumber(average(mappedCounts))]
            + mappedCounts.map { formatNumber($0) }
        )
        rows.append(["total_read_count", "", ""] + pivotSamples.map { formatNumber($0.totalReadCount) })
        rows.append(
            ["percent_reads_unmapped", "", ""]
            + pivotSamples.map { sample in
                sample.retainedPercent.map { formatNumber(max(0.0, min(100.0, 100.0 - $0))) } ?? ""
            }
        )

        for locus in canonicalLoci {
            for slot in 1...2 {
                rows.append(
                    ["\(locus) Haplotype \(slot)", "", ""]
                    + sampleNames.map { sample in
                        haplotypeValue(callsBySampleLocus[sample]?[locus], slot: slot) ?? ""
                    }
                )
            }
        }

        rows.append(
            ["Comments", "Subtotal", "# Obs."]
            + sampleNames.map { sample in haplotypeComments(callsBySampleLocus[sample] ?? [:]) }
        )

        let sectionOrder = sectionSuffixOrder.map { speciesPrefix + $0 }
        let observedBySection = Dictionary(grouping: orderedObservedAlleles) {
            sectionLabel(for: $0, speciesPrefix: speciesPrefix)
        }

        for section in sectionOrder {
            guard let alleles = observedBySection[section], !alleles.isEmpty else { continue }
            rows.append([section, "", ""] + Array(repeating: "", count: sampleNames.count))
            for allele in alleles {
                rows.append(alleleRow(allele, sampleNames: sampleNames, countsBySampleAllele: countsBySampleAllele))
            }
        }

        for section in observedBySection.keys.sorted().filter({ !sectionOrder.contains($0) }) {
            guard let alleles = observedBySection[section], !alleles.isEmpty else { continue }
            rows.append([section, "", ""] + Array(repeating: "", count: sampleNames.count))
            for allele in alleles {
                rows.append(alleleRow(allele, sampleNames: sampleNames, countsBySampleAllele: countsBySampleAllele))
            }
        }

        return rows
    }

    private static func completeSamples(
        _ samples: [FullLengthONTMHCPivotSample],
        with reportRows: [FullLengthONTMHCReportRow]
    ) -> [FullLengthONTMHCPivotSample] {
        var result = samples
        var seen = Set(samples.map(\.sample))
        let missingSamples = Set(reportRows.map(\.sample))
            .subtracting(seen)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for sample in missingSamples {
            let sampleRows = reportRows.filter { $0.sample == sample }
            let mapped = sampleRows.reduce(0) { $0 + $1.passedUniqueReads }
            let first = sampleRows.first
            result.append(FullLengthONTMHCPivotSample(
                sample: sample,
                mappedReadCount: mapped,
                totalReadCount: first?.sampleTotalReads,
                retainedPercent: first?.sampleUniqueRetainedPercent
            ))
            seen.insert(sample)
        }
        return result
    }

    private static func alleleCounts(_ reportRows: [FullLengthONTMHCReportRow]) -> [String: [String: Int]] {
        var counts: [String: [String: Int]] = [:]
        for row in reportRows {
            counts[row.genotype, default: [:]][row.sample, default: 0] += row.passedUniqueReads
        }
        return counts
    }

    private static func orderedObservedAlleles(
        observedAlleles: Set<String>,
        orderedAlleles: [String]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for allele in orderedAlleles where observedAlleles.contains(allele) && seen.insert(allele).inserted {
            result.append(allele)
        }
        let remaining = observedAlleles
            .filter { !seen.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        result.append(contentsOf: remaining)
        return result
    }

    private static func haplotypeCallsBySampleLocus(
        _ analysis: GenotypeHaplotypeAnalysis?
    ) -> [String: [String: GenotypeHaplotypeLocusCall]] {
        guard let analysis else { return [:] }
        var calls: [String: [String: GenotypeHaplotypeLocusCall]] = [:]
        for sample in analysis.samples {
            for call in sample.calls {
                calls[sample.sample, default: [:]][call.locus] = call
            }
        }
        return calls
    }

    private static func haplotypeValue(_ call: GenotypeHaplotypeLocusCall?, slot: Int) -> String? {
        guard let call else { return nil }
        let value = slot == 1 ? call.haplotype1 : call.haplotype2
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func haplotypeComments(_ callsByLocus: [String: GenotypeHaplotypeLocusCall]) -> String {
        let comments = callsByLocus
            .values
            .sorted { $0.locus.localizedStandardCompare($1.locus) == .orderedAscending }
            .compactMap { call -> String? in
                guard call.status != .called, call.status != .notAssayed else { return nil }
                let first = call.haplotype1.trimmingCharacters(in: .whitespacesAndNewlines)
                let second = call.haplotype2.trimmingCharacters(in: .whitespacesAndNewlines)
                let label: String
                if first.isEmpty {
                    label = second
                } else if second.isEmpty || first == second {
                    label = first
                } else {
                    label = "\(first)/\(second)"
                }
                return label.isEmpty ? "\(call.locus): \(call.status.rawValue)" : "\(call.locus): \(label)"
            }
        return comments.joined(separator: "; ")
    }

    private static func alleleRow(
        _ allele: String,
        sampleNames: [String],
        countsBySampleAllele: [String: [String: Int]]
    ) -> [String] {
        let counts = countsBySampleAllele[allele] ?? [:]
        let perSample = sampleNames.map { sample in counts[sample] ?? 0 }
        let subtotal = perSample.reduce(0, +)
        let observed = perSample.filter { $0 > 0 }.count
        return [
            allele,
            subtotal > 0 ? formatNumber(subtotal) : "",
            observed > 0 ? formatNumber(observed) : "",
        ] + perSample.map { $0 > 0 ? formatNumber($0) : "" }
    }

    private static func sectionLabel(for allele: String, speciesPrefix: String) -> String {
        let trimmed = allele.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("01_") { return speciesPrefix + "-F alleles" }
        if trimmed.hasPrefix("02_") { return speciesPrefix + "-G alleles" }
        if trimmed.hasPrefix("04_") || trimmed.hasPrefix("AG_") { return speciesPrefix + "-AG alleles" }
        if trimmed.hasPrefix("05_") { return speciesPrefix + "-A major alleles" }
        if trimmed.hasPrefix("06_") { return speciesPrefix + "-A minor alleles" }
        if trimmed.hasPrefix("07_") { return speciesPrefix + "-70 alleles" }
        if trimmed.hasPrefix("10_") { return speciesPrefix + "-L alleles" }
        if trimmed.hasPrefix("11_") || trimmed.hasPrefix("E_") { return speciesPrefix + "-E alleles" }
        if trimmed.hasPrefix("12_") || trimmed.hasPrefix("B") || trimmed.hasPrefix("I_") {
            return speciesPrefix + "-B alleles"
        }
        if trimmed.hasPrefix("13_") { return speciesPrefix + "-DRB alleles" }
        if trimmed.hasPrefix("14_") { return speciesPrefix + "-DQA/DQB alleles" }
        if trimmed.hasPrefix("15_") { return speciesPrefix + "-DPA/DPB alleles" }

        let gene = alleleGeneToken(trimmed)
        if gene == "F" { return speciesPrefix + "-F alleles" }
        if gene == "G" { return speciesPrefix + "-G alleles" }
        if gene == "AG" { return speciesPrefix + "-AG alleles" }
        if gene == "A1" { return speciesPrefix + "-A major alleles" }
        if gene.hasPrefix("A") { return speciesPrefix + "-A minor alleles" }
        if gene == "L" { return speciesPrefix + "-L alleles" }
        if gene == "E" { return speciesPrefix + "-E alleles" }
        if gene.hasPrefix("B") || gene == "I" { return speciesPrefix + "-B alleles" }
        if gene.hasPrefix("DRB") { return speciesPrefix + "-DRB alleles" }
        if gene.hasPrefix("DQA") || gene.hasPrefix("DQB") { return speciesPrefix + "-DQA/DQB alleles" }
        if gene.hasPrefix("DPA") || gene.hasPrefix("DPB") { return speciesPrefix + "-DPA/DPB alleles" }
        return "Other alleles"
    }

    private static func alleleGeneToken(_ allele: String) -> String {
        let name = allele.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? allele
        let afterSpecies = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? name
        let beforeStar = afterSpecies.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? afterSpecies
        let beforeColon = beforeStar.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? beforeStar
        return beforeColon.uppercased()
    }

    private static func inferSpeciesPrefix(
        reportRows: [FullLengthONTMHCReportRow],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?
    ) -> String {
        for genotype in reportRows.map(\.genotype) {
            let prefix = genotype.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if prefix.count == 4, prefix.allSatisfy(\.isLetter) {
                return prefix
            }
        }
        let speciesName = haplotypeAnalysis?.speciesName.lowercased() ?? ""
        if speciesName.contains("fascicularis") { return "Mafa" }
        if speciesName.contains("mulatta") { return "Mamu" }
        if speciesName.contains("nemestrina") { return "Mane" }
        if speciesName.contains("fuscata") { return "Mafu" }
        if speciesName.contains("tonkeana") { return "Mato" }
        if speciesName.contains("leonina") { return "Male" }
        if speciesName.contains("thibetana") { return "Math" }
        return "Mafa"
    }

    private static func average(_ values: [Int?]) -> Double? {
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return Double(present.reduce(0, +)) / Double(present.count)
    }

    private static func formatNumber(_ value: Int?) -> String {
        value.map { String($0) } ?? ""
    }

    private static func formatNumber(_ value: Int) -> String {
        String(value)
    }

    private static func formatNumber(_ value: Double?) -> String {
        guard let value else { return "" }
        if value.rounded() == value && abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(format: "%.1f", value)
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }
}

private struct FullLengthONTMHCWorkbookCopyResult: Sendable {
    let revision: ONTGenotypeWorkbookRevision
    let step: FullLengthONTMHCProvenanceStep
}

struct FullLengthONTMHCUnmatchedClosestMatchWorkbookRow: Sendable, Equatable {
    let sample: String
    let cluster: String
    let clusterReads: Int
    let rawSequence: String
    let sequence: String
    let trimStart: Int?
    let trimEnd: Int?
    let trimSource: String
    let closestMatch: FullLengthONTMHCClosestMatch?
    let rescueMatch: FullLengthONTMHCBlastRescueMatch?

    var rawLength: Int {
        rawSequence.count
    }

    var trimmedLength: Int {
        sequence.count
    }

    init(
        sample: String,
        cluster: String,
        clusterReads: Int,
        sequence: String,
        rawSequence: String? = nil,
        trimStart: Int? = nil,
        trimEnd: Int? = nil,
        trimSource: String = "provided-sequence",
        closestMatch: FullLengthONTMHCClosestMatch?,
        rescueMatch: FullLengthONTMHCBlastRescueMatch? = nil
    ) {
        self.sample = sample
        self.cluster = cluster
        self.clusterReads = clusterReads
        self.rawSequence = rawSequence ?? sequence
        self.sequence = sequence
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.trimSource = trimSource
        self.closestMatch = closestMatch
        self.rescueMatch = rescueMatch
    }
}

enum FullLengthONTMHCUnmatchedSequenceNormalizer {
    static func workbookRow(
        sample: String,
        record: FullLengthONTMHCClusterFASTARecord,
        closestMatch: FullLengthONTMHCClosestMatch?,
        rescueMatch: FullLengthONTMHCBlastRescueMatch? = nil
    ) -> FullLengthONTMHCUnmatchedClosestMatchWorkbookRow {
        let raw = record.sequence.uppercased()
        guard let closestMatch,
              let trimStart = closestMatch.trimStart,
              let trimEnd = closestMatch.trimEnd else {
            return FullLengthONTMHCUnmatchedClosestMatchWorkbookRow(
                sample: sample,
                cluster: record.name,
                clusterReads: record.readCount,
                sequence: raw,
                rawSequence: raw,
                trimStart: nil,
                trimEnd: nil,
                trimSource: "none-no-minimap-hit",
                closestMatch: closestMatch,
                rescueMatch: rescueMatch
            )
        }
        let start = max(1, min(trimStart, trimEnd))
        let end = min(raw.count, max(trimStart, trimEnd))
        var normalized = start <= end ? substring(raw, oneBasedClosedStart: start, oneBasedClosedEnd: end) : raw
        var trimSource = "minimap2-target-interval"
        if closestMatch.isReverse == true {
            normalized = reverseComplement(normalized)
            trimSource = "minimap2-target-interval-reverse-complement"
        }
        return FullLengthONTMHCUnmatchedClosestMatchWorkbookRow(
            sample: sample,
            cluster: record.name,
            clusterReads: record.readCount,
            sequence: normalized,
            rawSequence: raw,
            trimStart: start,
            trimEnd: end,
            trimSource: trimSource,
            closestMatch: closestMatch,
            rescueMatch: rescueMatch
        )
    }

    private static func substring(
        _ sequence: String,
        oneBasedClosedStart start: Int,
        oneBasedClosedEnd end: Int
    ) -> String {
        let startIndex = sequence.index(sequence.startIndex, offsetBy: start - 1)
        let endIndex = sequence.index(sequence.startIndex, offsetBy: end)
        return String(sequence[startIndex..<endIndex])
    }

    private static func reverseComplement(_ sequence: String) -> String {
        let complemented = sequence.reversed().map { base -> Character in
            switch base {
            case "A", "a": return "T"
            case "C", "c": return "G"
            case "G", "g": return "C"
            case "T", "t": return "A"
            default: return "N"
            }
        }
        return String(complemented).uppercased()
    }
}

struct FullLengthONTMHCBlastRescueMatch: Sendable, Equatable {
    static let minimumQueryCoverage = 70.0
    static let minimumAlignedBases = 1_000
    static let minimumPercentIdentity = 75.0
    static let maximumEValue = 1e-20

    let sample: String
    let cluster: String
    let clusterReads: Int
    let closestReference: String
    let percentIdentity: Double
    let queryCoverage: Double
    let alignedBases: Int
    let mismatches: Int
    let gapOpens: Int
    let eValue: Double
    let bitScore: Double
    let closestMatchID: String
}

enum FullLengthONTMHCBlastRescueParser {
    static func acceptedMatches(
        sample: String,
        recordsByCluster: [String: FullLengthONTMHCClusterFASTARecord],
        tsv: String
    ) throws -> [FullLengthONTMHCBlastRescueMatch] {
        let candidates = tsv
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> FullLengthONTMHCBlastRescueMatch? in
                parseLine(String(line), sample: sample, recordsByCluster: recordsByCluster)
            }
            .filter(passesThresholds)
        let grouped = Dictionary(grouping: candidates, by: \.cluster)
        return grouped.values.compactMap { group in
            group.sorted(by: rescueSort).first
        }
        .sorted {
            if $0.sample != $1.sample {
                return $0.sample.localizedStandardCompare($1.sample) == .orderedAscending
            }
            return $0.cluster.localizedStandardCompare($1.cluster) == .orderedAscending
        }
    }

    private static func parseLine(
        _ line: String,
        sample: String,
        recordsByCluster: [String: FullLengthONTMHCClusterFASTARecord]
    ) -> FullLengthONTMHCBlastRescueMatch? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 14,
              let record = recordsByCluster[fields[0]],
              let percentIdentity = Double(fields[2]),
              let alignedBases = Int(fields[3]),
              let mismatches = Int(fields[4]),
              let gapOpens = Int(fields[5]),
              let eValue = Double(fields[10]),
              let bitScore = Double(fields[11]),
              let queryLength = Double(fields[12]),
              queryLength > 0
        else {
            return nil
        }
        let queryCoverage = Double(alignedBases) / queryLength * 100.0
        let closestReference = fields[1]
        return FullLengthONTMHCBlastRescueMatch(
            sample: sample,
            cluster: record.name,
            clusterReads: record.readCount,
            closestReference: closestReference,
            percentIdentity: percentIdentity,
            queryCoverage: queryCoverage,
            alignedBases: alignedBases,
            mismatches: mismatches,
            gapOpens: gapOpens,
            eValue: eValue,
            bitScore: bitScore,
            closestMatchID: "\(closestReference)_blast-rescue"
        )
    }

    private static func passesThresholds(_ match: FullLengthONTMHCBlastRescueMatch) -> Bool {
        match.queryCoverage >= FullLengthONTMHCBlastRescueMatch.minimumQueryCoverage
            && match.alignedBases >= FullLengthONTMHCBlastRescueMatch.minimumAlignedBases
            && match.percentIdentity >= FullLengthONTMHCBlastRescueMatch.minimumPercentIdentity
            && match.eValue <= FullLengthONTMHCBlastRescueMatch.maximumEValue
    }

    static func rescueSort(
        _ lhs: FullLengthONTMHCBlastRescueMatch,
        _ rhs: FullLengthONTMHCBlastRescueMatch
    ) -> Bool {
        if lhs.eValue != rhs.eValue { return lhs.eValue < rhs.eValue }
        if lhs.bitScore != rhs.bitScore { return lhs.bitScore > rhs.bitScore }
        if lhs.queryCoverage != rhs.queryCoverage { return lhs.queryCoverage > rhs.queryCoverage }
        if lhs.percentIdentity != rhs.percentIdentity { return lhs.percentIdentity > rhs.percentIdentity }
        if lhs.alignedBases != rhs.alignedBases { return lhs.alignedBases > rhs.alignedBases }
        return lhs.closestReference.localizedStandardCompare(rhs.closestReference) == .orderedAscending
    }
}

enum FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder {
    static func detailRows(_ rows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow]) -> [[String]] {
        var result = [[
            "unmatched_sequence_id",
            "sample",
            "cluster",
            "cluster_reads",
            "raw_length",
            "trimmed_length",
            "trim_start",
            "trim_end",
            "trim_source",
            "closest_match_id",
            "match_class",
            "nucleotides_different",
            "snp_differences",
            "indel_bases",
            "aligned_bases",
            "score",
            "sequence",
        ]]
        result += rows.sorted(by: rowSort).map { row in
            let closest = row.closestMatch
            return [
                unmatchedSequenceID(for: row.sequence),
                row.sample,
                row.cluster,
                String(row.clusterReads),
                String(row.rawLength),
                String(row.trimmedLength),
                optionalNumber(row.trimStart),
                optionalNumber(row.trimEnd),
                row.trimSource,
                closest?.closestMatchID ?? "",
                closest?.matchClass.rawValue ?? "",
                optionalNumber(closest?.nucleotidesDifferent),
                optionalNumber(closest?.snpDifferences),
                optionalNumber(closest?.indelBases),
                optionalNumber(closest?.alignedBases),
                optionalNumber(closest?.score),
                row.sequence,
            ]
        }
        return result
    }

    static func pivotRows(
        _ rows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow],
        sampleOrder: [String]
    ) -> [[String]] {
        let sampleNames = completeSampleOrder(sampleOrder, with: rows)
        var result = [[
            "unmatched_sequence_id",
            "occurrence_count",
            "sample_count",
            "total_cluster_reads",
            "closest_match_id",
            "match_class",
            "nucleotides_different",
            "snp_differences",
            "indel_bases",
            "aligned_bases",
            "score",
        ] + sampleNames]
        let grouped = Dictionary(grouping: rows) { unmatchedSequenceID(for: $0.sequence) }
        let orderedGroups = grouped.keys.sorted { lhs, rhs in
            let left = grouped[lhs] ?? []
            let right = grouped[rhs] ?? []
            let leftReads = left.reduce(0) { $0 + $1.clusterReads }
            let rightReads = right.reduce(0) { $0 + $1.clusterReads }
            if leftReads != rightReads { return leftReads > rightReads }
            if left.count != right.count { return left.count > right.count }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        for unmatchedSequenceID in orderedGroups {
            guard let group = grouped[unmatchedSequenceID] else {
                continue
            }
            let metadata = group.compactMap(\.closestMatch).sorted(by: closestSort).first
            let totalReads = group.reduce(0) { $0 + $1.clusterReads }
            let readsBySample = group.reduce(into: [String: Int]()) { totals, item in
                totals[item.sample, default: 0] += item.clusterReads
            }
            let sampleCount = readsBySample.values.filter { $0 > 0 }.count
            result.append([
                unmatchedSequenceID,
                String(group.count),
                String(sampleCount),
                String(totalReads),
                metadata?.closestMatchID ?? "",
                metadata?.matchClass.rawValue ?? "",
                optionalNumber(metadata?.nucleotidesDifferent),
                optionalNumber(metadata?.snpDifferences),
                optionalNumber(metadata?.indelBases),
                optionalNumber(metadata?.alignedBases),
                optionalNumber(metadata?.score),
            ] + sampleNames.map { sample in
                guard let count = readsBySample[sample], count > 0 else { return "" }
                return String(count)
            })
        }
        return result
    }

    static func mhcLikeDetailRows(_ rows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow]) -> [[String]] {
        var result = [[
            "unmatched_sequence_id",
            "sample",
            "cluster",
            "cluster_reads",
            "raw_length",
            "trimmed_length",
            "trim_start",
            "trim_end",
            "trim_source",
            "match_source",
            "closest_match_id",
            "closest_reference",
            "match_class",
            "nucleotides_different",
            "snp_differences",
            "indel_bases",
            "aligned_bases",
            "score",
            "percent_identity",
            "query_coverage",
            "evalue",
            "bitscore",
            "sequence",
        ]]
        result += rows.filter(isMHCLike).sorted(by: rowSort).map { row in
            let metadata = mhcLikeMetadata(for: row)
            return [
                unmatchedSequenceID(for: row.sequence),
                row.sample,
                row.cluster,
                String(row.clusterReads),
                String(row.rawLength),
                String(row.trimmedLength),
                optionalNumber(row.trimStart),
                optionalNumber(row.trimEnd),
                row.trimSource,
                metadata.matchSource,
                metadata.closestMatchID,
                metadata.closestReference,
                metadata.matchClass,
                metadata.nucleotidesDifferent,
                metadata.snpDifferences,
                metadata.indelBases,
                metadata.alignedBases,
                metadata.score,
                metadata.percentIdentity,
                metadata.queryCoverage,
                metadata.eValue,
                metadata.bitScore,
                row.sequence,
            ]
        }
        return result
    }

    static func mhcLikePivotRows(
        _ rows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow],
        sampleOrder: [String]
    ) -> [[String]] {
        let sampleNames = completeSampleOrder(sampleOrder, with: rows.filter(isMHCLike))
        var result = [[
            "unmatched_sequence_id",
            "occurrence_count",
            "sample_count",
            "total_cluster_reads",
            "match_source",
            "closest_match_id",
            "closest_reference",
            "match_class",
            "nucleotides_different",
            "percent_identity",
            "query_coverage",
            "evalue",
            "bitscore",
        ] + sampleNames]
        let grouped = Dictionary(grouping: rows.filter(isMHCLike)) { unmatchedSequenceID(for: $0.sequence) }
        let orderedGroups = grouped.keys.sorted { lhs, rhs in
            let left = grouped[lhs] ?? []
            let right = grouped[rhs] ?? []
            let leftReads = left.reduce(0) { $0 + $1.clusterReads }
            let rightReads = right.reduce(0) { $0 + $1.clusterReads }
            if leftReads != rightReads { return leftReads > rightReads }
            if left.count != right.count { return left.count > right.count }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        for unmatchedSequenceID in orderedGroups {
            guard let group = grouped[unmatchedSequenceID] else {
                continue
            }
            let representative = group.sorted(by: mhcLikeSort).first
            let metadata = representative.map(mhcLikeMetadata)
            let totalReads = group.reduce(0) { $0 + $1.clusterReads }
            let readsBySample = group.reduce(into: [String: Int]()) { totals, item in
                totals[item.sample, default: 0] += item.clusterReads
            }
            let sampleCount = readsBySample.values.filter { $0 > 0 }.count
            result.append([
                unmatchedSequenceID,
                String(group.count),
                String(sampleCount),
                String(totalReads),
                metadata?.matchSource ?? "",
                metadata?.closestMatchID ?? "",
                metadata?.closestReference ?? "",
                metadata?.matchClass ?? "",
                metadata?.nucleotidesDifferent ?? "",
                metadata?.percentIdentity ?? "",
                metadata?.queryCoverage ?? "",
                metadata?.eValue ?? "",
                metadata?.bitScore ?? "",
            ] + sampleNames.map { sample in
                guard let count = readsBySample[sample], count > 0 else { return "" }
                return String(count)
            })
        }
        return result
    }

    static func deduplicatedFASTARecords(
        _ rows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow]
    ) -> [FullLengthONTMHCClusterFASTARecord] {
        let grouped = Dictionary(grouping: rows) { unmatchedSequenceID(for: $0.sequence) }
        let orderedGroups = grouped.keys.sorted { lhs, rhs in
            let left = grouped[lhs] ?? []
            let right = grouped[rhs] ?? []
            let leftReads = left.reduce(0) { $0 + $1.clusterReads }
            let rightReads = right.reduce(0) { $0 + $1.clusterReads }
            if leftReads != rightReads { return leftReads > rightReads }
            if left.count != right.count { return left.count > right.count }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return orderedGroups.compactMap { sequenceID in
            guard let group = grouped[sequenceID],
                  let representative = group.sorted(by: rowSort).first else {
                return nil
            }
            let samples = Set(group.map(\.sample)).sorted(by: localizedStandardLessThan)
            let totalReads = group.reduce(0) { $0 + $1.clusterReads }
            return FullLengthONTMHCClusterFASTARecord(
                name: [
                    sequenceID,
                    "occurrences=\(group.count)",
                    "sample_count=\(samples.count)",
                    "samples=\(samples.joined(separator: ";"))",
                    "total_cluster_reads=\(totalReads)",
                ].joined(separator: "|"),
                sequence: representative.sequence,
                readCount: totalReads
            )
        }
    }

    private static func completeSampleOrder(
        _ sampleOrder: [String],
        with rows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for sample in sampleOrder where seen.insert(sample).inserted {
            result.append(sample)
        }
        let missing = Set(rows.map(\.sample))
            .subtracting(seen)
            .sorted(by: localizedStandardLessThan)
        result.append(contentsOf: missing)
        return result
    }

    private static func rowSort(
        _ lhs: FullLengthONTMHCUnmatchedClosestMatchWorkbookRow,
        _ rhs: FullLengthONTMHCUnmatchedClosestMatchWorkbookRow
    ) -> Bool {
        if lhs.sample != rhs.sample {
            return lhs.sample.localizedStandardCompare(rhs.sample) == .orderedAscending
        }
        let leftID = lhs.closestMatch?.closestMatchID ?? ""
        let rightID = rhs.closestMatch?.closestMatchID ?? ""
        if leftID != rightID {
            return leftID.localizedStandardCompare(rightID) == .orderedAscending
        }
        return lhs.cluster.localizedStandardCompare(rhs.cluster) == .orderedAscending
    }

    private static func isMHCLike(_ row: FullLengthONTMHCUnmatchedClosestMatchWorkbookRow) -> Bool {
        row.closestMatch != nil || row.rescueMatch != nil
    }

    private struct MHCLikeMetadata {
        let matchSource: String
        let closestMatchID: String
        let closestReference: String
        let matchClass: String
        let nucleotidesDifferent: String
        let snpDifferences: String
        let indelBases: String
        let alignedBases: String
        let score: String
        let percentIdentity: String
        let queryCoverage: String
        let eValue: String
        let bitScore: String
    }

    private static func mhcLikeMetadata(for row: FullLengthONTMHCUnmatchedClosestMatchWorkbookRow) -> MHCLikeMetadata {
        if let closest = row.closestMatch {
            return MHCLikeMetadata(
                matchSource: "genotyping-sam",
                closestMatchID: closest.closestMatchID,
                closestReference: closest.closestReference,
                matchClass: closest.matchClass.rawValue,
                nucleotidesDifferent: optionalNumber(closest.nucleotidesDifferent),
                snpDifferences: optionalNumber(closest.snpDifferences),
                indelBases: optionalNumber(closest.indelBases),
                alignedBases: optionalNumber(closest.alignedBases),
                score: optionalNumber(closest.score),
                percentIdentity: "",
                queryCoverage: "",
                eValue: "",
                bitScore: ""
            )
        }
        guard let rescue = row.rescueMatch else {
            return MHCLikeMetadata(
                matchSource: "",
                closestMatchID: "",
                closestReference: "",
                matchClass: "",
                nucleotidesDifferent: "",
                snpDifferences: "",
                indelBases: "",
                alignedBases: "",
                score: "",
                percentIdentity: "",
                queryCoverage: "",
                eValue: "",
                bitScore: ""
            )
        }
        return MHCLikeMetadata(
            matchSource: "local-blast-rescue",
            closestMatchID: rescue.closestMatchID,
            closestReference: rescue.closestReference,
            matchClass: "blast-rescue",
            nucleotidesDifferent: "",
            snpDifferences: "",
            indelBases: "",
            alignedBases: optionalNumber(rescue.alignedBases),
            score: "",
            percentIdentity: formatNumber(rescue.percentIdentity),
            queryCoverage: formatNumber(rescue.queryCoverage),
            eValue: formatNumber(rescue.eValue),
            bitScore: formatNumber(rescue.bitScore)
        )
    }

    private static func mhcLikeSort(
        _ lhs: FullLengthONTMHCUnmatchedClosestMatchWorkbookRow,
        _ rhs: FullLengthONTMHCUnmatchedClosestMatchWorkbookRow
    ) -> Bool {
        if lhs.closestMatch != nil && rhs.closestMatch == nil { return true }
        if lhs.closestMatch == nil && rhs.closestMatch != nil { return false }
        if let left = lhs.closestMatch, let right = rhs.closestMatch {
            return closestSort(left, right)
        }
        if let left = lhs.rescueMatch, let right = rhs.rescueMatch {
            return FullLengthONTMHCBlastRescueParser.rescueSort(left, right)
        }
        return lhs.cluster.localizedStandardCompare(rhs.cluster) == .orderedAscending
    }

    private static func closestSort(
        _ lhs: FullLengthONTMHCClosestMatch,
        _ rhs: FullLengthONTMHCClosestMatch
    ) -> Bool {
        if lhs.closestMatchID != rhs.closestMatchID {
            return lhs.closestMatchID.localizedStandardCompare(rhs.closestMatchID) == .orderedAscending
        }
        if lhs.closestReference != rhs.closestReference {
            return lhs.closestReference.localizedStandardCompare(rhs.closestReference) == .orderedAscending
        }
        return lhs.matchClass.rawValue.localizedStandardCompare(rhs.matchClass.rawValue) == .orderedAscending
    }

    private static func localizedStandardLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private static func optionalNumber(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    private static func formatNumber(_ value: Double) -> String {
        if value.rounded() == value && abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(format: "%.3f", value)
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }

    static func unmatchedSequenceID(for sequence: String) -> String {
        let normalized = sequence
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        var bytes = Array(SHA256.hash(data: Data(normalized.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
            bytes[8],
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }
}

enum FullLengthONTMHCUnifiedPivotWorkbookBuilder {
    static func buildRows(
        reportRows: [FullLengthONTMHCReportRow],
        unmatchedRows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow],
        sampleOrder: [String]
    ) -> [[String]] {
        let sampleNames = completeSampleOrder(sampleOrder, reportRows: reportRows, unmatchedRows: unmatchedRows)
        var rows = [[
            "call_type",
            "call_id",
            "display_name",
            "closest_reference",
            "match_class",
            "occurrence_count",
            "sample_count",
            "total_cluster_reads",
        ] + sampleNames]

        let knownCounts = reportRows.reduce(into: [String: [String: Int]]()) { counts, row in
            counts[row.genotype, default: [:]][row.sample, default: 0] += row.passedUniqueReads
        }
        for genotype in knownCounts.keys.sorted(by: localizedStandardLessThan) {
            let counts = knownCounts[genotype] ?? [:]
            let total = counts.values.reduce(0, +)
            rows.append([
                "known-allele",
                genotype,
                genotype,
                genotype,
                "exact",
                String(counts.values.filter { $0 > 0 }.count),
                String(counts.values.filter { $0 > 0 }.count),
                String(total),
            ] + sampleNames.map { sample in
                guard let count = counts[sample], count > 0 else { return "" }
                return String(count)
            })
        }

        let novelRows = unmatchedRows.filter { $0.closestMatch != nil || $0.rescueMatch != nil }
        let groupedNovel = Dictionary(grouping: novelRows) {
            FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder.unmatchedSequenceID(for: $0.sequence)
        }
        let orderedNovelIDs = groupedNovel.keys.sorted { lhs, rhs in
            let left = groupedNovel[lhs] ?? []
            let right = groupedNovel[rhs] ?? []
            let leftReads = left.reduce(0) { $0 + $1.clusterReads }
            let rightReads = right.reduce(0) { $0 + $1.clusterReads }
            if leftReads != rightReads { return leftReads > rightReads }
            if left.count != right.count { return left.count > right.count }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        for sequenceID in orderedNovelIDs {
            guard let group = groupedNovel[sequenceID] else { continue }
            let readsBySample = group.reduce(into: [String: Int]()) { totals, row in
                totals[row.sample, default: 0] += row.clusterReads
            }
            let representative = group.sorted(by: novelSort).first
            let closestReference = representative?.closestMatch?.closestReference
                ?? representative?.rescueMatch?.closestReference
                ?? ""
            let matchClass = representative?.closestMatch?.matchClass.rawValue
                ?? (representative?.rescueMatch == nil ? "" : "blast-rescue")
            rows.append([
                "novel-unmatched",
                sequenceID,
                "Novel:\(sequenceID)",
                closestReference,
                matchClass,
                String(group.count),
                String(readsBySample.values.filter { $0 > 0 }.count),
                String(group.reduce(0) { $0 + $1.clusterReads }),
            ] + sampleNames.map { sample in
                guard let count = readsBySample[sample], count > 0 else { return "" }
                return String(count)
            })
        }

        return rows
    }

    private static func completeSampleOrder(
        _ sampleOrder: [String],
        reportRows: [FullLengthONTMHCReportRow],
        unmatchedRows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for sample in sampleOrder where seen.insert(sample).inserted {
            result.append(sample)
        }
        let missing = Set(reportRows.map(\.sample) + unmatchedRows.map(\.sample))
            .subtracting(seen)
            .sorted(by: localizedStandardLessThan)
        result.append(contentsOf: missing)
        return result
    }

    private static func novelSort(
        _ lhs: FullLengthONTMHCUnmatchedClosestMatchWorkbookRow,
        _ rhs: FullLengthONTMHCUnmatchedClosestMatchWorkbookRow
    ) -> Bool {
        if lhs.clusterReads != rhs.clusterReads { return lhs.clusterReads > rhs.clusterReads }
        if lhs.sample != rhs.sample {
            return lhs.sample.localizedStandardCompare(rhs.sample) == .orderedAscending
        }
        return lhs.cluster.localizedStandardCompare(rhs.cluster) == .orderedAscending
    }

    private static func localizedStandardLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

private struct FullLengthONTMHCSampleSummary: Sendable, Codable, Equatable {
    let sample: String
    let totalInputReads: Int
    let clusterCount: Int
    let clusteredReads: Int
    let assignedReads: Int
    let unmatchedClusters: Int
    let cdnaClusters: Int
    let savontPreset: String
    let savontStatus: FullLengthONTMHCSavontSampleStatus
    let savontFallbackReason: String?
}

private struct FullLengthONTMHCSampleExecutionConfiguration: Sendable, Equatable {
    let workerThreads: Int
    let savontThreads: Int
}

private struct FullLengthONTMHCSavontAttemptResult: Sendable {
    let plan: FullLengthONTMHCSavontRunPlan
    let savontThreads: Int
    let savontSingleStrand: Bool
    let arguments: [String]
    let stderr: String
    let exitCode: Int32
    let startedAt: Date
    let completedAt: Date
}

private struct FullLengthONTMHCSavontClusteringResult: Sendable {
    let preset: FullLengthONTMHCSavontPreset
    let normalizedFASTAURL: URL
    let completedAttempt: FullLengthONTMHCSavontAttemptResult?
}

private struct FullLengthONTMHCSavontSelectedClusters: Sendable {
    let preset: FullLengthONTMHCSavontPreset
    let clustersFASTAURL: URL
    let fallbackReason: String?
    let handledSavontFailure: Bool
}

private struct FullLengthONTMHCSampleResult: Sendable, Codable {
    let originalIndex: Int
    let processingRank: Int
    let sample: String
    let readCount: Int
    let clustersFASTAURL: URL
    let clusterRecords: [FullLengthONTMHCClusterFASTARecord]
    let genotypeRows: [FullLengthONTMHCClusterGenotypeRow]
    let sampleSummary: FullLengthONTMHCSampleSummary
    let unmatchedClusters: [FullLengthONTMHCClusterFASTARecord]
    let cdnaMatchedClusters: [FullLengthONTMHCClusterFASTARecord]
    let closestMatches: [FullLengthONTMHCClosestMatch]
    let steps: [FullLengthONTMHCProvenanceStep]

    func rehydrated(
        originalIndex: Int,
        processingRank: Int,
        readCount: Int,
        prepSteps: [FullLengthONTMHCProvenanceStep],
        reuseStep: FullLengthONTMHCProvenanceStep
    ) -> FullLengthONTMHCSampleResult {
        FullLengthONTMHCSampleResult(
            originalIndex: originalIndex,
            processingRank: processingRank,
            sample: sample,
            readCount: readCount,
            clustersFASTAURL: clustersFASTAURL,
            clusterRecords: clusterRecords,
            genotypeRows: [],
            sampleSummary: FullLengthONTMHCSampleSummary(
                sample: sampleSummary.sample,
                totalInputReads: readCount,
                clusterCount: sampleSummary.clusterCount,
                clusteredReads: sampleSummary.clusteredReads,
                assignedReads: 0,
                unmatchedClusters: 0,
                cdnaClusters: 0,
                savontPreset: sampleSummary.savontPreset,
                savontStatus: sampleSummary.savontStatus,
                savontFallbackReason: sampleSummary.savontFallbackReason
            ),
            unmatchedClusters: [],
            cdnaMatchedClusters: [],
            closestMatches: [],
            steps: prepSteps + steps.filter { !$0.isRegenerablePreparationStep } + [reuseStep]
        )
    }

    func applyingAuthoritativeGenotypingSummary(
        _ summary: FullLengthONTMHCClusterGenotypingSummary
    ) -> FullLengthONTMHCSampleResult {
        let status: FullLengthONTMHCSavontSampleStatus
        if sampleSummary.savontStatus == .handledSavontFailure && clusterRecords.isEmpty {
            status = .handledSavontFailure
        } else {
            status = summary.rows.isEmpty ? .noCall : .called
        }
        return FullLengthONTMHCSampleResult(
            originalIndex: originalIndex,
            processingRank: processingRank,
            sample: sample,
            readCount: readCount,
            clustersFASTAURL: clustersFASTAURL,
            clusterRecords: clusterRecords,
            genotypeRows: summary.rows,
            sampleSummary: FullLengthONTMHCSampleSummary(
                sample: sample,
                totalInputReads: readCount,
                clusterCount: clusterRecords.count,
                clusteredReads: clusterRecords.reduce(0) { $0 + $1.readCount },
                assignedReads: summary.rows.reduce(0) { $0 + $1.clusterReads },
                unmatchedClusters: summary.unmatchedClusters.count,
                cdnaClusters: summary.cdnaMatchedClusters.count,
                savontPreset: sampleSummary.savontPreset,
                savontStatus: status,
                savontFallbackReason: sampleSummary.savontFallbackReason
            ),
            unmatchedClusters: summary.unmatchedClusters,
            cdnaMatchedClusters: summary.cdnaMatchedClusters,
            closestMatches: summary.closestMatches,
            steps: steps
        )
    }
}

private struct FullLengthONTMHCSampleCheckpoint: Sendable, Codable {
    static let schemaVersion = "full-length-ont-mhc-sample-checkpoint/3"

    let schemaVersion: String
    let signature: FullLengthONTMHCSampleCheckpointSignature
    let result: FullLengthONTMHCSampleResult
    let createdAt: Date

    init(
        signature: FullLengthONTMHCSampleCheckpointSignature,
        result: FullLengthONTMHCSampleResult,
        createdAt: Date
    ) {
        self.schemaVersion = Self.schemaVersion
        self.signature = signature
        self.result = result
        self.createdAt = createdAt
    }
}

private struct FullLengthONTMHCSampleCheckpointSignature: Sendable, Codable, Equatable {
    let sample: String
    let sourceFASTQ: FullLengthONTMHCFileFingerprint
    let preparedFASTQ: FullLengthONTMHCFileFingerprint
    let referenceFASTA: FullLengthONTMHCFileFingerprint
    let orientReference: FullLengthONTMHCFileFingerprint?
    let forwardPrimer: FullLengthONTMHCFileFingerprint?
    let reversePrimer: FullLengthONTMHCFileFingerprint?
    let minimumLength: Int
    let maximumLength: Int
    let savontQualityValueCutoff: Int
    let savontMinimumClusterSize: Int
    let minUnmatchedReads: Int
    let cdnaThreshold: Int
    let workerThreads: Int
    let savontThreads: Int
    let savontToolVersion: String
    let savontCondaEnvironment: String
    let savontPackageSpec: String
}

private struct FullLengthONTMHCFileFingerprint: Sendable, Codable, Equatable {
    let path: String
    let sha256: String
    let fileSizeBytes: UInt64

    static func fingerprint(url: URL) throws -> FullLengthONTMHCFileFingerprint {
        let standardized = url.standardizedFileURL
        if isDirectory(standardized) {
            return try directoryFingerprint(url: standardized)
        }
        let data = try Data(contentsOf: standardized)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return FullLengthONTMHCFileFingerprint(
            path: standardized.path,
            sha256: digest,
            fileSizeBytes: UInt64(data.count)
        )
    }

    private static func directoryFingerprint(url: URL) throws -> FullLengthONTMHCFileFingerprint {
        let fileManager = FileManager.default
        let files = try fileManager.subpathsOfDirectory(atPath: url.path)
            .sorted()
            .map { relativePath -> String in
                let fileURL = url.appendingPathComponent(relativePath)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    return "\(relativePath)\tdirectory\t0"
                }
                let data = try Data(contentsOf: fileURL)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                return "\(relativePath)\t\(digest)\t\(data.count)"
            }
        let manifest = files.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined()
        return FullLengthONTMHCFileFingerprint(
            path: url.path,
            sha256: digest,
            fileSizeBytes: UInt64(manifest.utf8.count)
        )
    }
}

private struct FullLengthONTMHCProvenanceStep: Sendable, Codable {
    let toolName: String
    let toolVersion: String
    let argv: [String]
    let inputs: [URL]
    let outputs: [URL]
    let exitStatus: Int32
    let stderr: String?
    let startedAt: Date
    let completedAt: Date

    var isRegenerablePreparationStep: Bool {
        switch toolName {
        case "vsearch", "bbduk.sh", "reformat.sh":
            return outputs.isEmpty
        default:
            return false
        }
    }

    func provenanceStep() throws -> ProvenanceStep {
        try ProvenanceStep(
            toolName: toolName,
            toolVersion: toolVersion,
            argv: argv,
            inputs: inputs.map {
                try fileDescriptor(url: $0, format: fileFormat(for: $0), role: .input)
            },
            outputs: outputs.map {
                try fileDescriptor(url: $0, format: fileFormat(for: $0), role: .output)
            },
            exitStatus: Int(exitStatus),
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: stderr?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : stderr,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func fileFormat(for url: URL) -> FileFormat {
        if SequenceFormat.from(url: url) == .fasta {
            return .fasta
        }
        if SequenceFormat.from(url: url) == .fastq {
            return .fastq
        }
        switch url.pathExtension.lowercased() {
        case "bam":
            return .bam
        case "sam":
            return .sam
        case "json":
            return .json
        case "csv", "tsv", "txt", "log":
            return .text
        default:
            return .unknown
        }
    }

    private func fileDescriptor(url: URL, format: FileFormat?, role: FileRole) throws -> ProvenanceFileDescriptor {
        if isDirectory(url) {
            return ProvenanceFileDescriptor(path: url.path, format: format, role: role)
        }
        return try ProvenanceFileDescriptor.file(url: url, format: format, role: role)
    }
}

private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}

enum FullLengthONTMHCXLSXPackageWriter {
    struct Sheet: Sendable, Equatable {
        let name: String
        let rows: [[String]]

        init(name: String, rows: [[String]]) {
            self.name = name
            self.rows = rows
        }
    }

    static func write(sheets: [Sheet], to url: URL) throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-full-length-mhc-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let rels = temp.appendingPathComponent("_rels", isDirectory: true)
        let xl = temp.appendingPathComponent("xl", isDirectory: true)
        let xlRels = xl.appendingPathComponent("_rels", isDirectory: true)
        let worksheets = xl.appendingPathComponent("worksheets", isDirectory: true)
        for directory in [rels, xlRels, worksheets] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try contentTypesXML(sheetCount: sheets.count).write(
            to: temp.appendingPathComponent("[Content_Types].xml"),
            atomically: true,
            encoding: .utf8
        )
        try rootRelsXML.write(to: rels.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        try workbookXML(sheetNames: sheets.map(\.name)).write(
            to: xl.appendingPathComponent("workbook.xml"),
            atomically: true,
            encoding: .utf8
        )
        try workbookRelsXML(sheetCount: sheets.count).write(
            to: xlRels.appendingPathComponent("workbook.xml.rels"),
            atomically: true,
            encoding: .utf8
        )
        for (index, sheet) in sheets.enumerated() {
            try worksheetXML(rows: sheet.rows).write(
                to: worksheets.appendingPathComponent("sheet\(index + 1).xml"),
                atomically: true,
                encoding: .utf8
            )
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-X", "-q", "-r", url.path, "[Content_Types].xml", "_rels", "xl"]
        process.currentDirectoryURL = temp
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FullLengthONTMHCGenotypingError.reportFailed("zip exited with \(process.terminationStatus)")
        }
    }
}

private let rootRelsXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
"""

private func contentTypesXML(sheetCount: Int) -> String {
    let sheets = (1...sheetCount).map {
        "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
    }.joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
    \(sheets)
    </Types>
    """
}

private func workbookXML(sheetNames: [String]) -> String {
    let sheets = sheetNames.enumerated().map { index, name in
        "<sheet name=\"\(xmlEscape(name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
    }.joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets>
    \(sheets)
      </sheets>
    </workbook>
    """
}

private func workbookRelsXML(sheetCount: Int) -> String {
    let rels = (1...sheetCount).map {
        "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>"
    }.joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    \(rels)
    </Relationships>
    """
}

private func worksheetXML(rows: [[String]]) -> String {
    let rowCount = max(rows.count, 1)
    let columnCount = max(rows.map(\.count).max() ?? 1, 1)
    let dimension = "A1:\(xlsxColumn(columnCount))\(rowCount)"
    let body = rows.enumerated().map { rowIndex, row in
        let cells = row.enumerated().map { columnIndex, value in
            let ref = "\(xlsxColumn(columnIndex + 1))\(rowIndex + 1)"
            return "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(xmlEscape(value))</t></is></c>"
        }.joined()
        return "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
    }.joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <dimension ref="\(dimension)"/>
      <sheetData>
    \(body)
      </sheetData>
    </worksheet>
    """
}

private func xlsxColumn(_ oneBasedIndex: Int) -> String {
    var value = oneBasedIndex
    var result = ""
    while value > 0 {
        value -= 1
        let scalar = UnicodeScalar(65 + (value % 26))!
        result.insert(Character(scalar), at: result.startIndex)
        value /= 26
    }
    return result
}

private func xmlEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}
