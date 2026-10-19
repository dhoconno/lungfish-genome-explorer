// ProvenanceWriter+Document.swift - A provenance document that is not an envelope, published and signed as a record is
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension ProvenanceWriter {
    /// Publishes `data`, a provenance document that is not an envelope, at `documentURL`, and signs it when this
    /// writer holds a provider (Phase 2.12 lane 12.22, decision S5).
    ///
    /// The log that Add Annotation appends to, `annotations/manual-annotation-provenance.json`, is such a document.
    /// It keeps its own schema, so the caller encodes it and this writer only publishes and signs the bytes.
    ///
    /// - The bytes are published through ``DurableReplace`` as a record's are, so the name holds a complete old or
    ///   new file at every step, and the write joins the transaction of a caller that runs one.
    /// - With a provider, `<document>.signature.json` and `<document>.pub` sit beside the document and cover the
    ///   file as it is, every entry. A file that does not decode as an envelope is signed over its raw bytes
    ///   (`ProvenanceSigningPayload.data(forProvenanceData:)`). The local provider's pair is verified before the
    ///   call returns, as a record's is.
    /// - With none, the pair of an earlier write is removed, so a document written without a key reads as
    ///   unsigned and never as tampered. This is what a keyless write into a signed record does for an envelope.
    @discardableResult
    func writeDocument(_ data: Data, to documentURL: URL) throws -> URL {
        try DurableReplace.transaction { try writeDocumentSidecar(data, to: documentURL) }
    }

    private func writeDocumentSidecar(_ data: Data, to documentURL: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: documentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try publishDurably(data, to: documentURL, kind: .provenanceDocumentWritten)
        guard let signingProvider else {
            try removeSigningArtifacts(for: documentURL)
            return documentURL
        }
        _ = try sign(with: signingProvider, provenanceURL: documentURL)
        if signingProvider.providerIdentifier == ProvenanceSigningConfiguration.localProviderID {
            _ = try ProvenanceSignatureVerifier.verify(provenanceURL: documentURL)
        }
        return documentURL
    }
}
