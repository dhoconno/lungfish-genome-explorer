import Foundation
import LungfishIO
import LungfishAppKit

enum TwelveSChimeraStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case notReviewed
    case notDetected
    case candidate
    case confirmed

    var id: String { rawValue }

    var displayName: String {
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

    func includes(_ status: TwelveSChimeraStatus) -> Bool {
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

struct TwelveSResultDisplayState: Equatable, Sendable {
    var minimumExactReads: Int
    var filterText: String
    var includedTaxonGroups: Set<String>
    var excludedTaxonGroups: Set<String>
    var excludeHuman: Bool
    var requireAlternateMatches: Bool
    var minimumUnresolvedReads: Int
    var chimeraFilter: TwelveSChimeraStatusFilter

    init(
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
    var minimumReadsThreshold: MinimumReadsThreshold {
        .init(value: minimumExactReads)
    }

    var normalizedFilterText: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedIncludedTaxonGroups: Set<String> {
        Set(includedTaxonGroups.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    var normalizedExcludedTaxonGroups: Set<String> {
        Set(excludedTaxonGroups.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }
}

struct TwelveSResultDisplaySummary: Equatable, Sendable {
    let rowLabel: String
    let visibleRows: Int
    let totalRows: Int
}

struct TwelveSDetailSampleEvidenceRow: Equatable, Sendable {
    let sampleID: String
    let displayName: String
    let exactReads: Int
    let percentOfSampleExactReads: Double
}

struct TwelveSUnresolvedBlastRequest: Equatable, Sendable {
    let bundleURL: URL
    let minimumReads: Int
    let sequences: [TwelveSUnresolvedSequence]
}
