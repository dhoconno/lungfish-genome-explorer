// ProvenanceError.swift - Errors related to provenance recording and retrieval
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ProvenanceError

/// Errors related to provenance recording and retrieval.
public enum ProvenanceError: Error, LocalizedError, Sendable {
    case runNotFound(UUID)
    case noProvenanceAvailable(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .runNotFound(let id):
            return "Provenance run '\(id)' not found"
        case .noProvenanceAvailable(let path):
            return "No provenance record found for '\(path)'"
        case .exportFailed(let reason):
            return "Provenance export failed: \(reason)"
        }
    }
}
