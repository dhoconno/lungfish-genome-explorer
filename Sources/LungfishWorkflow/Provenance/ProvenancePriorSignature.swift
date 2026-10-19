// ProvenancePriorSignature.swift - The key and digest of a signature that a write with no key removed from a record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A signature that a write with no key removed from a record, as the record states it afterwards (Phase 2.12 lane
/// 12.22, ruling SWIFT-12.22-fingerprint).
///
/// A write with no key into a signed record replaces the bytes the signature covered, so the writer removes
/// `<record>.signature.json` and `<record>.pub`. When that pair verified against the old bytes just before they were
/// replaced, the new record lists it under the optional envelope key `priorSignatures`, and the Add Annotation log
/// lists it on the entry whose append removed it. The list says that an earlier state of the file was signed, by
/// which key and over which digest. It never holds a key, the signature bytes, a key path or a signing identity.
public struct ProvenancePriorSignature: Codable, Sendable, Equatable {
    /// The provider the verifier accepted.
    public let provider: String
    /// The SHA-256 of the public key text in lowercase hex, as the removed signature file stated it after
    /// `ProvenanceSignatureVerifier.verify` matched it to the `.pub` beside it.
    public let publicKeySHA256: String
    /// The digest the signature covered in lowercase hex, as `ProvenanceSignatureVerifier.verify` returned it for
    /// the old bytes.
    public let provenanceSHA256: String
    /// The signing time as the removed signature file stated it. The signature does not cover this field, so it is
    /// the signer's claim and not a fact that LGE checked.
    public let signedAt: Date

    public init(provider: String, publicKeySHA256: String, provenanceSHA256: String, signedAt: Date) {
        self.provider = provider
        self.publicKeySHA256 = publicKeySHA256
        self.provenanceSHA256 = provenanceSHA256
        self.signedAt = signedAt
    }

    /// The pair that `result` verified, which is the only way the writer builds one.
    init(_ result: ProvenanceSignatureVerificationResult) {
        self.init(
            provider: result.provider,
            publicKeySHA256: result.publicKeySHA256,
            provenanceSHA256: result.provenanceSHA256,
            signedAt: result.signedAt
        )
    }
}
