// ProvenanceWriter+Package.swift - Record bytes that a caller publishes with a write of its own
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

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

    /// The bytes of the record `data`, read at `sourceURL`, rewritten for `destinationURL`, which its caller publishes.
    ///
    /// It resolves the project-relative and placeholder paths of `data` against `sourceURL`, decodes the envelope,
    /// applies `remap`, and encodes and sanitizes the result for `destinationURL` as a sidecar write does. When the
    /// bytes change it runs the rule of a write with no key. The new bytes carry no signature, so `signatures` is
    /// emptied, a pair beside `sourceURL` that verifies against the bytes in place is named in `priorSignatures`, and
    /// the pair is removed before the bytes return, whether it verified or not. A publish that then fails leaves the
    /// old record unsigned, and no pair that fails is ever left beside the new one.
    public static func rewrite(
        _ data: Data,
        at sourceURL: URL,
        for destinationURL: URL,
        remap: (ProvenanceEnvelope) throws -> ProvenanceEnvelope
    ) throws -> Data {
        var envelope = try remap(ProvenanceEnvelopeReader.decodeCanonical(data, sidecarURL: sourceURL))
        let unchanged = try recordBytes(envelope, sanitizedFor: destinationURL)
        if unchanged == data { return data }
        let hasPair = [
            ProvenanceSigningConfiguration.signatureURL(for: sourceURL),
            ProvenanceSigningConfiguration.publicKeyURL(for: sourceURL),
        ].contains { FileManager.default.fileExists(atPath: $0.path) }
        if envelope.signatures.isEmpty, !hasPair { return unchanged }
        let writer = ProvenanceWriter(signingProvider: nil)
        envelope.signatures = []
        envelope = try writer.envelopeKeepingSignatureHistory(envelope, replacing: sourceURL)
        let bytes = try recordBytes(envelope, sanitizedFor: destinationURL)
        if hasPair {
            try DurableReplace.transaction { try writer.removeSigningArtifacts(for: sourceURL) }
        }
        return bytes
    }
}
