import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

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
