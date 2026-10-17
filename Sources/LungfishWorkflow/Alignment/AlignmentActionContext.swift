// AlignmentActionContext.swift - Immutable identity for full-viewer alignment actions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Cheap, stat-based identity for a file used to decide whether a cached
/// SHA-256 digest is still trustworthy, without rereading the file.
package struct AlignmentEvidenceFileIdentity: Sendable, Equatable, Hashable {
    package let path: String
    package let byteCount: UInt64
    package let modificationDate: Double
    package let inode: UInt64
    package let device: Int32

    package init(path: String, byteCount: UInt64, modificationDate: Double, inode: UInt64, device: Int32) {
        self.path = path
        self.byteCount = byteCount
        self.modificationDate = modificationDate
        self.inode = inode
        self.device = device
    }

    /// Reads the cheap identity fields for `url` with a single `stat(2)` call.
    package static func current(of url: URL) throws -> AlignmentEvidenceFileIdentity {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw AlignmentActionContext.EvidenceError.missingEvidence(url)
        }
        let modTime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return AlignmentEvidenceFileIdentity(
            path: url.standardizedFileURL.path,
            byteCount: UInt64(info.st_size),
            modificationDate: modTime,
            inode: UInt64(info.st_ino),
            device: info.st_dev
        )
    }
}

/// Caches SHA-256 digests keyed by cheap stat identity so repeated scientific
/// actions on the same, unchanged alignment evidence never rehash. A hit
/// requires path, size, mtime, inode and device to all match the cached
/// entry; any difference forces a fresh digest.
package actor AlignmentEvidenceDigestCache {
    package static let shared = AlignmentEvidenceDigestCache()

    package init() {}

    private var digests: [AlignmentEvidenceFileIdentity: String] = [:]

    /// Returns the cached digest for `identity` if present, computing and
    /// caching a fresh one with `hash` otherwise. `hash` runs off this actor's
    /// isolation only in the sense that callers should already be off the
    /// main actor; the cache lookup itself is cheap (dictionary access).
    package func digest(
        for identity: AlignmentEvidenceFileIdentity,
        computingWith hash: () throws -> String
    ) rethrows -> String {
        if let cached = digests[identity] {
            return cached
        }
        let computed = try hash()
        digests[identity] = computed
        return computed
    }

    /// Test/diagnostic seam: number of cached entries.
    package func cachedEntryCount() -> Int {
        digests.count
    }

    /// Test seam: clears the cache so tests do not leak state across runs.
    package func removeAll() {
        digests.removeAll()
    }
}

/// Stable, user-independent identity of the alignment evidence currently shown
/// by the full viewer.
package struct AlignmentEvidenceIdentity: Sendable, Equatable, Hashable {
    package let workflow: String
    package let resultID: String
    package let sampleID: String
    package let evidenceID: String

    package init(workflow: String, resultID: String, sampleID: String, evidenceID: String) {
        self.workflow = workflow
        self.resultID = resultID
        self.sampleID = sampleID
        self.evidenceID = evidenceID
    }
}

/// A final evidence file and the provenance fingerprint captured for it.
package struct AlignmentEvidenceFileSnapshot: Sendable, Equatable {
    package let url: URL
    package let byteCount: UInt64
    package let sha256: String

    package init(url: URL, byteCount: UInt64, sha256: String) {
        self.url = url
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// Where a scientific action may persist a new result.
package enum AlignmentOutputCapability: Sendable, Equatable {
    case projectDerivedRoot(URL)
    case userSelectedDestination
}

/// The original reads available for read-level actions.
package enum AlignmentSourceReadResolution: Sendable, Equatable {
    case sourceFASTQs([URL])
    case bamFallback
}

/// Immutable, App-owned input shared by every action exposed for displayed
/// alignment evidence.  It intentionally describes final evidence directly;
/// it never creates a wrapper bundle or mutates the evidence being viewed.
package struct AlignmentActionContext: Sendable, Equatable {
    package enum ValidationError: Error, Sendable, Equatable {
        case emptyIdentityField(String)
        case emptyContig
        case invalidContigLength(Int)
        case emptyPresentationLabel
        case unsupportedAlignmentFormat(String)
        case explicitIndexRequired(alignment: String, index: String)
        case snapshotPathMismatch(expected: URL, actual: URL)
        case missingDecodingReferenceSnapshot(URL)
        case unexpectedDecodingReferenceSnapshot(URL)
    }

    package enum EvidenceError: Error, Sendable, Equatable {
        case missingEvidence(URL)
        case staleEvidence(URL)
    }

    package let identity: AlignmentEvidenceIdentity
    package let alignmentURL: URL
    package let indexURL: URL
    package let decodingReferenceURL: URL?
    package let contig: String
    package let contigLength: Int
    package let alignmentSnapshot: AlignmentEvidenceFileSnapshot
    package let indexSnapshot: AlignmentEvidenceFileSnapshot
    package let decodingReferenceSnapshot: AlignmentEvidenceFileSnapshot?
    package let filters: AlignmentConsensusFilters
    package let outputCapability: AlignmentOutputCapability
    package let sourceReads: AlignmentSourceReadResolution
    package let presentationLabel: String

    package init(
        identity: AlignmentEvidenceIdentity,
        alignmentURL: URL,
        indexURL: URL,
        decodingReferenceURL: URL?,
        contig: String,
        contigLength: Int,
        alignmentSnapshot: AlignmentEvidenceFileSnapshot,
        indexSnapshot: AlignmentEvidenceFileSnapshot,
        decodingReferenceSnapshot: AlignmentEvidenceFileSnapshot?,
        filters: AlignmentConsensusFilters,
        outputCapability: AlignmentOutputCapability,
        sourceReads: AlignmentSourceReadResolution,
        presentationLabel: String
    ) throws {
        for (name, value) in [
            ("workflow", identity.workflow),
            ("resultID", identity.resultID),
            ("sampleID", identity.sampleID),
            ("evidenceID", identity.evidenceID)
        ] where Self.isBlank(value) {
            throw ValidationError.emptyIdentityField(name)
        }
        guard !Self.isBlank(contig) else { throw ValidationError.emptyContig }
        guard contigLength > 0 else { throw ValidationError.invalidContigLength(contigLength) }
        guard !Self.isBlank(presentationLabel) else { throw ValidationError.emptyPresentationLabel }

        let normalizedAlignmentURL = alignmentURL.standardizedFileURL
        let normalizedIndexURL = indexURL.standardizedFileURL
        let normalizedReferenceURL = decodingReferenceURL?.standardizedFileURL
        guard alignmentSnapshot.url.standardizedFileURL == normalizedAlignmentURL else {
            throw ValidationError.snapshotPathMismatch(expected: normalizedAlignmentURL, actual: alignmentSnapshot.url)
        }
        guard indexSnapshot.url.standardizedFileURL == normalizedIndexURL else {
            throw ValidationError.snapshotPathMismatch(expected: normalizedIndexURL, actual: indexSnapshot.url)
        }
        if let normalizedReferenceURL, decodingReferenceSnapshot == nil {
            throw ValidationError.missingDecodingReferenceSnapshot(normalizedReferenceURL)
        }
        if let decodingReferenceSnapshot {
            guard let normalizedReferenceURL else {
                throw ValidationError.unexpectedDecodingReferenceSnapshot(decodingReferenceSnapshot.url)
            }
            guard decodingReferenceSnapshot.url.standardizedFileURL == normalizedReferenceURL else {
                throw ValidationError.snapshotPathMismatch(expected: normalizedReferenceURL, actual: decodingReferenceSnapshot.url)
            }
        }

        let alignmentExtension = normalizedAlignmentURL.pathExtension.lowercased()
        let indexExtension = normalizedIndexURL.pathExtension.lowercased()
        switch alignmentExtension {
        case "bam":
            guard ["bai", "csi"].contains(indexExtension) else {
                throw ValidationError.explicitIndexRequired(alignment: alignmentExtension, index: indexExtension)
            }
        case "cram":
            guard ["crai", "csi"].contains(indexExtension) else {
                throw ValidationError.explicitIndexRequired(alignment: alignmentExtension, index: indexExtension)
            }
        default:
            throw ValidationError.unsupportedAlignmentFormat(alignmentExtension)
        }

        self.identity = identity
        self.alignmentURL = normalizedAlignmentURL
        self.indexURL = normalizedIndexURL
        self.decodingReferenceURL = normalizedReferenceURL
        self.contig = contig
        self.contigLength = contigLength
        self.alignmentSnapshot = .init(
            url: normalizedAlignmentURL,
            byteCount: alignmentSnapshot.byteCount,
            sha256: alignmentSnapshot.sha256
        )
        self.indexSnapshot = .init(
            url: normalizedIndexURL,
            byteCount: indexSnapshot.byteCount,
            sha256: indexSnapshot.sha256
        )
        if let decodingReferenceSnapshot, let normalizedReferenceURL {
            self.decodingReferenceSnapshot = .init(
                url: normalizedReferenceURL,
                byteCount: decodingReferenceSnapshot.byteCount,
                sha256: decodingReferenceSnapshot.sha256
            )
        } else {
            self.decodingReferenceSnapshot = nil
        }
        self.filters = filters
        self.outputCapability = outputCapability
        self.sourceReads = sourceReads
        self.presentationLabel = presentationLabel
    }

    /// Clipboard actions only present in-memory derivatives and therefore never
    /// need a project output root or destination chooser.
    package var allowsClipboardActions: Bool { true }

    /// Re-check every final evidence payload immediately before an action is
    /// launched or published. Runs entirely off the main actor: this is safe
    /// to call from any isolation domain because it touches only `Sendable`
    /// state and the file system. The shared provenance hasher keeps a real
    /// rehash byte-for-byte compatible with output provenance records, but a
    /// rehash only happens when the file's cheap stat identity (size, mtime,
    /// inode, device) no longer matches what was cached for that digest, or
    /// nothing has ever hashed this identity before.
    package nonisolated func validateCurrentSnapshots(
        digestCache: AlignmentEvidenceDigestCache = .shared
    ) async throws {
        try await validateSnapshot(alignmentSnapshot, at: alignmentURL, digestCache: digestCache)
        try await validateSnapshot(indexSnapshot, at: indexURL, digestCache: digestCache)
        if let decodingReferenceSnapshot, let decodingReferenceURL {
            try await validateSnapshot(decodingReferenceSnapshot, at: decodingReferenceURL, digestCache: digestCache)
        }
    }

    package func replacingFilters(_ filters: AlignmentConsensusFilters) throws -> AlignmentActionContext {
        try AlignmentActionContext(
            identity: identity,
            alignmentURL: alignmentURL,
            indexURL: indexURL,
            decodingReferenceURL: decodingReferenceURL,
            contig: contig,
            contigLength: contigLength,
            alignmentSnapshot: alignmentSnapshot,
            indexSnapshot: indexSnapshot,
            decodingReferenceSnapshot: decodingReferenceSnapshot,
            filters: filters,
            outputCapability: outputCapability,
            sourceReads: sourceReads,
            presentationLabel: presentationLabel
        )
    }

    private nonisolated func validateSnapshot(
        _ expected: AlignmentEvidenceFileSnapshot,
        at url: URL,
        digestCache: AlignmentEvidenceDigestCache
    ) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EvidenceError.missingEvidence(url)
        }
        let identity = try AlignmentEvidenceFileIdentity.current(of: url)
        // The cache's own dictionary lookup is actor-isolated (cheap), but the
        // fallback hash on a miss must not run on whatever isolation domain
        // called us (which may be the main actor); hop to a detached task so
        // a cache miss never blocks the caller's executor for the hash.
        let sha256 = try await Task.detached(priority: .userInitiated) {
            try await digestCache.digest(for: identity) {
                try ProvenanceFileHasher.sha256(of: url)
            }
        }.value
        let current = AlignmentEvidenceFileSnapshot(url: url, byteCount: identity.byteCount, sha256: sha256)
        guard current == expected else { throw EvidenceError.staleEvidence(url) }
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension AlignmentActionContext.EvidenceError: LocalizedError {
    /// The words of a refusal to act on evidence that is not what the view was built from (Phase 2.11
    /// lane A69, carry-in row SW11, ruled in the UX review of A69). The Operations row and the alert show
    /// this text, and without it they showed the system's "The operation couldn't be completed". The check
    /// runs before an action is launched and again before its result is published, so the words say that
    /// nothing was saved and never that nothing was run. They name the file and not its path.
    package var errorDescription: String? {
        switch self {
        case .missingEvidence(let url):
            return "The file \(url.lastPathComponent) is missing, so nothing was saved. Restore the file and try again."
        case .staleEvidence(let url):
            return "The file \(url.lastPathComponent) changed after the alignment was opened, so nothing was saved. Reopen the alignment and try again."
        }
    }
}
