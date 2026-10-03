import Foundation
import Darwin
import LungfishCore
import LungfishIO

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
    /// Nil when the run denominator was 0 or unknown; the genotypes are still valid.
    public let retainedUniquePercentOfTotalReads: Double?
    public let assignedUniqueRetainedReads: Int
    public let unassignedUniqueRetainedReads: Int
}
