// ProvenanceWriter+Package.swift - Record bytes that a caller publishes with a write of its own
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Why the writer refused to package an envelope.
public enum ProvenancePackageError: Error, Equatable, LocalizedError {
    /// The envelope names a signature, and the bytes the writer returns carry none (BIO 4).
    case envelopeCarriesSignatures(count: Int)

    public var errorDescription: String? {
        switch self {
        case .envelopeCarriesSignatures(let count):
            return "The provenance record names \(count) signature(s), and its bytes would carry none."
        }
    }
}

extension ProvenanceWriter {
    /// The bytes of a record that its caller publishes with a create-once write of its own, such as the records of a
    /// cleanup that moves project data to the Trash.
    ///
    /// They are the writer's encode of `envelope` with no portable-path rewrite and no signature, so a reader that
    /// compares exact paths and digests reads them as before. It throws when `envelope.signatures` is not empty, so no
    /// record names a signature that was never written.
    public static func package(_ envelope: ProvenanceEnvelope) throws -> Data {
        guard envelope.signatures.isEmpty else {
            throw ProvenancePackageError.envelopeCarriesSignatures(count: envelope.signatures.count)
        }
        return try recordBytes(envelope, sanitizedFor: nil)
    }
}
