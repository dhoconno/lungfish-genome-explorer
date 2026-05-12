// ProvenanceEnvelopeReader.swift - Canonical-first provenance sidecar reader
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum ProvenanceEnvelopeReader {
    public static func load(from directory: URL) throws -> ProvenanceEnvelope? {
        let url = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        return try load(fromSidecar: url)
    }

    public static func load(fromSidecar url: URL) throws -> ProvenanceEnvelope? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let modificationDate = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        return try decode(data, sourceURL: url, fallbackCreatedAt: modificationDate)
    }

    public static func decode(_ data: Data) throws -> ProvenanceEnvelope {
        try decode(data, sourceURL: nil, fallbackCreatedAt: nil)
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
