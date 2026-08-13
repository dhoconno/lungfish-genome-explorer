// AlignmentActionContext.swift - Immutable identity for full-viewer alignment actions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

/// Stable, user-independent identity of the alignment evidence currently shown
/// by the full viewer.
struct AlignmentEvidenceIdentity: Sendable, Equatable, Hashable {
    let workflow: String
    let resultID: String
    let sampleID: String
    let evidenceID: String

    init(workflow: String, resultID: String, sampleID: String, evidenceID: String) {
        self.workflow = workflow
        self.resultID = resultID
        self.sampleID = sampleID
        self.evidenceID = evidenceID
    }
}

/// A final evidence file and the provenance fingerprint captured for it.
struct AlignmentEvidenceFileSnapshot: Sendable, Equatable {
    let url: URL
    let byteCount: UInt64
    let sha256: String

    init(url: URL, byteCount: UInt64, sha256: String) {
        self.url = url
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// Where a scientific action may persist a new result.
enum AlignmentOutputCapability: Sendable, Equatable {
    case projectDerivedRoot(URL)
    case userSelectedDestination
}

/// The original reads available for read-level actions.
enum AlignmentSourceReadResolution: Sendable, Equatable {
    case sourceFASTQs([URL])
    case bamFallback
}

/// Immutable, App-owned input shared by every action exposed for displayed
/// alignment evidence.  It intentionally describes final evidence directly;
/// it never creates a wrapper bundle or mutates the evidence being viewed.
struct AlignmentActionContext: Sendable, Equatable {
    enum ValidationError: Error, Sendable, Equatable {
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

    enum EvidenceError: Error, Sendable, Equatable {
        case missingEvidence(URL)
        case staleEvidence(URL)
    }

    let identity: AlignmentEvidenceIdentity
    let alignmentURL: URL
    let indexURL: URL
    let decodingReferenceURL: URL?
    let contig: String
    let contigLength: Int
    let alignmentSnapshot: AlignmentEvidenceFileSnapshot
    let indexSnapshot: AlignmentEvidenceFileSnapshot
    let decodingReferenceSnapshot: AlignmentEvidenceFileSnapshot?
    let filters: AlignmentConsensusFilters
    let outputCapability: AlignmentOutputCapability
    let sourceReads: AlignmentSourceReadResolution
    let presentationLabel: String

    init(
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
    var allowsClipboardActions: Bool { true }

    /// Re-check every final evidence payload immediately before an action is
    /// launched or published.  The shared provenance hasher keeps this check
    /// byte-for-byte compatible with output provenance records.
    func validateCurrentSnapshots() throws {
        try validateSnapshot(alignmentSnapshot, at: alignmentURL)
        try validateSnapshot(indexSnapshot, at: indexURL)
        if let decodingReferenceSnapshot, let decodingReferenceURL {
            try validateSnapshot(decodingReferenceSnapshot, at: decodingReferenceURL)
        }
    }

    func replacingFilters(_ filters: AlignmentConsensusFilters) throws -> AlignmentActionContext {
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

    private func validateSnapshot(_ expected: AlignmentEvidenceFileSnapshot, at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EvidenceError.missingEvidence(url)
        }
        let current = AlignmentEvidenceFileSnapshot(
            url: url,
            byteCount: try ProvenanceFileHasher.fileSize(of: url),
            sha256: try ProvenanceFileHasher.sha256(of: url)
        )
        guard current == expected else { throw EvidenceError.staleEvidence(url) }
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
