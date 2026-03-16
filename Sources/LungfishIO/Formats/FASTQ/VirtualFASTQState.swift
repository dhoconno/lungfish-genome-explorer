// VirtualFASTQState.swift - Lifecycle state tracking for virtual FASTQ derivatives
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Materialization State

/// Lifecycle state of a virtual FASTQ derivative bundle.
///
/// Tracks whether a derivative has been materialized into a full FASTQ on disk.
/// Value type — safe to pass across isolation boundaries.
///
/// When persisted in a manifest and the app relaunches, a stale `.materializing`
/// state (from a crashed or interrupted session) is treated as `.virtual` by
/// `FASTQDerivedBundleManifest.resolvedState`.
public enum MaterializationState: Codable, Sendable, Equatable {
    /// Derivative is pointer-based. The bundle contains only metadata
    /// (read ID list, trim positions, orient map) referencing the root FASTQ.
    case virtual

    /// Materialization is in progress. Stores a stable identifier for the
    /// in-flight task so the UI can bind to progress and cancel.
    case materializing(taskID: UUID)

    /// Derivative has been fully written to disk as a standalone FASTQ.
    /// Stores the materialized file's SHA-256 for integrity verification.
    case materialized(checksum: String)
}

// MARK: - Virtual FASTQ Descriptor

/// Immutable snapshot of a virtual FASTQ's identity and lineage.
///
/// Used as the "job specification" for materialization — captures everything
/// needed to reconstruct the full FASTQ from the root without holding file
/// handles or task state.
public struct VirtualFASTQDescriptor: Sendable, Equatable, Identifiable {
    /// Unique identifier from the derived manifest.
    public let id: UUID

    /// URL to the `.lungfishfastq` bundle on disk.
    public let bundleURL: URL

    /// Relative path from this bundle to the root (physical FASTQ payload) bundle.
    public let rootBundleRelativePath: String

    /// FASTQ filename inside the root bundle.
    public let rootFASTQFilename: String

    /// What this derivative stores on disk (read ID list, trim positions, etc.).
    public let payload: FASTQDerivativePayload

    /// Sequence of operations from root to this dataset.
    public let lineage: [FASTQDerivativeOperation]

    /// Pairing mode inherited from the root.
    public let pairingMode: IngestionMetadata.PairingMode?

    /// The sequence format of the root payload file.
    public let sequenceFormat: SequenceFormat?

    /// Creates a descriptor from an existing derived bundle manifest.
    public init(bundleURL: URL, manifest: FASTQDerivedBundleManifest) {
        self.id = manifest.id
        self.bundleURL = bundleURL
        self.rootBundleRelativePath = manifest.rootBundleRelativePath
        self.rootFASTQFilename = manifest.rootFASTQFilename
        self.payload = manifest.payload
        self.lineage = manifest.lineage
        self.pairingMode = manifest.pairingMode
        self.sequenceFormat = manifest.sequenceFormat
    }

    /// Creates a descriptor with explicit values.
    public init(
        id: UUID,
        bundleURL: URL,
        rootBundleRelativePath: String,
        rootFASTQFilename: String,
        payload: FASTQDerivativePayload,
        lineage: [FASTQDerivativeOperation],
        pairingMode: IngestionMetadata.PairingMode?,
        sequenceFormat: SequenceFormat?
    ) {
        self.id = id
        self.bundleURL = bundleURL
        self.rootBundleRelativePath = rootBundleRelativePath
        self.rootFASTQFilename = rootFASTQFilename
        self.payload = payload
        self.lineage = lineage
        self.pairingMode = pairingMode
        self.sequenceFormat = sequenceFormat
    }

    /// Resolves the root bundle URL relative to this bundle's location.
    public var resolvedRootBundleURL: URL {
        bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(rootBundleRelativePath)
            .standardizedFileURL
    }

    /// Resolves the root FASTQ file URL.
    public var resolvedRootFASTQURL: URL {
        resolvedRootBundleURL.appendingPathComponent(rootFASTQFilename)
    }
}
