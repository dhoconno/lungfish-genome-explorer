import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeResultArtifacts: Codable, Equatable, Sendable {
    public let workbookURL: URL
    public let primaryWorkbookURL: URL
    public let longSummaryCSVURL: URL
    public let sampleSummaryCSVURL: URL
    public let statsJSONURL: URL
    public let provenanceURL: URL
    public let deduplicatedUnmatchedClustersFASTAURL: URL?
    public let haplotypeAnalysisURL: URL?

    public init(
        workbookURL: URL,
        primaryWorkbookURL: URL? = nil,
        longSummaryCSVURL: URL,
        sampleSummaryCSVURL: URL,
        statsJSONURL: URL,
        provenanceURL: URL,
        deduplicatedUnmatchedClustersFASTAURL: URL? = nil,
        haplotypeAnalysisURL: URL? = nil
    ) {
        self.workbookURL = workbookURL.standardizedFileURL
        self.primaryWorkbookURL = (primaryWorkbookURL ?? workbookURL).standardizedFileURL
        self.longSummaryCSVURL = longSummaryCSVURL.standardizedFileURL
        self.sampleSummaryCSVURL = sampleSummaryCSVURL.standardizedFileURL
        self.statsJSONURL = statsJSONURL.standardizedFileURL
        self.provenanceURL = provenanceURL.standardizedFileURL
        self.deduplicatedUnmatchedClustersFASTAURL = deduplicatedUnmatchedClustersFASTAURL?.standardizedFileURL
        self.haplotypeAnalysisURL = haplotypeAnalysisURL?.standardizedFileURL
    }

    public init(
        workbookURL: URL,
        longSummaryCSVURL: URL,
        sampleSummaryCSVURL: URL,
        statsJSONURL: URL,
        provenanceURL: URL,
        deduplicatedUnmatchedClustersFASTAURL: URL? = nil,
        haplotypeAnalysisURL: URL? = nil
    ) {
        self.init(
            workbookURL: workbookURL,
            primaryWorkbookURL: workbookURL,
            longSummaryCSVURL: longSummaryCSVURL,
            sampleSummaryCSVURL: sampleSummaryCSVURL,
            statsJSONURL: statsJSONURL,
            provenanceURL: provenanceURL,
            deduplicatedUnmatchedClustersFASTAURL: deduplicatedUnmatchedClustersFASTAURL,
            haplotypeAnalysisURL: haplotypeAnalysisURL
        )
    }

    public init(
        workbookURL: URL,
        longSummaryCSVURL: URL,
        sampleSummaryCSVURL: URL,
        statsJSONURL: URL,
        provenanceURL: URL,
        haplotypeAnalysisURL: URL? = nil
    ) {
        self.init(
            workbookURL: workbookURL,
            primaryWorkbookURL: workbookURL,
            longSummaryCSVURL: longSummaryCSVURL,
            sampleSummaryCSVURL: sampleSummaryCSVURL,
            statsJSONURL: statsJSONURL,
            provenanceURL: provenanceURL,
            deduplicatedUnmatchedClustersFASTAURL: nil,
            haplotypeAnalysisURL: haplotypeAnalysisURL
        )
    }
}
