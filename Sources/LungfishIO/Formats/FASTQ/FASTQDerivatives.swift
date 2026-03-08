// FASTQDerivatives.swift - Pointer-based FASTQ derivative datasets
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Field used for read lookup operations.
public enum FASTQSearchField: String, Codable, Sendable, CaseIterable {
    case id
    case description
}

/// Deduplication key strategy.
public enum FASTQDeduplicateMode: String, Codable, Sendable, CaseIterable {
    case identifier
    case description
    case sequence
}

/// Transformation used to create a derived FASTQ pointer dataset.
public enum FASTQDerivativeOperationKind: String, Codable, Sendable, CaseIterable {
    case subsampleProportion
    case subsampleCount
    case lengthFilter
    case searchText
    case searchMotif
    case deduplicate
}

/// Serializable operation configuration for derived FASTQ datasets.
public struct FASTQDerivativeOperation: Codable, Sendable, Equatable {
    public let kind: FASTQDerivativeOperationKind
    public let createdAt: Date

    // Generic optional parameter payload for lightweight persistence.
    public var proportion: Double?
    public var count: Int?
    public var minLength: Int?
    public var maxLength: Int?
    public var query: String?
    public var searchField: FASTQSearchField?
    public var useRegex: Bool?
    public var deduplicateMode: FASTQDeduplicateMode?
    public var pairedAware: Bool?

    public init(
        kind: FASTQDerivativeOperationKind,
        createdAt: Date = Date(),
        proportion: Double? = nil,
        count: Int? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        query: String? = nil,
        searchField: FASTQSearchField? = nil,
        useRegex: Bool? = nil,
        deduplicateMode: FASTQDeduplicateMode? = nil,
        pairedAware: Bool? = nil
    ) {
        self.kind = kind
        self.createdAt = createdAt
        self.proportion = proportion
        self.count = count
        self.minLength = minLength
        self.maxLength = maxLength
        self.query = query
        self.searchField = searchField
        self.useRegex = useRegex
        self.deduplicateMode = deduplicateMode
        self.pairedAware = pairedAware
    }

    public var shortLabel: String {
        switch kind {
        case .subsampleProportion:
            if let proportion {
                return String(format: "subsample-p%.4f", proportion)
            }
            return "subsample-proportion"
        case .subsampleCount:
            if let count {
                return "subsample-n\(count)"
            }
            return "subsample-count"
        case .lengthFilter:
            let minString = minLength.map(String.init) ?? "any"
            let maxString = maxLength.map(String.init) ?? "any"
            return "len-\(minString)-\(maxString)"
        case .searchText:
            return "search-text"
        case .searchMotif:
            return "search-motif"
        case .deduplicate:
            return "dedup"
        }
    }

    public var displaySummary: String {
        switch kind {
        case .subsampleProportion:
            if let proportion {
                return "Subsample by proportion (\(String(format: "%.4f", proportion)))"
            }
            return "Subsample by proportion"
        case .subsampleCount:
            if let count {
                return "Subsample \(count) reads"
            }
            return "Subsample by count"
        case .lengthFilter:
            let minString = minLength.map(String.init) ?? "-"
            let maxString = maxLength.map(String.init) ?? "-"
            return "Length filter (min: \(minString), max: \(maxString))"
        case .searchText:
            let fieldString = searchField?.rawValue ?? "id"
            let queryString = query ?? ""
            return "Search \(fieldString): \(queryString)"
        case .searchMotif:
            let queryString = query ?? ""
            return "Motif search: \(queryString)"
        case .deduplicate:
            let modeString = deduplicateMode?.rawValue ?? FASTQDeduplicateMode.identifier.rawValue
            if pairedAware == true {
                return "Deduplicate by \(modeString) (paired-aware)"
            }
            return "Deduplicate by \(modeString)"
        }
    }
}

/// Pointer manifest saved in derived `.lungfishfastq` bundles.
///
/// Derived bundles do not duplicate FASTQ payload bytes. They only store read IDs
/// and lineage metadata that points back to a parent/root bundle.
public struct FASTQDerivedBundleManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let name: String
    public let createdAt: Date

    /// Relative path from this bundle to the immediate parent bundle.
    public let parentBundleRelativePath: String

    /// Relative path from this bundle to the root (physical FASTQ payload) bundle.
    public let rootBundleRelativePath: String

    /// FASTQ filename inside the root bundle.
    public let rootFASTQFilename: String

    /// Read ID list filename in this bundle.
    public let readIDListFilename: String

    /// Sequence of operations from root to this dataset (inclusive of latest operation).
    public let lineage: [FASTQDerivativeOperation]

    /// Latest operation used to produce this dataset.
    public let operation: FASTQDerivativeOperation

    /// Cached dataset statistics for immediate dashboard/inspector rendering.
    public let cachedStatistics: FASTQDatasetStatistics

    /// Pairing mode inherited at generation time.
    public let pairingMode: IngestionMetadata.PairingMode?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        parentBundleRelativePath: String,
        rootBundleRelativePath: String,
        rootFASTQFilename: String,
        readIDListFilename: String = "read-ids.txt",
        lineage: [FASTQDerivativeOperation],
        operation: FASTQDerivativeOperation,
        cachedStatistics: FASTQDatasetStatistics,
        pairingMode: IngestionMetadata.PairingMode?
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.parentBundleRelativePath = parentBundleRelativePath
        self.rootBundleRelativePath = rootBundleRelativePath
        self.rootFASTQFilename = rootFASTQFilename
        self.readIDListFilename = readIDListFilename
        self.lineage = lineage
        self.operation = operation
        self.cachedStatistics = cachedStatistics
        self.pairingMode = pairingMode
    }
}
