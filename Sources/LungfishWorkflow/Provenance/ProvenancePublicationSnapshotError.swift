// ProvenancePublicationSnapshotError.swift - Errors thrown while snapshotting provenance publication artifacts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import CryptoKit
import LungfishIO

public enum ProvenancePublicationSnapshotError:
    Error, LocalizedError, Sendable
{
    case invalidRollbackWitness
    case artifactInspectionFailed(path: String, code: Int32)
    case artifactChangedDuringSnapshot(path: String)
    case mutationReceiptConflict(path: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRollbackWitness:
            return "The provenance rollback witness belongs to a different publication snapshot."
        case .artifactInspectionFailed(let path, let code):
            return "Could not inspect provenance publication artifact at "
                + "\(path) (errno \(code))."
        case .artifactChangedDuringSnapshot(let path):
            return "The provenance publication artifact changed while its rollback snapshot was captured: \(path)."
        case .mutationReceiptConflict(let path):
            return "The provenance publication artifact no longer matches the transaction generation at \(path)."
        }
    }
}
