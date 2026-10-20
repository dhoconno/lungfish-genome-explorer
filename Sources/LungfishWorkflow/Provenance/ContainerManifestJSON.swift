// ContainerManifestJSON.swift - The encoder of the container manifest that a Nextflow export writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A value that ``ContainerManifestJSON`` encodes. Only the entry type of the container manifest adopts it, and
/// `ProvenanceEnvelope` does not, so encoding an envelope with the manifest encoder does not compile (the shape of
/// item 2 of `BIO-13.12.md`, for row 11 of its F2).
protocol ContainerManifestPayload: Encodable {}

/// Encodes `containers/manifest.json`, a list of the images a run used, which is a manifest and not an envelope.
///
/// It sets the four options of `ProvenanceJSON` (ISO 8601 dates and `[.prettyPrinted, .sortedKeys,
/// .withoutEscapingSlashes]`) in its own code, so the bytes equal what the manifest had when it used the shared
/// provenance encoder, and it exposes no `JSONEncoder`. The writer ratchet counts none of its encodes, because it
/// never names that encoder.
enum ContainerManifestJSON {
    static func encode<Entry: ContainerManifestPayload>(_ entries: [Entry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(entries)
    }
}
