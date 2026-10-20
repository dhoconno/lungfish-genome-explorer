// ProvenanceWriter+Export.swift - The record bytes of an export, which keep the signature references of their source
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ProvenanceWriter {
    /// The bytes of the record an export writes as `provenance.json`.
    ///
    /// They are the writer's encode of `envelope` with no portable-path rewrite, the bytes `package` returns, except
    /// that an envelope which names signatures is encoded as it stands. The export of one signed record keeps the
    /// references its source holds (`ProvenanceExporter.mergeProvenanceChain` returns that record unchanged), and the
    /// export copies the signature pair of each source sidecar into its provenance folder, so those references name
    /// signatures that were written. A caller that publishes a record it built itself calls `package` instead, which
    /// refuses an envelope that names a signature.
    static func exportedRecordBytes(_ envelope: ProvenanceEnvelope) throws -> Data {
        try recordBytes(envelope, sanitizedFor: nil)
    }
}
