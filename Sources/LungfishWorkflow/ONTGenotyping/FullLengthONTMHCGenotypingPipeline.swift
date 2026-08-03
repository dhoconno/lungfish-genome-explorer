import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

private struct FullLengthONTMHCReviewCallKey: Hashable {
    let locus: String
    let genotype: String
}

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

    public var rawUnmatchedConsensusesFASTAURL: URL {
        outputDirectory
            .appendingPathComponent("artifacts/internal", isDirectory: true)
            .appendingPathComponent("raw-unmatched-consensuses.fasta")
    }

    public var rawUnmatchedConsensusDecisionsJSONURL: URL {
        outputDirectory
            .appendingPathComponent("artifacts/internal", isDirectory: true)
            .appendingPathComponent("raw-unmatched-consensus-decisions.json")
    }

    public var cdnaClustersFASTAURL: URL {
        outputDirectory.appendingPathComponent("cdna_clusters.fasta")
    }

    public var provenanceURL: URL {
        outputDirectory.appendingPathComponent("full-length-ont-mhc-genotyping-provenance.json")
    }

    public var failureProvenanceURL: URL {
        URL(fileURLWithPath: outputDirectory.standardizedFileURL.path + ".failed.lungfish-provenance.json")
    }

    var legacyPublicationFailureProvenanceURL: URL {
        outputDirectory.deletingLastPathComponent().appendingPathComponent(
            ".\(outputDirectory.lastPathComponent).publication-failure.json"
        )
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
    case candidateArtifactWorkDirectory
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
    public let reciprocalEvidenceBAMURL: URL?
    public let reciprocalEvidenceBAIURL: URL?
    public let candidateAllelesJSONURL: URL?
    public let candidateAllelesFASTAURL: URL?
    public let candidateAllelesGenBankURL: URL?
    public let unnameableClustersJSONURL: URL?
    public let unnameableClustersFASTAURL: URL?
    public let unnameableClustersGenBankURL: URL?
    public let cleanupWarnings: [FullLengthONTMHCGenotypingCleanupWarning]
}

private struct FullLengthONTMHCStagedRunResult: Sendable {
    let result: FullLengthONTMHCGenotypingResult
    let cohortWorkDirectory: URL
    let cohortTemporaryWorkDirectory: URL
    let candidateWorkDirectory: URL
}

private struct GenotypingWorkDirectoryDisposition: Codable, Sendable {
    let path: String
    let disposition: String
    let error: String?
}

private struct GenotypingWorkDirectoryDispositionEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let runID: UUID
    let entries: [GenotypingWorkDirectoryDisposition]
}

private struct FullLengthWorkDirectoryCleanupResult: Sendable {
    var warnings: [FullLengthONTMHCGenotypingCleanupWarning]
    var dispositions: [GenotypingWorkDirectoryDisposition]
}

private struct FullLengthFailureProvenancePreparationError: Error, LocalizedError {
    let inputPath: String
    let operation: String
    let underlyingDescription: String
    let initiatingFailureDescription: String?

    init(
        inputURL: URL,
        operation: String,
        underlyingError: Error,
        initiatingError: Error? = nil
    ) {
        self.inputPath = inputURL.standardizedFileURL.path
        self.operation = operation
        self.underlyingDescription = underlyingError.localizedDescription
        self.initiatingFailureDescription = initiatingError?.localizedDescription
    }

    var errorDescription: String? {
        let initiating = initiatingFailureDescription.map {
            " after initiating failure (\($0))"
        } ?? ""
        return "failure-provenance input preparation failed for \(inputPath) while \(operation)\(initiating): \(underlyingDescription)"
    }
}

private struct FullLengthFailureProvenancePreparationReceipt: Codable {
    let schemaVersion: Int
    let kind: String
    let runID: UUID
    let workflowName: String
    let workflowVersion: String
    let toolName: String
    let toolVersion: String
    let argv: [String]
    let durableReplayArgv: [String]
    let reproducibleCommand: String
    let options: ProvenanceOptions
    let runtimeIdentity: ProvenanceRuntimeIdentity
    let inputPath: String
    let preparationError: String
    let originalError: String
    let startedAt: Date
    let completedAt: Date
    let wallTimeSeconds: TimeInterval
    let exitStatus: Int
    let stderr: String
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
        case reciprocalEvidenceBAMURL
        case reciprocalEvidenceBAIURL
        case candidateAllelesJSONURL
        case candidateAllelesFASTAURL
        case candidateAllelesGenBankURL
        case unnameableClustersJSONURL
        case unnameableClustersFASTAURL
        case unnameableClustersGenBankURL
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
        reciprocalEvidenceBAMURL = try container.decodeIfPresent(URL.self, forKey: .reciprocalEvidenceBAMURL)
        reciprocalEvidenceBAIURL = try container.decodeIfPresent(URL.self, forKey: .reciprocalEvidenceBAIURL)
        candidateAllelesJSONURL = try container.decodeIfPresent(URL.self, forKey: .candidateAllelesJSONURL)
        candidateAllelesFASTAURL = try container.decodeIfPresent(URL.self, forKey: .candidateAllelesFASTAURL)
        candidateAllelesGenBankURL = try container.decodeIfPresent(URL.self, forKey: .candidateAllelesGenBankURL)
        unnameableClustersJSONURL = try container.decodeIfPresent(URL.self, forKey: .unnameableClustersJSONURL)
        unnameableClustersFASTAURL = try container.decodeIfPresent(URL.self, forKey: .unnameableClustersFASTAURL)
        unnameableClustersGenBankURL = try container.decodeIfPresent(URL.self, forKey: .unnameableClustersGenBankURL)
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
        try container.encodeIfPresent(reciprocalEvidenceBAMURL, forKey: .reciprocalEvidenceBAMURL)
        try container.encodeIfPresent(reciprocalEvidenceBAIURL, forKey: .reciprocalEvidenceBAIURL)
        try container.encodeIfPresent(candidateAllelesJSONURL, forKey: .candidateAllelesJSONURL)
        try container.encodeIfPresent(candidateAllelesFASTAURL, forKey: .candidateAllelesFASTAURL)
        try container.encodeIfPresent(candidateAllelesGenBankURL, forKey: .candidateAllelesGenBankURL)
        try container.encodeIfPresent(unnameableClustersJSONURL, forKey: .unnameableClustersJSONURL)
        try container.encodeIfPresent(unnameableClustersFASTAURL, forKey: .unnameableClustersFASTAURL)
        try container.encodeIfPresent(unnameableClustersGenBankURL, forKey: .unnameableClustersGenBankURL)
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

private enum FullLengthONTMHCWorkbookTintDefaults {
    static let sharedNovel = "F5D78E"
    static let singletonNovel = "F5B97A"
    static let sharedExtension = "A8D8D0"
    static let singletonExtension = "AFCBF2"
}

struct FullLengthONTMHCWorkbookProjectionInputDocument: Codable, Equatable, Sendable {
    static let schemaVersion = 2

    struct SourceSummary: Codable, Equatable, Sendable {
        let reportRowCount: Int
        let sampleSummaryCount: Int
        let genotypeRowCount: Int
        let unmatchedClusterRowCount: Int
        let orderedAlleleCount: Int
        let includesHaplotypeAnalysis: Bool
        let candidateRecordCount: Int
        let unnameableRecordCount: Int
        let normalizedUnmatchedRowCount: Int
        let referenceRecordCount: Int
    }

    let schemaVersion: Int
    let tintARGB: [String: String]
    let sourceSummary: SourceSummary
    let sheets: [FullLengthONTMHCXLSXPackageWriter.Sheet]

    init(sourceSummary: SourceSummary, sheets: [FullLengthONTMHCXLSXPackageWriter.Sheet]) {
        schemaVersion = Self.schemaVersion
        tintARGB = [
            FullLengthONTMHCWorkbookTintCategory.sharedNovel.rawValue: FullLengthONTMHCWorkbookTintDefaults.sharedNovel,
            FullLengthONTMHCWorkbookTintCategory.singletonNovel.rawValue: FullLengthONTMHCWorkbookTintDefaults.singletonNovel,
            FullLengthONTMHCWorkbookTintCategory.sharedExtension.rawValue: FullLengthONTMHCWorkbookTintDefaults.sharedExtension,
            FullLengthONTMHCWorkbookTintCategory.singletonExtension.rawValue: FullLengthONTMHCWorkbookTintDefaults.singletonExtension,
        ]
        self.sourceSummary = sourceSummary
        self.sheets = sheets
    }
}

private struct FullLengthONTMHCReferenceInputManifest: Decodable {
    let recordStore: RecordStore?

    enum CodingKeys: String, CodingKey {
        case recordStore = "record_store"
    }

    struct RecordStore: Decodable {
        let databasePath: String

        enum CodingKeys: String, CodingKey {
            case databasePath = "database_path"
        }
    }
}

struct FullLengthONTMHCReferenceCatalogProjection: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let cdnaThreshold: Int
    let records: [MHCReferenceRecord]

    init(cdnaThreshold: Int, records: [MHCReferenceRecord]) {
        schemaVersion = Self.schemaVersion
        self.cdnaThreshold = cdnaThreshold
        self.records = records
    }
}

struct FullLengthONTMHCRawUnmatchedDecisionDocument: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let rows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case rows
    }

    init(rows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow]) {
        schemaVersion = Self.schemaVersion
        self.rows = rows.sorted {
            if $0.sample != $1.sample {
                return $0.sample < $1.sample
            }
            if $0.cluster != $1.cluster {
                return $0.cluster < $1.cluster
            }
            if $0.candidateSequence != $1.candidateSequence {
                return $0.candidateSequence < $1.candidateSequence
            }
            return $0.clusterReads < $1.clusterReads
        }
    }
}

private struct FullLengthONTMHCReferenceCatalogInputs: Sendable, Equatable {
    let fastaURL: URL
    let manifestURL: URL?
    let recordStoreURL: URL?

    var allURLs: [URL] {
        [fastaURL, manifestURL, recordStoreURL].compactMap { $0 }
    }
}

private enum FullLengthONTMHCSavontSampleStatus: String, Sendable, Codable, Equatable {
    case called
    case noCall = "no-call"
    case handledSavontFailure = "handled-savont-failure"
}

enum FullLengthONTMHCMetadataPublicationEvent: Sendable, Equatable {
    case runLockAcquired(lockURL: URL)
    case candidateArtifactsStaged(outputDirectoryURL: URL)
    case provenanceWrittenBeforeManifestPublication(
        stagedManifestURL: URL,
        finalManifestURL: URL,
        provenanceURL: URL
    )
    case resultBundlePublishedBeforeReceipt(
        stagedDirectoryURL: URL,
        finalDirectoryURL: URL
    )
    case provenanceFinalizedBeforeManifestPublication(
        finalManifestURL: URL,
        provenanceURL: URL
    )
    case successManifestPublished(
        finalManifestURL: URL,
        provenanceURL: URL
    )
}

enum FullLengthONTMHCExclusivePublicationTarget: Sendable, Equatable {
    case resultBundle
    case successManifest
}

private struct FullLengthONTMHCSuccessManifestPublicationPlan: Sendable {
    let stagedURL: URL
    let finalURL: URL
    let stagedDescriptor: ProvenanceFileDescriptor
    let finalDescriptor: ProvenanceFileDescriptor
}

private struct FullLengthONTMHCReferenceVisualizationPublication: Sendable {
    let descriptor: ONTMHCReferenceVisualizationArtifacts
    let recordsJSONURL: URL
    let genBankURL: URL
    let fastaURL: URL

    var outputURLs: [URL] {
        [recordsJSONURL, genBankURL, fastaURL]
    }
}

private struct FullLengthONTMHCReferenceVisualizationPublicationError: Error, LocalizedError {
    let step: ProvenanceStep
    let underlyingLocalizedDescription: String

    var errorDescription: String? {
        "MHC reference visualization extraction failed: \(underlyingLocalizedDescription)"
    }
}

private struct FullLengthONTMHCResultBundlePublicationRecord: Sendable {
    let stagedDirectoryURL: URL
    let finalDirectoryURL: URL
    let payloadMappings: [(staged: ProvenanceFileDescriptor, final: ProvenanceFileDescriptor)]
    let replacingExisting: Bool
    let publicationMechanism: String
    let successManifestMechanism: String
    let fallbackReason: String?
    let startedAt: Date
    let completedAt: Date

    let exitStatus: Int32
    let errorMessage: String?

    private var receiptStartedAt: Date {
        Self.receiptDate(startedAt)
    }

    private var receiptCompletedAt: Date {
        Self.receiptDate(completedAt)
    }

    private static func receiptDate(_ date: Date) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: formatter.string(from: date)) ?? date
    }

    var provenanceStep: ProvenanceStep {
        let mode = replacingExisting ? "replace" : "create"
        let argv = [
            "lungfish-internal", "publish-result-bundle",
            "--mode", mode,
            "--atomic-mechanism", publicationMechanism,
            "--success-manifest-mechanism", successManifestMechanism,
            stagedDirectoryURL.path,
            finalDirectoryURL.path,
        ]
        var resolvedOptions: [String: ParameterValue] = [
            "publicationMode": .string(mode),
            "atomicMechanism": .string(publicationMechanism),
            "successManifestMechanism": .string(successManifestMechanism),
        ]
        if let fallbackReason {
            resolvedOptions["fallbackReason"] = .string(fallbackReason)
        }
        return ProvenanceStep(
            toolName: "lungfish-internal publish-result-bundle",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            resolvedOptions: resolvedOptions,
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: payloadMappings.map(\.staged),
            outputs: payloadMappings.map(\.final),
            exitStatus: Int(exitStatus),
            wallTimeSeconds: receiptCompletedAt.timeIntervalSince(receiptStartedAt),
            stderr: errorMessage,
            startedAt: receiptStartedAt,
            completedAt: receiptCompletedAt
        )
    }

    func recordingSuccessManifestFallback(reason: String) -> Self {
        .init(
            stagedDirectoryURL: stagedDirectoryURL,
            finalDirectoryURL: finalDirectoryURL,
            payloadMappings: payloadMappings,
            replacingExisting: replacingExisting,
            publicationMechanism: publicationMechanism,
            successManifestMechanism: "exclusive-file-reservation-then-rename",
            fallbackReason: [fallbackReason, reason].compactMap { $0 }.joined(separator: "; "),
            startedAt: startedAt,
            completedAt: completedAt,
            exitStatus: exitStatus,
            errorMessage: errorMessage
        )
    }
}

private struct FullLengthONTMHCResultBundlePublicationError: Error, LocalizedError, Sendable {
    let record: FullLengthONTMHCResultBundlePublicationRecord

    var errorDescription: String? {
        "Could not atomically publish the complete MHC result bundle: \(record.errorMessage ?? "unknown error")"
    }
}

private struct FullLengthONTMHCExclusiveRenameUnsupportedError: Error, LocalizedError, Sendable {
    let targetDescription: String
    let code: POSIXErrorCode

    var errorDescription: String? {
        "renameatx_np(RENAME_EXCL) is unavailable for \(targetDescription): \(POSIXError(code).localizedDescription)"
    }
}

private struct FullLengthONTMHCRollbackFailureRecovery: Sendable {
    let retainedPriorGenerationURL: URL?
    let retainedFailedPublishedGenerationURL: URL?
    let quarantineError: String?

    var retainedRoots: [URL] {
        [retainedPriorGenerationURL, retainedFailedPublishedGenerationURL].compactMap { $0 }
    }
}

struct FullLengthONTMHCReviewCatalogAuthority: Sendable {
    let referenceRecords: [MHCReferenceRecord]
    let candidateDocument: ONTMHCCandidateAllelesDocument
    let unnameableDocument: ONTMHCUnnameableClustersDocument?
    let snapshots: [GenotypeReviewAuthorityFileSnapshot]

    func requireUnchanged() throws {
        for snapshot in snapshots {
            try snapshot.requireUnchanged()
        }
    }
}

public struct FullLengthONTMHCGenotypingPipeline: Sendable {
    private let nativeToolRunner: NativeToolRunner
    private let condaManager: CondaManager
    private let postPublicationWorkDirectoryCleaner: any FullLengthONTMHCWorkDirectoryCleaning
    private let metadataPublicationObserver: @Sendable (FullLengthONTMHCMetadataPublicationEvent) throws -> Void
    private let rollbackOperationObserver: @Sendable () throws -> Void
    private let cleanupJournalObserver:
        @Sendable (GenotypingCleanupJournalEvent) throws -> Void
    private let exclusivePublicationFailureInjector: @Sendable (FullLengthONTMHCExclusivePublicationTarget) throws -> Int32?
    private let reviewableRowCatalogPublisher:
        @Sendable (
            GenotypeReviewableRowCatalogInputs,
            URL,
            @escaping @Sendable () throws -> Void
        ) throws -> GenotypeReviewableRowCatalogPublication

    static func reviewableCatalogAuthority(
        expectedReferenceRecords: [MHCReferenceRecord],
        referenceCatalogURL: URL,
        expectedCandidateDocument: ONTMHCCandidateAllelesDocument,
        candidateURL: URL,
        expectedUnnameableDocument: ONTMHCUnnameableClustersDocument? = nil,
        unnameableURL: URL? = nil,
        authorityObserver: () throws -> Void = {}
    ) throws -> FullLengthONTMHCReviewCatalogAuthority {
        let referenceSnapshot = try GenotypeReviewAuthorityFileSnapshot.capture(
            referenceCatalogURL
        )
        let candidateSnapshot = try GenotypeReviewAuthorityFileSnapshot.capture(
            candidateURL
        )
        let unnameableSnapshot = try unnameableURL.map {
            try GenotypeReviewAuthorityFileSnapshot.capture($0)
        }
        let referenceProjection = try JSONDecoder().decode(
            FullLengthONTMHCReferenceCatalogProjection.self,
            from: referenceSnapshot.data
        )
        let candidateDocument = try JSONDecoder().decode(
            ONTMHCCandidateAllelesDocument.self,
            from: candidateSnapshot.data
        )
        guard referenceProjection.records == expectedReferenceRecords else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(referenceCatalogURL.path)
        }
        guard candidateDocument == expectedCandidateDocument else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(candidateURL.path)
        }
        let unnameableDocument = try unnameableSnapshot.map {
            try JSONDecoder().decode(
                ONTMHCUnnameableClustersDocument.self,
                from: $0.data
            )
        }
        guard unnameableDocument == expectedUnnameableDocument else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(unnameableURL?.path ?? candidateURL.path)
        }
        try authorityObserver()
        try referenceSnapshot.requireUnchanged()
        try candidateSnapshot.requireUnchanged()
        try unnameableSnapshot?.requireUnchanged()
        return FullLengthONTMHCReviewCatalogAuthority(
            referenceRecords: referenceProjection.records,
            candidateDocument: candidateDocument,
            unnameableDocument: unnameableDocument,
            snapshots: [referenceSnapshot, candidateSnapshot] + [unnameableSnapshot].compactMap { $0 }
        )
    }

    public init(
        nativeToolRunner: NativeToolRunner = .shared,
        condaManager: CondaManager = .shared,
        postPublicationWorkDirectoryCleaner: any FullLengthONTMHCWorkDirectoryCleaning = DefaultFullLengthONTMHCWorkDirectoryCleaner()
    ) {
        self.nativeToolRunner = nativeToolRunner
        self.condaManager = condaManager
        self.postPublicationWorkDirectoryCleaner = postPublicationWorkDirectoryCleaner
        self.metadataPublicationObserver = { _ in }
        self.rollbackOperationObserver = {}
        self.cleanupJournalObserver = { _ in }
        self.exclusivePublicationFailureInjector = { _ in nil }
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
        nativeToolRunner: NativeToolRunner,
        condaManager: CondaManager,
        postPublicationWorkDirectoryCleaner: any FullLengthONTMHCWorkDirectoryCleaning,
        metadataPublicationObserver: @escaping @Sendable (FullLengthONTMHCMetadataPublicationEvent) throws -> Void,
        rollbackOperationObserver: @escaping @Sendable () throws -> Void = {},
        cleanupJournalObserver:
            @escaping @Sendable (GenotypingCleanupJournalEvent) throws -> Void = { _ in },
        exclusivePublicationFailureInjector: @escaping @Sendable (FullLengthONTMHCExclusivePublicationTarget) throws -> Int32? = { _ in nil },
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
        self.nativeToolRunner = nativeToolRunner
        self.condaManager = condaManager
        self.postPublicationWorkDirectoryCleaner = postPublicationWorkDirectoryCleaner
        self.metadataPublicationObserver = metadataPublicationObserver
        self.rollbackOperationObserver = rollbackOperationObserver
        self.cleanupJournalObserver = cleanupJournalObserver
        self.exclusivePublicationFailureInjector = exclusivePublicationFailureInjector
        self.reviewableRowCatalogPublisher = reviewableRowCatalogPublisher
    }

    public func run(
        _ request: FullLengthONTMHCGenotypingRunRequest,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> FullLengthONTMHCGenotypingResult {
        let runStartedAt = Date()
        let lifecycleRunID = UUID()
        let lifecycleProcessIdentity = try OwnedProcessIdentity.current()
        let runLock = try DarwinFullLengthONTMHCRunLock.acquire(
            outputDirectoryURL: request.outputDirectory
        )
        defer { runLock.release() }
        let finalOutputURL = request.outputDirectory.standardizedFileURL
        let stagedOutputURL = finalOutputURL.deletingLastPathComponent().appendingPathComponent(
            ".\(finalOutputURL.lastPathComponent).run-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let lifecycleProjectRoot = (request.projectURL
            ?? stagedOutputURL.deletingLastPathComponent()).standardizedFileURL
        var finalExisted = false
        var failureEnvelopeSnapshot: ProvenanceEnvelope?
        var successfulPublicationRecordSnapshot: FullLengthONTMHCResultBundlePublicationRecord?
        var rollbackStepSnapshot: ProvenanceStep?
        var rollbackFailureRecovery: FullLengthONTMHCRollbackFailureRecovery?
        do {
            try metadataPublicationObserver(.runLockAcquired(lockURL: runLock.lockURL))
            try validateInputs(request)
            finalExisted = try FullLengthONTMHCAlignmentSafety().requireOptionalDirectoryEntryNoFollow(
                finalOutputURL,
                role: "final output bundle directory"
            )
            try FileManager.default.createDirectory(
                at: stagedOutputURL,
                withIntermediateDirectories: false
            )
            try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
                stagedOutputURL,
                request: OwnedWorkDirectoryCreationRequest(
                    projectURL: lifecycleProjectRoot,
                    parentDirectoryURL: stagedOutputURL.deletingLastPathComponent(),
                    prefix: ".full-length-ont-mhc-staging-",
                    runID: lifecycleRunID,
                    processIdentity: lifecycleProcessIdentity,
                    state: .active,
                    lockRelativePath: projectRelativePath(
                        runLock.lockURL,
                        projectRoot: lifecycleProjectRoot
                    ),
                    keepIntermediates: request.keepIntermediates,
                    toolName: "lungfish fastq full-length-ont-mhc-genotype",
                    toolVersion: WorkflowRun.currentAppVersion
                )
            )
            if finalExisted, request.reuseCompatibleCheckpoints {
                try importRequestedCheckpointGeneration(
                    request: request,
                    priorFinalOutputURL: finalOutputURL,
                    stagedOutputURL: stagedOutputURL
                )
            }
            let stagedRequest = request.replacingOutput(
                outputDirectory: stagedOutputURL,
                outputName: request.outputName
            )
            let stagedRun = try await runStaged(
                stagedRequest,
                logicalFinalOutputURL: finalOutputURL,
                progressHandler: progressHandler
            )
            let stagedResult = stagedRun.result
            try Task.checkCancellation()
            try finalizeStagedBundleMetadata(
                stagedOutputURL: stagedOutputURL,
                finalOutputURL: finalOutputURL
            )
            try Task.checkCancellation()
            let publicationMappings = try resultBundlePublicationMappings(
                stagedOutputURL: stagedOutputURL,
                finalOutputURL: finalOutputURL
            )
            var publicationRecord = try publishStagedResultBundle(
                stagedOutputURL: stagedOutputURL,
                finalOutputURL: finalOutputURL,
                replacingExisting: finalExisted,
                payloadMappings: publicationMappings
            )
            successfulPublicationRecordSnapshot = publicationRecord
            do {
                try metadataPublicationObserver(.resultBundlePublishedBeforeReceipt(
                    stagedDirectoryURL: stagedOutputURL,
                    finalDirectoryURL: finalOutputURL
                ))
                try appendActualResultBundlePublicationReceipt(
                    publicationRecord,
                    provenanceURL: finalOutputURL.appendingPathComponent(
                        "full-length-ont-mhc-genotyping-provenance.json"
                    )
                )
                let finalProvenanceURL = finalOutputURL.appendingPathComponent(
                    "full-length-ont-mhc-genotyping-provenance.json"
                )
                let finalManifestURL = ONTGenotypeResultBundle.manifestURL(in: finalOutputURL)
                try metadataPublicationObserver(.provenanceFinalizedBeforeManifestPublication(
                    finalManifestURL: finalManifestURL,
                    provenanceURL: finalProvenanceURL
                ))
                publicationRecord = try publishRelocatedSuccessManifest(
                    in: finalOutputURL,
                    publicationRecord: publicationRecord
                )
                successfulPublicationRecordSnapshot = publicationRecord
                try OwnedWorkDirectoryMarkerStore.transition(
                    finalOutputURL,
                    expectedProjectURL: lifecycleProjectRoot,
                    expectedRunID: lifecycleRunID,
                    to: .completed
                )
                try FileManager.default.removeItem(
                    at: finalOutputURL.appendingPathComponent(
                        OwnedWorkDirectoryMarker.fileName
                    )
                )
                try metadataPublicationObserver(.successManifestPublished(
                    finalManifestURL: finalManifestURL,
                    provenanceURL: finalProvenanceURL
                ))
            } catch {
                failureEnvelopeSnapshot = try? ProvenanceEnvelopeReader.load(
                    fromSidecar: finalOutputURL.appendingPathComponent(
                        "full-length-ont-mhc-genotyping-provenance.json"
                    )
                )
                let rollbackStartedAt = Date()
                do {
                    try rollbackPublishedResultBundle(
                        stagedOutputURL: stagedOutputURL,
                        finalOutputURL: finalOutputURL,
                        replacingExisting: finalExisted
                    )
                    rollbackStepSnapshot = rollbackProvenanceStep(
                        for: publicationRecord,
                        startedAt: rollbackStartedAt,
                        completedAt: Date(),
                        exitStatus: 0,
                        errorMessage: nil
                    )
                } catch let rollbackError {
                    let recovery = retainRollbackFailureGenerations(
                        after: publicationRecord
                    )
                    rollbackFailureRecovery = recovery
                    let rollbackErrorText = [
                        rollbackError.localizedDescription,
                        recovery.quarantineError,
                    ].compactMap { $0 }.joined(separator: "; ")
                    rollbackStepSnapshot = rollbackProvenanceStep(
                        for: publicationRecord,
                        startedAt: rollbackStartedAt,
                        completedAt: Date(),
                        exitStatus: 1,
                        errorMessage: rollbackErrorText,
                        recovery: recovery
                    )
                    throw FullLengthONTMHCGenotypingError.reportFailed(
                        "Post-publication metadata failed (\(error.localizedDescription)); rollback also failed (\(rollbackError.localizedDescription))."
                    )
                }
                throw error
            }
            let cleanupPlan = try beginSuccessfulCleanupJournal(
                projectRoot: lifecycleProjectRoot,
                runID: lifecycleRunID,
                stagedRun: stagedRun,
                finalOutputURL: finalOutputURL,
                retiredPublicationURL:
                    finalExisted
                        && FileManager.default.fileExists(
                            atPath: stagedOutputURL.path
                        )
                        ? stagedOutputURL
                        : nil,
                keepIntermediates: request.keepIntermediates
            )
            var publicationCleanup = completeSuccessfulWorkDirectoryLifecycle(
                stagedRun: stagedRun,
                finalOutputURL: finalOutputURL,
                projectRoot: lifecycleProjectRoot,
                runID: lifecycleRunID,
                keepIntermediates: request.keepIntermediates,
                cleanupPlan: cleanupPlan
            )
            if finalExisted, cleanupPlan.entry(for: stagedOutputURL) != nil {
                let disposition = identityBoundRemovalDisposition(
                    plan: cleanupPlan,
                    url: stagedOutputURL,
                    successDisposition: "removed"
                ) {
                    try FileManager.default.removeItem(at: $0)
                }
                publicationCleanup.dispositions.append(disposition)
                if let error = disposition.error {
                    publicationCleanup.warnings.append(.init(
                        kind: .retiredCohortPublicationDirectory,
                        path: stagedOutputURL.path,
                        error: error,
                        publishedArtifactsRemainValid: true
                    ))
                }
            }
            try appendSuccessfulCleanupDisposition(
                projectRoot: lifecycleProjectRoot,
                runID: lifecycleRunID,
                outputBundleURL: finalOutputURL,
                dispositions: publicationCleanup.dispositions
            )
            return relocatedResult(
                stagedResult,
                from: stagedOutputURL,
                to: finalOutputURL,
                additionalCleanupWarnings: publicationCleanup.warnings
            )
        } catch let journalError as GenotypingCleanupJournalError {
            throw journalError
        } catch {
            let partialEnvelope = failureEnvelopeSnapshot ?? loadPartialFailureEnvelope(
                stagedOutputURL: stagedOutputURL,
                finalOutputURL: finalOutputURL,
                finalExistedBeforeRun: finalExisted
            )
            let priorFailureEnvelopeData = try? Data(
                contentsOf: request.failureProvenanceURL
            )
            let failedPublicationRecord = (error as? FullLengthONTMHCResultBundlePublicationError)?.record
            var reportedError: Error = error
            var retainedFailureDiagnosticRoots = rollbackFailureRecovery?.retainedRoots ?? []
            let candidateWorkDirectory = candidateArtifactWorkDirectory(for: stagedOutputURL)
            if FileManager.default.fileExists(atPath: candidateWorkDirectory.path) {
                do {
                    if let retainedLogsURL = try retainCandidateFailureLogs(
                        from: candidateWorkDirectory,
                        for: request
                    ) {
                        retainedFailureDiagnosticRoots.append(retainedLogsURL)
                    }
                } catch let candidateLogRetentionError {
                    reportedError = FullLengthONTMHCGenotypingError.reportFailed(
                        "Run failed (\(error.localizedDescription)); candidate failure-log retention also failed (\(candidateLogRetentionError.localizedDescription))."
                    )
                }
            }
            let historyWriter = ProjectOperationHistoryWriter(
                projectURL: lifecycleProjectRoot
            )
            do {
                try writeFailureProvenance(
                    request: request,
                    stagedOutputURL: stagedOutputURL,
                    startedAt: runStartedAt,
                    error: reportedError,
                    partialEnvelope: partialEnvelope,
                    failedPublicationRecord: failedPublicationRecord,
                    successfulPublicationRecord: successfulPublicationRecordSnapshot,
                    rollbackStep: rollbackStepSnapshot,
                    rollbackFailureRecovery: rollbackFailureRecovery,
                    additionalDiagnosticRoots: retainedFailureDiagnosticRoots
                )
                let failureData = try Data(contentsOf: request.failureProvenanceURL)
                var historyPayloads = ["failure-provenance.json": failureData]
                if let priorFailureEnvelopeData {
                    historyPayloads["superseded-prior-failure-provenance.json"] =
                        priorFailureEnvelopeData
                }
                _ = try historyWriter.createOperation(
                    operationID: lifecycleRunID,
                    payloads: historyPayloads
                )
            } catch let preparationError as FullLengthFailureProvenancePreparationError {
                let originalFailure = reportedError
                reportedError = FullLengthONTMHCGenotypingError.reportFailed(
                    "Run failed (\(originalFailure.localizedDescription)); \(preparationError.localizedDescription)."
                )
                do {
                    let receiptData = try failureProvenancePreparationReceiptData(
                        request: request,
                        runID: lifecycleRunID,
                        startedAt: runStartedAt,
                        originalError: originalFailure,
                        preparationError: preparationError,
                        rollbackFailureRecovery: rollbackFailureRecovery
                    )
                    var historyPayloads = [
                        "failure-provenance-preparation-error.json": receiptData,
                    ]
                    if let priorFailureEnvelopeData {
                        historyPayloads["prior-failure-provenance.json"] =
                            priorFailureEnvelopeData
                    }
                    _ = try historyWriter.createOperation(
                        operationID: lifecycleRunID,
                        payloads: historyPayloads
                    )
                    if FileManager.default.fileExists(
                        atPath: request.failureProvenanceURL.path
                    ) {
                        do {
                            try FileManager.default.removeItem(
                                at: request.failureProvenanceURL
                            )
                        } catch {
                            reportedError = FullLengthONTMHCGenotypingError.reportFailed(
                                "Run failed (\(reportedError.localizedDescription)); stale failed-run provenance could not be retired (\(error.localizedDescription))."
                            )
                        }
                    }
                } catch let receiptError {
                    throw FullLengthONTMHCGenotypingError.reportFailed(
                        "Run failed (\(reportedError.localizedDescription)); incomplete failure-provenance preparation receipt also could not be written (\(receiptError.localizedDescription))."
                    )
                }
            } catch let provenanceError {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Run failed (\(reportedError.localizedDescription)); failed-run provenance also could not be written (\(provenanceError.localizedDescription))."
                )
            }
            let retainedRecoveryPaths = Set(
                rollbackFailureRecovery?.retainedRoots.map { $0.standardizedFileURL.path } ?? []
            )
            let dispositions = failCurrentRunWorkDirectories(
                stagedOutputURL: stagedOutputURL,
                projectRoot: lifecycleProjectRoot,
                runID: lifecycleRunID,
                keepIntermediates: request.keepIntermediates,
                retainedRecoveryPaths: retainedRecoveryPaths
            )
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let dispositionData = try encoder.encode(
                    GenotypingWorkDirectoryDispositionEnvelope(
                        schemaVersion: 1,
                        runID: lifecycleRunID,
                        entries: dispositions
                    )
                )
                try historyWriter.append(
                    dispositionData,
                    named: "cleanup-disposition.json",
                    toOperation: lifecycleRunID
                )
            } catch let dispositionError {
                reportedError = FullLengthONTMHCGenotypingError.reportFailed(
                    "Run failed (\(reportedError.localizedDescription)); cleanup disposition could not be appended for current-run roots (\(dispositionError.localizedDescription))."
                )
            }
            let cleanupFailures = dispositions.filter { $0.error != nil }
            if !cleanupFailures.isEmpty {
                let details = cleanupFailures.map {
                    "\($0.path): \($0.error ?? "unknown cleanup error")"
                }.joined(separator: "; ")
                reportedError = FullLengthONTMHCGenotypingError.reportFailed(
                    "Run failed (\(reportedError.localizedDescription)); current-run work cleanup failed: \(details)"
                )
            }
            throw reportedError
        }
    }

    private func runStaged(
        _ request: FullLengthONTMHCGenotypingRunRequest,
        logicalFinalOutputURL: URL,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> FullLengthONTMHCStagedRunResult {
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

        let referenceCatalogProjectionURL = request.outputDirectory
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("reference", isDirectory: true)
            .appendingPathComponent("mhc-reference-catalog.json")
        let referenceCatalog = try materializeMHCReferenceCatalog(
            sourceURL: request.referenceSourceURL,
            fastaURL: referenceFASTAURL,
            cdnaThreshold: request.cdnaThreshold,
            outputURL: referenceCatalogProjectionURL
        )

        try Data().write(to: request.unmatchedClustersFASTAURL, options: .atomic)
        try Data().write(to: request.cdnaClustersFASTAURL, options: .atomic)

        progress.emit(
            0.02,
            "Planning \(request.inputFASTQURLs.count) \(sampleLabel(request.inputFASTQURLs.count)): \(executionPlan.sampleJobs) concurrent sample \(jobLabel(executionPlan.sampleJobs)), Savont \(executionPlan.savontThreadsPerSample) thread/sample."
        )
        let stagedSamples = try stageSamples(
            request: request,
            workDirectory: workDirectory,
            logicalFinalOutputURL: logicalFinalOutputURL,
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
        try bindSiblingWorkDirectory(
            cohortWorkDirectory,
            stagedOutputURL: request.outputDirectory,
            request: request
        )
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
        let candidateReferenceRecords = referenceCatalog.records
        let summariesBySample = try genotypeSummariesFromFinalCohortBAM(
            orderedResults: orderedResults,
            samURL: bamView.samURL,
            cohortAlignmentResult: cohortAlignmentResult,
            referenceFASTAURL: referenceFASTAURL,
            referenceRecords: candidateReferenceRecords,
            request: request
        )
        let hitSummaryDerivationStartedAt = Date()
        let referenceLengths = try FullLengthONTMHCClusterGenotyper
            .readFASTARecords(from: referenceFASTAURL)
            .reduce(into: [String: Int]()) { lengths, record in
                lengths[record.name] = record.sequence.count
            }
        let genotypingHitSummariesByTarget = try FullLengthONTMHCGenotypingHitSummaryAccumulator.summaries(
            samURL: bamView.samURL,
            bamPath: "artifacts/alignments/genotyping-evidence.bam",
            referenceLengths: referenceLengths,
            cdnaThreshold: request.cdnaThreshold,
            referenceRecords: candidateReferenceRecords,
            targetLengths: Dictionary(uniqueKeysWithValues: orderedResults.flatMap { result in
                result.clusterRecords.map { ("\(result.sample)|\($0.name)", $0.sequence.count) }
            })
        )
        let hitSummaryDerivationCompletedAt = Date()
        let authoritativeResults = try orderedResults.map { result in
            guard let summary = summariesBySample[result.sample] else {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Final cohort BAM did not yield a summary for sample \(result.sample)."
                )
            }
            return result.applyingAuthoritativeGenotypingSummary(summary)
        }
        var allGenotypeRows = authoritativeResults.flatMap(\.genotypeRows)
        let sampleCounts = Dictionary(uniqueKeysWithValues: orderedResults.map { ($0.sample, $0.readCount) })
        var sampleSummaries = authoritativeResults.map(\.sampleSummary)
        var pipelineSteps = sampleResults
            .flatMap(\.steps)
            .sorted { lhs, rhs in lhs.startedAt < rhs.startedAt }
        pipelineSteps.append(referenceCatalog.step)
        let blastRescueDirectory = request.outputDirectory
            .appendingPathComponent(".full-length-ont-mhc", isDirectory: true)
            .appendingPathComponent("blast-rescue", isDirectory: true)
        let blastReferenceURL = try prepareBlastRescueReference(
            referenceFASTAURL,
            rescueDirectory: blastRescueDirectory
        )
        var rescueBySampleCluster: [String: FullLengthONTMHCBlastRescueMatch] = [:]
        var blastRescueTSVURLs: [URL] = []
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
            if !rescueCandidates.isEmpty {
                blastRescueTSVURLs.append(
                    blastRescueTSVURL(
                        sample: result.sample,
                        sampleDirectory: sampleDirectory
                    )
                )
            }
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
        let rawDecisionSerializationStartedAt = Date()
        try FileManager.default.createDirectory(
            at: request.rawUnmatchedConsensusesFASTAURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rawDecisionDocument = FullLengthONTMHCRawUnmatchedDecisionDocument(
            rows: unmatchedClosestMatchRows
        )
        let rawDecisionEncoder = JSONEncoder()
        rawDecisionEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try rawDecisionEncoder.encode(rawDecisionDocument).write(
            to: request.rawUnmatchedConsensusDecisionsJSONURL,
            options: .atomic
        )
        let rawDecisionSerializationCompletedAt = Date()
        let orderedClusterFASTAURLs = authoritativeResults
            .map(\.clustersFASTAURL)
            .sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
        let orderedBlastRescueTSVURLs = blastRescueTSVURLs
            .sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
        let rawDecisionInputs = [
            cohortAlignmentResult.bamURL,
            cohortAlignmentResult.baiURL,
            referenceFASTAURL,
            referenceCatalogProjectionURL,
        ] + orderedClusterFASTAURLs + orderedBlastRescueTSVURLs
        var rawDecisionArgv = [
            "lungfish-in-process", "serialize-raw-unmatched-consensus-decisions",
            "--genotyping-bam", cohortAlignmentResult.bamURL.path,
            "--genotyping-bai", cohortAlignmentResult.baiURL.path,
            "--reference-fasta", referenceFASTAURL.path,
            "--reference-catalog", referenceCatalogProjectionURL.path,
        ]
        for inputURL in orderedClusterFASTAURLs {
            rawDecisionArgv += ["--cluster-fasta", inputURL.path]
        }
        for inputURL in orderedBlastRescueTSVURLs {
            rawDecisionArgv += ["--blast-rescue-tsv", inputURL.path]
        }
        rawDecisionArgv += [
            "--output", request.rawUnmatchedConsensusDecisionsJSONURL.path,
        ]
        pipelineSteps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish-in-process:serialize-raw-unmatched-consensus-decisions",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: rawDecisionArgv,
            resolvedOptions: [
                "schemaVersion": .integer(FullLengthONTMHCRawUnmatchedDecisionDocument.schemaVersion),
                "rowCount": .integer(rawDecisionDocument.rows.count),
                "rowIdentityFields": .array([
                    .string("sample_id"), .string("source_cluster_id"), .string("cluster_read_count"),
                    .string("raw_sequence"), .string("candidate_sequence"),
                    .string("candidate_was_reverse_complemented"),
                ]),
                "orientationRule": .string("raw cohort strand XOR full-candidate reverse-complement"),
                "trimRule": .string("mapped interval is metadata; complete oriented consensus defines candidate identity"),
                "closestMatchRule": .string("persist selected minimap2 evidence from the cohort BAM or BLAST evidence from checksum-bound per-sample TSVs with every row"),
                "orderingRule": .string("sample, source cluster, candidate sequence, cluster read count"),
                "blastRescueTSVCount": .integer(orderedBlastRescueTSVURLs.count),
                "blastRescueTSVOrderingRule": .string("standardized absolute path, bytewise ascending"),
                "blastRescueMinimumQueryCoveragePercent": .number(
                    FullLengthONTMHCBlastRescueMatch.minimumQueryCoverage
                ),
                "blastRescueMinimumAlignedBases": .integer(
                    FullLengthONTMHCBlastRescueMatch.minimumAlignedBases
                ),
                "blastRescueMinimumPercentIdentity": .number(
                    FullLengthONTMHCBlastRescueMatch.minimumPercentIdentity
                ),
                "blastRescueMaximumEValue": .number(
                    FullLengthONTMHCBlastRescueMatch.maximumEValue
                ),
                "blastRescueSelectionRule": .string(
                    "lowest e-value, highest bit score, query coverage, percent identity, aligned bases, then closest reference"
                ),
            ],
            inputs: rawDecisionInputs,
            outputs: [request.rawUnmatchedConsensusDecisionsJSONURL],
            exitStatus: 0,
            stderr: nil,
            startedAt: rawDecisionSerializationStartedAt,
            completedAt: rawDecisionSerializationCompletedAt
        ))

        let rawUnmatchedMaterializationStartedAt = Date()
        let rawDecisionDecoder = JSONDecoder()
        let persistedRawDecisionDocument = try rawDecisionDecoder.decode(
            FullLengthONTMHCRawUnmatchedDecisionDocument.self,
            from: Data(contentsOf: request.rawUnmatchedConsensusDecisionsJSONURL)
        )
        let rawUnmatchedRecords = FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder
            .deduplicatedFASTARecords(persistedRawDecisionDocument.rows)
        try writeFASTARecords(
            rawUnmatchedRecords,
            to: request.rawUnmatchedConsensusesFASTAURL
        )
        let rawUnmatchedMaterializationCompletedAt = Date()
        let rawUnmatchedMaterializationArgv = [
            "lungfish-in-process", "materialize-raw-unmatched-consensus-fasta",
            "--decisions", request.rawUnmatchedConsensusDecisionsJSONURL.path,
            "--output", request.rawUnmatchedConsensusesFASTAURL.path,
        ]
        pipelineSteps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish-in-process:materialize-raw-unmatched-consensus-fasta",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: rawUnmatchedMaterializationArgv,
            resolvedOptions: [
                "recordCount": .integer(rawUnmatchedRecords.count),
                "sequenceIdentityRule": .string("SHA-256 of complete oriented consensus sequence"),
                "supportMetadataRule": .string("aggregate occurrence, sample, and cluster-read support by sequence identity"),
                "outputPath": .string("artifacts/internal/raw-unmatched-consensuses.fasta"),
                "rootPublicationOwner": .string("FullLengthONTMHCCandidateArtifactWriter"),
                "canonicalRootOutputPath": .string("deduplicated_unmatched_clusters.fasta"),
                "decisionPayloadSchemaVersion": .integer(
                    FullLengthONTMHCRawUnmatchedDecisionDocument.schemaVersion
                ),
            ],
            inputs: [request.rawUnmatchedConsensusDecisionsJSONURL],
            outputs: [request.rawUnmatchedConsensusesFASTAURL],
            exitStatus: 0,
            stderr: nil,
            startedAt: rawUnmatchedMaterializationStartedAt,
            completedAt: rawUnmatchedMaterializationCompletedAt
        ))

        let evidenceArtifactPair = try validatedEvidenceArtifactPair(
            cohortAlignmentResult,
            bundleDirectoryURL: request.outputDirectory
        )
        let candidateWriter = FullLengthONTMHCCandidateArtifactWriter(
            minimap2ExecutableURL: minimap2ExecutableURL,
            samtoolsExecutableURL: samtoolsExecutableURL
        )
        let candidateWorkDirectory = candidateArtifactWorkDirectory(
            for: request.outputDirectory
        )
        try FileManager.default.createDirectory(at: candidateWorkDirectory, withIntermediateDirectories: true)
        try bindSiblingWorkDirectory(
            candidateWorkDirectory,
            stagedOutputURL: request.outputDirectory,
            request: request
        )
        let candidateReferenceAnnotationInputURLs = request.referenceSourceURL.pathExtension.lowercased() == "lungfishref"
            ? try mhcReferenceVisualizationInputURLs(
                sourceURL: request.referenceSourceURL,
                fastaURL: referenceFASTAURL
            )
            : try mhcReferenceCatalogInputURLs(
                sourceURL: request.referenceSourceURL,
                fastaURL: referenceFASTAURL
            )
        let candidateArtifactResult = try await candidateWriter.stage(.init(
            observations: try unmatchedClosestMatchRows.map { row in
                let summaries = try genotypingHitSummariesByTarget["\(row.sample)|\(row.cluster)"]
                    .map { summary in
                        try FullLengthONTMHCCandidateObservationNormalizer.canonicalize(
                            summary: summary,
                            candidateWasReverseComplemented: row.candidateWasReverseComplemented
                        )
                    }
                return FullLengthONTMHCCandidateSequenceObservation(
                    sampleID: row.sample,
                    readGroupID: row.sample,
                    sourceClusterID: row.cluster,
                    clusterReadCount: row.clusterReads,
                    sequence: row.candidateSequence,
                    genotypingHitSummaries: summaries.map { [$0] } ?? []
                )
            },
            referenceAlleleFASTAURL: referenceFASTAURL,
            rawUnmatchedConsensusesFASTAURL: request.rawUnmatchedConsensusesFASTAURL,
            referenceBundleURL: request.referenceSourceURL,
            referenceAnnotationInputURLs: candidateReferenceAnnotationInputURLs,
            referenceRecords: candidateReferenceRecords,
            genotypingEvidence: evidenceArtifactPair,
            threads: request.threads,
            outputDirectoryURL: request.outputDirectory,
            finalOutputDirectoryURL: logicalFinalOutputURL,
            workDirectoryURL: candidateWorkDirectory,
            analysisName: request.outputName,
            projectBundleName: request.projectURL?.lastPathComponent
        ))
        pipelineSteps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish MHC genotyping hit summary accumulator",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-in-process", "summarize-full-length-ont-mhc-genotyping-hits",
                "--bam-path", "artifacts/alignments/genotyping-evidence.bam",
                "--cdna-threshold", String(request.cdnaThreshold),
                bamView.samURL.path,
                referenceFASTAURL.path,
            ],
            resolvedOptions: [
                "alignmentIdentity": .array([
                    .string("bam_path"), .string("query_name"), .string("reference_name"),
                    .string("read_group_id"), .string("reference_start"), .string("cigar"),
                ]),
                "alignmentCountSemantics": .string("unique-schema-v1-locator-tuples"),
                "queryCountSemantics": .string("unique-locator-count-per-query-and-target"),
                "exactGenomicRule": .string("zero SNP substitutions; exact end-to-end genomic known status additionally requires full reference and consensus spans from target position 1 with no I/D/N/S/H"),
                "partialExtensionDeferralRule": .string("a zero-SNP genomic overlap with no I/D/N but incomplete reference or consensus end coverage is deferred from initial known calls for reciprocal partial-extension classification; an exact end-to-end genomic match still wins"),
                "legacyBroadGenomicRule": .string("zero-SNP genomic relationships containing internal I/D/N events retain prior known-call behavior unless qualifying cDNA extension evidence independently supports an extension"),
                "cdnaCompatibilityRule": .string("zero SNP substitutions; cDNA reference coverage >= 0.95; no individual cDNA-deficit I/S/H event >= 20 bases"),
                "knownCDNAStructuralRule": .string("compatible cDNA; cluster coverage >= 0.95; each terminal cluster flank < 20 bases; no individual cluster-side D/N segment >= 20 bases"),
                "extensionCDNAStructuralRule": .string("compatible cDNA plus any terminal cluster flank or individual cluster-side D/N segment >= 20 bases"),
                "structuralSegmentMinimumBases": .integer(20),
                "minimumCDNAReferenceCoverage": .number(0.95),
                "cohortAlignmentOrientation": .string("reference allele is SAM query; consensus cluster is SAM target; target POS/end flanks and D/N are cluster-only sequence; I/S/H are missing cDNA-query coverage"),
                "reciprocalAlignmentOrientation": .string("consensus cluster is SAM query; reference allele is SAM target; I/S are cluster-only sequence; D/N and uncovered target ends are missing cDNA-reference coverage"),
                "cohortCDNAReferenceCoverageDefinition": .string("comparable query/reference bases / annotated cDNA reference length, clamped to 1; I/S/H deficit bases excluded"),
                "cohortClusterCoverageDefinition": .string("target reference span / complete consensus cluster length, clamped to 1"),
                "reciprocalCDNAReferenceCoverageDefinition": .string("comparable query/reference bases / annotated cDNA reference length, clamped to 1; D/N/uncovered-target deficit bases excluded"),
                "reciprocalClusterCoverageDefinition": .string("query span / complete consensus cluster length, clamped to 1"),
                "cohortInterpretationOrientation": .string("canonical candidate orientation: raw cohort strand XOR full-candidate reverse-complement; leading/trailing cluster flanks swapped when reversed"),
                "secondaryAlignmentCompletenessRule": .string("cohort minimap2 -N equals per-sample consensus target count; reciprocal minimap2 -N equals reference record count; secondary=yes; no fixed cap"),
                "eventThresholdSemantics": .string("20-base threshold is applied to each individual event and each terminal side; event lengths are never summed to cross the threshold"),
                "classificationPrecedence": .array([
                    .string("exact genomic known"), .string("partial extension candidate"),
                    .string("structural cDNA extension candidate"),
                    .string("end-to-end cDNA known"), .string("SNP-defined novel"), .string("un-nameable"),
                ]),
                "perReferenceCollapseRule": .string("retain one best full-coverage interpretation per raw cDNA reference ID by relationship, cDNA coverage, cluster coverage, then score; retain all compatible reference IDs"),
                "strandConflictRule": .string("equally compatible opposite-strand interpretations are ambiguous and un-nameable"),
                "genomicLocusResolutionRule": .string("unambiguous genomic reciprocal evidence resolves locus and closest comparison; naming cDNAs are filtered to that locus while all compatible cDNA interpretations remain in the audit payload"),
                "provisionalNamingAmbiguityRule": .string("one compatible in-locus cDNA name supplies _ext base; otherwise genomic closest supplies base and provisional_naming_ambiguous is true"),
                "candidateSequenceIdentityRule": .string("complete consensus, reverse-complemented as a whole when selected strand is reverse; mapped-interval crop is metadata only and never defines candidate identity, deduplicated FASTA, reciprocal input, or full-length Excel sequence"),
                "candidateDocumentSchemaVersion": .integer(5),
                "referenceMoleculeClassSource": .string("materialized annotated MHC reference catalog; length threshold is fallback only when metadata is absent"),
                "retainedCDNAExtensionInterpretationCount": .integer(
                    genotypingHitSummariesByTarget.values.reduce(0) {
                        $0 + $1.cdnaExtensionInterpretations.count
                    }
                ),
                "structurallyReroutedClusterCount": .integer(Set(
                    summariesBySample.values.flatMap(\.cdnaStructuralInterpretations).filter {
                        $0.relationship == .extension
                    }.map(\.clusterID)
                ).count),
                "closestBiologicalRank": .array([
                    .string("snps-ascending"), .string("non-intron-indel-bases-ascending"),
                    .string("matched-bases-descending"), .string("alignment-score-descending"),
                ]),
                "closestTieSemantics": .string("retain-all-query-names-before-lexical-tie-break"),
                "cdnaThreshold": .integer(request.cdnaThreshold),
            ],
            inputs: [cohortAlignmentResult.bamURL, bamView.samURL, referenceFASTAURL, referenceCatalogProjectionURL],
            outputs: [candidateArtifactResult.candidateJSONURL],
            exitStatus: 0,
            stderr: nil,
            startedAt: hitSummaryDerivationStartedAt,
            completedAt: hitSummaryDerivationCompletedAt
        ))
        try metadataPublicationObserver(.candidateArtifactsStaged(
            outputDirectoryURL: request.outputDirectory
        ))
        try Task.checkCancellation()
        let reciprocalKnownRows = reciprocalKnownGenotypeRows(
            from: candidateArtifactResult
        )
        allGenotypeRows.append(contentsOf: reciprocalKnownRows)
        let cdnaAlleles = Set(candidateReferenceRecords.filter {
            $0.moleculeClass == .cDNA
        }.map(\.alleleName))
        let cdnaReferenceIDs = Set(candidateReferenceRecords.filter {
            $0.moleculeClass == .cDNA
        }.map(\.sequenceID))
        sampleSummaries = sampleSummaries.map { summary in
            let rows = reciprocalKnownRows.filter { $0.sample == summary.sample }
            guard !rows.isEmpty else { return summary }
            let reciprocalCDNAClusters = Set(rows.filter {
                $0.referenceSequenceID.map(cdnaReferenceIDs.contains) ?? cdnaAlleles.contains($0.allele)
            }.map(\.cluster))
            let assignedSourceReads = Dictionary(grouping: rows, by: \.cluster).values.reduce(0) {
                $0 + ($1.map(\.clusterReads).max() ?? 0)
            }
            return FullLengthONTMHCSampleSummary(
                sample: summary.sample,
                totalInputReads: summary.totalInputReads,
                clusterCount: summary.clusterCount,
                clusteredReads: summary.clusteredReads,
                assignedReads: summary.assignedReads + assignedSourceReads,
                unmatchedClusters: max(0, summary.unmatchedClusters - Set(rows.map(\.cluster)).count),
                cdnaClusters: summary.cdnaClusters + reciprocalCDNAClusters.count,
                savontPreset: summary.savontPreset,
                savontStatus: .called,
                savontFallbackReason: summary.savontFallbackReason
            )
        }

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
        let candidateCanonicalizationInputURL = request.outputDirectory.appendingPathComponent(
            "artifacts/internal/mhc-candidate-canonicalization-input.json"
        )
        let candidateSourceMapURL = request.outputDirectory.appendingPathComponent(
            "artifacts/internal/mhc-candidate-source-map.json"
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
                "--reciprocal-known-bam", candidateArtifactResult.reciprocalBAMURL.path,
                "--reciprocal-known-bai", candidateArtifactResult.reciprocalBAIURL.path,
                "--candidate-canonicalization-input", candidateCanonicalizationInputURL.path,
                "--candidate-source-map", candidateSourceMapURL.path,
                cohortAlignmentResult.bamURL.path,
            ],
            resolvedOptions: [
                "postCropKnownFoldbackRule": .string(
                    "uniquely-resolved-reference-ready-zero-canonical-substitution-genomic-candidates-fold-back-to-named-allele;ambiguous-reference-ties-remain-candidates;incomplete-zero-canonical-substitution-genomic-candidates-remain-reviewable-partial-extensions"
                ),
            ],
            inputs: [
                cohortAlignmentResult.bamURL,
                URL(fileURLWithPath: bamView.commandRecord.stdoutLogDescriptor.path),
                referenceFASTAURL,
                candidateArtifactResult.reciprocalBAMURL,
                candidateArtifactResult.reciprocalBAIURL,
                candidateCanonicalizationInputURL,
                candidateSourceMapURL,
            ] + authoritativeResults.map(\.clustersFASTAURL),
            outputs: [request.reportCSVURL, request.sampleSummaryCSVURL, request.statsJSONURL],
            exitStatus: 0,
            stderr: nil,
            startedAt: bamView.commandRecord.completedAt,
            completedAt: Date()
        ))
        let candidateDocument = try JSONDecoder().decode(
            ONTMHCCandidateAllelesDocument.self,
            from: Data(contentsOf: candidateArtifactResult.candidateJSONURL)
        )
        let unnameableDocument = try JSONDecoder().decode(
            ONTMHCUnnameableClustersDocument.self,
            from: Data(contentsOf: candidateArtifactResult.unnameableJSONURL)
        )
        let reviewableRowCatalogPublication =
            try publishReviewableRowCatalogIfNeeded(
                request: request,
                referenceRecords: candidateReferenceRecords,
                referenceCatalogProjectionURL: referenceCatalogProjectionURL,
                reportRows: reportRows,
                sampleNames: sampleSummaries.map(\.sample),
                candidateDocument: candidateDocument,
                candidateJSONURL: candidateArtifactResult.candidateJSONURL,
                unnameableDocument: unnameableDocument,
                unnameableJSONURL: candidateArtifactResult.unnameableJSONURL,
                genotypingEvidenceBAMURL: cohortAlignmentResult.bamURL,
                genotypingEvidenceBAIURL: cohortAlignmentResult.baiURL
            )
        if let publication = reviewableRowCatalogPublication,
           let step = publication.provenance.steps.first {
            pipelineSteps.append(FullLengthONTMHCProvenanceStep(
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                argv: step.argv,
                resolvedOptions: step.resolvedOptions,
                runtimeIdentity: step.runtimeIdentity ?? ProvenanceRuntimeIdentity(),
                inputs: step.inputs.map { URL(fileURLWithPath: $0.path) },
                outputs: [publication.outputURL],
                exitStatus: Int32(step.exitStatus ?? 0),
                stderr: step.stderr,
                startedAt: step.startedAt ?? publication.provenance.createdAt,
                completedAt: step.completedAt ?? publication.provenance.createdAt
            ))
        }
        let referenceVisualizationPublication = try publishMHCReferenceVisualizations(
            referenceBundleURL: request.referenceSourceURL,
            referenceFASTAURL: referenceFASTAURL,
            referenceRecords: candidateReferenceRecords,
            exactCallRows: allGenotypeRows,
            exactCallInputURL: request.reportCSVURL,
            candidateDocument: candidateDocument,
            candidateJSONURL: candidateArtifactResult.candidateJSONURL,
            unnameableDocument: unnameableDocument,
            unnameableJSONURL: candidateArtifactResult.unnameableJSONURL,
            outputDirectoryURL: request.outputDirectory,
            finalOutputDirectoryURL: logicalFinalOutputURL,
            steps: &pipelineSteps
        )
        let haplotypeAnalysis = try writeHaplotypeAnalysisIfRequested(
            request: request,
            supportDirectory: request.outputDirectory.appendingPathComponent(".full-length-ont-mhc", isDirectory: true),
            generatedAt: Date()
        )
        let orderedAlleles = try FullLengthONTMHCClusterGenotyper
            .readFASTARecords(from: referenceFASTAURL)
            .map(\.name)
        let workbookAssemblyStartedAt = Date()
        let workbookProjection = try FullLengthONTMHCWorkbookProjection(
            candidateDocument: candidateDocument,
            unnameableDocument: unnameableDocument,
            sampleOrder: sampleSummaries.map(\.sample)
        )
        let knownAlleleDisplayNames = Dictionary(
            uniqueKeysWithValues: candidateReferenceRecords.map { ($0.sequenceID, $0.alleleName) }
        )
        let normalizedUnmatchedRows = try workbookProjection.normalizedUnmatchedRows(
            candidateFASTARecords: FullLengthONTMHCClusterGenotyper.readFASTARecords(
                from: candidateArtifactResult.candidateFASTAURL
            ),
            unnameableFASTARecords: FullLengthONTMHCClusterGenotyper.readFASTARecords(
                from: candidateArtifactResult.unnameableFASTAURL
            ),
            candidateGenBankRecords: try GenBankReader(
                url: candidateArtifactResult.candidateGenBankURL
            ).readAllSync(),
            unnameableGenBankRecords: try GenBankReader(
                url: candidateArtifactResult.unnameableGenBankURL
            ).readAllSync(),
            knownAlleleDisplayNames: knownAlleleDisplayNames
        )
        let workbookProjectionInputURL = request.outputDirectory
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("projections", isDirectory: true)
            .appendingPathComponent("mhc-workbook-projection-input.json")
        let projectionInputDocument = FullLengthONTMHCWorkbookProjectionInputDocument(
            sourceSummary: .init(
                reportRowCount: reportRows.count,
                sampleSummaryCount: sampleSummaries.count,
                genotypeRowCount: allGenotypeRows.count,
                unmatchedClusterRowCount: unmatchedClosestMatchRows.count,
                orderedAlleleCount: orderedAlleles.count,
                includesHaplotypeAnalysis: haplotypeAnalysis != nil,
                candidateRecordCount: candidateDocument.candidates.count,
                unnameableRecordCount: unnameableDocument.clusters.count,
                normalizedUnmatchedRowCount: normalizedUnmatchedRows.count,
                referenceRecordCount: candidateReferenceRecords.count
            ),
            sheets: workbookSheets(
                reportRows: reportRows,
                sampleSummaries: sampleSummaries,
                haplotypeAnalysis: haplotypeAnalysis,
                projection: workbookProjection,
                normalizedUnmatchedRows: normalizedUnmatchedRows,
                knownAlleleDisplayNames: knownAlleleDisplayNames
            )
        )
        try FileManager.default.createDirectory(
            at: workbookProjectionInputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let workbookInputEncoder = JSONEncoder()
        workbookInputEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try workbookInputEncoder.encode(projectionInputDocument).write(
            to: workbookProjectionInputURL,
            options: .atomic
        )
        let workbookAssemblyCompletedAt = Date()
        var workbookAssemblyInputs = [
            candidateArtifactResult.candidateJSONURL,
            candidateArtifactResult.candidateFASTAURL,
            candidateArtifactResult.candidateGenBankURL,
            candidateArtifactResult.unnameableJSONURL,
            candidateArtifactResult.unnameableFASTAURL,
            candidateArtifactResult.unnameableGenBankURL,
            cohortAlignmentResult.bamURL,
            cohortAlignmentResult.baiURL,
            candidateArtifactResult.reciprocalBAMURL,
            candidateArtifactResult.reciprocalBAIURL,
            request.reportCSVURL,
            request.sampleSummaryCSVURL,
            request.deduplicatedUnmatchedClustersFASTAURL,
            referenceFASTAURL,
            referenceCatalogProjectionURL,
        ]
        if haplotypeAnalysis != nil,
           FileManager.default.fileExists(atPath: request.haplotypeAnalysisURL.path) {
            workbookAssemblyInputs.append(request.haplotypeAnalysisURL)
        }
        var workbookAssemblyArgv = [
            "lungfish-in-process", "assemble-mhc-workbook-projection-input",
            "--candidate-json", candidateArtifactResult.candidateJSONURL.path,
            "--candidate-fasta", candidateArtifactResult.candidateFASTAURL.path,
            "--candidate-genbank", candidateArtifactResult.candidateGenBankURL.path,
            "--unnameable-json", candidateArtifactResult.unnameableJSONURL.path,
            "--unnameable-fasta", candidateArtifactResult.unnameableFASTAURL.path,
            "--unnameable-genbank", candidateArtifactResult.unnameableGenBankURL.path,
            "--genotyping-bam", cohortAlignmentResult.bamURL.path,
            "--genotyping-bai", cohortAlignmentResult.baiURL.path,
            "--reciprocal-bam", candidateArtifactResult.reciprocalBAMURL.path,
            "--reciprocal-bai", candidateArtifactResult.reciprocalBAIURL.path,
            "--report-csv", request.reportCSVURL.path,
            "--sample-summary-csv", request.sampleSummaryCSVURL.path,
            "--unmatched-fasta", request.deduplicatedUnmatchedClustersFASTAURL.path,
            "--reference-fasta", referenceFASTAURL.path,
            "--reference-catalog", referenceCatalogProjectionURL.path,
            "--output", workbookProjectionInputURL.path,
        ]
        if let assayID = request.haplotypeAssayID {
            workbookAssemblyArgv += ["--haplotype-assay", assayID]
        }
        if let definitionSetID = request.haplotypeDefinitionSetID {
            workbookAssemblyArgv += ["--haplotype-definition-set", definitionSetID]
        }
        if haplotypeAnalysis != nil {
            workbookAssemblyArgv += ["--haplotype-analysis", request.haplotypeAnalysisURL.path]
        }
        pipelineSteps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish-in-process:assemble-mhc-workbook-projection-input",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: workbookAssemblyArgv,
            resolvedOptions: [
                "reportRowCount": .integer(reportRows.count),
                "sampleSummaryCount": .integer(sampleSummaries.count),
                "genotypeRowCount": .integer(allGenotypeRows.count),
                "unmatchedClusterRowCount": .integer(unmatchedClosestMatchRows.count),
                "orderedAlleleCount": .integer(orderedAlleles.count),
                "normalizedUnmatchedRowCount": .integer(normalizedUnmatchedRows.count),
                "referenceRecordCount": .integer(candidateReferenceRecords.count),
                "projectionSchemaVersion": .integer(FullLengthONTMHCWorkbookProjectionInputDocument.schemaVersion),
                "includesHaplotypeAnalysis": .boolean(haplotypeAnalysis != nil),
                "inProcessSourceException": .string("typed row arrays are fully materialized in deterministic projection JSON"),
            ],
            inputs: workbookAssemblyInputs,
            outputs: [workbookProjectionInputURL],
            exitStatus: 0,
            stderr: nil,
            startedAt: workbookAssemblyStartedAt,
            completedAt: workbookAssemblyCompletedAt
        ))

        let workbookProjectionStartedAt = Date()
        let durableWorkbookInput = try JSONDecoder().decode(
            FullLengthONTMHCWorkbookProjectionInputDocument.self,
            from: Data(contentsOf: workbookProjectionInputURL)
        )
        try FullLengthONTMHCXLSXPackageWriter.write(
            sheets: durableWorkbookInput.sheets,
            to: request.workbookURL
        )
        let workbookProjectionCompletedAt = Date()
        pipelineSteps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish-internal mhc-candidate-workbook-project",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-internal", "mhc-candidate-workbook-project",
                "--projection-input", workbookProjectionInputURL.path,
                "--workbook", request.workbookURL.path,
                "--shared-novel-tint", FullLengthONTMHCWorkbookTintDefaults.sharedNovel,
                "--singleton-novel-tint", FullLengthONTMHCWorkbookTintDefaults.singletonNovel,
                "--shared-extension-tint", FullLengthONTMHCWorkbookTintDefaults.sharedExtension,
                "--singleton-extension-tint", FullLengthONTMHCWorkbookTintDefaults.singletonExtension,
            ],
            resolvedOptions: [
                "sharedNovelTint": .string(FullLengthONTMHCWorkbookTintDefaults.sharedNovel),
                "singletonNovelTint": .string(FullLengthONTMHCWorkbookTintDefaults.singletonNovel),
                "sharedExtensionTint": .string(FullLengthONTMHCWorkbookTintDefaults.sharedExtension),
                "singletonExtensionTint": .string(FullLengthONTMHCWorkbookTintDefaults.singletonExtension),
            ],
            inputs: [workbookProjectionInputURL],
            outputs: [request.workbookURL],
            exitStatus: 0,
            stderr: nil,
            startedAt: workbookProjectionStartedAt,
            completedAt: workbookProjectionCompletedAt
        ))
        let workbookCopy = try createInitialCurrentWorkbookCopy(for: request)
        pipelineSteps.append(workbookCopy.step)
        let referenceRecordStoreSnapshot = try await GenotypeReferenceRecordStoreSnapshot.publish(
            fromReferenceBundle: request.referenceSourceURL,
            toResultBundle: request.outputDirectory
        )
        if let snapshot = referenceRecordStoreSnapshot {
            pipelineSteps.append(FullLengthONTMHCProvenanceStep(
                toolName: "lungfish genotype reference metadata snapshot",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: ["copy", snapshot.sourceURL.path, snapshot.destinationURL.path],
                inputs: [snapshot.sourceURL],
                outputs: [snapshot.destinationURL],
                exitStatus: 0,
                stderr: nil,
                startedAt: snapshot.startedAt,
                completedAt: snapshot.completedAt
            ))
        }
        try rewriteCheckpointPaths(
            in: request.outputDirectory,
            replacing: request.outputDirectory.standardizedFileURL.path,
            with: logicalFinalOutputURL.standardizedFileURL.path
        )
        let manifestCreatedAt = Date()
        var manifestPublicationPlan: FullLengthONTMHCSuccessManifestPublicationPlan?
        do {
            let plan = try stageManifest(
                request: request,
                workbookRevision: workbookCopy.revision,
                evidenceArtifactPair: evidenceArtifactPair,
                candidateArtifacts: candidateArtifactResult.manifest,
                referenceVisualizations: referenceVisualizationPublication?.descriptor,
                referenceRecordStore: referenceRecordStoreSnapshot?.info,
                reviewableRowCatalog: reviewableRowCatalogPublication?.artifact,
                createdAt: manifestCreatedAt
            )
            manifestPublicationPlan = plan
            let provenanceCompletedAt = Date()
            try writeProvenance(
                request: request,
                referenceFASTAURL: referenceFASTAURL,
                executionPlan: executionPlan,
                stagedSamples: stagedSamples,
                processingOrder: orderedSamples,
                steps: pipelineSteps,
                cohortAlignmentResult: cohortAlignmentResult,
                bamViewRecord: bamView.commandRecord,
                candidateArtifactResult: candidateArtifactResult,
                referenceVisualizationPublication: referenceVisualizationPublication,
                manifestPublicationPlan: plan,
                startedAt: startedAt,
                completedAt: provenanceCompletedAt
            )
            try metadataPublicationObserver(.provenanceWrittenBeforeManifestPublication(
                stagedManifestURL: plan.stagedURL,
                finalManifestURL: ONTGenotypeResultBundle.manifestURL(in: logicalFinalOutputURL),
                provenanceURL: request.provenanceURL
            ))
            manifestPublicationPlan = nil
        } catch {
            if let stagedURL = manifestPublicationPlan?.stagedURL,
               FileManager.default.fileExists(atPath: stagedURL.path) {
                do {
                    try FileManager.default.removeItem(at: stagedURL)
                } catch let cleanupError {
                    throw FullLengthONTMHCGenotypingError.reportFailed(
                        "Metadata staging failed (\(error.localizedDescription)); staged manifest cleanup also failed (\(cleanupError.localizedDescription))."
                    )
                }
            }
            throw error
        }
        let cleanupWarnings = cohortAlignmentResult.cleanupDiagnostics.map(cleanupWarning)
        progress.emit(
            0.98,
            "Finalizing full-length ONT MHC result before intermediate cleanup."
        )
        let result = FullLengthONTMHCGenotypingResult(
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
            reciprocalEvidenceBAMURL: candidateArtifactResult.reciprocalBAMURL,
            reciprocalEvidenceBAIURL: candidateArtifactResult.reciprocalBAIURL,
            candidateAllelesJSONURL: candidateArtifactResult.candidateJSONURL,
            candidateAllelesFASTAURL: candidateArtifactResult.candidateFASTAURL,
            candidateAllelesGenBankURL: candidateArtifactResult.candidateGenBankURL,
            unnameableClustersJSONURL: candidateArtifactResult.unnameableJSONURL,
            unnameableClustersFASTAURL: candidateArtifactResult.unnameableFASTAURL,
            unnameableClustersGenBankURL: candidateArtifactResult.unnameableGenBankURL,
            cleanupWarnings: cleanupWarnings
        )
        return FullLengthONTMHCStagedRunResult(
            result: result,
            cohortWorkDirectory: cohortWorkDirectory,
            cohortTemporaryWorkDirectory:
                cohortAlignmentResult.temporaryWorkDirectoryURL,
            candidateWorkDirectory: candidateWorkDirectory
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

    private func finalizeStagedBundleMetadata(
        stagedOutputURL: URL,
        finalOutputURL: URL
    ) throws {
        let provenanceURL = stagedOutputURL.appendingPathComponent(
            "full-length-ont-mhc-genotyping-provenance.json"
        )
        try rewriteJSONStrings(
            at: provenanceURL,
            replacing: stagedOutputURL.standardizedFileURL.path,
            with: finalOutputURL.standardizedFileURL.path
        )
    }

    private func importRequestedCheckpointGeneration(
        request: FullLengthONTMHCGenotypingRunRequest,
        priorFinalOutputURL: URL,
        stagedOutputURL: URL
    ) throws {
        let sampleNames = plannedSampleNames(for: request.inputFASTQURLs)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for sample in sampleNames {
            try Task.checkCancellation()
            let relativeCheckpointPath = ".full-length-ont-mhc/checkpoints/samples/\(sample).json"
            let sourceCheckpointURL = priorFinalOutputURL.appendingPathComponent(relativeCheckpointPath)
            guard FileManager.default.fileExists(atPath: sourceCheckpointURL.path) else { continue }
            let checkpointDescriptor: Int32
            do {
                checkpointDescriptor = try FullLengthONTMHCAlignmentSafety().openRegularFileNoFollow(
                    sourceCheckpointURL,
                    within: priorFinalOutputURL,
                    role: "sample checkpoint"
                )
            } catch {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Prior sample checkpoint must be reachable through real directories and be a regular file without symlinks: \(sourceCheckpointURL.path) (\(error.localizedDescription))"
                )
            }
            let checkpointData = try readData(
                from: checkpointDescriptor,
                role: "sample checkpoint",
                maximumBytes: 16 * 1_024 * 1_024
            )
            guard let checkpoint = try? decoder.decode(
                FullLengthONTMHCSampleCheckpoint.self,
                from: checkpointData
            ), checkpoint.schemaVersion == FullLengthONTMHCSampleCheckpoint.schemaVersion,
               checkpoint.signature.sample == sample,
               checkpoint.result.sample == sample else {
                continue
            }

            var allowedSourceFiles = Set<URL>()
            allowedSourceFiles.insert(checkpoint.result.clustersFASTAURL.standardizedFileURL)
            for url in checkpoint.result.steps.flatMap(\.outputs) {
                allowedSourceFiles.insert(url.standardizedFileURL)
            }
            for sourceURL in allowedSourceFiles.sorted(by: { $0.path < $1.path }) {
                try copyCheckpointRegularFile(
                    sourceURL,
                    sample: sample,
                    priorFinalOutputURL: priorFinalOutputURL,
                    stagedOutputURL: stagedOutputURL
                )
            }

            let destinationCheckpointURL = stagedOutputURL.appendingPathComponent(relativeCheckpointPath)
            try FileManager.default.createDirectory(
                at: destinationCheckpointURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try checkpointData.write(to: destinationCheckpointURL, options: .atomic)
            try rewriteJSONStrings(
                at: destinationCheckpointURL,
                replacing: priorFinalOutputURL.standardizedFileURL.path,
                with: stagedOutputURL.standardizedFileURL.path
            )
        }
    }

    private func plannedSampleNames(for inputURLs: [URL]) -> [String] {
        var counts: [String: Int] = [:]
        return inputURLs.enumerated().map { index, url in
            let base = sampleName(for: url, fallbackIndex: index)
            let occurrence = (counts[base] ?? 0) + 1
            counts[base] = occurrence
            return occurrence == 1 ? base : "\(base)-\(occurrence)"
        }
    }

    private func copyCheckpointRegularFile(
        _ sourceURL: URL,
        sample: String,
        priorFinalOutputURL: URL,
        stagedOutputURL: URL
    ) throws {
        let source = sourceURL.standardizedFileURL
        let rootComponents = priorFinalOutputURL.standardizedFileURL.pathComponents
        let sourceComponents = source.pathComponents
        guard sourceComponents.count > rootComponents.count,
              Array(sourceComponents.prefix(rootComponents.count)) == rootComponents else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Prior sample checkpoint output escapes its result bundle: \(source.path)"
            )
        }
        let relativeComponents = Array(sourceComponents.dropFirst(rootComponents.count))
        guard relativeComponents.count >= 3,
              relativeComponents[0] == "samples",
              relativeComponents[1] == sample else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Prior sample checkpoint output is outside the allowed sample directory: \(source.path)"
            )
        }
        let sourceDescriptor: Int32
        do {
            sourceDescriptor = try FullLengthONTMHCAlignmentSafety().openRegularFileNoFollow(
                source,
                within: priorFinalOutputURL,
                role: "sample checkpoint output"
            )
        } catch {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Prior sample checkpoint output must be reachable through real directories and be a regular file without symlinks: \(source.path) (\(error.localizedDescription))"
            )
        }
        let destination = relativeComponents.reduce(stagedOutputURL) {
            $0.appendingPathComponent($1)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let imported = try copyRegularFile(
            from: sourceDescriptor,
            to: destination,
            role: "sample checkpoint output"
        )
        let destinationSize = try ProvenanceFileHasher.fileSize(of: destination)
        let destinationChecksum = try ProvenanceFileHasher.sha256(of: destination) {
            try Task.checkCancellation()
        }
        guard imported.size == destinationSize, imported.sha256 == destinationChecksum else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Imported sample checkpoint output failed size/checksum validation: \(source.path)"
            )
        }
    }

    private func readData(
        from descriptor: Int32,
        role: String,
        maximumBytes: Int
    ) throws -> Data {
        defer { Darwin.close(descriptor) }
        var result = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try readDescriptorChunk(descriptor, maximumBytes: 1_024 * 1_024)
            guard !chunk.isEmpty else { return result }
            guard result.count <= maximumBytes - chunk.count else {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "\(role.capitalized) exceeds \(maximumBytes) bytes."
                )
            }
            result.append(chunk)
        }
    }

    private func copyRegularFile(
        from sourceDescriptor: Int32,
        to destination: URL,
        role: String
    ) throws -> (size: UInt64, sha256: String) {
        defer { Darwin.close(sourceDescriptor) }
        let destinationDescriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(destinationDescriptor) }
        var hasher = SHA256()
        var size: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try readDescriptorChunk(sourceDescriptor, maximumBytes: 1_024 * 1_024)
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            size += UInt64(chunk.count)
            try chunk.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var written = 0
                while written < chunk.count {
                    let count = Darwin.write(
                        destinationDescriptor,
                        baseAddress.advanced(by: written),
                        chunk.count - written
                    )
                    guard count > 0 else {
                        throw FullLengthONTMHCGenotypingError.reportFailed(
                            "Could not copy \(role): \(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription)"
                        )
                    }
                    written += count
                }
            }
        }
        let sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (size, sha256)
    }

    private func readDescriptorChunk(_ descriptor: Int32, maximumBytes: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: maximumBytes)
        let count = Darwin.read(descriptor, &bytes, maximumBytes)
        guard count >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Data(bytes.prefix(count))
    }

    private func rewriteCheckpointPaths(
        in bundleURL: URL,
        replacing oldValue: String,
        with newValue: String
    ) throws {
        let checkpointDirectory = bundleURL
            .appendingPathComponent(".full-length-ont-mhc/checkpoints/samples", isDirectory: true)
        guard FileManager.default.fileExists(atPath: checkpointDirectory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(
            at: checkpointDirectory,
            includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension.lowercased() == "json" }) {
            try rewriteJSONStrings(
                at: url,
                replacing: oldValue,
                with: newValue
            )
        }
    }

    private func rewriteJSONStrings(
        at url: URL,
        replacing oldValue: String,
        with newValue: String
    ) throws {
        func rewritten(_ value: Any) -> Any {
            if let string = value as? String {
                return string.replacingOccurrences(of: oldValue, with: newValue)
            }
            if let array = value as? [Any] {
                return array.map(rewritten)
            }
            if let dictionary = value as? [String: Any] {
                return dictionary.mapValues(rewritten)
            }
            return value
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let data = try JSONSerialization.data(
            withJSONObject: rewritten(object),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }

    private func publishStagedResultBundle(
        stagedOutputURL: URL,
        finalOutputURL: URL,
        replacingExisting: Bool,
        payloadMappings: [(staged: ProvenanceFileDescriptor, final: ProvenanceFileDescriptor)]
    ) throws -> FullLengthONTMHCResultBundlePublicationRecord {
        try FullLengthONTMHCAlignmentSafety().requireDirectoryNoFollow(
            stagedOutputURL,
            role: "staged full-length MHC result bundle"
        )
        let startedAt = Date()
        let flags = UInt32(replacingExisting ? RENAME_SWAP : RENAME_EXCL)
        let initialErrorNumber: Int32?
        if !replacingExisting,
           let injectedError = try exclusivePublicationFailureInjector(.resultBundle) {
            initialErrorNumber = injectedError
        } else {
            let status = stagedOutputURL.path.withCString { stagedPath in
                finalOutputURL.path.withCString { finalPath in
                    Darwin.renameatx_np(
                        AT_FDCWD,
                        stagedPath,
                        AT_FDCWD,
                        finalPath,
                        flags
                    )
                }
            }
            initialErrorNumber = status == 0 ? nil : errno
        }
        guard let initialErrorNumber else {
            return FullLengthONTMHCResultBundlePublicationRecord(
                stagedDirectoryURL: stagedOutputURL,
                finalDirectoryURL: finalOutputURL,
                payloadMappings: payloadMappings,
                replacingExisting: replacingExisting,
                publicationMechanism: "renameatx_np",
                successManifestMechanism: "renameatx_np",
                fallbackReason: nil,
                startedAt: startedAt,
                completedAt: Date(),
                exitStatus: 0,
                errorMessage: nil
            )
        }
        let initialCode = POSIXErrorCode(rawValue: initialErrorNumber) ?? .EIO
        guard !replacingExisting, isUnsupportedExclusiveRename(initialErrorNumber) else {
            let record = FullLengthONTMHCResultBundlePublicationRecord(
                stagedDirectoryURL: stagedOutputURL,
                finalDirectoryURL: finalOutputURL,
                payloadMappings: payloadMappings,
                replacingExisting: replacingExisting,
                publicationMechanism: "renameatx_np",
                successManifestMechanism: "renameatx_np",
                fallbackReason: nil,
                startedAt: startedAt,
                completedAt: Date(),
                exitStatus: -1,
                errorMessage: POSIXError(initialCode).localizedDescription
            )
            throw FullLengthONTMHCResultBundlePublicationError(record: record)
        }
        let fallbackReason = "renameatx_np(RENAME_EXCL) unavailable: \(POSIXError(initialCode).localizedDescription)"
        let fallbackError: Error?
        do {
            try publishNewDirectoryUsingExclusiveReservation(
                stagedURL: stagedOutputURL,
                finalURL: finalOutputURL
            )
            fallbackError = nil
        } catch {
            fallbackError = error
        }
        let record = FullLengthONTMHCResultBundlePublicationRecord(
            stagedDirectoryURL: stagedOutputURL,
            finalDirectoryURL: finalOutputURL,
            payloadMappings: payloadMappings,
            replacingExisting: replacingExisting,
            publicationMechanism: "exclusive-directory-reservation-then-rename",
            successManifestMechanism: "exclusive-file-reservation-then-rename",
            fallbackReason: fallbackReason,
            startedAt: startedAt,
            completedAt: Date(),
            exitStatus: fallbackError == nil ? 0 : -1,
            errorMessage: fallbackError?.localizedDescription
        )
        if fallbackError != nil {
            throw FullLengthONTMHCResultBundlePublicationError(record: record)
        }
        return record
    }

    private func isUnsupportedExclusiveRename(_ errorNumber: Int32) -> Bool {
        errorNumber == ENOTSUP || errorNumber == EOPNOTSUPP
    }

    private func publishNewDirectoryUsingExclusiveReservation(
        stagedURL: URL,
        finalURL: URL
    ) throws {
        let reservationStatus = finalURL.path.withCString { path in
            Darwin.mkdir(path, S_IRWXU)
        }
        guard reservationStatus == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var publicationSucceeded = false
        defer {
            if !publicationSucceeded {
                _ = finalURL.path.withCString { Darwin.rmdir($0) }
            }
        }
        let status = stagedURL.path.withCString { stagedPath in
            finalURL.path.withCString { finalPath in
                Darwin.rename(stagedPath, finalPath)
            }
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        publicationSucceeded = true
    }

    private func resultBundlePublicationMappings(
        stagedOutputURL: URL,
        finalOutputURL: URL
    ) throws -> [(staged: ProvenanceFileDescriptor, final: ProvenanceFileDescriptor)] {
        guard let enumerator = FileManager.default.enumerator(
            at: stagedOutputURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw FullLengthONTMHCGenotypingError.reportFailed("Could not enumerate staged result payload.")
        }
        let rootComponents = stagedOutputURL.standardizedFileURL.pathComponents
        var mappings: [(staged: ProvenanceFileDescriptor, final: ProvenanceFileDescriptor)] = []
        for case let source as URL in enumerator {
            try Task.checkCancellation()
            let relativeComponents = source.standardizedFileURL.pathComponents
                .dropFirst(rootComponents.count)
            if relativeComponents.first == "workflow" {
                enumerator.skipDescendants()
                continue
            }
            var information = stat()
            guard Darwin.lstat(source.path, &information) == 0 else {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Could not inspect staged result payload entry: \(source.path)"
                )
            }
            switch information.st_mode & S_IFMT {
            case S_IFDIR:
                continue
            case S_IFREG:
                break
            default:
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Staged result payload contains an unsupported filesystem entry: \(source.path)"
                )
            }
            if source.lastPathComponent == "full-length-ont-mhc-genotyping-provenance.json" { continue }
            if source.lastPathComponent == OwnedWorkDirectoryMarker.fileName { continue }
            if source.lastPathComponent.hasPrefix(".\(ONTGenotypeResultBundleManifest.filename).staging-") { continue }
            let destination = relativeComponents.reduce(finalOutputURL) {
                $0.appendingPathComponent($1)
            }
            let checksum = try ProvenanceFileHasher.sha256(of: source) {
                try Task.checkCancellation()
            }
            let size = try ProvenanceFileHasher.fileSize(of: source)
            let staged = ProvenanceFileDescriptor(
                path: source.path,
                checksumSHA256: checksum,
                fileSize: size,
                role: .input
            )
            let final = ProvenanceFileDescriptor(
                path: destination.path,
                checksumSHA256: checksum,
                fileSize: size,
                role: .output,
                originPath: source.path
            )
            mappings.append((staged, final))
        }
        return mappings.sorted { $0.staged.path < $1.staged.path }
    }

    private func appendActualResultBundlePublicationReceipt(
        _ record: FullLengthONTMHCResultBundlePublicationRecord,
        provenanceURL: URL
    ) throws {
        try writeExecutedPublicationReceipt(
            record,
            provenanceURL: provenanceURL,
            replacingPriorReceipt: false
        )
    }

    private func writeExecutedPublicationReceipt(
        _ record: FullLengthONTMHCResultBundlePublicationRecord,
        provenanceURL: URL,
        replacingPriorReceipt: Bool
    ) throws {
        let publicationStep = record.provenanceStep
        guard let envelope = try ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL) else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Published result bundle is missing its staged provenance receipt."
            )
        }
        guard let receiptCompletedAt = publicationStep.completedAt else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Executed publication receipt is missing its completion time."
            )
        }
        var resolvedDefaults = envelope.options.resolvedDefaults
        resolvedDefaults["mhcResultBundleAtomicPublication"] = .string(
            record.publicationMechanism == "renameatx_np"
                ? "adjacent-directory-renameatx_np"
                : record.publicationMechanism
        )
        resolvedDefaults["mhcSuccessManifestAtomicPublication"] = .string(record.successManifestMechanism)
        let options = ProvenanceOptions(
            explicit: envelope.options.explicit,
            defaults: envelope.options.defaults,
            resolvedDefaults: resolvedDefaults
        )
        var steps = envelope.steps
        if replacingPriorReceipt,
           let index = steps.lastIndex(where: {
               $0.toolName == "lungfish-internal publish-result-bundle"
           }) {
            steps[index] = publicationStep
        } else {
            steps.append(publicationStep)
        }
        let updated = ProvenanceEnvelope(
            schemaVersion: envelope.schemaVersion,
            id: envelope.id,
            createdAt: envelope.createdAt,
            workflowName: envelope.workflowName,
            workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName,
            toolVersion: envelope.toolVersion,
            githubReleaseVersion: envelope.githubReleaseVersion,
            tool: envelope.tool,
            argv: envelope.argv,
            durableReplayArgv: envelope.durableReplayArgv,
            reproducibleCommand: envelope.reproducibleCommand,
            options: options,
            runtimeIdentity: envelope.runtimeIdentity,
            files: envelope.files,
            output: envelope.output,
            outputs: envelope.outputs,
            steps: steps,
            wallTimeSeconds: receiptCompletedAt.timeIntervalSince(envelope.createdAt),
            exitStatus: 0,
            stderr: envelope.stderr,
            signatures: envelope.signatures,
            legacyWorkflowRun: envelope.legacyRun
        )
        try ProvenanceWriter(signingProvider: nil).write(updated, toSidecar: provenanceURL)
    }

    private func publishRelocatedSuccessManifest(
        in finalOutputURL: URL,
        publicationRecord: FullLengthONTMHCResultBundlePublicationRecord
    ) throws -> FullLengthONTMHCResultBundlePublicationRecord {
        let entries = try FileManager.default.contentsOfDirectory(
            at: finalOutputURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".\(ONTGenotypeResultBundleManifest.filename).staging-")
        }
        guard entries.count == 1, let stagedURL = entries.first else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Expected exactly one staged success manifest after result publication."
            )
        }
        let finalURL = ONTGenotypeResultBundle.manifestURL(in: finalOutputURL)
        let checksum = try ProvenanceFileHasher.sha256(of: stagedURL) {
            try Task.checkCancellation()
        }
        let size = try ProvenanceFileHasher.fileSize(of: stagedURL)
        let plan = FullLengthONTMHCSuccessManifestPublicationPlan(
            stagedURL: stagedURL,
            finalURL: finalURL,
            stagedDescriptor: .init(
                path: stagedURL.path,
                checksumSHA256: checksum,
                fileSize: size,
                role: .input
            ),
            finalDescriptor: .init(
                path: finalURL.path,
                checksumSHA256: checksum,
                fileSize: size,
                role: .output,
                originPath: stagedURL.path
            )
        )
        if publicationRecord.successManifestMechanism == "exclusive-file-reservation-then-rename" {
            try publishSuccessManifestUsingExclusiveReservation(plan)
            return publicationRecord
        }
        do {
            try publishSuccessManifestUsingRenameExclusive(plan)
            return publicationRecord
        } catch let error as FullLengthONTMHCExclusiveRenameUnsupportedError {
            let updatedRecord = publicationRecord.recordingSuccessManifestFallback(
                reason: error.localizedDescription
            )
            let provenanceURL = finalOutputURL.appendingPathComponent(
                "full-length-ont-mhc-genotyping-provenance.json"
            )
            try writeExecutedPublicationReceipt(
                updatedRecord,
                provenanceURL: provenanceURL,
                replacingPriorReceipt: true
            )
            try metadataPublicationObserver(.provenanceFinalizedBeforeManifestPublication(
                finalManifestURL: finalURL,
                provenanceURL: provenanceURL
            ))
            try publishSuccessManifestUsingExclusiveReservation(plan)
            return updatedRecord
        }
    }

    private func rollbackPublishedResultBundle(
        stagedOutputURL: URL,
        finalOutputURL: URL,
        replacingExisting: Bool
    ) throws {
        try rollbackOperationObserver()
        if replacingExisting {
            let status = stagedOutputURL.path.withCString { stagedPath in
                finalOutputURL.path.withCString { finalPath in
                    Darwin.renameatx_np(
                        AT_FDCWD,
                        stagedPath,
                        AT_FDCWD,
                        finalPath,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            guard status == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            try FileManager.default.removeItem(at: finalOutputURL)
        }
    }

    private func rollbackProvenanceStep(
        for publicationRecord: FullLengthONTMHCResultBundlePublicationRecord,
        startedAt: Date,
        completedAt: Date,
        exitStatus: Int,
        errorMessage: String?,
        recovery: FullLengthONTMHCRollbackFailureRecovery? = nil
    ) -> ProvenanceStep {
        let action = publicationRecord.replacingExisting
            ? "swap-prior-generation-back"
            : "remove-published-generation"
        var argv = [
            "lungfish-internal", "rollback-result-bundle",
            "--action", action,
            "--atomic-mechanism", publicationRecord.replacingExisting ? "renameatx_np" : "removeItem",
            publicationRecord.finalDirectoryURL.path,
            publicationRecord.stagedDirectoryURL.path,
        ]
        if let path = recovery?.retainedPriorGenerationURL?.path {
            argv += ["--retained-prior-generation", path]
        }
        if let path = recovery?.retainedFailedPublishedGenerationURL?.path {
            argv += ["--retained-failed-published-generation", path]
        }
        return ProvenanceStep(
            toolName: "lungfish-internal rollback-result-bundle",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            resolvedOptions: [
                "rollbackAction": .string(action),
                "publicationMode": .string(publicationRecord.replacingExisting ? "replace" : "create"),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: publicationRecord.provenanceStep.outputs.map { $0.withRole(.input) },
            outputs: [],
            exitStatus: exitStatus,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: errorMessage,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func retainRollbackFailureGenerations(
        after publicationRecord: FullLengthONTMHCResultBundlePublicationRecord
    ) -> FullLengthONTMHCRollbackFailureRecovery {
        let fileManager = FileManager.default
        let stagedURL = publicationRecord.stagedDirectoryURL.standardizedFileURL
        let finalURL = publicationRecord.finalDirectoryURL.standardizedFileURL
        let retainedPriorURL: URL? = publicationRecord.replacingExisting
            && fileManager.fileExists(atPath: stagedURL.path)
            ? stagedURL
            : nil
        guard fileManager.fileExists(atPath: finalURL.path) else {
            return FullLengthONTMHCRollbackFailureRecovery(
                retainedPriorGenerationURL: retainedPriorURL,
                retainedFailedPublishedGenerationURL: nil,
                quarantineError: nil
            )
        }
        let quarantineURL = publicationRecord.replacingExisting
            ? URL(fileURLWithPath: stagedURL.path + ".published-recovery", isDirectory: true)
            : stagedURL
        let status = finalURL.path.withCString { finalPath in
            quarantineURL.path.withCString { quarantinePath in
                PortableExclusiveRename.renameatxNP(
                    AT_FDCWD,
                    finalPath,
                    AT_FDCWD,
                    quarantinePath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if status == 0 {
            return FullLengthONTMHCRollbackFailureRecovery(
                retainedPriorGenerationURL: retainedPriorURL,
                retainedFailedPublishedGenerationURL: quarantineURL,
                quarantineError: nil
            )
        }
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        return FullLengthONTMHCRollbackFailureRecovery(
            retainedPriorGenerationURL: retainedPriorURL,
            retainedFailedPublishedGenerationURL: finalURL,
            quarantineError: "Could not quarantine failed published generation at \(quarantineURL.path): \(error.localizedDescription)"
        )
    }

    private func relocatedResult(
        _ result: FullLengthONTMHCGenotypingResult,
        from stagedOutputURL: URL,
        to finalOutputURL: URL,
        additionalCleanupWarnings: [FullLengthONTMHCGenotypingCleanupWarning] = []
    ) -> FullLengthONTMHCGenotypingResult {
        func relocated(_ url: URL?) -> URL? {
            guard let url else { return nil }
            let stagedComponents = stagedOutputURL.standardizedFileURL.pathComponents
            let components = url.standardizedFileURL.pathComponents
            guard components.count >= stagedComponents.count,
                  Array(components.prefix(stagedComponents.count)) == stagedComponents else {
                return url
            }
            return components.dropFirst(stagedComponents.count).reduce(finalOutputURL) {
                $0.appendingPathComponent($1)
            }
        }
        return FullLengthONTMHCGenotypingResult(
            outputDirectory: finalOutputURL,
            reportCSVURL: relocated(result.reportCSVURL)!,
            sampleSummaryCSVURL: relocated(result.sampleSummaryCSVURL)!,
            statsJSONURL: relocated(result.statsJSONURL)!,
            workbookURL: relocated(result.workbookURL)!,
            primaryWorkbookURL: relocated(result.primaryWorkbookURL)!,
            haplotypeAnalysisURL: relocated(result.haplotypeAnalysisURL),
            unmatchedClustersFASTAURL: relocated(result.unmatchedClustersFASTAURL)!,
            deduplicatedUnmatchedClustersFASTAURL: relocated(result.deduplicatedUnmatchedClustersFASTAURL)!,
            cdnaClustersFASTAURL: relocated(result.cdnaClustersFASTAURL)!,
            provenanceURL: relocated(result.provenanceURL)!,
            referenceFASTAURL: result.referenceFASTAURL,
            genotypingEvidenceBAMURL: relocated(result.genotypingEvidenceBAMURL),
            genotypingEvidenceBAIURL: relocated(result.genotypingEvidenceBAIURL),
            reciprocalEvidenceBAMURL: relocated(result.reciprocalEvidenceBAMURL),
            reciprocalEvidenceBAIURL: relocated(result.reciprocalEvidenceBAIURL),
            candidateAllelesJSONURL: relocated(result.candidateAllelesJSONURL),
            candidateAllelesFASTAURL: relocated(result.candidateAllelesFASTAURL),
            candidateAllelesGenBankURL: relocated(result.candidateAllelesGenBankURL),
            unnameableClustersJSONURL: relocated(result.unnameableClustersJSONURL),
            unnameableClustersFASTAURL: relocated(result.unnameableClustersFASTAURL),
            unnameableClustersGenBankURL: relocated(result.unnameableClustersGenBankURL),
            cleanupWarnings: result.cleanupWarnings.map { warning in
                guard warning.path.hasPrefix(stagedOutputURL.path) else { return warning }
                return FullLengthONTMHCGenotypingCleanupWarning(
                    kind: warning.kind,
                    path: warning.path.replacingOccurrences(
                        of: stagedOutputURL.path,
                        with: finalOutputURL.path
                    ),
                    error: warning.error,
                    publishedArtifactsRemainValid: warning.publishedArtifactsRemainValid
                )
            } + additionalCleanupWarnings
        )
    }

    private func completeSuccessfulWorkDirectoryLifecycle(
        stagedRun: FullLengthONTMHCStagedRunResult,
        finalOutputURL: URL,
        projectRoot: URL,
        runID: UUID,
        keepIntermediates: Bool,
        cleanupPlan: GenotypingCleanupPlan
    ) -> FullLengthWorkDirectoryCleanupResult {
        if keepIntermediates {
            var warnings: [FullLengthONTMHCGenotypingCleanupWarning] = []
            var dispositions: [GenotypingWorkDirectoryDisposition] = []
            for (url, kind) in [
                (
                    stagedRun.cohortWorkDirectory,
                    FullLengthONTMHCGenotypingCleanupWarningKind
                        .cohortAlignmentWorkDirectory
                ),
                (
                    stagedRun.candidateWorkDirectory,
                    FullLengthONTMHCGenotypingCleanupWarningKind
                        .candidateArtifactWorkDirectory
                ),
            ] {
                let disposition = identityBoundRetainedDisposition(
                    plan: cleanupPlan,
                    url: url
                ) { detachedURL in
                    try OwnedWorkDirectoryMarkerStore.transition(
                        detachedURL,
                        expectedProjectURL: projectRoot,
                        expectedRunID: runID,
                        to: .completed
                    )
                }
                dispositions.append(disposition)
                if let error = disposition.error {
                    warnings.append(
                        .init(
                            kind: kind,
                            path: url.standardizedFileURL.path,
                            error: error,
                            publishedArtifactsRemainValid: true
                        )
                    )
                }
            }
            let workflowDirectory = finalOutputURL.appendingPathComponent(
                "workflow",
                isDirectory: true
            )
            if cleanupPlan.entry(for: workflowDirectory) != nil {
                let disposition = identityBoundRetainedDisposition(
                    plan: cleanupPlan,
                    url: workflowDirectory,
                    mutation: { _ in }
                )
                dispositions.append(disposition)
                if let error = disposition.error {
                    warnings.append(.init(
                        kind: .workflowIntermediates,
                        path: workflowDirectory.standardizedFileURL.path,
                        error: error,
                        publishedArtifactsRemainValid: true
                    ))
                }
            }
            return .init(warnings: warnings, dispositions: dispositions)
        }

        var warnings: [FullLengthONTMHCGenotypingCleanupWarning] = []
        var dispositions: [GenotypingWorkDirectoryDisposition] = []
        var cohortTemporaryCleanupFailed = false
        if cleanupPlan.entry(
            for: stagedRun.cohortTemporaryWorkDirectory
        ) != nil {
            let disposition = identityBoundRemovalDisposition(
                plan: cleanupPlan,
                url: stagedRun.cohortTemporaryWorkDirectory,
                successDisposition: "removed"
            ) {
                try postPublicationWorkDirectoryCleaner.removeWorkDirectory(
                    at: $0
                )
            }
            dispositions.append(disposition)
            if let error = disposition.error {
                cohortTemporaryCleanupFailed = true
                warnings.append(
                    .init(
                        kind: .cohortAlignmentTemporaryWorkDirectory,
                        path:
                            stagedRun.cohortTemporaryWorkDirectory
                                .standardizedFileURL.path,
                        error: error,
                        publishedArtifactsRemainValid: true
                    )
                )
            }
        }
        for (url, kind) in [
            (
                stagedRun.cohortWorkDirectory,
                FullLengthONTMHCGenotypingCleanupWarningKind
                    .cohortAlignmentWorkDirectory
            ),
            (
                stagedRun.candidateWorkDirectory,
                FullLengthONTMHCGenotypingCleanupWarningKind
                    .candidateArtifactWorkDirectory
            ),
        ] {
            if kind == .cohortAlignmentWorkDirectory,
               cohortTemporaryCleanupFailed {
                dispositions.append(.init(
                    path: url.standardizedFileURL.path,
                    disposition: "retained-cleanup-failed",
                    error:
                        "Retained because cleanup of the nested cohort "
                        + "alignment temporary work directory failed."
                ))
                continue
            }
            let disposition = identityBoundRemovalDisposition(
                plan: cleanupPlan,
                url: url,
                successDisposition: "removed"
            ) { detachedURL in
                try OwnedWorkDirectoryMarkerStore.transition(
                    detachedURL,
                    expectedProjectURL: projectRoot,
                    expectedRunID: runID,
                    to: .completed
                )
                try postPublicationWorkDirectoryCleaner.removeWorkDirectory(
                    at: detachedURL
                )
            }
            dispositions.append(disposition)
            if let error = disposition.error {
                warnings.append(
                    .init(
                        kind: kind,
                        path: url.standardizedFileURL.path,
                        error: error,
                        publishedArtifactsRemainValid: true
                    )
                )
            }
        }
        let relocatedWorkflowDirectory = finalOutputURL
            .appendingPathComponent("workflow", isDirectory: true)
        if cleanupPlan.entry(for: relocatedWorkflowDirectory) != nil {
            let workflowPath = relocatedWorkflowDirectory
                .standardizedFileURL.path
            let workflowEntries = cleanupPlan.entries.filter {
                $0.path == workflowPath
                    || $0.path.hasPrefix(workflowPath + "/")
            }.sorted {
                $0.path.split(separator: "/").count
                    > $1.path.split(separator: "/").count
            }
            var protectedDescendants: [String] = []
            for entry in workflowEntries {
                let url = URL(fileURLWithPath: entry.path)
                if protectedDescendants.contains(where: {
                    $0.hasPrefix(entry.path + "/")
                }) {
                    let disposition = GenotypingWorkDirectoryDisposition(
                        path: entry.path,
                        disposition: "retained-cleanup-failed",
                        error:
                            "Retained because an identity-mismatched or "
                            + "unremovable descendant must survive."
                    )
                    dispositions.append(disposition)
                    protectedDescendants.append(entry.path)
                    warnings.append(.init(
                        kind: .workflowIntermediates,
                        path: entry.path,
                        error: disposition.error ?? "Cleanup was retained.",
                        publishedArtifactsRemainValid: true
                    ))
                    continue
                }
                let disposition = identityBoundRemovalDisposition(
                    plan: cleanupPlan,
                    url: url,
                    successDisposition:
                        entry.path == workflowPath
                            ? "intermediates-removed"
                            : "removed"
                ) {
                    try postPublicationWorkDirectoryCleaner
                        .removeWorkDirectory(at: $0)
                }
                dispositions.append(disposition)
                if let error = disposition.error {
                    protectedDescendants.append(entry.path)
                    warnings.append(.init(
                        kind: .workflowIntermediates,
                        path: entry.path,
                        error: error,
                        publishedArtifactsRemainValid: true
                    ))
                }
            }
        }
        return .init(warnings: warnings, dispositions: dispositions)
    }

    private func identityBoundRemovalDisposition(
        plan: GenotypingCleanupPlan,
        url: URL,
        successDisposition: String,
        remover: (URL) throws -> Void
    ) -> GenotypingWorkDirectoryDisposition {
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
    ) -> GenotypingWorkDirectoryDisposition {
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

    private func beginSuccessfulCleanupJournal(
        projectRoot: URL,
        runID: UUID,
        stagedRun: FullLengthONTMHCStagedRunResult,
        finalOutputURL: URL,
        retiredPublicationURL: URL?,
        keepIntermediates: Bool
    ) throws -> GenotypingCleanupPlan {
        let operationURL = ProjectOperationHistoryWriter(
            projectURL: projectRoot
        ).operationDirectoryURL(for: runID)
        let cleanupPlanURL = operationURL.appendingPathComponent(
            GenotypingCleanupJournal.planPayloadName
        )
        do {
            var candidates: [
                (
                    url: URL,
                    intendedAction: GenotypingCleanupIntendedAction
                )
            ] = [
                (
                    stagedRun.cohortWorkDirectory,
                    keepIntermediates
                        ? .retainByRequestAfterMarkerCompletion
                        : .removeOwnedWorkDirectory
                ),
                (
                    stagedRun.candidateWorkDirectory,
                    keepIntermediates
                        ? .retainByRequestAfterMarkerCompletion
                        : .removeOwnedWorkDirectory
                ),
            ]
            let workflowDirectory = finalOutputURL.appendingPathComponent(
                "workflow",
                isDirectory: true
            )
            if keepIntermediates {
                candidates.append(
                    (workflowDirectory, .retainByRequest)
                )
            } else {
                let descendantPaths =
                    try FileManager.default.subpathsOfDirectory(
                        atPath: workflowDirectory.path
                    )
                candidates.append(contentsOf: descendantPaths.map {
                    (
                        workflowDirectory.appendingPathComponent($0),
                        .removeRegenerableWorkflowIntermediates
                    )
                })
                candidates.append(
                    (
                        workflowDirectory,
                        .removeRegenerableWorkflowIntermediates
                    )
                )
            }
            if !keepIntermediates {
                candidates.insert(
                    (
                        stagedRun.cohortTemporaryWorkDirectory,
                        .removeOwnedTemporaryWorkDirectory
                    ),
                    at: 0
                )
            }
            if let retiredPublicationURL {
                candidates.append(
                    (
                        retiredPublicationURL,
                        .removeRetiredPublicationDirectory
                    )
                )
            }
            let entries = try GenotypingCleanupJournal.planEntries(candidates)
            try cleanupJournalObserver(.beforeInitialCreation)
            _ = try ProjectOperationHistoryWriter(
                projectURL: projectRoot
            ).createOperation(
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
                operationURL: operationURL,
                outputBundleURL: finalOutputURL,
                entriesByPath: Dictionary(
                    uniqueKeysWithValues: entries.map { ($0.path, $0) }
                )
            )
            try cleanupJournalObserver(
                .afterInitialCreationBeforeMutation
            )
            return plan
        } catch {
            throw GenotypingCleanupJournalError(
                runID: runID,
                operationPath: operationURL.path,
                cleanupPlanPath: cleanupPlanURL.path,
                outputBundlePath: finalOutputURL.path,
                phase: .initialCreation,
                publishedArtifactsValid: true,
                retainedRootPaths:
                    [
                        stagedRun.cohortWorkDirectory,
                        stagedRun.candidateWorkDirectory,
                        finalOutputURL.appendingPathComponent("workflow"),
                        retiredPublicationURL,
                    ].compactMap { $0?.standardizedFileURL.path },
                underlyingDescription: error.localizedDescription
            )
        }
    }

    private func appendSuccessfulCleanupDisposition(
        projectRoot: URL,
        runID: UUID,
        outputBundleURL: URL,
        dispositions: [GenotypingWorkDirectoryDisposition]
    ) throws {
        let operationURL = ProjectOperationHistoryWriter(
            projectURL: projectRoot
        ).operationDirectoryURL(for: runID)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                GenotypingWorkDirectoryDispositionEnvelope(
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
                operationPath: operationURL.path,
                cleanupPlanPath: operationURL.appendingPathComponent(
                    GenotypingCleanupJournal.planPayloadName
                ).path,
                outputBundlePath: outputBundleURL.standardizedFileURL.path,
                phase: .terminalAppend,
                publishedArtifactsValid: true,
                retainedRootPaths: dispositions.filter {
                    $0.disposition != "removed"
                        && $0.disposition != "intermediates-removed"
                }.map(\.path),
                underlyingDescription: error.localizedDescription
            )
        }
    }

    private func failCurrentRunWorkDirectories(
        stagedOutputURL: URL,
        projectRoot: URL,
        runID: UUID,
        keepIntermediates: Bool,
        retainedRecoveryPaths: Set<String>
    ) -> [GenotypingWorkDirectoryDisposition] {
        let siblingParent = stagedOutputURL.deletingLastPathComponent()
        let ordinaryCurrentRunRoots = [
            siblingParent.appendingPathComponent(
                ".\(stagedOutputURL.lastPathComponent).cohort-alignment-work",
                isDirectory: true
            ),
            candidateArtifactWorkDirectory(for: stagedOutputURL),
            stagedOutputURL,
        ]
        let recoveryRoots = retainedRecoveryPaths
            .sorted()
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        var seenPaths = Set<String>()
        let currentRunRoots = (ordinaryCurrentRunRoots + recoveryRoots).filter {
            seenPaths.insert($0.standardizedFileURL.path).inserted
        }
        var dispositions: [GenotypingWorkDirectoryDisposition] = []
        for url in currentRunRoots {
            let path = url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path) else {
                continue
            }
            if retainedRecoveryPaths.contains(path) {
                do {
                    let markerURL = url.appendingPathComponent(
                        OwnedWorkDirectoryMarker.fileName
                    )
                    if FileManager.default.fileExists(atPath: markerURL.path) {
                        let marker = try OwnedWorkDirectoryMarkerStore.load(
                            from: url,
                            expectedProjectURL: projectRoot
                        )
                        if marker.state == .active {
                            try OwnedWorkDirectoryMarkerStore.transition(
                                url,
                                expectedProjectURL: projectRoot,
                                expectedRunID: runID,
                                to: .failed
                            )
                        }
                    }
                    dispositions.append(.init(
                        path: path,
                        disposition: "retained-rollback-recovery",
                        error: nil
                    ))
                } catch {
                    dispositions.append(.init(
                        path: path,
                        disposition: "retained-cleanup-failed",
                        error: cleanupErrorDescription(error)
                    ))
                }
                continue
            }
            do {
                try OwnedWorkDirectoryMarkerStore.transition(
                    url,
                    expectedProjectURL: projectRoot,
                    expectedRunID: runID,
                    to: .failed
                )
                if keepIntermediates {
                    dispositions.append(
                        .init(
                            path: path,
                            disposition: "retained-by-request",
                            error: nil
                        )
                    )
                } else {
                    try postPublicationWorkDirectoryCleaner
                        .removeWorkDirectory(at: url)
                    dispositions.append(
                        .init(
                            path: path,
                            disposition: "removed",
                            error: nil
                        )
                    )
                }
            } catch {
                dispositions.append(
                    .init(
                        path: path,
                        disposition: "retained-cleanup-failed",
                        error: cleanupErrorDescription(error)
                    )
                )
            }
        }
        return dispositions
    }

    private func projectRelativePath(_ url: URL, projectRoot: URL) -> String? {
        let rootPath = projectRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func bindSiblingWorkDirectory(
        _ directoryURL: URL,
        stagedOutputURL: URL,
        request: FullLengthONTMHCGenotypingRunRequest
    ) throws {
        let projectRoot = (request.projectURL
            ?? stagedOutputURL.deletingLastPathComponent()).standardizedFileURL
        let rootMarker = try OwnedWorkDirectoryMarkerStore.load(
            from: stagedOutputURL,
            expectedProjectURL: projectRoot
        )
        try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
            directoryURL,
            request: OwnedWorkDirectoryCreationRequest(
                projectURL: projectRoot,
                parentDirectoryURL: directoryURL.deletingLastPathComponent(),
                prefix: ".full-length-ont-mhc-work-",
                runID: rootMarker.runID,
                processIdentity: OwnedProcessIdentity(
                    processIdentifier: rootMarker.processIdentifier,
                    processStartTime: rootMarker.processStartTime,
                    bootSessionID: rootMarker.bootSessionID
                ),
                state: .active,
                lockRelativePath: rootMarker.lockRelativePath,
                keepIntermediates: rootMarker.keepIntermediates,
                toolName: rootMarker.toolName,
                toolVersion: rootMarker.toolVersion
            )
        )
    }

    private func candidateArtifactWorkDirectory(for outputDirectoryURL: URL) -> URL {
        outputDirectoryURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(outputDirectoryURL.lastPathComponent).candidate-artifact-work",
                isDirectory: true
            )
    }

    private func retainCandidateFailureLogs(
        from candidateWorkDirectory: URL,
        for request: FullLengthONTMHCGenotypingRunRequest
    ) throws -> URL? {
        let safety = FullLengthONTMHCAlignmentSafety()
        try safety.requireSafeDirectoryTree(
            candidateWorkDirectory,
            role: "failed candidate artifact work directory"
        )
        guard let enumerator = FileManager.default.enumerator(
            at: candidateWorkDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return nil
        }
        let maximumRetainedLogCount = 32
        let maximumRetainedLogBytes: Int64 = 2 * 1_024 * 1_024
        var logURLs: [URL] = []
        for case let url as URL in enumerator {
            if logURLs.count == maximumRetainedLogCount {
                break
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            guard url.pathComponents.contains("logs")
                    || url.pathExtension.lowercased() == "log" else {
                continue
            }
            try safety.requireRegularFileNoFollow(
                url,
                role: "failed candidate artifact log"
            )
            guard try ProvenanceFileHasher.fileSize(of: url)
                <= maximumRetainedLogBytes else {
                continue
            }
            logURLs.append(url)
        }
        guard !logURLs.isEmpty else { return nil }
        let diagnosticsRoot = URL(
            fileURLWithPath: request.failureProvenanceURL.path + ".diagnostics",
            isDirectory: true
        )
        let retainedLogsRoot = diagnosticsRoot.appendingPathComponent(
            "candidate-artifact-logs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: retainedLogsRoot,
            withIntermediateDirectories: true
        )
        let sourcePrefix = candidateWorkDirectory.standardizedFileURL.path + "/"
        for sourceURL in logURLs.sorted(by: { $0.path < $1.path }) {
            let relativePath = sourceURL.standardizedFileURL.path
                .replacingOccurrences(of: sourcePrefix, with: "")
            let destinationURL = retainedLogsRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
        return diagnosticsRoot
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

    func mhcReferenceRecords(
        sourceURL: URL,
        fastaURL: URL,
        cdnaThreshold: Int
    ) throws -> [MHCReferenceRecord] {
        if sourceURL.pathExtension.lowercased() == "lungfishref" {
            return try MHCReferenceRecordCatalog.load(
                from: sourceURL,
                cdnaThreshold: cdnaThreshold
            ).records
        }
        return try FullLengthONTMHCClusterGenotyper.readFASTARecords(from: fastaURL).map { record in
            let sequenceID = record.name.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
                ?? record.name
            let alleleName = sequenceID
            let locus = alleleName.split(separator: "*", maxSplits: 1).first.map(String.init)
                ?? alleleName
            return MHCReferenceRecord(
                sequenceID: sequenceID,
                alleleName: alleleName,
                locus: locus,
                moleculeClass: record.sequence.count < cdnaThreshold ? .cDNA : .genomicDNA,
                classEvidence: .lengthThresholdFallback,
                sequenceLength: record.sequence.count
            )
        }
    }

    func mhcReferenceCatalogInputURLs(
        sourceURL: URL,
        fastaURL: URL
    ) throws -> [URL] {
        try mhcReferenceCatalogInputs(sourceURL: sourceURL, fastaURL: fastaURL).allURLs
    }

    private func mhcReferenceVisualizationInputURLs(
        sourceURL: URL,
        fastaURL: URL
    ) throws -> [URL] {
        var urls = try mhcReferenceCatalogInputURLs(sourceURL: sourceURL, fastaURL: fastaURL)
        let manifest = try BundleManifest.load(from: sourceURL)
        func appendBundleMember(_ path: String, field: String) throws {
            let url = try BundleManifest.validatedBundleMemberURL(
                for: path,
                in: sourceURL,
                field: field
            ).standardizedFileURL
            if !urls.contains(where: { $0.standardizedFileURL == url }) {
                urls.append(url)
            }
        }
        if let genome = manifest.genome {
            try appendBundleMember(genome.indexPath, field: "genome.index_path")
            if let gzipIndexPath = genome.gzipIndexPath {
                try appendBundleMember(gzipIndexPath, field: "genome.gzip_index_path")
            }
        }
        for annotation in manifest.annotations {
            if let databasePath = annotation.databasePath, !databasePath.isEmpty {
                try appendBundleMember(
                    databasePath,
                    field: "annotations[\(annotation.id)].database_path"
                )
            }
        }
        return urls
    }

    private func mhcReferenceCatalogInputs(
        sourceURL: URL,
        fastaURL: URL
    ) throws -> FullLengthONTMHCReferenceCatalogInputs {
        let source = sourceURL.standardizedFileURL
        let fasta = fastaURL.standardizedFileURL
        if source.pathExtension.lowercased() == "lungfishref" {
            let manifestURL = source.appendingPathComponent("manifest.json").standardizedFileURL
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(FullLengthONTMHCReferenceInputManifest.self, from: data)
            var recordStoreURL: URL?
            if let databasePath = manifest.recordStore?.databasePath,
               !databasePath.isEmpty {
                recordStoreURL = try BundleManifest.validatedBundleMemberURL(
                    for: databasePath,
                    in: source,
                    field: "record_store.database_path"
                ).standardizedFileURL
            }
            return FullLengthONTMHCReferenceCatalogInputs(
                fastaURL: fasta,
                manifestURL: manifestURL,
                recordStoreURL: recordStoreURL
            )
        }
        if MHCAmpliconReferenceBundle.isBundleURL(source) {
            return FullLengthONTMHCReferenceCatalogInputs(
                fastaURL: fasta,
                manifestURL: MHCAmpliconReferenceBundle.manifestURL(in: source).standardizedFileURL,
                recordStoreURL: nil
            )
        }
        return FullLengthONTMHCReferenceCatalogInputs(
            fastaURL: fasta,
            manifestURL: nil,
            recordStoreURL: nil
        )
    }

    private func materializeMHCReferenceCatalog(
        sourceURL: URL,
        fastaURL: URL,
        cdnaThreshold: Int,
        outputURL: URL
    ) throws -> (records: [MHCReferenceRecord], step: FullLengthONTMHCProvenanceStep) {
        let inputs = try mhcReferenceCatalogInputs(sourceURL: sourceURL, fastaURL: fastaURL)
        var argv = [
            "lungfish-in-process", "import-mhc-reference-catalog",
            "--reference-fasta", inputs.fastaURL.path,
        ]
        if let manifestURL = inputs.manifestURL {
            argv += ["--reference-bundle-manifest", manifestURL.path]
        }
        if let recordStoreURL = inputs.recordStoreURL {
            argv += ["--record-store", recordStoreURL.path]
        }
        argv += [
            "--cdna-threshold", String(cdnaThreshold),
            "--output", outputURL.path,
        ]

        let startedAt = Date()
        do {
            let records = try mhcReferenceRecords(
                sourceURL: sourceURL,
                fastaURL: fastaURL,
                cdnaThreshold: cdnaThreshold
            )
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(FullLengthONTMHCReferenceCatalogProjection(
                cdnaThreshold: cdnaThreshold,
                records: records
            )).write(to: outputURL, options: .atomic)
            let projection = try JSONDecoder().decode(
                FullLengthONTMHCReferenceCatalogProjection.self,
                from: Data(contentsOf: outputURL)
            )
            let completedAt = Date()
            return (
                projection.records,
                FullLengthONTMHCProvenanceStep(
                    toolName: "lungfish-in-process:import-mhc-reference-catalog",
                    toolVersion: WorkflowRun.currentAppVersion,
                    argv: argv,
                    resolvedOptions: [
                        "recordCount": .integer(projection.records.count),
                        "cdnaThreshold": .integer(cdnaThreshold),
                        "moleculeClassSource": .string("reference-metadata-with-length-fallback"),
                    ],
                    inputs: inputs.allURLs,
                    outputs: [outputURL],
                    exitStatus: 0,
                    stderr: nil,
                    startedAt: startedAt,
                    completedAt: completedAt
                )
            )
        } catch {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "MHC reference catalog import failed after \(Date().timeIntervalSince(startedAt)) seconds: \(error.localizedDescription)"
            )
        }
    }

    private func materializeFASTQ(
        inputURL: URL,
        sample: String,
        sampleDirectory: URL,
        logicalFinalOutputURL: URL
    ) throws -> FullLengthONTMHCFASTQMaterializationResult {
        let outputURL = sampleDirectory.appendingPathComponent("00-input.fastq")
        return try FullLengthONTMHCFASTQMaterializer.materializePlainFASTQ(
            inputURL: inputURL,
            outputURL: outputURL,
            logicalOutputURL: logicalFinalOutputURL
                .appendingPathComponent("workflow", isDirectory: true)
                .appendingPathComponent(sample, isDirectory: true)
                .appendingPathComponent("00-input.fastq")
        )
    }

    private func stageSamples(
        request: FullLengthONTMHCGenotypingRunRequest,
        workDirectory: URL,
        logicalFinalOutputURL: URL,
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
            let materialization = try materializeFASTQ(
                inputURL: inputURL,
                sample: sample,
                sampleDirectory: sampleDirectory,
                logicalFinalOutputURL: logicalFinalOutputURL
            )
            let materializedFASTQ = materialization.outputURL
            let readCount = fastqReadCount(materializedFASTQ)
            stagedSamples.append(FullLengthONTMHCScheduledSample(
                originalIndex: index,
                inputURL: inputURL,
                sample: sample,
                sampleDirectory: sampleDirectory,
                materializedFASTQURL: materializedFASTQ,
                readCount: readCount,
                materializationStep: materialization.step
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
        samURL: URL,
        cohortAlignmentResult: FullLengthONTMHCCohortAlignmentResult,
        referenceFASTAURL: URL,
        referenceRecords: [MHCReferenceRecord],
        request: FullLengthONTMHCGenotypingRunRequest
    ) throws -> [String: FullLengthONTMHCClusterGenotypingSummary] {
        let readGroupBySample = Dictionary(
            uniqueKeysWithValues: cohortAlignmentResult.sampleMappings.map {
                ($0.sampleID, $0.readGroupID)
            }
        )
        return try FullLengthONTMHCFinalBAMParser().genotypeSummaries(
            samURL: samURL,
            referenceFASTAURL: referenceFASTAURL,
            referenceRecords: referenceRecords,
            samples: orderedResults.map { result in
                FullLengthONTMHCFinalBAMSampleContext(
                    sampleID: result.sample,
                    readGroupID: readGroupBySample[result.sample],
                    clusterRecords: result.clusterRecords
                )
            },
            cdnaThreshold: request.cdnaThreshold,
            minUnmatchedReads: request.minUnmatchedReads
        )
    }

    private func reciprocalKnownGenotypeRows(
        from result: FullLengthONTMHCCandidateArtifactResult
    ) -> [FullLengthONTMHCClusterGenotypeRow] {
        return zip(result.classifiedClusters, result.classifications).flatMap {
            (cluster, classification) -> [FullLengthONTMHCClusterGenotypeRow] in
            guard case .known(let calls) = classification else { return [] }
            return calls.flatMap { call in
                cluster.observations.flatMap { observation in
                    observation.sourceClusterIDs.compactMap { sourceClusterID in
                        guard let reads = observation.sourceClusterReadCounts[sourceClusterID] else { return nil }
                        return FullLengthONTMHCClusterGenotypeRow(
                            sample: observation.sampleID,
                            cluster: sourceClusterID,
                            clusterReads: reads,
                            allele: call.reference.alleleName,
                            alleleLength: call.reference.sequenceLength,
                            alignedBases: call.comparableBases,
                            score: call.alignmentScore,
                            referenceSequenceID: call.reference.sequenceID,
                            mappingQuality: call.mappingQuality,
                            cigar: call.cigar,
                            evidence: call.evidence
                        )
                    }
                }
            }
        }.sorted {
            if $0.sample != $1.sample {
                return $0.sample.localizedStandardCompare($1.sample) == .orderedAscending
            }
            if $0.allele != $1.allele {
                return $0.allele.localizedStandardCompare($1.allele) == .orderedAscending
            }
            if $0.cluster != $1.cluster {
                return $0.cluster.localizedStandardCompare($1.cluster) == .orderedAscending
            }
            if $0.referenceSequenceID != $1.referenceSequenceID {
                return ($0.referenceSequenceID ?? "").localizedStandardCompare(
                    $1.referenceSequenceID ?? ""
                ) == .orderedAscending
            }
            return ($0.cigar ?? "").localizedStandardCompare($1.cigar ?? "") == .orderedAscending
        }
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
        let tsvURL = blastRescueTSVURL(
            sample: sample,
            sampleDirectory: sampleDirectory
        )
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

    private func blastRescueTSVURL(sample: String, sampleDirectory: URL) -> URL {
        sampleDirectory
            .appendingPathComponent("blast-rescue", isDirectory: true)
            .appendingPathComponent("\(sample).unmatched-blast-rescue.tsv")
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
        let assigned = Dictionary(
            genotypeRows.map { ("\($0.sample)\0\($0.cluster)", $0.clusterReads) },
            uniquingKeysWith: max
        ).values.reduce(0, +)
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

    private func workbookSheets(
        reportRows: [FullLengthONTMHCReportRow],
        sampleSummaries: [FullLengthONTMHCSampleSummary],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?,
        projection: FullLengthONTMHCWorkbookProjection,
        normalizedUnmatchedRows: [FullLengthONTMHCNormalizedUnmatchedRow],
        knownAlleleDisplayNames: [String: String]
    ) -> [FullLengthONTMHCXLSXPackageWriter.Sheet] {
        [
            .init(
                name: "Unified Genotype Pivot",
                cells: FullLengthONTMHCUnifiedPivotWorkbookBuilder.buildWorkbookCells(
                    reportRows: reportRows,
                    projection: projection,
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
                    haplotypeAnalysis: haplotypeAnalysis,
                    knownAlleleDisplayNames: knownAlleleDisplayNames
                )
            ),
            .init(
                name: "Unmatched Alleles",
                cells: FullLengthONTMHCUnmatchedWorksheetBuilder.buildCells(
                    rows: normalizedUnmatchedRows,
                    sampleOrder: sampleSummaries.map(\.sample)
                )
            ),
        ]
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
            ["Genotype call rule", "Known genotype calls require zero SNP differences. Indel-only genomic-reference alignments remain calls to the existing allele; true genomic extensions of cDNA references are classified separately with the _ext suffix."],
            ["Score formula", "score = aligned_bases - (100 * snp_differences) - (10 * indel_bases)"],
            ["Score interpretation", "Higher scores are better. Alignments without SNPs or indels have score equal to aligned_bases; each SNP subtracts 100 and each indel base subtracts 10."],
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
            ["Genotypes worksheet", "Cluster-level known genotype evidence. Each row is one sample cluster assigned to one existing reference allele."],
            ["Genotyping pivot worksheet", "Sample-by-genotype pivot formatted for review of full-length genotyping calls and haplotype summaries."],
            ["Unmatched Clusters worksheet", "One row per unmatched cluster with sequence, read support, deterministic unmatched_sequence_id, and closest-match metadata when available."],
            ["Unmatched Shared Pivot worksheet", "One row per unique unmatched sequence with occurrence count, total supporting reads, closest-match summary, and per-sample read counts."],
            ["MHC-like Unmatched Clusters worksheet", "One row per unmatched cluster with either genotyping SAM closest-match evidence or accepted local BLAST rescue evidence."],
            ["MHC-like Unmatched Pivot worksheet", "One row per unique MHC-like unmatched sequence with occurrence count, total supporting reads, best evidence summary, and per-sample read counts."],
            ["Unified Genotype Pivot worksheet", "One sample-by-call pivot combining known reference genotype calls with every classified _nov and _ext candidate. Stable cluster IDs keep distinct sequences on separate rows even when provisional names collide."],
            ["Candidate Alleles worksheet", "One machine-readable row per classified candidate. Every singleton/shared _nov and _ext candidate is retained; color is limited to the provisional-name cell and classification/support columns remain authoritative."],
            ["Un-nameable Clusters worksheet", "One machine-readable row per unmatched cluster that cannot receive a provisional allele name, including the reason, support, FASTA identity, evidence locator, and per-sample reads."],
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
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: .haplotyped,
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
            sha256: try ProvenanceFileHasher.sha256(of: destinationURL) {
                try Task.checkCancellation()
            },
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

    private func publishReviewableRowCatalogIfNeeded(
        request: FullLengthONTMHCGenotypingRunRequest,
        referenceRecords: [MHCReferenceRecord],
        referenceCatalogProjectionURL: URL,
        reportRows: [FullLengthONTMHCReportRow],
        sampleNames: [String],
        candidateDocument: ONTMHCCandidateAllelesDocument,
        candidateJSONURL: URL,
        unnameableDocument: ONTMHCUnnameableClustersDocument,
        unnameableJSONURL: URL,
        genotypingEvidenceBAMURL: URL,
        genotypingEvidenceBAIURL: URL
    ) throws -> GenotypeReviewableRowCatalogPublication? {
        guard request.haplotypeDefinitionSetID == nil else { return nil }
        let csvAuthority = try GenotypeReviewCSVSemanticAuthority.capture(
            sampleSummaryURL: request.sampleSummaryCSVURL,
            reportURL: request.reportCSVURL
        )
        let expectedCalls = reportRows.map {
            ONTGenotypeCall(
                sample: $0.sample,
                genotype: $0.genotype,
                passedAlignments: $0.passedAlignments,
                passedUniqueReads: $0.passedUniqueReads,
                sampleTotalReads: $0.sampleTotalReads,
                sampleUniqueRetainedReads: $0.sampleUniqueRetainedReads,
                sampleUniqueRetainedPercent: $0.sampleUniqueRetainedPercent,
                overallInputReads: $0.overallInputReads,
                overallUniqueRetainedReads: $0.overallUniqueRetainedReads,
                overallUniqueRetainedPercent: $0.overallUniqueRetainedPercent
            )
        }
        try csvAuthority.requireMatches(
            expectedRoster: sampleNames,
            expectedCalls: expectedCalls
        )
        let reviewAuthority = try Self.reviewableCatalogAuthority(
            expectedReferenceRecords: referenceRecords,
            referenceCatalogURL: referenceCatalogProjectionURL,
            expectedCandidateDocument: candidateDocument,
            candidateURL: candidateJSONURL,
            expectedUnnameableDocument: unnameableDocument,
            unnameableURL: unnameableJSONURL
        )
        let exactReferenceRecords = reviewAuthority.referenceRecords
        let exactCandidateDocument = reviewAuthority.candidateDocument
        let sharedCalls = try Self.reviewableSharedCalls(
            csvAuthority.calls,
            referenceRecords: exactReferenceRecords
        )
        let outputURL = request.outputDirectory
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("projections", isDirectory: true)
            .appendingPathComponent("genotype-reviewable-rows.json")
        let argv = [
            "lungfish-internal", "publish-genotype-reviewable-rows",
            "--reference-catalog", referenceCatalogProjectionURL.path,
            "--sample-roster", request.sampleSummaryCSVURL.path,
            "--calls", request.reportCSVURL.path,
            "--candidate-json", candidateJSONURL.path,
            "--unnameable-json", unnameableJSONURL.path,
            "--genotyping-bam", genotypingEvidenceBAMURL.path,
            "--genotyping-bai", genotypingEvidenceBAIURL.path,
            "--output", outputURL.path,
            "--support-metric", "passed-unique-reads",
        ]
        let bamSnapshot = try GenotypeReviewAuthorityFileSnapshot.capture(
            genotypingEvidenceBAMURL,
            retainingData: false
        )
        let baiSnapshot = try GenotypeReviewAuthorityFileSnapshot.capture(
            genotypingEvidenceBAIURL,
            retainingData: false
        )
        let descriptors = [
            reviewAuthority.snapshots[0].descriptor(format: .json, role: .reference),
            csvAuthority.sampleSnapshot.descriptor(format: .text, role: .input),
            csvAuthority.reportSnapshot.descriptor(format: .text, role: .input),
            reviewAuthority.snapshots[1].descriptor(format: .json, role: .input),
            reviewAuthority.snapshots[2].descriptor(format: .json, role: .input),
            bamSnapshot.descriptor(format: .bam, role: .input),
            baiSnapshot.descriptor(format: nil, role: .index),
        ]
        let publication = try reviewableRowCatalogPublisher(
            GenotypeReviewableRowCatalogInputs(
                referenceRecords: exactReferenceRecords,
                authoritativeSamples: csvAuthority.roster,
                calls: sharedCalls,
                candidates:
                    GenotypeReviewableRowCandidate.fullLengthCandidates(
                        from: exactCandidateDocument
                    ) + GenotypeReviewableRowCandidate.fullLengthIncompleteCandidates(
                        from: reviewAuthority.unnameableDocument ?? unnameableDocument
                    ),
                inputDescriptors: descriptors,
                workflowName: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
                workflowVersion: "1",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: argv,
                userVisibleOptions: [
                    "workflowMode": .string(GenotypeResultWorkflowMode.genotypeOnly.rawValue),
                    "candidateDesignation": .string("full-length-candidate-or-incomplete-reference-span-review"),
                ],
                resolvedDefaults: [
                    "supportMetric": .string("passed-unique-reads"),
                    "referenceRowScope": .string("all-exact-run-reference-records"),
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
                try reviewAuthority.requireUnchanged()
                try csvAuthority.requireUnchanged()
                try bamSnapshot.requireMetadataUnchanged()
                try baiSnapshot.requireMetadataUnchanged()
            }
        )
        return publication
    }

    static func reviewableSharedCalls(
        _ calls: [ONTGenotypeCall],
        referenceRecords: [MHCReferenceRecord]
    ) throws -> [ONTGenotypeSharedCall] {
        let recordsBySequenceID = Dictionary(
            uniqueKeysWithValues: referenceRecords.map {
                ($0.sequenceID, $0)
            }
        )
        let recordsByAllele = Dictionary(
            grouping: referenceRecords,
            by: \.alleleName
        )
        var rowsByCall:
            [FullLengthONTMHCReviewCallKey: [ONTGenotypeCall]] = [:]
        for row in calls {
            let reference: MHCReferenceRecord
            if let exact = recordsBySequenceID[row.genotype] {
                reference = exact
            } else if let matches = recordsByAllele[row.genotype],
                      let first = matches.first,
                      Set(matches.map(\.locus)).count == 1 {
                reference = first
            } else {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Authoritative workbook review-row call \(row.genotype) does not resolve to exactly one exact-run reference record."
                )
            }
            let key = FullLengthONTMHCReviewCallKey(
                locus: GenotypeHaplotypeLocusResolver.canonicalLocusName(
                    reference.locus
                ),
                genotype: row.genotype
            )
            rowsByCall[key, default: []].append(row)
        }
        return try rowsByCall.map { key, rows in
            let support = try Dictionary(grouping: rows, by: \.sample)
                .map { sample, sampleRows in
                    ONTGenotypeSampleSupport(
                        sample: sample,
                        passedAlignments: try checkedReviewSupportSum(
                            sampleRows.map(\.passedAlignments),
                            sample: sample
                        ),
                        passedUniqueReads: try checkedReviewSupportSum(
                            sampleRows.map(\.passedUniqueReads),
                            sample: sample
                        )
                    )
                }
            return ONTGenotypeSharedCall(
                locus: key.locus,
                genotype: key.genotype,
                sampleSupport: support
            )
        }
    }

    private static func checkedReviewSupportSum(
        _ values: [Int],
        sample: String
    ) throws -> Int {
        var result = 0
        for value in values {
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else {
                throw GenotypeReviewableRowCatalogPublisherError
                    .invalidSupport(sample: sample, value: value)
            }
            result = addition.partialValue
        }
        return result
    }

    private func publishMHCReferenceVisualizations(
        referenceBundleURL: URL,
        referenceFASTAURL: URL,
        referenceRecords: [MHCReferenceRecord],
        exactCallRows: [FullLengthONTMHCClusterGenotypeRow],
        exactCallInputURL: URL,
        candidateDocument: ONTMHCCandidateAllelesDocument,
        candidateJSONURL: URL,
        unnameableDocument: ONTMHCUnnameableClustersDocument,
        unnameableJSONURL: URL,
        outputDirectoryURL: URL,
        finalOutputDirectoryURL: URL,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) throws -> FullLengthONTMHCReferenceVisualizationPublication? {
        guard referenceBundleURL.pathExtension.lowercased() == "lungfishref",
              isDirectory(referenceBundleURL) else {
            return nil
        }

        let rawReferenceIDs = Set(referenceRecords.map(\.sequenceID))
        let exactKnownRawReferenceIDs = exactCallRows.reduce(into: Set<String>()) { ids, row in
            if let referenceSequenceID = row.referenceSequenceID,
               rawReferenceIDs.contains(referenceSequenceID) {
                ids.insert(referenceSequenceID)
            } else if rawReferenceIDs.contains(row.allele) {
                ids.insert(row.allele)
            }
        }

        let referenceDirectoryURL = outputDirectoryURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("reference", isDirectory: true)
        let recordsJSONURL = referenceDirectoryURL
            .appendingPathComponent("mhc-reference-visualizations.json")
        let genBankURL = referenceDirectoryURL
            .appendingPathComponent("mhc-reference-records.gb")
        let fastaURL = referenceDirectoryURL
            .appendingPathComponent("mhc-reference-records.fasta")
        let finalReferenceDirectoryURL = finalOutputDirectoryURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("reference", isDirectory: true)
        let finalOutputURLs = [
            finalReferenceDirectoryURL.appendingPathComponent("mhc-reference-visualizations.json"),
            finalReferenceDirectoryURL.appendingPathComponent("mhc-reference-records.gb"),
            finalReferenceDirectoryURL.appendingPathComponent("mhc-reference-records.fasta"),
        ]
        let startedAt = Date()
        let sourceReferenceURLs = try mhcReferenceVisualizationInputURLs(
            sourceURL: referenceBundleURL,
            fastaURL: referenceFASTAURL
        )
        let inputs = (sourceReferenceURLs + [candidateJSONURL, unnameableJSONURL, exactCallInputURL]).reduce(
            into: [URL]()
        ) { unique, url in
            guard !unique.contains(where: {
                $0.standardizedFileURL == url.standardizedFileURL
            }) else { return }
            unique.append(url.standardizedFileURL)
        }
        let outputURLs = [recordsJSONURL, genBankURL, fastaURL]
        func extractionArgv(
            candidateJSONURL: URL?,
            unnameableJSONURL: URL?,
            exactCallInputURL: URL?,
            outputURLs: [URL]
        ) -> [String] {
            var values = [
                "lungfish-in-process", "extract-mhc-reference-visualizations",
                "--reference-bundle", referenceBundleURL.path,
            ]
            if let candidateJSONURL {
                values += ["--candidate-json", candidateJSONURL.path]
            }
            if let unnameableJSONURL {
                values += ["--unnameable-json", unnameableJSONURL.path]
            }
            if let exactCallInputURL {
                values += ["--exact-call-input", exactCallInputURL.path]
            }
            for rawReferenceID in exactKnownRawReferenceIDs.sorted() {
                values += ["--exact-known-reference-id", rawReferenceID]
            }
            values += [
                "--records-json", outputURLs[0].path,
                "--genbank", outputURLs[1].path,
                "--fasta", outputURLs[2].path,
            ]
            return values
        }
        let argv = extractionArgv(
            candidateJSONURL: candidateJSONURL,
            unnameableJSONURL: unnameableJSONURL,
            exactCallInputURL: exactCallInputURL,
            outputURLs: outputURLs
        )
        func resolvedOptions(recordCount: Int?) -> [String: ParameterValue] {
            var values: [String: ParameterValue] = [
                "schemaVersion": .integer(1),
                "exactKnownRawReferenceIDs": .array(
                    exactKnownRawReferenceIDs.sorted().map(ParameterValue.string)
                ),
                "includeCandidateClosestReferences": .boolean(true),
                "includeUnnameableClosestReferences": .boolean(true),
                "candidateCount": .integer(candidateDocument.candidates.count),
                "unnameableCount": .integer(unnameableDocument.clusters.count),
                "jsonEncoding": .string("pretty-printed-sorted-keys-without-escaped-slashes"),
                "companionOrdering": .string("source-ordinal-then-raw-reference-id"),
            ]
            if let recordCount {
                values["recordCount"] = .integer(recordCount)
            }
            return values
        }
        func provenanceStep(
            recordCount: Int?,
            outputs: [URL],
            exitStatus: Int32,
            stderr: String?,
            completedAt: Date
        ) -> FullLengthONTMHCProvenanceStep {
            return FullLengthONTMHCProvenanceStep(
                toolName: "lungfish-in-process:extract-mhc-reference-visualizations",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: argv,
                resolvedOptions: resolvedOptions(recordCount: recordCount),
                inputs: inputs,
                outputs: outputs,
                exitStatus: exitStatus,
                stderr: stderr,
                startedAt: startedAt,
                completedAt: completedAt
            )
        }

        do {
            let output = try MHCReferenceVisualizationArtifactBuilder().build(.init(
                referenceBundleURL: referenceBundleURL,
                exactKnownRawReferenceIDs: exactKnownRawReferenceIDs,
                candidates: candidateDocument,
                unnameable: unnameableDocument
            ))
            try FileManager.default.createDirectory(
                at: referenceDirectoryURL,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(output.document).write(to: recordsJSONURL, options: .atomic)
            try Data(output.genBankText.utf8).write(to: genBankURL, options: .atomic)
            try Data(output.fastaText.utf8).write(to: fastaURL, options: .atomic)

            func artifactReference(_ url: URL) throws -> ONTMHCArtifactReference {
                ONTMHCArtifactReference(
                    path: relativePath(from: outputDirectoryURL, to: url),
                    sha256: try ProvenanceFileHasher.sha256(of: url) {
                        try Task.checkCancellation()
                    },
                    sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: url))
                )
            }
            let publication = try FullLengthONTMHCReferenceVisualizationPublication(
                descriptor: ONTMHCReferenceVisualizationArtifacts(
                    schemaVersion: 1,
                    recordCount: output.document.records.count,
                    recordsJSON: artifactReference(recordsJSONURL),
                    genBank: artifactReference(genBankURL),
                    fasta: artifactReference(fastaURL)
                ),
                recordsJSONURL: recordsJSONURL,
                genBankURL: genBankURL,
                fastaURL: fastaURL
            )
            steps.append(provenanceStep(
                recordCount: output.document.records.count,
                outputs: publication.outputURLs,
                exitStatus: 0,
                stderr: nil,
                completedAt: Date()
            ))
            return publication
        } catch {
            let completedAt = Date()
            let visualizationFailure = error
            let failureInputDirectoryURL = URL(
                fileURLWithPath: finalOutputDirectoryURL.standardizedFileURL.path
                    + ".failed.lungfish-provenance.json.inputs",
                isDirectory: true
            )
            let preparedFailureInputDirectory: Bool = {
                do {
                    let safety = FullLengthONTMHCAlignmentSafety()
                    if try safety.requireOptionalDirectoryEntryNoFollow(
                        failureInputDirectoryURL,
                        role: "MHC visualization failure input directory"
                    ) {
                        try safety.requireSafeDirectoryTree(
                            failureInputDirectoryURL,
                            role: "MHC visualization failure input directory"
                        )
                        try FileManager.default.removeItem(at: failureInputDirectoryURL)
                    }
                    try FileManager.default.createDirectory(
                        at: failureInputDirectoryURL,
                        withIntermediateDirectories: false
                    )
                    return true
                } catch {
                    return false
                }
            }()
            func retainFailureInput(_ sourceURL: URL, name: String) -> URL? {
                guard preparedFailureInputDirectory else { return nil }
                let retainedURL = failureInputDirectoryURL.appendingPathComponent(name)
                do {
                    try Data(contentsOf: sourceURL).write(to: retainedURL, options: .atomic)
                    return retainedURL
                } catch {
                    return nil
                }
            }
            let retainedCandidateJSONURL = retainFailureInput(
                candidateJSONURL,
                name: "candidate-alleles.json"
            )
            let retainedUnnameableJSONURL = retainFailureInput(
                unnameableJSONURL,
                name: "unnameable-unmatched-clusters.json"
            )
            let retainedExactCallInputURL = retainFailureInput(
                exactCallInputURL,
                name: "exact-calls.csv"
            )
            let failedArgv = extractionArgv(
                candidateJSONURL: retainedCandidateJSONURL,
                unnameableJSONURL: retainedUnnameableJSONURL,
                exactCallInputURL: retainedExactCallInputURL,
                outputURLs: finalOutputURLs
            )
            var seenInputPaths = Set<String>()
            var failedInputs: [ProvenanceFileDescriptor] = []
            for url in sourceReferenceURLs + [
                retainedCandidateJSONURL,
                retainedUnnameableJSONURL,
                retainedExactCallInputURL,
            ].compactMap({ $0 }) {
                let path = url.standardizedFileURL.path
                guard seenInputPaths.insert(path).inserted else { continue }
                do {
                    failedInputs.append(try ProvenanceFileDescriptor.file(
                        url: url,
                        format: failureFileFormat(url),
                        role: .input
                    ))
                } catch {
                    throw FullLengthFailureProvenancePreparationError(
                        inputURL: url,
                        operation: "describing a reference-visualization scientific input",
                        underlyingError: error,
                        initiatingError: visualizationFailure
                    )
                }
            }
            let failedStep = ProvenanceStep(
                toolName: "lungfish-in-process:extract-mhc-reference-visualizations",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: failedArgv,
                durableReplayArgv: failedArgv,
                reproducibleCommand: failedArgv.map(shellEscape).joined(separator: " "),
                resolvedOptions: resolvedOptions(recordCount: nil),
                runtimeIdentity: ProvenanceRuntimeIdentity(),
                inputs: failedInputs,
                outputs: [],
                exitStatus: (error is CancellationError || Task.isCancelled) ? 130 : 1,
                wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
                stderr: error.localizedDescription,
                startedAt: startedAt,
                completedAt: completedAt
            )
            throw FullLengthONTMHCReferenceVisualizationPublicationError(
                step: failedStep,
                underlyingLocalizedDescription: error.localizedDescription
            )
        }
    }

    private func stageManifest(
        request: FullLengthONTMHCGenotypingRunRequest,
        workbookRevision: ONTGenotypeWorkbookRevision,
        evidenceArtifactPair: ONTMHCBAMArtifactPair,
        candidateArtifacts: ONTMHCCandidateArtifactManifest,
        referenceVisualizations: ONTMHCReferenceVisualizationArtifacts?,
        referenceRecordStore: ONTGenotypeReferenceRecordStoreInfo?,
        reviewableRowCatalog: ONTMHCArtifactReference?,
        createdAt: Date
    ) throws -> FullLengthONTMHCSuccessManifestPublicationPlan {
        let resolvedHaplotypeDefinitionSet = try resolveHaplotypeDefinitionSet(for: request)
        let manifest = ONTGenotypeResultBundleManifest(
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: request.haplotypeDefinitionSetID == nil ? .genotypeOnly : .haplotyped,
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
            mhcCandidateArtifacts: candidateArtifacts,
            mhcReferenceVisualizations: referenceVisualizations,
            referenceRecordStore: referenceRecordStore,
            reviewableRowCatalog: reviewableRowCatalog
        )
        let stagedURL = request.outputDirectory.appendingPathComponent(
            ".\(ONTGenotypeResultBundleManifest.filename).staging-\(UUID().uuidString)"
        ).standardizedFileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: stagedURL, options: .atomic)
        let checksum = try ProvenanceFileHasher.sha256(of: stagedURL) {
            try Task.checkCancellation()
        }
        let fileSize = try ProvenanceFileHasher.fileSize(of: stagedURL)
        let finalURL = request.manifestURL.standardizedFileURL
        let stagedDescriptor = ProvenanceFileDescriptor(
            path: stagedURL.path,
            checksumSHA256: checksum,
            fileSize: fileSize,
            format: .json,
            role: .input
        )
        let finalDescriptor = ProvenanceFileDescriptor(
            path: finalURL.path,
            checksumSHA256: checksum,
            fileSize: fileSize,
            format: .json,
            role: .output,
            originPath: stagedURL.path
        )
        return FullLengthONTMHCSuccessManifestPublicationPlan(
            stagedURL: stagedURL,
            finalURL: finalURL,
            stagedDescriptor: stagedDescriptor,
            finalDescriptor: finalDescriptor
        )
    }

    private func validateSuccessManifestPublicationPlan(
        _ plan: FullLengthONTMHCSuccessManifestPublicationPlan
    ) throws {
        guard !FileManager.default.fileExists(atPath: plan.finalURL.path) else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Success manifest destination unexpectedly exists before last-step publication: \(plan.finalURL.path)"
            )
        }
        guard try ProvenanceFileHasher.sha256(of: plan.stagedURL, cancellationCheck: {
            try Task.checkCancellation()
        }) == plan.stagedDescriptor.checksumSHA256,
              try ProvenanceFileHasher.fileSize(of: plan.stagedURL) == plan.stagedDescriptor.fileSize else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Staged success manifest no longer matches its provenance descriptor."
            )
        }
    }

    private func publishSuccessManifestUsingRenameExclusive(
        _ plan: FullLengthONTMHCSuccessManifestPublicationPlan
    ) throws {
        try validateSuccessManifestPublicationPlan(plan)
        let errorNumber: Int32?
        if let injectedError = try exclusivePublicationFailureInjector(.successManifest) {
            errorNumber = injectedError
        } else {
            let status = plan.stagedURL.path.withCString { stagedPath in
                plan.finalURL.path.withCString { finalPath in
                    Darwin.renameatx_np(
                        AT_FDCWD,
                        stagedPath,
                        AT_FDCWD,
                        finalPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            errorNumber = status == 0 ? nil : errno
        }
        guard let errorNumber else { return }
        let code = POSIXErrorCode(rawValue: errorNumber) ?? .EIO
        if isUnsupportedExclusiveRename(errorNumber) {
            throw FullLengthONTMHCExclusiveRenameUnsupportedError(
                targetDescription: "success manifest",
                code: code
            )
        } else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Could not atomically publish success manifest last: \(POSIXError(code).localizedDescription)"
            )
        }
    }

    private func publishSuccessManifestUsingExclusiveReservation(
        _ plan: FullLengthONTMHCSuccessManifestPublicationPlan
    ) throws {
        try validateSuccessManifestPublicationPlan(plan)
        let descriptor = plan.finalURL.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Could not exclusively reserve success manifest destination: \(POSIXError(code).localizedDescription)"
            )
        }
        guard Darwin.close(descriptor) == 0 else {
            let closeCode = POSIXErrorCode(rawValue: errno) ?? .EIO
            _ = plan.finalURL.path.withCString { Darwin.unlink($0) }
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Could not close success manifest reservation: \(POSIXError(closeCode).localizedDescription)"
            )
        }
        var publicationSucceeded = false
        defer {
            if !publicationSucceeded {
                _ = plan.finalURL.path.withCString { Darwin.unlink($0) }
            }
        }
        let status = plan.stagedURL.path.withCString { stagedPath in
            plan.finalURL.path.withCString { finalPath in
                Darwin.rename(stagedPath, finalPath)
            }
        }
        guard status == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Could not publish success manifest using exclusive reservation: \(POSIXError(code).localizedDescription)"
            )
        }
        publicationSucceeded = true
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
        if FileManager.default.fileExists(atPath: request.manifestURL.path) {
            try FileManager.default.removeItem(at: request.manifestURL)
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
        candidateArtifactResult: FullLengthONTMHCCandidateArtifactResult,
        referenceVisualizationPublication: FullLengthONTMHCReferenceVisualizationPublication?,
        manifestPublicationPlan: FullLengthONTMHCSuccessManifestPublicationPlan,
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
            "mhcCandidateReciprocalMappingPreset": .string("asm20"),
            "mhcCandidateReciprocalMaximumSecondaryAlignments": .integer(100),
            "mhcCandidateReciprocalSecondaryAlignments": .boolean(true),
            "mhcCandidateReciprocalEQX": .boolean(true),
            "mhcCandidateReciprocalCS": .string("long"),
            "mhcCandidateMinimumAlignedBases": .integer(ONTMHCCandidateThresholds.defaults.minimumAlignedBases),
            "mhcCandidateMinimumIdentity": .number(ONTMHCCandidateThresholds.defaults.minimumIdentity),
            "mhcCandidateMinimumShorterCoverage": .number(ONTMHCCandidateThresholds.defaults.minimumShorterCoverage),
            "mhcCandidateMinimumIntronGapBases": .integer(ONTMHCCandidateThresholds.defaults.minimumIntronGapBases),
            "mhcCandidateNovelDistanceMetric": .string("SNP-substitutions-only"),
            "mhcCandidateZeroSNPIndelClassification": .string("known-existing-allele"),
            "mhcRawUnmatchedConsensusesPath": .string("artifacts/internal/raw-unmatched-consensuses.fasta"),
            "mhcRawUnmatchedDecisionPath": .string("artifacts/internal/raw-unmatched-consensus-decisions.json"),
            "mhcCanonicalUnmatchedClustersPath": .string("deduplicated_unmatched_clusters.fasta"),
            "mhcCanonicalUnmatchedPublicationRule": .string("writer-only-root-publication"),
            "mhcReferenceVisualizationSchemaVersion": .integer(1),
            "mhcReferenceVisualizationRecordsPath": .string("artifacts/reference/mhc-reference-visualizations.json"),
            "mhcReferenceVisualizationGenBankPath": .string("artifacts/reference/mhc-reference-records.gb"),
            "mhcReferenceVisualizationFASTAPath": .string("artifacts/reference/mhc-reference-records.fasta"),
            "mhcResultBundleAtomicPublication": .string("adjacent-directory-renameatx_np"),
            "minimap2CondaEnvironment": .string("minimap2"),
            "samtoolsCondaEnvironment": .string("samtools"),
            "mhcWorkbookSharedNovelTint": .string(FullLengthONTMHCWorkbookTintDefaults.sharedNovel),
            "mhcWorkbookSingletonNovelTint": .string(FullLengthONTMHCWorkbookTintDefaults.singletonNovel),
            "mhcWorkbookSharedExtensionTint": .string(FullLengthONTMHCWorkbookTintDefaults.sharedExtension),
            "mhcWorkbookSingletonExtensionTint": .string(FullLengthONTMHCWorkbookTintDefaults.singletonExtension),
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
            "mhcCandidateReciprocalMappingPreset": .string("asm20"),
            "mhcCandidateReciprocalMaximumSecondaryAlignments": .integer(100),
            "mhcCandidateReciprocalSecondaryAlignments": .boolean(true),
            "mhcCandidateReciprocalEQX": .boolean(true),
            "mhcCandidateReciprocalCS": .string("long"),
            "mhcCandidateMinimumAlignedBases": .integer(ONTMHCCandidateThresholds.defaults.minimumAlignedBases),
            "mhcCandidateMinimumIdentity": .number(ONTMHCCandidateThresholds.defaults.minimumIdentity),
            "mhcCandidateMinimumShorterCoverage": .number(ONTMHCCandidateThresholds.defaults.minimumShorterCoverage),
            "mhcCandidateMinimumIntronGapBases": .integer(ONTMHCCandidateThresholds.defaults.minimumIntronGapBases),
            "mhcCandidateNovelDistanceMetric": .string("SNP-substitutions-only"),
            "mhcCandidateZeroSNPIndelClassification": .string("known-existing-allele"),
            "mhcRawUnmatchedConsensusesPath": .string("artifacts/internal/raw-unmatched-consensuses.fasta"),
            "mhcRawUnmatchedDecisionPath": .string("artifacts/internal/raw-unmatched-consensus-decisions.json"),
            "mhcCanonicalUnmatchedClustersPath": .string("deduplicated_unmatched_clusters.fasta"),
            "mhcCanonicalUnmatchedPublicationRule": .string("writer-only-root-publication"),
            "mhcReferenceVisualizationSchemaVersion": .integer(1),
            "mhcReferenceVisualizationRecordsPath": .string("artifacts/reference/mhc-reference-visualizations.json"),
            "mhcReferenceVisualizationGenBankPath": .string("artifacts/reference/mhc-reference-records.gb"),
            "mhcReferenceVisualizationFASTAPath": .string("artifacts/reference/mhc-reference-records.fasta"),
            "mhcResultBundleAtomicPublication": .string("adjacent-directory-renameatx_np"),
            "minimap2CondaEnvironment": .string("minimap2"),
            "samtoolsCondaEnvironment": .string("samtools"),
            "mhcWorkbookSharedNovelTint": .string(FullLengthONTMHCWorkbookTintDefaults.sharedNovel),
            "mhcWorkbookSingletonNovelTint": .string(FullLengthONTMHCWorkbookTintDefaults.singletonNovel),
            "mhcWorkbookSharedExtensionTint": .string(FullLengthONTMHCWorkbookTintDefaults.sharedExtension),
            "mhcWorkbookSingletonExtensionTint": .string(FullLengthONTMHCWorkbookTintDefaults.singletonExtension),
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
            (cohortAlignmentResult.transformationRecords + candidateArtifactResult.transformationRecords).map { transformation in
                .dictionary(transformation.resolvedOptions.mapValues(ParameterValue.string))
            }
        )
        explicit["mhcRawUnmatchedConsensusesFASTA"] = .file(request.rawUnmatchedConsensusesFASTAURL)
        explicit["mhcRawUnmatchedDecisionPayload"] = .file(
            request.rawUnmatchedConsensusDecisionsJSONURL
        )
        explicit["mhcCandidateStableUnmatchedFASTA"] = .file(candidateArtifactResult.stableUnmatchedFASTAURL)
        explicit["mhcCandidateReciprocalBAM"] = .file(candidateArtifactResult.reciprocalBAMURL)
        explicit["mhcCandidateReciprocalBAI"] = .file(candidateArtifactResult.reciprocalBAIURL)
        explicit["mhcCandidateJSON"] = .file(candidateArtifactResult.candidateJSONURL)
        explicit["mhcCandidateFASTA"] = .file(candidateArtifactResult.candidateFASTAURL)
        explicit["mhcCandidateGenBank"] = .file(candidateArtifactResult.candidateGenBankURL)
        explicit["mhcCandidateEMBL"] = .file(candidateArtifactResult.candidateEMBLURL)
        explicit["mhcUnnameableJSON"] = .file(candidateArtifactResult.unnameableJSONURL)
        explicit["mhcUnnameableFASTA"] = .file(candidateArtifactResult.unnameableFASTAURL)
        explicit["mhcUnnameableGenBank"] = .file(candidateArtifactResult.unnameableGenBankURL)
        explicit["mhcUnnameableEMBL"] = .file(candidateArtifactResult.unnameableEMBLURL)
        if let referenceVisualizationPublication {
            explicit["mhcReferenceVisualizationRecords"] = .file(
                referenceVisualizationPublication.recordsJSONURL
            )
            explicit["mhcReferenceVisualizationGenBank"] = .file(
                referenceVisualizationPublication.genBankURL
            )
            explicit["mhcReferenceVisualizationFASTA"] = .file(
                referenceVisualizationPublication.fastaURL
            )
        }
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
        .relocatedOutput(manifestPublicationPlan.finalDescriptor)
        .output(request.unmatchedClustersFASTAURL, format: .fasta, role: .output)
        .output(request.rawUnmatchedConsensusDecisionsJSONURL, format: .json, role: .output)
        .output(request.rawUnmatchedConsensusesFASTAURL, format: .fasta, role: .output)
        .output(request.deduplicatedUnmatchedClustersFASTAURL, format: .fasta, role: .output)
        .output(request.cdnaClustersFASTAURL, format: .fasta, role: .output)
        .output(cohortAlignmentResult.bamURL, format: .bam, role: .output)
        .output(cohortAlignmentResult.baiURL, format: .unknown, role: .index)
        .output(candidateArtifactResult.reciprocalBAMURL, format: .bam, role: .output)
        .output(candidateArtifactResult.reciprocalBAIURL, format: .unknown, role: .index)
        .output(candidateArtifactResult.candidateJSONURL, format: .json, role: .output)
        .output(candidateArtifactResult.candidateFASTAURL, format: .fasta, role: .output)
        .output(candidateArtifactResult.candidateGenBankURL, format: .genBank, role: .output)
        .output(candidateArtifactResult.candidateEMBLURL, format: .text, role: .output)
        .output(candidateArtifactResult.unnameableJSONURL, format: .json, role: .output)
        .output(candidateArtifactResult.unnameableFASTAURL, format: .fasta, role: .output)
        .output(candidateArtifactResult.unnameableGenBankURL, format: .genBank, role: .output)
        .output(candidateArtifactResult.unnameableEMBLURL, format: .text, role: .output)

        if let referenceVisualizationPublication {
            for outputURL in referenceVisualizationPublication.outputURLs {
                builder = try builder.output(
                    outputURL,
                    format: outputURL.pathExtension.lowercased() == "json" ? .json :
                        (outputURL.pathExtension.lowercased() == "fasta" ? .fasta : .text),
                    role: .output
                )
            }
        }

        if request.haplotypeDefinitionSetID != nil {
            builder = try builder.output(request.haplotypeAnalysisURL, format: .json, role: .report)
        }

        for input in request.inputFASTQURLs where !isDirectory(input) {
            builder = try builder.input(input, format: .fastq, role: .input)
        }
        for primer in [request.orientReferenceURL, request.forwardPrimerURL, request.reversePrimerURL].compactMap({ $0 }) {
            builder = try builder.input(primer, format: .fasta, role: .reference)
        }
        var allProvenanceSteps = stagedSamples.compactMap(\.materializationStep)
        allProvenanceSteps += try steps.map { try $0.provenanceStep() }
        allProvenanceSteps += try cohortAlignmentProvenanceSteps(
            cohortAlignmentResult,
            bamViewRecord: bamViewRecord
        )
        allProvenanceSteps += try (
            candidateArtifactResult.toolVersionDiscoveryRecords + candidateArtifactResult.commandRecords
        ).map {
            try provenanceStep(for: $0)
        }
        allProvenanceSteps += candidateArtifactResult.transformationRecords.map {
            $0.provenanceStep()
        }
        allProvenanceSteps.sort {
            ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast)
        }
        for step in allProvenanceSteps {
            builder = builder.step(step)
        }

        let builtEnvelope = try builder.complete(
            exitStatus: 0,
            startedAt: startedAt,
            endedAt: completedAt
        )
        let durableOutputs = builtEnvelope.outputs.filter { descriptor in
            !descriptor.path.contains(".cohort-alignment-work")
                && !descriptor.path.contains(".candidate-artifact-work")
                && !descriptor.path.contains("/.alignments-replacement-")
                && !descriptor.path.contains("/workflow/")
        }
        let envelope = ProvenanceEnvelope(
            schemaVersion: builtEnvelope.schemaVersion,
            id: builtEnvelope.id,
            createdAt: builtEnvelope.createdAt,
            workflowName: builtEnvelope.workflowName,
            workflowVersion: builtEnvelope.workflowVersion,
            toolName: builtEnvelope.toolName,
            toolVersion: builtEnvelope.toolVersion,
            githubReleaseVersion: builtEnvelope.githubReleaseVersion,
            tool: builtEnvelope.tool,
            argv: builtEnvelope.argv,
            durableReplayArgv: builtEnvelope.durableReplayArgv,
            reproducibleCommand: builtEnvelope.reproducibleCommand,
            options: builtEnvelope.options,
            runtimeIdentity: builtEnvelope.runtimeIdentity,
            files: builtEnvelope.files,
            output: durableOutputs.first,
            outputs: durableOutputs,
            steps: builtEnvelope.steps,
            wallTimeSeconds: builtEnvelope.wallTimeSeconds,
            exitStatus: builtEnvelope.exitStatus,
            stderr: builtEnvelope.stderr,
            signatures: builtEnvelope.signatures,
            legacyWorkflowRun: builtEnvelope.legacyRun
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: request.provenanceURL)
    }

    private func loadPartialFailureEnvelope(
        stagedOutputURL: URL,
        finalOutputURL: URL,
        finalExistedBeforeRun: Bool
    ) -> ProvenanceEnvelope? {
        let stagedURL = stagedOutputURL.appendingPathComponent(
            "full-length-ont-mhc-genotyping-provenance.json"
        )
        if let envelope = try? ProvenanceEnvelopeReader.load(fromSidecar: stagedURL) {
            return envelope
        }
        guard !finalExistedBeforeRun else { return nil }
        let finalURL = finalOutputURL.appendingPathComponent(
            "full-length-ont-mhc-genotyping-provenance.json"
        )
        return try? ProvenanceEnvelopeReader.load(fromSidecar: finalURL)
    }

    private func writeFailureProvenance(
        request: FullLengthONTMHCGenotypingRunRequest,
        stagedOutputURL: URL,
        startedAt: Date,
        error: Error,
        partialEnvelope: ProvenanceEnvelope?,
        failedPublicationRecord: FullLengthONTMHCResultBundlePublicationRecord?,
        successfulPublicationRecord: FullLengthONTMHCResultBundlePublicationRecord?,
        rollbackStep: ProvenanceStep?,
        rollbackFailureRecovery: FullLengthONTMHCRollbackFailureRecovery?,
        additionalDiagnosticRoots: [URL] = []
    ) throws {
        let completedAt = Date()
        let cancelled = isCancellation(error)
        let exitStatus = cancelled ? 130 : 1
        let stderrText = cancelled
            ? "Full-length ONT MHC genotyping was cancelled: \(error.localizedDescription)"
            : error.localizedDescription
        let inputs = try failureInputDescriptors(request)
        let outputs = try failureDiagnosticDescriptors(
            stagedOutputURL: stagedOutputURL,
            additionalRoots: additionalDiagnosticRoots
        )
        let options = failureProvenanceOptions(
            request: request,
            outcome: cancelled ? "cancelled" : "failed",
            retainedDiagnosticCount: outputs.count,
            rollbackFailureRecovery: rollbackFailureRecovery
        )
        var steps = partialEnvelope?.steps ?? []
        func appendIfMissing(_ candidate: ProvenanceStep) {
            let exists = steps.contains {
                $0.toolName == candidate.toolName
                    && $0.argv == candidate.argv
                    && $0.exitStatus == candidate.exitStatus
                    && $0.startedAt == candidate.startedAt
            }
            if !exists {
                steps.append(candidate)
            }
        }
        if let cohortError = error as? FullLengthONTMHCCohortAlignmentBuildError {
            for record in cohortError.toolVersionDiscoveryRecords + cohortError.commandRecords {
                do {
                    steps.append(try provenanceStep(for: record))
                } catch {
                    let sourceURL = record.inputs.first ?? record.executableURL
                    throw FullLengthFailureProvenancePreparationError(
                        inputURL: sourceURL,
                        operation: "rehydrating a failed cohort command provenance step",
                        underlyingError: error
                    )
                }
            }
            steps.append(contentsOf: cohortError.transformationRecords.map { $0.provenanceStep() })
        }
        if let visualizationError = error as? FullLengthONTMHCReferenceVisualizationPublicationError {
            appendIfMissing(visualizationError.step)
        }
        if let catalogError =
            error as? GenotypeReviewableRowCatalogPublicationFailure,
           let failedStep = catalogError.provenance.steps.last {
            appendIfMissing(failedStep)
        }
        if let successfulPublicationRecord {
            appendIfMissing(successfulPublicationRecord.provenanceStep)
        }
        if let failedPublicationRecord {
            appendIfMissing(failedPublicationRecord.provenanceStep)
        }
        if let rollbackStep {
            appendIfMissing(rollbackStep)
        }
        let receiptArgv = request.argv + [
            "--failure-provenance", request.failureProvenanceURL.path,
        ]
        steps.append(ProvenanceStep(
            toolName: "lungfish-internal record-full-length-mhc-failed-run",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: receiptArgv,
            durableReplayArgv: request.argv,
            reproducibleCommand: request.argv.map(shellEscape).joined(separator: " "),
            resolvedOptions: options.resolvedDefaults,
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: inputs,
            outputs: outputs,
            exitStatus: exitStatus,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: stderrText,
            startedAt: startedAt,
            completedAt: completedAt
        ))
        steps.sort { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        var seenFiles = Set<String>()
        let files = (inputs + outputs + steps.flatMap { $0.inputs + $0.outputs }).filter {
            seenFiles.insert("\($0.role.rawValue)\u{0}\($0.path)").inserted
        }
        let envelope = ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: "lungfish fastq full-length-ont-mhc-genotype",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: CLICommandIdentity.executableName,
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(
                name: CLICommandIdentity.executableName,
                version: WorkflowRun.currentAppVersion,
                kind: "cli"
            ),
            argv: request.argv,
            durableReplayArgv: request.argv,
            reproducibleCommand: request.argv.map(shellEscape).joined(separator: " "),
            options: options,
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: files,
            output: outputs.first,
            outputs: outputs,
            steps: steps,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: exitStatus,
            stderr: stderrText
        )
        if FileManager.default.fileExists(atPath: request.failureProvenanceURL.path) {
            try FileManager.default.removeItem(at: request.failureProvenanceURL)
        }
        try ProvenanceWriter(signingProvider: nil).write(
            envelope,
            toSidecar: request.failureProvenanceURL
        )
    }

    private func failureInputDescriptors(
        _ request: FullLengthONTMHCGenotypingRunRequest
    ) throws -> [ProvenanceFileDescriptor] {
        var descriptors: [ProvenanceFileDescriptor] = []
        for inputURL in request.inputFASTQURLs {
            do {
                let sourceDescriptors = try FullLengthONTMHCFASTQMaterializer
                    .provenanceSourceDescriptors(for: inputURL)
                descriptors.append(contentsOf: sourceDescriptors)
            } catch {
                throw FullLengthFailureProvenancePreparationError(
                    inputURL: inputURL,
                    operation: "describing a FASTQ scientific source",
                    underlyingError: error
                )
            }
        }
        let referenceFASTA: URL
        do {
            referenceFASTA = try resolveMHCReferenceFASTA(request.referenceSourceURL)
        } catch {
            throw FullLengthFailureProvenancePreparationError(
                inputURL: request.referenceSourceURL,
                operation: "resolving the MHC reference source",
                underlyingError: error
            )
        }
        let catalogInputs: FullLengthONTMHCReferenceCatalogInputs
        do {
            catalogInputs = try mhcReferenceCatalogInputs(
                sourceURL: request.referenceSourceURL,
                fastaURL: referenceFASTA
            )
        } catch {
            throw FullLengthFailureProvenancePreparationError(
                inputURL: request.referenceSourceURL,
                operation: "resolving MHC reference catalog inputs",
                underlyingError: error
            )
        }
        let referencePaths = Set(catalogInputs.allURLs.map {
            $0.standardizedFileURL.path
        })
        let supplementalURLs: [URL] = catalogInputs.allURLs + [
            request.orientReferenceURL,
            request.forwardPrimerURL,
            request.reversePrimerURL,
        ].compactMap { $0 }
        var seen = Set<String>()
        for url in supplementalURLs.map(\.standardizedFileURL) where seen.insert(url.path).inserted {
            do {
                descriptors.append(try ProvenanceFileDescriptor.file(
                    url: url,
                    format: failureFileFormat(url),
                    role: referencePaths.contains(url.path) ? .reference : .input
                ))
            } catch {
                throw FullLengthFailureProvenancePreparationError(
                    inputURL: url,
                    operation: referencePaths.contains(url.path)
                        ? "describing an MHC reference or catalog source"
                        : "describing a configured scientific input",
                    underlyingError: error
                )
            }
        }
        var seenDescriptors = Set<String>()
        return descriptors.filter {
            seenDescriptors.insert("\($0.role.rawValue)\u{0}\($0.path)").inserted
        }
    }

    private func failureProvenancePreparationReceiptData(
        request: FullLengthONTMHCGenotypingRunRequest,
        runID: UUID,
        startedAt: Date,
        originalError: Error,
        preparationError: FullLengthFailureProvenancePreparationError,
        rollbackFailureRecovery: FullLengthONTMHCRollbackFailureRecovery?
    ) throws -> Data {
        let completedAt = Date()
        let exitStatus = isCancellation(originalError) ? 130 : 1
        let stderr = [
            originalError.localizedDescription,
            preparationError.localizedDescription,
        ].joined(separator: "\n")
        let receipt = FullLengthFailureProvenancePreparationReceipt(
            schemaVersion: 1,
            kind: "incomplete-failure-provenance-preparation",
            runID: runID,
            workflowName: "lungfish fastq full-length-ont-mhc-genotype",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: CLICommandIdentity.executableName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: request.argv,
            durableReplayArgv: request.argv,
            reproducibleCommand: request.argv.map(shellEscape).joined(separator: " "),
            options: failureProvenanceOptions(
                request: request,
                outcome: isCancellation(originalError)
                    ? "cancelled-provenance-incomplete"
                    : "failed-provenance-incomplete",
                retainedDiagnosticCount: 0,
                rollbackFailureRecovery: rollbackFailureRecovery
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputPath: preparationError.inputPath,
            preparationError: preparationError.localizedDescription,
            originalError: originalError.localizedDescription,
            startedAt: startedAt,
            completedAt: completedAt,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: exitStatus,
            stderr: stderr
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(receipt)
    }

    private func failureDiagnosticDescriptors(
        stagedOutputURL: URL,
        additionalRoots: [URL] = []
    ) throws -> [ProvenanceFileDescriptor] {
        let parentURL = stagedOutputURL.deletingLastPathComponent()
        let runToken = stagedOutputURL.lastPathComponent
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        var seenRoots = Set<String>()
        let roots = (contents.filter {
            $0.lastPathComponent.contains(runToken)
                && $0.standardizedFileURL != stagedOutputURL.standardizedFileURL
                && !$0.lastPathComponent.contains("candidate-artifact-work")
                && !$0.lastPathComponent.contains("cohort-alignment-work")
        } + additionalRoots)
            .map(\.standardizedFileURL)
            .filter {
                !$0.path.contains("candidate-artifact-work")
                    && !$0.path.contains("cohort-alignment-work")
            }
            .filter { seenRoots.insert($0.path).inserted }
        var fileURLs: [URL] = []
        let safety = FullLengthONTMHCAlignmentSafety()
        for root in roots.sorted(by: { $0.path < $1.path }) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                try safety.requireSafeDirectoryTree(root, role: "retained failed-run diagnostics")
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: []
                ) else { continue }
                for case let entry as URL in enumerator {
                    var entryIsDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: entry.path, isDirectory: &entryIsDirectory),
                       !entryIsDirectory.boolValue,
                       entry.lastPathComponent != OwnedWorkDirectoryMarker.fileName {
                        fileURLs.append(entry.standardizedFileURL)
                    }
                }
            } else {
                try safety.requireRegularFileNoFollow(root, role: "retained failed-run diagnostic")
                fileURLs.append(root.standardizedFileURL)
            }
        }
        return try fileURLs.sorted { $0.path < $1.path }.map { url in
            try ProvenanceFileDescriptor.file(
                url: url,
                format: failureFileFormat(url),
                role: url.path.contains("/logs/") || url.pathExtension == "log" ? .log : .output
            )
        }
    }

    private func failureProvenanceOptions(
        request: FullLengthONTMHCGenotypingRunRequest,
        outcome: String,
        retainedDiagnosticCount: Int,
        rollbackFailureRecovery: FullLengthONTMHCRollbackFailureRecovery? = nil
    ) -> ProvenanceOptions {
        let defaults: [String: ParameterValue] = [
            "threads": .integer(max(1, ProcessInfo.processInfo.activeProcessorCount)),
            "minimumLength": .integer(2_000),
            "maximumLength": .integer(4_000),
            "savontQualityValueCutoff": .integer(FullLengthONTMHCGenotypingRunRequest.defaultSavontQualityValueCutoff),
            "savontMinimumClusterSize": .integer(FullLengthONTMHCGenotypingRunRequest.defaultSavontMinimumClusterSize),
            "minUnmatchedReads": .integer(5),
            "cdnaThreshold": .integer(2_000),
            "sampleJobs": .string("auto"),
            "savontThreadsPerSample": .string("auto"),
            "keepIntermediates": .boolean(false),
            "reuseCompatibleCheckpoints": .boolean(false),
        ]
        var resolved: [String: ParameterValue] = [
            "threads": .integer(request.threads),
            "minimumLength": .integer(request.minimumLength),
            "maximumLength": .integer(request.maximumLength),
            "savontQualityValueCutoff": .integer(request.savontQualityValueCutoff),
            "savontMinimumClusterSize": .integer(request.savontMinimumClusterSize),
            "minUnmatchedReads": .integer(request.minUnmatchedReads),
            "cdnaThreshold": .integer(request.cdnaThreshold),
            "sampleJobs": request.sampleJobs.map(ParameterValue.integer) ?? .string("auto"),
            "savontThreadsPerSample": request.savontThreadsPerSample.map(ParameterValue.integer) ?? .string("auto"),
            "keepIntermediates": .boolean(request.keepIntermediates),
            "reuseCompatibleCheckpoints": .boolean(request.reuseCompatibleCheckpoints),
            "outcome": .string(outcome),
            "retainedDiagnosticCount": .integer(retainedDiagnosticCount),
        ]
        resolved["haplotypeDropoutSampleFraction"] = request.haplotypeDropoutSampleFraction
            .map(ParameterValue.number) ?? .string("disabled")
        resolved["haplotypeDropoutLocusFraction"] = request.haplotypeDropoutLocusFraction
            .map(ParameterValue.number) ?? .string("disabled")
        resolved["haplotypeDropoutLocusFractionOverrides"] = .dictionary(
            request.haplotypeDropoutLocusFractionOverrides.mapValues(ParameterValue.number)
        )
        resolved["haplotypeDefinition"] = request.haplotypeDefinitionSetID
            .map(ParameterValue.string) ?? .string("disabled")
        if let path = rollbackFailureRecovery?.retainedPriorGenerationURL?.path {
            resolved["retainedPriorGenerationPath"] = .file(URL(fileURLWithPath: path))
        }
        if let path = rollbackFailureRecovery?.retainedFailedPublishedGenerationURL?.path {
            resolved["retainedFailedPublishedGenerationPath"] = .file(URL(fileURLWithPath: path))
        }
        var explicit = resolved
        explicit["inputFASTQs"] = .array(request.inputFASTQURLs.map(ParameterValue.file))
        explicit["reference"] = .file(request.referenceSourceURL)
        explicit["outputDirectory"] = .file(request.outputDirectory)
        explicit["outputName"] = .string(request.outputName)
        explicit["failureProvenance"] = .file(request.failureProvenanceURL)
        if let value = request.orientReferenceURL { explicit["orientReference"] = .file(value) }
        if let value = request.forwardPrimerURL { explicit["forwardPrimer"] = .file(value) }
        if let value = request.reversePrimerURL { explicit["reversePrimer"] = .file(value) }
        if let value = request.projectURL { explicit["project"] = .file(value) }
        return ProvenanceOptions(explicit: explicit, defaults: defaults, resolvedDefaults: resolved)
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? FullLengthONTMHCCohortAlignmentBuildError)?.wasCancelled == true
            || Task.isCancelled
    }

    private func failureFileFormat(_ url: URL) -> FileFormat {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".fastq") || name.hasSuffix(".fastq.gz") || name.hasSuffix(".fq") || name.hasSuffix(".fq.gz") { return .fastq }
        if name.hasSuffix(".fasta") || name.hasSuffix(".fasta.gz") || name.hasSuffix(".fa") || name.hasSuffix(".fa.gz") { return .fasta }
        if name.hasSuffix(".bam") { return .bam }
        if name.hasSuffix(".sam") { return .sam }
        if name.hasSuffix(".json") { return .json }
        if name.hasSuffix(".sqlite") || name.hasSuffix(".db") { return .sqlite }
        if name.hasSuffix(".csv") || name.hasSuffix(".tsv") || name.hasSuffix(".log") { return .text }
        return .unknown
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
            steps.append(transformation.provenanceStep())
        }
        guard let publication = result.publicationRecord else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Cohort alignment publication completed without its actual atomic publication record."
            )
        }
        steps.append(ProvenanceStep(
            toolName: publication.toolName,
            toolVersion: publication.toolVersion,
            argv: publication.argv,
            durableReplayArgv: publication.argv,
            reproducibleCommand: publication.argv.map(shellEscape).joined(separator: " "),
            resolvedOptions: [
                "atomicMechanism": .string(publication.atomicMechanism),
                "publicationScope": .string("cohort-alignment-artifacts"),
            ],
            runtimeIdentity: result.runtimeIdentity,
            inputs: result.publicationMappings.map {
                provenanceDescriptor($0.stagedDescriptor, forcedRole: .input)
            },
            outputs: result.publicationMappings.map {
                provenanceDescriptor(
                    $0.finalDescriptor,
                    forcedRole: $0.finalDescriptor.role == .evidenceBAI ? .index : .output
                )
            },
            exitStatus: Int(publication.exitStatus),
            wallTimeSeconds: publication.wallTime,
            stderr: publication.errorMessage,
            startedAt: publication.startedAt,
            completedAt: publication.completedAt
        ))
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
            resolvedOptions: [
                "executionMode": .string("external-command"),
                "capturedArgv": .boolean(true),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(),
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
        var result = [[
            "sample",
            "genotype",
            "cluster",
            "cluster_reads",
            "allele_length",
            "aligned_bases",
            "score",
            "reference_sequence_id",
            "mapping_quality",
            "cigar",
            "evidence_bam_path",
            "evidence_query_name",
            "evidence_reference_name",
            "evidence_read_group_id",
            "evidence_reference_start",
            "evidence_cigar",
        ]]
        result += rows.map {
            [
                $0.sample,
                $0.allele,
                $0.cluster,
                String($0.clusterReads),
                String($0.alleleLength),
                String($0.alignedBases),
                String($0.score),
                $0.referenceSequenceID ?? "",
                $0.mappingQuality.map(String.init) ?? "",
                $0.cigar ?? "",
                $0.evidence?.bamPath ?? "",
                $0.evidence?.queryName ?? "",
                $0.evidence?.referenceName ?? "",
                $0.evidence?.readGroupID ?? "",
                $0.evidence.map { String($0.referenceStart) } ?? "",
                $0.evidence?.cigar ?? "",
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
        let countsBySampleAllele = alleleCounts(reportRows)
        let observedAlleles = Set(countsBySampleAllele.keys)
        let orderedObservedAlleles = orderedObservedAlleles(
            observedAlleles: observedAlleles,
            orderedAlleles: orderedAlleles
        )

        var rows = buildHeaderRows(
            reportRows: reportRows,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis
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

    static func buildHeaderRows(
        reportRows: [FullLengthONTMHCReportRow],
        samples: [FullLengthONTMHCPivotSample],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?
    ) -> [[String]] {
        let pivotSamples = completeSamples(samples, with: reportRows)
        let sampleNames = pivotSamples.map(\.sample)
        let callsBySampleLocus = haplotypeCallsBySampleLocus(haplotypeAnalysis)
        var rows = [
            ["Client ID", "", ""] + sampleNames,
            ["GS ID", "Total", "Average"] + sampleNames,
        ]
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

struct FullLengthONTMHCUnmatchedClosestMatchWorkbookRow: Sendable, Codable, Equatable {
    let sample: String
    let cluster: String
    let clusterReads: Int
    let rawSequence: String
    let sequence: String
    let candidateSequence: String
    let candidateWasReverseComplemented: Bool
    let trimStart: Int?
    let trimEnd: Int?
    let trimSource: String
    let closestMatch: FullLengthONTMHCClosestMatch?
    let rescueMatch: FullLengthONTMHCBlastRescueMatch?

    private enum CodingKeys: String, CodingKey {
        case sample = "sample_id"
        case cluster = "source_cluster_id"
        case clusterReads = "cluster_read_count"
        case rawSequence = "raw_sequence"
        case sequence = "display_sequence"
        case candidateSequence = "candidate_sequence"
        case candidateWasReverseComplemented = "candidate_was_reverse_complemented"
        case trimStart = "trim_start"
        case trimEnd = "trim_end"
        case trimSource = "trim_source"
        case closestMatch = "closest_match"
        case rescueMatch = "rescue_match"
    }

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
        candidateSequence: String? = nil,
        candidateWasReverseComplemented: Bool? = nil,
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
        self.candidateSequence = candidateSequence ?? rawSequence ?? sequence
        self.candidateWasReverseComplemented = candidateWasReverseComplemented
            ?? (closestMatch?.isReverse == true)
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.trimSource = trimSource
        self.closestMatch = closestMatch
        self.rescueMatch = rescueMatch
    }
}

enum FullLengthONTMHCCandidateObservationNormalizer {
    static func canonicalize(
        summary: ONTMHCGenotypingTargetHitSummary,
        candidateWasReverseComplemented: Bool
    ) throws -> ONTMHCGenotypingTargetHitSummary {
        guard candidateWasReverseComplemented else { return summary }
        let interpretations = summary.cdnaExtensionInterpretations.map { interpretation in
            ONTMHCCDNAExtensionInterpretation(
                rawReferenceID: interpretation.rawReferenceID,
                alleleName: interpretation.alleleName,
                locus: interpretation.locus,
                cDNAReferenceCoverage: interpretation.cDNAReferenceCoverage,
                clusterCoverage: interpretation.clusterCoverage,
                leadingClusterFlankBases: interpretation.trailingClusterFlankBases,
                trailingClusterFlankBases: interpretation.leadingClusterFlankBases,
                largestClusterStructuralSegmentBases: interpretation.largestClusterStructuralSegmentBases,
                largestCDNADeficitSegmentBases: interpretation.largestCDNADeficitSegmentBases,
                snpSubstitutions: interpretation.snpSubstitutions,
                ordinaryIndelBases: interpretation.ordinaryIndelBases,
                isReverse: !interpretation.isReverse,
                alignmentScore: interpretation.alignmentScore,
                identity: interpretation.identity
            )
        }
        return try ONTMHCGenotypingTargetHitSummary(
            bamPath: summary.bamPath,
            targetName: summary.targetName,
            alignmentCount: summary.alignmentCount,
            queryAlignmentCounts: summary.queryAlignmentCounts,
            exactMatchQueryNames: summary.exactMatchQueryNames,
            closestMatchQueryNames: summary.closestMatchQueryNames,
            cdnaExtensionInterpretations: interpretations
        )
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
        var candidateSequence = raw
        var trimSource = "minimap2-target-interval"
        if closestMatch.isReverse == true {
            normalized = reverseComplement(normalized)
            candidateSequence = reverseComplement(raw)
            trimSource = "minimap2-target-interval-reverse-complement"
        }
        return FullLengthONTMHCUnmatchedClosestMatchWorkbookRow(
            sample: sample,
            cluster: record.name,
            clusterReads: record.readCount,
            sequence: normalized,
            rawSequence: raw,
            candidateSequence: candidateSequence,
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

struct FullLengthONTMHCBlastRescueMatch: Sendable, Codable, Equatable {
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
        let grouped = Dictionary(grouping: rows) { unmatchedSequenceID(for: $0.candidateSequence) }
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
        let grouped = Dictionary(grouping: rows) { unmatchedSequenceID(for: $0.candidateSequence) }
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
                sequence: representative.candidateSequence,
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
    static func buildWorkbookCells(
        reportRows: [FullLengthONTMHCReportRow],
        projection: FullLengthONTMHCWorkbookProjection,
        samples: [FullLengthONTMHCPivotSample],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?,
        knownAlleleDisplayNames: [String: String]
    ) -> [[FullLengthONTMHCWorkbookCell]] {
        let unifiedMetadataColumnCount = 12
        let headerRows = buildAnalystHeaderCells(
            reportRows: reportRows,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis
        ).map { row -> [FullLengthONTMHCWorkbookCell] in
            let legacyMetadata = Array(row.prefix(3))
            let sampleValues = Array(row.dropFirst(3))
            return legacyMetadata
                + Array(
                    repeating: FullLengthONTMHCWorkbookCell.blank,
                    count: unifiedMetadataColumnCount - legacyMetadata.count
                )
                + sampleValues
        }
        let table = buildCells(
            reportRows: reportRows,
            projection: projection,
            sampleOrder: samples.map(\.sample),
            knownAlleleDisplayNames: knownAlleleDisplayNames
        )
        let separatorWidth = max(
            headerRows.map(\.count).max() ?? 0,
            table.map(\.count).max() ?? 0
        )
        return headerRows
            + [Array(repeating: FullLengthONTMHCWorkbookCell.blank, count: separatorWidth)]
            + table
    }

    static func buildAnalystHeaderCells(
        reportRows: [FullLengthONTMHCReportRow],
        samples: [FullLengthONTMHCPivotSample],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?
    ) -> [[FullLengthONTMHCWorkbookCell]] {
        FullLengthONTMHCPivotWorkbookBuilder.buildHeaderRows(
            reportRows: reportRows,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis
        ).map { row in
            let label = row.first ?? ""
            return row.enumerated().map { columnIndex, value in
                analystHeaderCell(label: label, columnIndex: columnIndex, value: value)
            }
        }
    }

    private static func analystHeaderCell(
        label: String,
        columnIndex: Int,
        value: String
    ) -> FullLengthONTMHCWorkbookCell {
        switch label {
        case "Mapped Read Count" where columnIndex == 2:
            return decimalMetricCell(value)
        case "Mapped Read Count" where columnIndex >= 1:
            return integerMetricCell(value)
        case "total_read_count" where columnIndex >= 3:
            return integerMetricCell(value)
        case "percent_reads_unmapped" where columnIndex >= 3:
            return decimalMetricCell(value)
        default:
            return FullLengthONTMHCWorkbookCell(value)
        }
    }

    private static func integerMetricCell(_ value: String) -> FullLengthONTMHCWorkbookCell {
        guard let integer = Int(value) else { return FullLengthONTMHCWorkbookCell(value) }
        return FullLengthONTMHCWorkbookCell(integer)
    }

    private static func decimalMetricCell(_ value: String) -> FullLengthONTMHCWorkbookCell {
        guard let decimal = Double(value) else { return FullLengthONTMHCWorkbookCell(value) }
        return FullLengthONTMHCWorkbookCell(decimal)
    }

    static func buildCells(
        reportRows: [FullLengthONTMHCReportRow],
        projection: FullLengthONTMHCWorkbookProjection,
        sampleOrder: [String],
        knownAlleleDisplayNames: [String: String] = [:]
    ) -> [[FullLengthONTMHCWorkbookCell]] {
        let tintsByStableID = Dictionary(uniqueKeysWithValues: projection.candidateRows.map {
            ($0.stableClusterID, $0.tintCategory)
        } + projection.unnameableRows.compactMap { row in
            row.candidateInterpretation.map {
                (row.stableClusterID, incompleteCandidateTint(
                    classification: $0.classification,
                    supportClass: row.supportClass
                ))
            }
        })
        return buildRows(
            reportRows: reportRows,
            projection: projection,
            sampleOrder: sampleOrder,
            knownAlleleDisplayNames: knownAlleleDisplayNames
        ).enumerated().map { rowIndex, row in
            let tint = rowIndex == 0 || row.count < 3 ? nil : tintsByStableID[row[1]]
            return row.enumerated().map { columnIndex, value in
                if rowIndex > 0, columnIndex >= 9 {
                    if value.isEmpty { return .blank }
                    if let number = Int(value) { return FullLengthONTMHCWorkbookCell(number) }
                }
                return FullLengthONTMHCWorkbookCell(value, tint: columnIndex == 2 ? tint : nil)
            }
        }
    }

    static func buildRows(
        reportRows: [FullLengthONTMHCReportRow],
        projection: FullLengthONTMHCWorkbookProjection,
        sampleOrder: [String],
        knownAlleleDisplayNames: [String: String] = [:]
    ) -> [[String]] {
        let sampleNames = completeSampleOrder(
            sampleOrder,
            reportRows: reportRows,
            candidateRows: projection.candidateRows,
            unnameableRows: projection.unnameableRows
        )
        var rows = [[
            "call_type",
            "call_id",
            "display_name",
            "stable_cluster_id",
            "locus",
            "classification",
            "support_class",
            "closest_reference",
            "match_class",
            "occurrence_count",
            "sample_count",
            "total_cluster_reads",
        ] + sampleNames]
        var dataRows: [[String]] = []

        let knownCounts = reportRows.reduce(into: [String: [String: Int]]()) { counts, row in
            counts[row.genotype, default: [:]][row.sample, default: 0] += row.passedUniqueReads
        }
        for callID in knownCounts.keys.sorted(by: localizedStandardLessThan) {
            let counts = knownCounts[callID] ?? [:]
            let total = counts.values.reduce(0, +)
            let displayName = knownAlleleDisplayNames[callID]
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ?? callID
            dataRows.append([
                "known-allele",
                callID,
                displayName,
                "",
                "",
                "known",
                "",
                displayName,
                "exact",
                String(counts.values.filter { $0 > 0 }.count),
                String(counts.values.filter { $0 > 0 }.count),
                String(total),
            ] + sampleNames.map { sample in
                guard let count = counts[sample], count > 0 else { return "" }
                return String(count)
            })
        }

        for candidate in projection.candidateRows {
            dataRows.append([
                "candidate-\(candidate.classification)",
                candidate.stableClusterID,
                candidate.provisionalName,
                candidate.stableClusterID,
                candidate.locus,
                candidate.classification,
                candidate.supportClass,
                candidate.closestReferenceName,
                candidate.classification,
                String(candidate.occurrenceCount),
                String(candidate.independentSampleCount),
                String(candidate.totalClusterReads),
            ] + sampleNames.map { sample in
                guard let count = candidate.readsBySample[sample], count > 0 else { return "" }
                return String(count)
            })
        }

        for row in projection.unnameableRows {
            guard let interpretation = row.candidateInterpretation else { continue }
            dataRows.append([
                "candidate-incomplete",
                row.stableClusterID,
                interpretation.provisionalName,
                row.stableClusterID,
                interpretation.locus,
                interpretation.classification.rawValue,
                row.supportClass,
                interpretation.closestReferenceName,
                ONTMHCUnnameableReason.incompleteReferenceSpan.rawValue,
                String(row.occurrenceCount),
                String(row.independentSampleCount),
                String(row.totalClusterReads),
            ] + sampleNames.map { sample in
                guard let count = row.readsBySample[sample], count > 0 else { return "" }
                return String(count)
            })
        }

        dataRows.sort { lhs, rhs in
            MHCAlleleDisplayOrder.compare(
                lhs[2],
                rhs[2],
                lhsStableID: lhs[3].isEmpty ? lhs[1] : lhs[3],
                rhsStableID: rhs[3].isEmpty ? rhs[1] : rhs[3]
            ) == .orderedAscending
        }
        rows.append(contentsOf: dataRows)

        return rows
    }

    private static func completeSampleOrder(
        _ sampleOrder: [String],
        reportRows: [FullLengthONTMHCReportRow],
        candidateRows: [FullLengthONTMHCCandidateWorkbookRow],
        unnameableRows: [FullLengthONTMHCUnnameableWorkbookRow]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for sample in sampleOrder where seen.insert(sample).inserted {
            result.append(sample)
        }
        let missing = Set(
            reportRows.map(\.sample)
                + candidateRows.flatMap { Array($0.readsBySample.keys) }
                + unnameableRows.compactMap { row in
                    row.candidateInterpretation == nil ? nil : Array(row.readsBySample.keys)
                }.flatMap { $0 }
        )
            .subtracting(seen)
            .sorted(by: localizedStandardLessThan)
        result.append(contentsOf: missing)
        return result
    }

    private static func localizedStandardLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private static func incompleteCandidateTint(
        classification: ONTMHCCandidateClassification,
        supportClass: String
    ) -> FullLengthONTMHCWorkbookTintCategory {
        switch (classification, supportClass == ONTMHCCandidateSupportClass.shared.rawValue) {
        case (.novel, true): .sharedNovel
        case (.novel, false): .singletonNovel
        case (.extension, true): .sharedExtension
        case (.extension, false): .singletonExtension
        case (.partialExtension, true): .sharedExtension
        case (.partialExtension, false): .singletonExtension
        }
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
                assignedReads: FullLengthONTMHCClusterReportBuilder.assignedReadCount(
                    genotypeRows: summary.rows
                ),
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
        return FullLengthONTMHCFileFingerprint(
            path: standardized.path,
            sha256: try ProvenanceFileHasher.sha256(of: standardized) {
                try Task.checkCancellation()
            },
            fileSizeBytes: try ProvenanceFileHasher.fileSize(of: standardized)
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
                let digest = try ProvenanceFileHasher.sha256(of: fileURL) {
                    try Task.checkCancellation()
                }
                let size = try ProvenanceFileHasher.fileSize(of: fileURL)
                return "\(relativePath)\t\(digest)\t\(size)"
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
    let resolvedOptions: [String: ParameterValue]
    let runtimeIdentity: ProvenanceRuntimeIdentity
    let inputs: [URL]
    let outputs: [URL]
    let exitStatus: Int32
    let stderr: String?
    let startedAt: Date
    let completedAt: Date

    private enum CodingKeys: String, CodingKey {
        case toolName
        case toolVersion
        case argv
        case resolvedOptions
        case runtimeIdentity
        case inputs
        case outputs
        case exitStatus
        case stderr
        case startedAt
        case completedAt
    }

    init(
        toolName: String,
        toolVersion: String,
        argv: [String],
        resolvedOptions: [String: ParameterValue] = [:],
        runtimeIdentity: ProvenanceRuntimeIdentity = ProvenanceRuntimeIdentity(),
        inputs: [URL],
        outputs: [URL],
        exitStatus: Int32,
        stderr: String?,
        startedAt: Date,
        completedAt: Date
    ) {
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.argv = argv
        self.resolvedOptions = resolvedOptions
        self.runtimeIdentity = runtimeIdentity
        self.inputs = inputs
        self.outputs = outputs
        self.exitStatus = exitStatus
        self.stderr = stderr
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            toolName: try container.decode(String.self, forKey: .toolName),
            toolVersion: try container.decode(String.self, forKey: .toolVersion),
            argv: try container.decode([String].self, forKey: .argv),
            resolvedOptions: try container.decodeIfPresent(
                [String: ParameterValue].self,
                forKey: .resolvedOptions
            ) ?? [:],
            runtimeIdentity: try container.decodeIfPresent(
                ProvenanceRuntimeIdentity.self,
                forKey: .runtimeIdentity
            ) ?? ProvenanceRuntimeIdentity(),
            inputs: try container.decode([URL].self, forKey: .inputs),
            outputs: try container.decode([URL].self, forKey: .outputs),
            exitStatus: try container.decode(Int32.self, forKey: .exitStatus),
            stderr: try container.decodeIfPresent(String.self, forKey: .stderr),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            completedAt: try container.decode(Date.self, forKey: .completedAt)
        )
    }

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
            durableReplayArgv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            resolvedOptions: resolvedOptions,
            runtimeIdentity: runtimeIdentity,
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
    struct Sheet: Codable, Sendable, Equatable {
        let name: String
        let cells: [[FullLengthONTMHCWorkbookCell]]

        init(name: String, rows: [[String]]) {
            self.name = name
            cells = rows.map { row in row.map { FullLengthONTMHCWorkbookCell($0) } }
        }

        init(name: String, cells: [[FullLengthONTMHCWorkbookCell]]) {
            self.name = name
            self.cells = cells
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
        try fullLengthONTMHCWorkbookStylesXML.write(
            to: xl.appendingPathComponent("styles.xml"),
            atomically: true,
            encoding: .utf8
        )
        for (index, sheet) in sheets.enumerated() {
            try worksheetXML(rows: sheet.cells).write(
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
      <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
    \(sheets)
    </Types>
    """
}

private func workbookXML(sheetNames: [String]) -> String {
    let sheets = sheetNames.enumerated().map { index, name in
        "<sheet name=\"\(ooxmlTextEncode(name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
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
      <Relationship Id="rId\(sheetCount + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """
}

private let fullLengthONTMHCWorkbookStylesXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="2">
    <font><sz val="11"/><name val="Aptos"/></font>
    <font><b/><sz val="11"/><name val="Aptos"/></font>
  </fonts>
  <fills count="6">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="\(opaqueWorkbookARGB(FullLengthONTMHCWorkbookTintDefaults.sharedNovel))"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="\(opaqueWorkbookARGB(FullLengthONTMHCWorkbookTintDefaults.singletonNovel))"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="\(opaqueWorkbookARGB(FullLengthONTMHCWorkbookTintDefaults.sharedExtension))"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="\(opaqueWorkbookARGB(FullLengthONTMHCWorkbookTintDefaults.singletonExtension))"/><bgColor indexed="64"/></patternFill></fill>
  </fills>
  <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="6">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
    <xf numFmtId="0" fontId="0" fillId="2" borderId="0" xfId="0" applyFill="1"/>
    <xf numFmtId="0" fontId="0" fillId="3" borderId="0" xfId="0" applyFill="1"/>
    <xf numFmtId="0" fontId="0" fillId="4" borderId="0" xfId="0" applyFill="1"/>
    <xf numFmtId="0" fontId="0" fillId="5" borderId="0" xfId="0" applyFill="1"/>
  </cellXfs>
  <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>
"""

private func opaqueWorkbookARGB(_ rgb: String) -> String {
    "FF" + rgb
}

private func worksheetXML(rows: [[FullLengthONTMHCWorkbookCell]]) -> String {
    let rowCount = max(rows.count, 1)
    let columnCount = max(rows.map(\.count).max() ?? 1, 1)
    let dimension = "A1:\(xlsxColumn(columnCount))\(rowCount)"
    let widths = (0..<columnCount).map { columnIndex -> String in
        let length = rows.compactMap { row -> Int? in
            guard row.indices.contains(columnIndex) else { return nil }
            return workbookCellDisplayText(row[columnIndex]).count
        }.max() ?? 0
        let width = min(48, max(8, length + 2))
        return "<col min=\"\(columnIndex + 1)\" max=\"\(columnIndex + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
    }.joined()
    let body = rows.enumerated().map { rowIndex, row in
        let cells = row.enumerated().map { columnIndex, cell in
            let ref = "\(xlsxColumn(columnIndex + 1))\(rowIndex + 1)"
            let style = workbookCellStyle(cell, isHeader: rowIndex == 0).map { " s=\"\($0)\"" } ?? ""
            switch cell.value {
            case .text(let value):
                return "<c r=\"\(ref)\"\(style) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(ooxmlTextEncode(value))</t></is></c>"
            case .integer(let value):
                return "<c r=\"\(ref)\"\(style)><v>\(value)</v></c>"
            case .decimal(let value):
                return "<c r=\"\(ref)\"\(style)><v>\(workbookDecimal(value))</v></c>"
            case .blank:
                return "<c r=\"\(ref)\"\(style)/>"
            }
        }.joined()
        return "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
    }.joined(separator: "\n")
    let filter = rows.isEmpty ? "" : "<autoFilter ref=\"A1:\(xlsxColumn(columnCount))\(rowCount)\"/>"
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <dimension ref="\(dimension)"/>
      <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
      <cols>\(widths)</cols>
      <sheetData>
    \(body)
      </sheetData>
      \(filter)
    </worksheet>
    """
}

private func workbookCellStyle(_ cell: FullLengthONTMHCWorkbookCell, isHeader: Bool) -> Int? {
    if isHeader { return 1 }
    switch cell.tint {
    case .sharedNovel: return 2
    case .singletonNovel: return 3
    case .sharedExtension: return 4
    case .singletonExtension: return 5
    case nil: return nil
    }
}

private func workbookCellDisplayText(_ cell: FullLengthONTMHCWorkbookCell) -> String {
    switch cell.value {
    case .text(let value): value
    case .integer(let value): String(value)
    case .decimal(let value): workbookDecimal(value)
    case .blank: ""
    }
}

private func workbookDecimal(_ value: Double) -> String {
    guard value.isFinite else { return "" }
    return String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
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

private func ooxmlTextEncode(_ value: String) -> String {
    let scalars = Array(value.unicodeScalars)
    var encoded = ""
    encoded.reserveCapacity(value.utf8.count)
    for index in scalars.indices {
        let scalar = scalars[index]
        if scalar == "_", isLiteralOOXMLEscapeToken(at: index, in: scalars) {
            encoded += "_x005F_"
            continue
        }
        guard isLegalXML10Scalar(scalar.value) else {
            encoded += String(format: "_x%04X_", scalar.value)
            continue
        }
        switch scalar {
        case "&": encoded += "&amp;"
        case "<": encoded += "&lt;"
        case ">": encoded += "&gt;"
        case "\"": encoded += "&quot;"
        case "'": encoded += "&apos;"
        default: encoded.unicodeScalars.append(scalar)
        }
    }
    return encoded
}

private func isLiteralOOXMLEscapeToken(
    at index: Int,
    in scalars: [Unicode.Scalar]
) -> Bool {
    guard index + 6 < scalars.count,
          scalars[index + 1] == "x" || scalars[index + 1] == "X",
          scalars[index + 6] == "_" else {
        return false
    }
    return scalars[(index + 2)...(index + 5)].allSatisfy { scalar in
        switch scalar.value {
        case 48...57, 65...70, 97...102: true
        default: false
        }
    }
}

private func isLegalXML10Scalar(_ value: UInt32) -> Bool {
    value == 0x9
        || value == 0xA
        || value == 0xD
        || (0x20...0xD7FF).contains(value)
        || (0xE000...0xFFFD).contains(value)
        || (0x10000...0x10FFFF).contains(value)
}
