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
    /// The distribution length built and supported by Lungfish database installs.
    public static let supportedReadLength = 150

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
            readLength: supportedReadLength,
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

/// What the Kraken report allows Bracken to estimate, decided before Bracken runs.
///
/// The rules are those of the managed Bracken's own check in `est_abundance.py`. It keeps a taxon
/// whose rank code is the resolved level and whose clade count, the reads of the taxon and of
/// everything below it (column 2 of the report), is not below the threshold. A taxon at the
/// threshold is kept. A strain below a species (rank S1) is not at species level, and a taxon
/// above the level counts for nothing, however many reads it holds. Bracken exits 1 with "no reads
/// found" when it keeps none, and this check finds that case first. The live pin is
/// `BrackenThresholdPreflightLiveConformanceTests`, which holds each rule against the managed tool
/// one read below the threshold, at it and one read above.
enum BrackenReportCheck {

    /// The reason the report cannot be profiled at `resolution` with the message that goes with
    /// it, or nil when Bracken has at least one taxon to estimate.
    static func failure(
        in tree: TaxonTree,
        resolution: BrackenProfileResolution
    ) -> (BrackenProfileDegradationReason, String)? {
        let atRank = tree.nodes(at: resolution.rank)
        guard !atRank.isEmpty else {
            return (
                .rankAbsentFromReport,
                "The Kraken report has no rows at resolved rank \(resolution.rank.code) (\(resolution.rank.displayName))."
            )
        }
        let most = atRank.map(\.readsClade).max() ?? 0
        guard most < resolution.threshold else { return nil }
        let rank = resolution.rank.displayName.lowercased()
        return (
            .belowThreshold,
            "No \(rank) reaches the Bracken threshold of \(resolution.threshold) reads. "
                + "The \(rank) with the most reads has \(most)."
        )
    }
}

public enum BrackenProfileState: String, Sendable, Codable, Equatable {
    case notRequested
    case completed
    case degraded
}

/// Machine-readable reason why a requested Bracken profile did not complete.
///
/// The reason is stored in the `profileOutcome` of `classification-result.json`, and a result
/// travels between releases. A later release can name a reason this build does not know, so
/// reading never fails on a raw value. The reader keeps the value as ``unknown(_:)`` and writes it
/// back exactly as it came, so the result still opens, shows its message and can be saved again.
///
/// The raw value is the stored token. Two reasons with the same token are equal, so a known case
/// and ``unknown(_:)`` holding its token are the same reason. A known case never decodes as
/// ``unknown(_:)``, and `description` is the token, so a message that interpolates a reason reads
/// the same for every case.
public enum BrackenProfileDegradationReason: Sendable, Hashable, Codable, RawRepresentable, CustomStringConvertible {
    case unsupportedRank
    case rankAbsentFromReport
    case distributionUnavailable
    case toolUnavailable
    case toolFailed
    case outputMissing
    case outputInvalid

    /// No taxon at the resolved rank has enough reads to pass Bracken's threshold, so Bracken was
    /// not run. Builds before Phase 2.9 never wrote it. 2026.10.15 reads it as ``unknown(_:)`` and
    /// opens the result, and 2026.10.14 does not open it.
    case belowThreshold

    /// A reason this build does not know, held exactly as it was stored.
    case unknown(String)

    /// The reason stored as `rawValue`. A token this build does not know becomes
    /// ``unknown(_:)``, so this initializer never fails.
    public init(rawValue: String) {
        switch rawValue {
        case "unsupportedRank": self = .unsupportedRank
        case "rankAbsentFromReport": self = .rankAbsentFromReport
        case "distributionUnavailable": self = .distributionUnavailable
        case "toolUnavailable": self = .toolUnavailable
        case "toolFailed": self = .toolFailed
        case "outputMissing": self = .outputMissing
        case "outputInvalid": self = .outputInvalid
        case "belowThreshold": self = .belowThreshold
        default: self = .unknown(rawValue)
        }
    }

    /// The stored token.
    public var rawValue: String {
        switch self {
        case .unsupportedRank: return "unsupportedRank"
        case .rankAbsentFromReport: return "rankAbsentFromReport"
        case .distributionUnavailable: return "distributionUnavailable"
        case .toolUnavailable: return "toolUnavailable"
        case .toolFailed: return "toolFailed"
        case .outputMissing: return "outputMissing"
        case .outputInvalid: return "outputInvalid"
        case .belowThreshold: return "belowThreshold"
        case .unknown(let token): return token
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }

    /// The stored token, which is also what string interpolation shows.
    public var description: String { rawValue }
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

    /// A profile that ran to completion.
    ///
    /// `message` carries a note about how the run was carried out when there is one worth
    /// the reader's attention -- most importantly that the database had no kmer distribution
    /// for the requested read length and a nearby one was substituted, which changes the
    /// abundance estimates and was previously visible only in the system log.
    public static func completed(
        resolution: BrackenProfileResolution,
        toolVersion: String? = nil,
        message: String? = nil
    ) -> BrackenProfileOutcome {
        BrackenProfileOutcome(
            state: .completed,
            resolution: resolution,
            toolVersion: toolVersion,
            message: message
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
