// AlignmentFilterModels.swift - Pure BAM filtering request/plan models
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Duplicate handling mode for BAM filtering.
public enum AlignmentFilterDuplicateMode: String, Sendable, Codable, Equatable {
    /// Exclude duplicates from the filtered output.
    case exclude
    /// Mark duplicates first, then exclude duplicate-marked reads from the final derived BAM.
    case remove
}

/// Explicit preprocessing required before the final `samtools view` step.
public enum AlignmentFilterPreprocessingStep: Sendable, Codable, Equatable {
    /// `removeDuplicates == false` represents duplicate marking only.
    case samtoolsMarkdup(removeDuplicates: Bool)
}

/// Identity-based BAM filtering criteria.
public enum AlignmentFilterIdentityFilter: Sendable, Codable, Equatable {
    /// Keep only exact matches (`NM == 0`).
    case exactMatch
    /// Keep reads meeting or exceeding the given percent identity threshold.
    case minimumPercentIdentity(Double)

    /// Returns the samtools expression for this filter.
    public var samtoolsExpression: String {
        switch self {
        case .exactMatch:
            return "[NM] == 0"
        case .minimumPercentIdentity(let threshold):
            return "(qlen > sclen) && (((qlen - sclen - [NM]) / (qlen - sclen)) * 100 >= \(Self.formattedThreshold(threshold)))"
        }
    }

    /// Required SAM tags for evaluating this identity filter.
    public var requiredSAMTags: [String] {
        ["NM"]
    }

    public var displayLabel: String {
        switch self {
        case .exactMatch:
            return "Exact matches"
        case .minimumPercentIdentity(let threshold):
            return "\(Self.formattedThreshold(threshold))% minimum identity"
        }
    }

    public var metadataValue: String {
        switch self {
        case .exactMatch:
            return "exact_match"
        case .minimumPercentIdentity(let threshold):
            return "minimum_percent_identity:\(Self.formattedThreshold(threshold))"
        }
    }

    public static func formattedThreshold(_ threshold: Double) -> String {
        if threshold.rounded(.towardZero) == threshold {
            return String(Int(threshold))
        }

        var text = String(threshold)
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }
}

/// Pure request model for BAM filtering.
public struct AlignmentFilterRequest: Sendable, Codable, Equatable {
    public var mappedOnly: Bool
    public var primaryOnly: Bool
    public var minimumMAPQ: Int?
    public var duplicateMode: AlignmentFilterDuplicateMode?
    public var identityFilter: AlignmentFilterIdentityFilter?
    public var region: String?

    public init(
        mappedOnly: Bool = false,
        primaryOnly: Bool = false,
        minimumMAPQ: Int? = nil,
        duplicateMode: AlignmentFilterDuplicateMode? = nil,
        identityFilter: AlignmentFilterIdentityFilter? = nil,
        region: String? = nil
    ) {
        self.mappedOnly = mappedOnly
        self.primaryOnly = primaryOnly
        self.minimumMAPQ = minimumMAPQ
        self.duplicateMode = duplicateMode
        self.identityFilter = identityFilter
        self.region = region
    }

    public var derivedAlignmentDefaultName: String {
        if let identityFilter {
            return identityFilter.displayLabel
        }

        switch duplicateMode {
        case .remove:
            return "Duplicate-marked reads removed"
        case .exclude:
            return "Duplicate-marked reads hidden"
        case nil:
            break
        }

        if let minimumMAPQ {
            return "MAPQ >= \(minimumMAPQ)"
        }

        if mappedOnly && primaryOnly {
            return "Mapped primary alignments"
        }
        if mappedOnly {
            return "Mapped alignments"
        }
        if primaryOnly {
            return "Primary alignments"
        }

        return "Filtered alignments"
    }

    public var derivedAlignmentSummary: String {
        let parts = derivedAlignmentFilterParts
        guard !parts.isEmpty else { return "No additional filters" }
        return parts.joined(separator: "; ")
    }

    public var derivedAlignmentFilterParts: [String] {
        var parts: [String] = []

        if let identityFilter {
            parts.append(identityFilter.displayLabel)
        }
        if mappedOnly {
            parts.append("mapped reads only")
        }
        if primaryOnly {
            parts.append("primary alignments only")
        }
        if let minimumMAPQ {
            parts.append("MAPQ >= \(minimumMAPQ)")
        }
        switch duplicateMode {
        case .exclude:
            parts.append("duplicate-marked reads hidden")
        case .remove:
            parts.append("duplicate-marked reads removed")
        case nil:
            break
        }
        if let region = region?.trimmingCharacters(in: .whitespacesAndNewlines),
           !region.isEmpty {
            parts.append("region \(region)")
        }

        return parts
    }
}

/// Deterministic samtools command plan for BAM filtering.
public struct AlignmentFilterCommandPlan: Sendable, Codable, Equatable {
    public let executable: String
    public let subcommand: String
    public let arguments: [String]
    public let trailingArguments: [String]
    public let preprocessingSteps: [AlignmentFilterPreprocessingStep]
    public let duplicateMode: AlignmentFilterDuplicateMode?
    public let identityFilterExpression: String?
    public let requiredSAMTags: [String]

    public init(
        executable: String = "samtools",
        subcommand: String = "view",
        arguments: [String],
        trailingArguments: [String] = [],
        preprocessingSteps: [AlignmentFilterPreprocessingStep] = [],
        duplicateMode: AlignmentFilterDuplicateMode? = nil,
        identityFilterExpression: String? = nil,
        requiredSAMTags: [String] = []
    ) {
        self.executable = executable
        self.subcommand = subcommand
        self.arguments = arguments
        self.trailingArguments = trailingArguments
        self.preprocessingSteps = preprocessingSteps
        self.duplicateMode = duplicateMode
        self.identityFilterExpression = identityFilterExpression
        self.requiredSAMTags = requiredSAMTags
    }

    /// Full command arguments including the subcommand, input path, and trailing regions.
    public func commandArguments(appendingInputPath inputPath: String) -> [String] {
        [subcommand] + arguments + [inputPath] + trailingArguments
    }
}

/// Errors thrown while building a BAM filter command plan.
public enum AlignmentFilterError: Error, LocalizedError, Sendable, Equatable {
    case invalidRegion(String)
    case invalidMinimumMAPQ(Int)
    case invalidMinimumPercentIdentity(Double)

    public var errorDescription: String? {
        switch self {
        case .invalidRegion(let region):
            return "Invalid BAM filter region: \(region)"
        case .invalidMinimumMAPQ(let mapq):
            return "Invalid minimum MAPQ: \(mapq)"
        case .invalidMinimumPercentIdentity(let threshold):
            return "Invalid minimum percent identity: \(threshold)"
        }
    }
}
