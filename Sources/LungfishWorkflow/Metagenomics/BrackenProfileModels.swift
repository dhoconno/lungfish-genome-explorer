// BrackenProfileModels.swift - Database-aware Bracken request and outcome models
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// How the profiling rank was selected.
public enum BrackenRankRequest: Sendable, Codable, Equatable {
    /// Resolve the rank from stable database capabilities.
    case automatic

    /// Preserve a caller-supplied rank exactly.
    case explicit(TaxonomicRank)

    /// Stable, human-readable value used by summaries and provenance.
    public var provenanceValue: String {
        switch self {
        case .automatic:
            return "automatic"
        case .explicit(let rank):
            return "explicit:\(rank.code)"
        }
    }
}

/// User-visible Bracken options captured before database-aware resolution.
public struct BrackenProfileRequest: Sendable, Codable, Equatable {
    public let rank: BrackenRankRequest
    public let readLength: Int
    public let threshold: Int

    public init(
        rank: BrackenRankRequest,
        readLength: Int = 150,
        threshold: Int = 10
    ) {
        self.rank = rank
        self.readLength = readLength
        self.threshold = threshold
    }

    /// The only automatic defaults supported by the current database builds.
    public static let automaticDefault = BrackenProfileRequest(
        rank: .automatic,
        readLength: 150,
        threshold: 10
    )
}

/// Evidence explaining how an automatic or explicit request became a rank.
public enum BrackenRankResolutionSource: String, Sendable, Codable, Equatable {
    case explicitRequest
    case catalogIdentity
    case installationRecipe
    case compatibilityDefault
}

/// Fully resolved Bracken settings used for preflight and execution.
public struct BrackenProfileResolution: Sendable, Codable, Equatable {
    public let request: BrackenRankRequest
    public let rank: TaxonomicRank
    public let source: BrackenRankResolutionSource
    public let readLength: Int
    public let threshold: Int

    public init(
        request: BrackenRankRequest,
        rank: TaxonomicRank,
        source: BrackenRankResolutionSource,
        readLength: Int,
        threshold: Int
    ) {
        self.request = request
        self.rank = rank
        self.source = source
        self.readLength = readLength
        self.threshold = threshold
    }
}

/// Stable database capability rules for Bracken rank resolution.
public enum BrackenDatabaseCapabilities {
    private static let genusCatalogIDs: Set<String> = [
        "kraken2-special-silva",
        "kraken2-special-greengenes",
    ]

    public static func resolve(
        catalogID: String?,
        installationRecipe: MetagenomicsDatabaseInstallationRecipe?,
        request: BrackenRankRequest,
        readLength: Int = 150,
        threshold: Int = 10
    ) -> BrackenProfileResolution {
        if case .explicit(let rank) = request {
            return BrackenProfileResolution(
                request: request,
                rank: rank,
                source: .explicitRequest,
                readLength: readLength,
                threshold: threshold
            )
        }

        if let catalogID,
           MetagenomicsDatabaseInfo.catalogEntry(catalogID: catalogID) != nil {
            let rank: TaxonomicRank = genusCatalogIDs.contains(catalogID) ? .genus : .species
            return BrackenProfileResolution(
                request: request,
                rank: rank,
                source: .catalogIdentity,
                readLength: readLength,
                threshold: threshold
            )
        }

        if case .kraken2Special(let type) = installationRecipe,
           type == .silva || type == .greengenes {
            return BrackenProfileResolution(
                request: request,
                rank: .genus,
                source: .installationRecipe,
                readLength: readLength,
                threshold: threshold
            )
        }

        return BrackenProfileResolution(
            request: request,
            rank: .species,
            source: .compatibilityDefault,
            readLength: readLength,
            threshold: threshold
        )
    }

    public static func resolve(
        catalogID: String?,
        installationRecipe: MetagenomicsDatabaseInstallationRecipe?,
        request: BrackenProfileRequest
    ) -> BrackenProfileResolution {
        resolve(
            catalogID: catalogID,
            installationRecipe: installationRecipe,
            request: request.rank,
            readLength: request.readLength,
            threshold: request.threshold
        )
    }

    /// Returns the exact Bracken `-l` code, or nil when Bracken does not support
    /// the rank. Unsupported ranks are never rewritten to species.
    public static func levelCode(for rank: TaxonomicRank) -> String? {
        switch rank {
        case .domain: return "D"
        case .phylum: return "P"
        case .class: return "C"
        case .order: return "O"
        case .family: return "F"
        case .genus: return "G"
        case .species: return "S"
        default: return nil
        }
    }
}

public enum BrackenProfileState: String, Sendable, Codable, Equatable {
    case notRequested
    case completed
    case degraded
}

/// Machine-readable reason why a requested Bracken profile did not complete.
public enum BrackenProfileDegradationReason: String, Sendable, Codable, Equatable {
    case unsupportedRank
    case rankAbsentFromReport
    case distributionUnavailable
    case toolUnavailable
    case toolFailed
    case outputMissing
    case outputInvalid
}

/// Durable scientific outcome of the optional profiling phase.
public struct BrackenProfileOutcome: Sendable, Codable, Equatable {
    public let state: BrackenProfileState
    public let resolution: BrackenProfileResolution?
    public let toolVersion: String?
    public let reason: BrackenProfileDegradationReason?
    public let message: String?

    private init(
        state: BrackenProfileState,
        resolution: BrackenProfileResolution?,
        toolVersion: String? = nil,
        reason: BrackenProfileDegradationReason? = nil,
        message: String? = nil
    ) {
        self.state = state
        self.resolution = resolution
        self.toolVersion = toolVersion
        self.reason = reason
        self.message = message
    }

    public static let notRequested = BrackenProfileOutcome(
        state: .notRequested,
        resolution: nil
    )

    public static func completed(
        resolution: BrackenProfileResolution,
        toolVersion: String? = nil
    ) -> BrackenProfileOutcome {
        BrackenProfileOutcome(
            state: .completed,
            resolution: resolution,
            toolVersion: toolVersion
        )
    }

    public static func degraded(
        resolution: BrackenProfileResolution,
        reason: BrackenProfileDegradationReason,
        message: String,
        toolVersion: String? = nil
    ) -> BrackenProfileOutcome {
        BrackenProfileOutcome(
            state: .degraded,
            resolution: resolution,
            toolVersion: toolVersion,
            reason: reason,
            message: message
        )
    }
}

extension MetagenomicsDatabaseInstallationRecipe {
    /// Stable compact representation for result summaries and provenance options.
    public var provenanceValue: String {
        switch self {
        case .archive(let url):
            return "archive:\(url.absoluteString)"
        case .kraken2Special(let type):
            return "kraken2-special:\(type.rawValue)"
        }
    }
}
