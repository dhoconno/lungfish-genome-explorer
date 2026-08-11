// SampleMetadataPresentationContext.swift — Result-scoped sample metadata contracts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Explicit persisted identities for a single sample.
public struct SampleIdentity: Equatable, Sendable {
    public let canonicalID: String
    public let aliases: [String]
    public let alignmentTrackIDs: [String]
    public let readGroupIDs: [String]

    public init(
        canonicalID: String,
        aliases: [String],
        alignmentTrackIDs: [String],
        readGroupIDs: [String]
    ) {
        self.canonicalID = canonicalID
        self.aliases = aliases
        self.alignmentTrackIDs = alignmentTrackIDs
        self.readGroupIDs = readGroupIDs
    }
}

/// Errors emitted when persisted sample identities do not form an unambiguous index.
public enum SampleIdentityIndexError: Error, Equatable {
    case emptyCanonicalID
    case duplicateCanonicalID(String)
    case ambiguousAlias(String)
    case ambiguousAlignmentTrackID(String)
    case ambiguousReadGroupID(String)
    case invalidOneSampleFallback(String)
}

/// Resolves metadata and BAM identities only through persisted mappings.
///
/// Values are trimmed and compared case-insensitively. A canonical ID always
/// wins before aliases are considered. Aliases, tracks, and read groups that
/// map to more than one canonical sample are rejected when the index is built.
public struct SampleIdentityIndex: Sendable {
    private let canonicalIDs: [String: String]
    private let aliases: [String: String]
    private let alignmentTrackIDs: [String: String]
    private let readGroupIDs: [String: String]
    private let readGroupsByCanonicalID: [String: Set<String>]
    private let explicitOneSampleFallbackCanonicalID: String?

    public init(
        samples: [SampleIdentity],
        explicitOneSampleFallbackCanonicalID: String? = nil
    ) throws {
        var canonicalIDs: [String: String] = [:]
        for sample in samples {
            let key = Self.normalized(sample.canonicalID)
            guard !key.isEmpty else { throw SampleIdentityIndexError.emptyCanonicalID }
            guard canonicalIDs[key] == nil else {
                throw SampleIdentityIndexError.duplicateCanonicalID(sample.canonicalID)
            }
            canonicalIDs[key] = sample.canonicalID
        }

        var aliases: [String: String] = [:]
        var alignmentTrackIDs: [String: String] = [:]
        var readGroupIDs: [String: String] = [:]
        var readGroupsByCanonicalID: [String: Set<String>] = [:]

        for sample in samples {
            for alias in sample.aliases {
                let key = Self.normalized(alias)
                guard !key.isEmpty, canonicalIDs[key] == nil else { continue }
                try Self.insert(
                    canonicalID: sample.canonicalID,
                    key: key,
                    into: &aliases,
                    ambiguousError: .ambiguousAlias(key)
                )
            }
            for trackID in sample.alignmentTrackIDs {
                let key = Self.normalized(trackID)
                guard !key.isEmpty else { continue }
                try Self.insert(
                    canonicalID: sample.canonicalID,
                    key: key,
                    into: &alignmentTrackIDs,
                    ambiguousError: .ambiguousAlignmentTrackID(key)
                )
            }
            for readGroupID in sample.readGroupIDs {
                let key = Self.normalized(readGroupID)
                guard !key.isEmpty else { continue }
                try Self.insert(
                    canonicalID: sample.canonicalID,
                    key: key,
                    into: &readGroupIDs,
                    ambiguousError: .ambiguousReadGroupID(key)
                )
                readGroupsByCanonicalID[sample.canonicalID, default: []].insert(readGroupID)
            }
        }

        if let fallback = explicitOneSampleFallbackCanonicalID {
            let resolvedFallback = canonicalIDs[Self.normalized(fallback)]
            guard samples.count == 1, let resolvedFallback else {
                throw SampleIdentityIndexError.invalidOneSampleFallback(fallback)
            }
            self.explicitOneSampleFallbackCanonicalID = resolvedFallback
        } else {
            self.explicitOneSampleFallbackCanonicalID = nil
        }

        self.canonicalIDs = canonicalIDs
        self.aliases = aliases
        self.alignmentTrackIDs = alignmentTrackIDs
        self.readGroupIDs = readGroupIDs
        self.readGroupsByCanonicalID = readGroupsByCanonicalID
    }

    /// Resolves a metadata value using canonical IDs first, then explicit aliases.
    public func canonicalSampleID(forMetadataIdentifier identifier: String?) -> String? {
        guard let identifier else { return nil }
        let key = Self.normalized(identifier)
        return canonicalIDs[key] ?? aliases[key]
    }

    /// Resolves a BAM alignment track without deriving identity from its path.
    public func canonicalSampleID(forAlignmentTrackID trackID: String?) -> String? {
        guard let trackID else { return explicitOneSampleFallbackCanonicalID }
        return alignmentTrackIDs[Self.normalized(trackID)]
    }

    /// Resolves a BAM read group; an explicit one-sample fallback is used only for a missing ID.
    public func canonicalSampleID(forReadGroupID readGroupID: String?) -> String? {
        guard let readGroupID else { return explicitOneSampleFallbackCanonicalID }
        return readGroupIDs[Self.normalized(readGroupID)]
    }

    /// All read groups belonging to a selected canonical sample.
    public func readGroupIDs(forCanonicalSampleID canonicalID: String) -> Set<String> {
        readGroupsByCanonicalID[canonicalIDs[Self.normalized(canonicalID)] ?? canonicalID] ?? []
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func insert(
        canonicalID: String,
        key: String,
        into values: inout [String: String],
        ambiguousError: SampleIdentityIndexError
    ) throws {
        if let existing = values[key], existing != canonicalID {
            throw ambiguousError
        }
        values[key] = canonicalID
    }
}

/// Information retained by a result owner for a future import/provenance service.
public struct SampleMetadataImportContext: Equatable, Sendable {
    public let workflowName: String
    public let workflowVersion: String
    public let sourceMetadataURL: URL
    public let identityInputURLs: [URL]
    public let commandArguments: [String]
    public let resolvedOptions: [String: String]

    public init(
        workflowName: String,
        workflowVersion: String,
        sourceMetadataURL: URL,
        identityInputURLs: [URL],
        commandArguments: [String] = [],
        resolvedOptions: [String: String] = [:]
    ) {
        self.workflowName = workflowName
        self.workflowVersion = workflowVersion
        self.sourceMetadataURL = sourceMetadataURL
        self.identityInputURLs = identityInputURLs
        self.commandArguments = commandArguments
        self.resolvedOptions = resolvedOptions
    }
}

/// Result-owned source of truth for current sample metadata and live consumers.
@MainActor
public final class SampleMetadataPresentationContext {
    public typealias ObserverToken = UUID
    public typealias Observer = (SampleMetadataStore) -> Void

    public let finalResultURL: URL
    public let identityIndex: SampleIdentityIndex
    public private(set) var sampleMetadataStore: SampleMetadataStore
    public let importContext: SampleMetadataImportContext

    private var observers: [ObserverToken: Observer] = [:]

    public init(
        finalResultURL: URL,
        identityIndex: SampleIdentityIndex,
        sampleMetadataStore: SampleMetadataStore,
        importContext: SampleMetadataImportContext
    ) {
        self.finalResultURL = finalResultURL
        self.identityIndex = identityIndex
        self.sampleMetadataStore = sampleMetadataStore
        self.importContext = importContext
    }

    /// Registers a viewport consumer and delivers the current store immediately.
    @discardableResult
    public func observe(_ observer: @escaping Observer) -> ObserverToken {
        let token = UUID()
        observers[token] = observer
        observer(sampleMetadataStore)
        return token
    }

    public func removeObserver(_ token: ObserverToken) {
        observers.removeValue(forKey: token)
    }

    /// Publishes the complete imported store; column headers are never filtered here.
    public func updateSampleMetadataStore(_ store: SampleMetadataStore) {
        sampleMetadataStore = store
        for observer in observers.values {
            observer(store)
        }
    }
}
