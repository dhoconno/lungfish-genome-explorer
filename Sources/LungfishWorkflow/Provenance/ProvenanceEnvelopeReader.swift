// ProvenanceEnvelopeReader.swift - Canonical-first provenance sidecar reader
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum ProvenanceEnvelopeReader {
    public static func load(from directory: URL) throws -> ProvenanceEnvelope? {
        let url = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> ProvenanceEnvelope {
        do {
            return try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
        } catch {
            let legacy = try ProvenanceJSON.decoder.decode(WorkflowRun.self, from: data)
            return legacy.canonicalEnvelope()
        }
    }
}
