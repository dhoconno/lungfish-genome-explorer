// ProvenanceWriter+Export.swift - The record bytes of an export, which keep the signature references of their source
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ProvenanceWriter {
    /// The bytes of the record an export writes as `provenance.json`, the writer's encode of `envelope` with no
    /// portable-path rewrite. For an envelope that names no signature they are the bytes `package` returns. The export
    /// of one record writes it as its source holds it (`ProvenanceExporter.mergeProvenanceChain`), so its `signatures`
    /// describe the source sidecar, whose pair the export copies into its `provenance` folder. They do not sign
    /// `provenance.json`, which the exporter signs on its own when a key is set, and the verifier never matches them to
    /// that pair. A caller that publishes a record it built itself calls `package`, which refuses an envelope that
    /// names a signature.
    static func exportedRecordBytes(_ envelope: ProvenanceEnvelope) throws -> Data {
        try recordBytes(envelope, sanitizedFor: nil)
    }
}
