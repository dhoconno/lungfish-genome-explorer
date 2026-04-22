import Foundation

public enum AlignmentFilterDuplicateMode: String, Codable, Sendable, CaseIterable {
    case keepAll
    case excludeMarked
    case remove
}

public enum AlignmentFilterIdentityFilter: Sendable, Equatable, Codable {
    case none
    case exactMatchesOnly
    case minimumPercent(Double)
}

public struct AlignmentFilterRequest: Sendable, Equatable, Codable {
    public let sourceTrackID: String
    public let sourceTrackName: String
    public let outputTrackName: String
    public let minimumMAPQ: Int
    public let mappedOnly: Bool
    public let primaryOnly: Bool
    public let properPairsOnly: Bool
    public let bothMatesMapped: Bool
    public let duplicateMode: AlignmentFilterDuplicateMode
    public let identityFilter: AlignmentFilterIdentityFilter
    public let regions: [String]
}

public struct AlignmentFilterCommandPlan: Sendable, Equatable {
    public let arguments: [String]
    public let requiredTags: [String]
    public let summary: String
}

public enum AlignmentFilterError: Error, LocalizedError, Sendable, Equatable {
    case invalidPercentIdentity(String)
    case conflictingIdentityFilters
    case duplicateRemovalUnavailable(String)
    case missingRequiredTags([String])

    public var errorDescription: String? {
        switch self {
        case .invalidPercentIdentity(let value):
            return "Percent identity must be a number between 0 and 100, got '\(value)'."
        case .conflictingIdentityFilters:
            return "Choose either exact matches or minimum percent identity, not both."
        case .duplicateRemovalUnavailable(let reason):
            return reason
        case .missingRequiredTags(let tags):
            return "The source BAM is missing required alignment tags: \(tags.joined(separator: ", "))."
        }
    }
}
