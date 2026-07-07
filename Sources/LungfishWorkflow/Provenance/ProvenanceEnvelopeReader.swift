// ProvenanceEnvelopeReader.swift - Canonical-first provenance sidecar reader
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

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
        let data = try Data(contentsOf: url)
        let modificationDate = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        return try decode(data, sourceURL: url, fallbackCreatedAt: modificationDate)
    }

    public static func loadCanonical(fromSidecar url: URL) throws -> ProvenanceEnvelope? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decodeCanonical(try Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> ProvenanceEnvelope {
        try decode(data, sourceURL: nil, fallbackCreatedAt: nil)
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
