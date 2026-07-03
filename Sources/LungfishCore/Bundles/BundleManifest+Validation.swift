// BundleManifest+Validation.swift - Reference genome bundle manifest data model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Validation

extension BundleManifest {

    /// Validates the manifest for completeness and consistency.
    ///
    /// - Returns: Array of validation errors (empty if valid)
    public func validate() -> [BundleValidationError] {
        var errors: [BundleValidationError] = []

        // Check required fields
        if name.isEmpty {
            errors.append(.missingField("name"))
        }
        if identifier.isEmpty {
            errors.append(.missingField("identifier"))
        }
        // Genome fields are only required for bundles with sequence data.
        if let genome {
            if genome.path.isEmpty {
                errors.append(.missingField("genome.path"))
            }
            if genome.indexPath.isEmpty {
                errors.append(.missingField("genome.indexPath"))
            }
            if genome.chromosomes.isEmpty {
                errors.append(.missingField("genome.chromosomes"))
            }
        }

        // Check for duplicate track IDs. Iteration order (annotations -> variants
        // -> tracks -> alignments) is preserved so the first reported duplicate is
        // deterministic.
        var trackIds = Set<String>()
        let allTrackIds = annotations.map(\.id)
            + variants.map(\.id)
            + tracks.map(\.id)
            + alignments.map(\.id)
        for id in allTrackIds {
            if trackIds.contains(id) {
                errors.append(.duplicateTrackId(id))
            }
            trackIds.insert(id)
        }

        return errors
    }
}

/// Validation errors for bundle manifests.
public enum BundleValidationError: Error, LocalizedError, Sendable {
    /// Required field is missing or empty.
    case missingField(String)
    /// Duplicate track ID found.
    case duplicateTrackId(String)
    /// File referenced in manifest not found.
    case fileNotFound(String)
    /// Invalid file format.
    case invalidFileFormat(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingField(let field):
            return "Required field '\(field)' is missing or empty"
        case .duplicateTrackId(let id):
            return "Duplicate track ID: '\(id)'"
        case .fileNotFound(let path):
            return "Referenced file not found: '\(path)'"
        case .invalidFileFormat(let path, let expected):
            return "File '\(path)' has invalid format (expected \(expected))"
        }
    }
}
