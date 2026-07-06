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
            } else {
                appendPathValidationError(path: genome.path, field: "genome.path", to: &errors)
            }
            if genome.indexPath.isEmpty {
                errors.append(.missingField("genome.indexPath"))
            } else {
                appendPathValidationError(path: genome.indexPath, field: "genome.indexPath", to: &errors)
            }
            if let gzipIndexPath = genome.gzipIndexPath {
                appendPathValidationError(path: gzipIndexPath, field: "genome.gzipIndexPath", to: &errors)
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

        for track in annotations {
            appendPathValidationError(path: track.path, field: "annotations[\(track.id)].path", to: &errors)
            if let databasePath = track.databasePath {
                appendPathValidationError(path: databasePath, field: "annotations[\(track.id)].databasePath", to: &errors)
            }
        }

        for track in variants {
            appendPathValidationError(path: track.path, field: "variants[\(track.id)].path", to: &errors)
            appendPathValidationError(path: track.indexPath, field: "variants[\(track.id)].indexPath", to: &errors)
            if let databasePath = track.databasePath {
                appendPathValidationError(path: databasePath, field: "variants[\(track.id)].databasePath", to: &errors)
            }
        }

        for track in tracks {
            appendPathValidationError(path: track.path, field: "tracks[\(track.id)].path", to: &errors)
        }

        for track in alignments {
            appendExternalOrBundlePathValidationError(path: track.sourcePath, field: "alignments[\(track.id)].sourcePath", to: &errors)
            appendExternalOrBundlePathValidationError(path: track.indexPath, field: "alignments[\(track.id)].indexPath", to: &errors)
            if let metadataDBPath = track.metadataDBPath {
                appendPathValidationError(path: metadataDBPath, field: "alignments[\(track.id)].metadataDBPath", to: &errors)
            }
        }

        return errors
    }

    /// Returns a URL for a manifest path only if it is a safe member of the bundle.
    ///
    /// This accepts files that do not exist yet so callers can use it before writes.
    /// Existing symlinks are resolved and must still point inside the bundle.
    public static func validatedBundleMemberURL(
        for relativePath: String,
        in bundleURL: URL,
        field: String = "path",
        allowReservedControlPath: Bool = false
    ) throws -> URL {
        guard isSafeBundleMemberPath(relativePath, allowReservedControlPath: allowReservedControlPath) else {
            throw BundleValidationError.invalidPath(field, relativePath)
        }

        let standardizedBundle = bundleURL.standardizedFileURL
        let candidate = standardizedBundle
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard isDescendant(candidate, of: standardizedBundle) else {
            throw BundleValidationError.invalidPath(field, relativePath)
        }

        if FileManager.default.fileExists(atPath: candidate.path) {
            let resolvedBundle = standardizedBundle.resolvingSymlinksInPath()
            let resolvedCandidate = candidate.resolvingSymlinksInPath()
            guard isDescendant(resolvedCandidate, of: resolvedBundle) else {
                throw BundleValidationError.invalidPath(field, relativePath)
            }
        }

        return candidate
    }

    private func appendPathValidationError(
        path: String,
        field: String,
        to errors: inout [BundleValidationError]
    ) {
        guard !Self.isSafeBundleMemberPath(path) else { return }
        errors.append(.invalidPath(field, path))
    }

    private func appendExternalOrBundlePathValidationError(
        path: String,
        field: String,
        to errors: inout [BundleValidationError]
    ) {
        if URL(fileURLWithPath: path).isFileURL, path.hasPrefix("/") {
            return
        }
        appendPathValidationError(path: path, field: field, to: &errors)
    }

    private static func isSafeBundleMemberPath(
        _ path: String,
        allowReservedControlPath: Bool = false
    ) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == path,
              !path.hasPrefix("/"),
              !path.hasPrefix("~") else {
            return false
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }

        return allowReservedControlPath || !isReservedBundleControlPath(path)
    }

    private static func isReservedBundleControlPath(_ path: String) -> Bool {
        path == BundleManifest.filename
            || path == ".lungfish-provenance.json"
            || path == "provenance"
            || path.hasPrefix("provenance/")
    }

    private static func isDescendant(_ url: URL, of directory: URL) -> Bool {
        let directoryPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return url.path.hasPrefix(directoryPath)
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
    /// Bundle member path is absolute, escapes the bundle, or targets reserved control metadata.
    case invalidPath(String, String)

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
        case .invalidPath(let field, let path):
            return "Manifest path '\(field)' is not a safe bundle-relative path: '\(path)'"
        }
    }
}
