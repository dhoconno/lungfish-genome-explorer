// ProvenanceEnvelopeReader.swift - Canonical-first provenance sidecar reader
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

public enum ProvenanceEnvelopeReader {
    public static func load(from directory: URL) throws -> ProvenanceEnvelope? {
        let url = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        return try load(fromSidecar: url)
    }

    public static func loadCanonical(from directory: URL) throws -> ProvenanceEnvelope? {
        let url = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        return try loadCanonical(fromSidecar: url)
    }

    public static func load(fromSidecar url: URL) throws -> ProvenanceEnvelope? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = PortablePath.resolveJSON(
            try Data(contentsOf: url),
            forFileAt: url,
            encoder: ProvenanceJSON.encoder
        )
        let modificationDate = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        return try decode(data, sourceURL: url, fallbackCreatedAt: modificationDate)
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
        try decode(data, sourceURL: nil, fallbackCreatedAt: nil)
    }

    /// Decodes canonical bytes read from `sidecarURL`, resolving the
    /// project-relative and placeholder paths LGE writes into projects.
    public static func decodeCanonical(_ data: Data, sidecarURL: URL) throws -> ProvenanceEnvelope {
        try decodeCanonical(PortablePath.resolveJSON(data, forFileAt: sidecarURL, encoder: ProvenanceJSON.encoder))
    }

    public static func decodeCanonical(_ data: Data) throws -> ProvenanceEnvelope {
        try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
    }

    private static func decode(_ data: Data, sourceURL: URL?, fallbackCreatedAt: Date?) throws -> ProvenanceEnvelope {
        do {
            return try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
        } catch {
            do {
                let legacy = try ProvenanceJSON.decoder.decode(WorkflowRun.self, from: data)
                return legacy.canonicalEnvelope()
            } catch {
                return try PrimitiveProvenanceEnvelopeAdapter.decode(
                    data,
                    sourceURL: sourceURL,
                    fallbackCreatedAt: fallbackCreatedAt
                )
            }
        }
    }
}
