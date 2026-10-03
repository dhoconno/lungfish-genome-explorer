// ProvenanceSignatureReference.swift - Pointer to a detached signature for a provenance file
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ProvenanceSignatureReference

public struct ProvenanceSignatureReference: Codable, Sendable, Equatable {
    public let provider: String
    public let provenanceSHA256: String
    public let signaturePath: String
    public let publicKeyPath: String?

    public init(provider: String, provenanceSHA256: String, signaturePath: String, publicKeyPath: String? = nil) {
        self.provider = provider
        self.provenanceSHA256 = provenanceSHA256
        self.signaturePath = signaturePath
        self.publicKeyPath = publicKeyPath
    }
}
