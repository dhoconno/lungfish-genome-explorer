// ProvenanceEnvelopeReader.swift - Canonical-first provenance sidecar reader
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

public enum ProvenanceEnvelopeReader {
    /// Which decoder of the tolerant reader accepted a record (plan decision V6).
    public enum RecordShape: String, Sendable, Equatable, CaseIterable {
        /// A `ProvenanceEnvelope`, at any schema version.
        case envelope
        /// A bare `WorkflowRun`, the shape LGE wrote before Phase 2.4.
        case workflowRun
        /// Any other JSON object, read by the primitive adapter.
        case primitive
    }

    /// What the tolerant reader made of a record, and what it filled in itself.
    public struct Reading: Sendable, Equatable {
        public let envelope: ProvenanceEnvelope
        public let shape: RecordShape
        /// Whether the record states how its run ended. When it does not, `envelope.status` is
        /// derived from the exit status, which cannot tell a completed run from a cancelled one.
        public let statusWasRecorded: Bool
    }

    public static func load(from directory: URL) throws -> ProvenanceEnvelope? {
        let url = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        return try load(fromSidecar: url)
    }

    public static func loadCanonical(from directory: URL) throws -> ProvenanceEnvelope? {
        let url = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        return try loadCanonical(fromSidecar: url)
    }

    public static func load(fromSidecar url: URL) throws -> ProvenanceEnvelope? {
        guard let sidecar = try resolvedSidecar(url) else { return nil }
        return try shaped(sidecar.data, sourceURL: url, fallbackCreatedAt: sidecar.modificationDate).envelope
    }

    /// Reads a sidecar as `load(fromSidecar:)` does and also says which shape decoded.
    public static func read(fromSidecar url: URL) throws -> Reading? {
        guard let sidecar = try resolvedSidecar(url) else { return nil }
        return try reading(sidecar.data, sourceURL: url, fallbackCreatedAt: sidecar.modificationDate)
    }

    public static func loadCanonical(fromSidecar url: URL) throws -> ProvenanceEnvelope? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decodeCanonical(PortablePath.resolveJSON(
            try Data(contentsOf: url),
            forFileAt: url,
            encoder: ProvenanceJSON.encoder
        ))
    }

    public static func decode(_ data: Data) throws -> ProvenanceEnvelope {
        try shaped(data, sourceURL: nil, fallbackCreatedAt: nil).envelope
    }

    /// Decodes bytes as `decode(_:)` does and also says which shape decoded.
    public static func read(_ data: Data) throws -> Reading {
        try reading(data, sourceURL: nil, fallbackCreatedAt: nil)
    }

    /// Decodes canonical bytes read from `sidecarURL`, resolving the
    /// project-relative and placeholder paths LGE writes into projects.
    public static func decodeCanonical(_ data: Data, sidecarURL: URL) throws -> ProvenanceEnvelope {
        try decodeCanonical(PortablePath.resolveJSON(data, forFileAt: sidecarURL, encoder: ProvenanceJSON.encoder))
    }

    public static func decodeCanonical(_ data: Data) throws -> ProvenanceEnvelope {
        try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
    }

    private static func resolvedSidecar(_ url: URL) throws -> (data: Data, modificationDate: Date?)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = PortablePath.resolveJSON(
            try Data(contentsOf: url),
            forFileAt: url,
            encoder: ProvenanceJSON.encoder
        )
        let modificationDate = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        return (data, modificationDate)
    }

    /// The envelope, then a bare `WorkflowRun`, then the primitive adapter, which accepts any
    /// JSON object.
    private static func shaped(
        _ data: Data,
        sourceURL: URL?,
        fallbackCreatedAt: Date?
    ) throws -> (envelope: ProvenanceEnvelope, shape: RecordShape) {
        if let envelope = try? ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data) {
            return (envelope, .envelope)
        }
        if let legacy = try? ProvenanceJSON.decoder.decode(WorkflowRun.self, from: data) {
            return (legacy.recordedEnvelope(), .workflowRun)
        }
        let envelope = try PrimitiveProvenanceEnvelopeAdapter.decode(
            data,
            sourceURL: sourceURL,
            fallbackCreatedAt: fallbackCreatedAt
        )
        return (envelope, .primitive)
    }

    private static func reading(_ data: Data, sourceURL: URL?, fallbackCreatedAt: Date?) throws -> Reading {
        let (envelope, shape) = try shaped(data, sourceURL: sourceURL, fallbackCreatedAt: fallbackCreatedAt)
        let statusWasRecorded: Bool
        switch shape {
        case .envelope:
            // The envelope decoder falls back to the embedded run's status, which a run records.
            let stated = (try? ProvenanceJSON.decoder.decode(StatedStatus.self, from: data))?.status
            statusWasRecorded = stated.flatMap(RunStatus.init(rawValue:)) != nil || envelope.legacyRun != nil
        case .workflowRun:
            statusWasRecorded = true
        case .primitive:
            // The adapter reads no status key, so the status is always derived.
            statusWasRecorded = false
        }
        return Reading(envelope: envelope, shape: shape, statusWasRecorded: statusWasRecorded)
    }

    /// The top-level `status` key, read on its own so a word that names no status reads as absent.
    private struct StatedStatus: Decodable {
        let status: String?

        private enum CodingKeys: String, CodingKey {
            case status
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
        }
    }
}
