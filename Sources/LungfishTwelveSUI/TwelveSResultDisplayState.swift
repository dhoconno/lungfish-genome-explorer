import Foundation
import LungfishIO
import LungfishAppKit

public enum TwelveSChimeraStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case notReviewed
    case notDetected
    case candidate
    case confirmed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all:
            return "All"
        case .notReviewed:
            return "Not Reviewed"
        case .notDetected:
            return "Not Detected"
        case .candidate:
            return "Candidate"
        case .confirmed:
            return "Confirmed"
        }
    }

    public func includes(_ status: TwelveSChimeraStatus) -> Bool {
        switch self {
        case .all:
            return true
        case .notReviewed:
            return status == .notReviewed
        case .notDetected:
            return status == .notDetected
        case .candidate:
            return status == .candidate
        case .confirmed:
            return status == .confirmed
        }
    }
}

public struct TwelveSResultDisplayState: Equatable, Sendable {
    public var minimumExactReads: Int
    public var filterText: String
    public var includedTaxonGroups: Set<String>
    public var excludedTaxonGroups: Set<String>
    public var excludeHuman: Bool
    public var requireAlternateMatches: Bool
    public var minimumUnresolvedReads: Int
    public var chimeraFilter: TwelveSChimeraStatusFilter

    public init(
        minimumExactReads: Int = 0,
        filterText: String = "",
        includedTaxonGroups: Set<String> = [],
        excludedTaxonGroups: Set<String> = [],
        excludeHuman: Bool = false,
        requireAlternateMatches: Bool = false,
        minimumUnresolvedReads: Int = 0,
        chimeraFilter: TwelveSChimeraStatusFilter = .all
    ) {
        self.minimumExactReads = max(0, minimumExactReads)
        self.filterText = filterText
        self.includedTaxonGroups = includedTaxonGroups
        self.excludedTaxonGroups = excludedTaxonGroups
        self.excludeHuman = excludeHuman
        self.requireAlternateMatches = requireAlternateMatches
        self.minimumUnresolvedReads = max(0, minimumUnresolvedReads)
        self.chimeraFilter = chimeraFilter
    }

    /// The 12S row-visibility filter expressed as the shared threshold type so
    /// both result viewports converge on one model. Behavior is unchanged: 12S
    /// continues to drive its live filter from `minimumExactReads`.
    public var minimumReadsThreshold: MinimumReadsThreshold {
        .init(value: minimumExactReads)
    }

    public var normalizedFilterText: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalizedIncludedTaxonGroups: Set<String> {
        Set(includedTaxonGroups.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    public var normalizedExcludedTaxonGroups: Set<String> {
        Set(excludedTaxonGroups.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }
}

public struct TwelveSResultDisplaySummary: Equatable, Sendable {
    public let rowLabel: String
    public let visibleRows: Int
    public let totalRows: Int

    public init(rowLabel: String, visibleRows: Int, totalRows: Int) {
        self.rowLabel = rowLabel
        self.visibleRows = visibleRows
        self.totalRows = totalRows
    }
}

public struct TwelveSDetailSampleEvidenceRow: Equatable, Sendable {
    public let sampleID: String
    public let displayName: String
    public let exactReads: Int
    public let percentOfSampleExactReads: Double

    public init(sampleID: String, displayName: String, exactReads: Int, percentOfSampleExactReads: Double) {
        self.sampleID = sampleID
        self.displayName = displayName
        self.exactReads = exactReads
        self.percentOfSampleExactReads = percentOfSampleExactReads
    }
}

public struct TwelveSUnresolvedBlastRequest: Equatable, Sendable {
    public let bundleURL: URL
    public let minimumReads: Int
    public let sequences: [TwelveSUnresolvedSequence]

    public init(bundleURL: URL, minimumReads: Int, sequences: [TwelveSUnresolvedSequence]) {
        self.bundleURL = bundleURL
        self.minimumReads = minimumReads
        self.sequences = sequences
    }
}
