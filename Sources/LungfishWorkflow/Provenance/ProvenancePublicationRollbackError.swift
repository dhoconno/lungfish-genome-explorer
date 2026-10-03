// ProvenancePublicationRollbackError.swift - Carries both the original failure and the rollback failure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import CryptoKit
import LungfishIO

public struct ProvenancePublicationRollbackError: Error, LocalizedError {
    public let originalErrorDescription: String
    public let rollbackErrorDescription: String

    public init(originalError: Error, rollbackError: Error) {
        originalErrorDescription = String(reflecting: originalError)
        rollbackErrorDescription = String(reflecting: rollbackError)
    }

    public var errorDescription: String? {
        "Provenance publication failed and rollback failed; original error: \(originalErrorDescription); rollback failed: \(rollbackErrorDescription)"
    }
}
