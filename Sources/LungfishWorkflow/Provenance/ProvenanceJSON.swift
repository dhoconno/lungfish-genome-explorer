// ProvenanceJSON.swift - Shared JSON encoder and decoder for provenance files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ProvenanceJSON

public enum ProvenanceJSON {
    /// Pretty, sorted, whole-second ISO 8601 dates and slashes written as typed, so the raw bytes
    /// show `@/Analyses/run` and never `@\/Analyses\/run`. A signature covers the parsed record
    /// reserialized (`ProvenanceSigningPayload`), so the escaping of the bytes never reaches it.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
