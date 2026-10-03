// ProvenanceWriterError.swift - Errors thrown by the provenance writer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishIO

public enum ProvenanceWriterError: Error, LocalizedError, Sendable, Equatable {
    case unstableSignatureArtifact(
        provider: String,
        expectedSignaturePath: String,
        actualSignaturePath: String,
        expectedPublicKeyPath: String,
        actualPublicKeyPath: String
    )
    case unsafeStagedSignatureArtifact(provider: String, path: String)
    case unsafeStagedArtifact(path: String, reason: String)
    case unsafeExistingArtifact(path: String, reason: String)
    case exclusivePublicationFailed(path: String, code: Int32)
    case exclusivePublicationIdentityMismatch(path: String)
    case exclusivePublicationCleanupFailed(
        path: String,
        quarantinePath: String?,
        reason: String
    )
    case exclusivePublicationRollbackFailed(
        originalError: String,
        cleanupErrors: [String],
        preservedQuarantinePaths: [String]
    )
    case directoryPreparationFailed(path: String, code: Int32)
    case transactionalSigningRequired(provider: String)
    case durabilitySyncFailed(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .unstableSignatureArtifact(
            let provider,
            let expectedSignaturePath,
            let actualSignaturePath,
            let expectedPublicKeyPath,
            let actualPublicKeyPath
        ):
            return """
            Provenance signing provider '\(provider)' changed signature artifact URLs for the same provenance URL; expected signature \(expectedSignaturePath) and public key \(expectedPublicKeyPath), got signature \(actualSignaturePath) and public key \(actualPublicKeyPath).
            """
        case .unsafeStagedSignatureArtifact(let provider, let path):
            return "Provenance signing provider '\(provider)' produced an artifact outside the staging directory: \(path)."
        case .unsafeStagedArtifact(let path, let reason):
            return "Unsafe staged provenance artifact at \(path): \(reason)."
        case .unsafeExistingArtifact(let path, let reason):
            return "Unsafe existing provenance artifact at \(path): \(reason)."
        case .exclusivePublicationFailed(let path, let code):
            return "Could not publish a new provenance artifact without replacement at \(path): \(POSIXError(.init(rawValue: code) ?? .EIO).localizedDescription)"
        case .exclusivePublicationIdentityMismatch(let path):
            return "Exclusive provenance publication renamed a different filesystem object than the validated staged regular file at \(path)."
        case .exclusivePublicationCleanupFailed(
            let path,
            let quarantinePath,
            let reason
        ):
            let quarantineDescription = quarantinePath.map {
                " The filesystem object was preserved at \($0)."
            } ?? ""
            return "Could not safely clean provenance artifact at \(path): \(reason).\(quarantineDescription)"
        case .exclusivePublicationRollbackFailed(
            let originalError,
            let cleanupErrors,
            let preservedQuarantinePaths
        ):
            let preservedDescription = preservedQuarantinePaths.isEmpty
                ? ""
                : " Preserved filesystem objects: \(preservedQuarantinePaths.joined(separator: ", "))."
            return "Provenance publication failed (\(originalError)), and rollback was incomplete: \(cleanupErrors.joined(separator: "; ")).\(preservedDescription)"
        case .directoryPreparationFailed(let path, let code):
            return "Could not prepare provenance directory at \(path): "
                + POSIXError(
                    .init(rawValue: code) ?? .EIO
                ).localizedDescription
        case .transactionalSigningRequired(let provider):
            return "Provenance signing provider '\(provider)' does not support operation-derived publication receipts."
        case .durabilitySyncFailed(let path, let code):
            return "Could not durably synchronize provenance artifact \(path): \(POSIXError(.init(rawValue: code) ?? .EIO).localizedDescription)"
        }
    }
}
