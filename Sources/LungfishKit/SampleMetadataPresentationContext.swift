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
    /// Read-group identity scoped to its owning alignment track. BAM read
    /// group IDs are only required to be unique within one BAM, so this map
    /// preserves identity when independent tracks both use values such as
    /// `RG1` for different samples.
    public let readGroupIDsByAlignmentTrackID: [String: [String]]

    public init(
        canonicalID: String,
        aliases: [String],
        alignmentTrackIDs: [String],
        readGroupIDs: [String],
        readGroupIDsByAlignmentTrackID: [String: [String]] = [:]
    ) {
        self.canonicalID = canonicalID
        self.aliases = aliases
        self.alignmentTrackIDs = alignmentTrackIDs
        self.readGroupIDs = readGroupIDs
        self.readGroupIDsByAlignmentTrackID = readGroupIDsByAlignmentTrackID
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
    private let alignmentTrackIDToSampleID: [String: String]
    private let readGroupIDs: [String: String]
    private let trackReadGroupIDs: [String: String]
    private let alignmentTrackIDsByCanonicalID: [String: Set<String>]
    private let readGroupsByCanonicalID: [String: Set<String>]
    private let explicitOneSampleFallbackCanonicalID: String?

    /// Persisted canonical sample IDs available to metadata and BAM list rows.
    public let canonicalSampleIDs: Set<String>

    /// Stable identity evidence for metadata-import provenance.  Keys are
    /// normalized identifiers (canonical IDs and explicit aliases); values
    /// are their persisted canonical sample IDs.
    public var metadataIdentifierMappings: [String: String] {
        canonicalIDs.merging(aliases) { canonical, _ in canonical }
    }

    public var readGroupMappings: [String: String] { readGroupIDs }

    /// Stable track-scoped RG evidence for provenance. The unit separator
    /// cannot collide with normalized SAM identifiers or manifest track IDs.
    public var trackReadGroupMappings: [String: String] { trackReadGroupIDs }

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
        var alignmentTrackIDToSampleID: [String: String] = [:]
        var readGroupIDs: [String: String] = [:]
        var trackReadGroupIDs: [String: String] = [:]
        var scopedReadGroupClaims: [String: Set<String>] = [:]
        var unscopedReadGroupClaims: [String: Set<String>] = [:]
        var alignmentTrackIDsByCanonicalID: [String: Set<String>] = [:]
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
                    into: &alignmentTrackIDToSampleID,
                    ambiguousError: .ambiguousAlignmentTrackID(key)
                )
                alignmentTrackIDsByCanonicalID[sample.canonicalID, default: []].insert(trackID)
            }
            for readGroupID in sample.readGroupIDs {
                let key = Self.normalized(readGroupID)
                guard !key.isEmpty else { continue }
                let isScoped = sample.readGroupIDsByAlignmentTrackID.values.contains { values in
                    values.contains { Self.normalized($0) == key }
                }
                if isScoped {
                    scopedReadGroupClaims[key, default: []].insert(sample.canonicalID)
                } else {
                    unscopedReadGroupClaims[key, default: []].insert(sample.canonicalID)
                }
                readGroupsByCanonicalID[sample.canonicalID, default: []].insert(readGroupID)
            }
            for (trackID, values) in sample.readGroupIDsByAlignmentTrackID {
                let trackKey = Self.normalized(trackID)
                guard !trackKey.isEmpty else { continue }
                for readGroupID in values {
                    let readGroupKey = Self.normalized(readGroupID)
                    guard !readGroupKey.isEmpty else { continue }
                    try Self.insert(
                        canonicalID: sample.canonicalID,
                        key: Self.trackReadGroupKey(trackID: trackKey, readGroupID: readGroupKey),
                        into: &trackReadGroupIDs,
                        ambiguousError: .ambiguousReadGroupID(readGroupKey)
                    )
                    readGroupsByCanonicalID[sample.canonicalID, default: []].insert(readGroupID)
                }
            }
        }

        for key in Set(scopedReadGroupClaims.keys).union(unscopedReadGroupClaims.keys) {
            let scoped = scopedReadGroupClaims[key] ?? []
            let unscoped = unscopedReadGroupClaims[key] ?? []
            let allClaims = scoped.union(unscoped)
            if unscoped.count > 1 || (!unscoped.isEmpty && allClaims.count > 1) {
                throw SampleIdentityIndexError.ambiguousReadGroupID(key)
            }
            // Preserve the convenient bare-RG lookup only when it is globally
            // unambiguous. Reused IDs remain resolvable through track scope.
            if allClaims.count == 1, let canonicalID = allClaims.first {
                readGroupIDs[key] = canonicalID
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
        self.alignmentTrackIDToSampleID = alignmentTrackIDToSampleID
        self.readGroupIDs = readGroupIDs
        self.trackReadGroupIDs = trackReadGroupIDs
        self.alignmentTrackIDsByCanonicalID = alignmentTrackIDsByCanonicalID
        self.readGroupsByCanonicalID = readGroupsByCanonicalID
        self.canonicalSampleIDs = Set(canonicalIDs.values)
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
        return alignmentTrackIDToSampleID[Self.normalized(trackID)]
    }

    /// Resolves a BAM read group; an explicit one-sample fallback is used only for a missing ID.
    public func canonicalSampleID(forReadGroupID readGroupID: String?) -> String? {
        guard let readGroupID else { return explicitOneSampleFallbackCanonicalID }
        return readGroupIDs[Self.normalized(readGroupID)]
    }

    /// Resolves a BAM read group within its owning track. This is the
    /// authoritative lookup for multi-track bundles because RG IDs may be
    /// reused by unrelated BAM files.
    public func canonicalSampleID(
        forReadGroupID readGroupID: String?,
        alignmentTrackID: String?
    ) -> String? {
        guard let readGroupID else { return explicitOneSampleFallbackCanonicalID }
        guard let alignmentTrackID else { return canonicalSampleID(forReadGroupID: readGroupID) }
        return trackReadGroupIDs[Self.trackReadGroupKey(
            trackID: Self.normalized(alignmentTrackID),
            readGroupID: Self.normalized(readGroupID)
        )]
    }

    /// All read groups belonging to a selected canonical sample.
    public func readGroupIDs(forCanonicalSampleID canonicalID: String) -> Set<String> {
        readGroupsByCanonicalID[canonicalIDs[Self.normalized(canonicalID)] ?? canonicalID] ?? []
    }

    /// All alignment track IDs belonging to a selected canonical sample.
    public func alignmentTrackIDs(forCanonicalSampleID canonicalID: String) -> Set<String> {
        alignmentTrackIDsByCanonicalID[canonicalIDs[Self.normalized(canonicalID)] ?? canonicalID] ?? []
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func trackReadGroupKey(trackID: String, readGroupID: String) -> String {
        "\(trackID)\u{1F}\(readGroupID)"
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
    public let resultID: String
    public let provenanceID: String
    public let workflowName: String
    public let workflowVersion: String

    public init(
        resultID: String,
        provenanceID: String,
        workflowName: String,
        workflowVersion: String
    ) {
        self.resultID = resultID
        self.provenanceID = provenanceID
        self.workflowName = workflowName
        self.workflowVersion = workflowVersion
    }
}

/// A result viewport that accepts the complete metadata store owned by its
/// result's presentation context. Leaf modules conform directly so the App
/// composition root never needs classifier-specific import callbacks.
@MainActor
public protocol SampleMetadataPresentationConsumer: AnyObject {
    func applySampleMetadata(_ store: SampleMetadataStore?)
}

/// Result-owned source of truth for current sample metadata and live consumers.
@MainActor
public final class SampleMetadataPresentationContext {
    public typealias ObserverToken = UUID
    public typealias Observer = (SampleMetadataStore?) -> Void

    public let finalResultURL: URL
    public let identityIndex: SampleIdentityIndex
    public let identityInputURLs: [URL]
    public private(set) var sampleMetadataStore: SampleMetadataStore?
    public let importContext: SampleMetadataImportContext

    private var observers: [ObserverToken: Observer] = [:]
    private var observerTokensInRegistrationOrder: [ObserverToken] = []
    private var observerGeneration = 0
    private var isDeliveringObservers = false

    public init(
        finalResultURL: URL,
        identityIndex: SampleIdentityIndex,
        identityInputURLs: [URL] = [],
        sampleMetadataStore: SampleMetadataStore? = nil,
        importContext: SampleMetadataImportContext
    ) {
        self.finalResultURL = finalResultURL
        self.identityIndex = identityIndex
        self.identityInputURLs = identityInputURLs.map(\.standardizedFileURL)
        self.sampleMetadataStore = sampleMetadataStore
        self.importContext = importContext
    }

    /// Registers a viewport consumer and delivers the current store immediately.
    /// Consumers must call ``removeObserver(_:)`` when they no longer need updates.
    @discardableResult
    public func observe(_ observer: @escaping Observer) -> ObserverToken {
        let token = UUID()
        observers[token] = observer
        observerTokensInRegistrationOrder.append(token)
        observer(sampleMetadataStore)
        return token
    }

    /// Registers a viewport consumer and immediately applies the current store.
    @discardableResult
    public func observe(_ consumer: any SampleMetadataPresentationConsumer) -> ObserverToken {
        observe { [weak consumer] store in
            consumer?.applySampleMetadata(store)
        }
    }

    public func removeObserver(_ token: ObserverToken) {
        observers.removeValue(forKey: token)
        observerTokensInRegistrationOrder.removeAll { $0 == token }
    }

    /// Publishes the complete imported store; column headers are never filtered here.
    public func updateSampleMetadataStore(_ store: SampleMetadataStore) {
        sampleMetadataStore = store
        notifyObservers()
    }

    /// Clears imported metadata after its owning result removes it.
    public func clearSampleMetadataStore() {
        sampleMetadataStore = nil
        notifyObservers()
    }

    private func notifyObservers() {
        observerGeneration &+= 1
        guard !isDeliveringObservers else { return }

        isDeliveringObservers = true
        defer { isDeliveringObservers = false }

        while true {
            let generation = observerGeneration
            let store = sampleMetadataStore
            let observerTokenSnapshot = observerTokensInRegistrationOrder

            for token in observerTokenSnapshot {
                guard observerGeneration == generation else { break }
                guard let observer = observers[token] else { continue }
                observer(store)
            }

            guard observerGeneration == generation else { continue }
            return
        }
    }
}
