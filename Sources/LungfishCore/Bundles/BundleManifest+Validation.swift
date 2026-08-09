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

        if let recordStore {
            appendPathValidationError(
                path: recordStore.databasePath,
                field: "record_store.database_path",
                to: &errors
            )
            if recordStore.format != ReferenceRecordStoreInfo.supportedFormat {
                errors.append(.invalidValue(
                    "record_store.format",
                    recordStore.format,
                    ReferenceRecordStoreInfo.supportedFormat
                ))
            }
            if recordStore.schemaVersion != ReferenceRecordStoreInfo.supportedSchemaVersion {
                errors.append(.invalidValue(
                    "record_store.schema_version",
                    String(recordStore.schemaVersion),
                    String(ReferenceRecordStoreInfo.supportedSchemaVersion)
                ))
            }
            if recordStore.recordCount < 0 {
                errors.append(.invalidValue(
                    "record_store.record_count",
                    String(recordStore.recordCount),
                    "zero or greater"
                ))
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
    ///
    /// - Parameter allowedEscapeRoots: An optional set of already-trusted
    ///   directory URLs that a bundle-owned TOP-LEVEL symlink is permitted to
    ///   escape into. The default (`[]`) preserves the historical strict
    ///   behavior: any symlink that resolves outside the bundle is rejected.
    ///
    ///   When non-empty, the post-resolution descendancy re-check may be relaxed
    ///   ONLY IF BOTH of the following hold:
    ///     (a) the first path component of `relativePath` is itself a symlink
    ///         located directly inside the resolved bundle root (a bundle-owned
    ///         top-level symlink); a leaf-file symlink never qualifies; AND
    ///     (b) the fully resolved candidate is contained within one of the
    ///         `allowedEscapeRoots`, decided by FILE IDENTITY (device + inode)
    ///         walking the resolved candidate's parent chain — never by string
    ///         prefix (which is unsound under APFS case-insensitivity and
    ///         NFC/NFD normalization).
    ///
    ///   The escape roots are a PURE trust input; callers (see LungfishIO's
    ///   `ReferenceBundle`) are responsible for deriving them under their own
    ///   security constraints. This function performs no origin validation.
    public static func validatedBundleMemberURL(
        for relativePath: String,
        in bundleURL: URL,
        field: String = "path",
        allowReservedControlPath: Bool = false,
        allowedEscapeRoots: [URL] = []
    ) throws -> URL {
        guard isSafeBundleMemberPath(relativePath, allowReservedControlPath: allowReservedControlPath) else {
            throw BundleValidationError.invalidPath(field, relativePath)
        }

        let standardizedBundle = bundleURL.standardizedFileURL
        let candidate = standardizedBundle
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        // Lexical descendancy check on the UNRESOLVED candidate stays untouched.
        guard isDescendant(candidate, of: standardizedBundle) else {
            throw BundleValidationError.invalidPath(field, relativePath)
        }

        if FileManager.default.fileExists(atPath: candidate.path) {
            let resolvedBundle = standardizedBundle.resolvingSymlinksInPath()
            let resolvedCandidate = candidate.resolvingSymlinksInPath()
            if !isDescendant(resolvedCandidate, of: resolvedBundle) {
                // The post-resolution re-check failed. Permit the escape only if
                // the hardened top-level-owned-symlink-into-allowed-root rule
                // holds; otherwise reject (historical strict behavior).
                guard !allowedEscapeRoots.isEmpty,
                      isBundleOwnedTopLevelSymlink(
                          relativePath: relativePath,
                          resolvedBundle: resolvedBundle
                      ),
                      isContainedByFileIdentity(
                          resolvedCandidate: resolvedCandidate,
                          allowedRoots: allowedEscapeRoots
                      ) else {
                    throw BundleValidationError.invalidPath(field, relativePath)
                }
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

    // MARK: - Hardened escape-root allowance helpers

    /// Condition (a): the first path component of `relativePath` must itself be a
    /// symbolic link located DIRECTLY inside the resolved bundle root. A
    /// leaf-file symlink (where the first component is a real directory) does not
    /// qualify. This authenticates only the first hop and is defense-in-depth;
    /// containment security rests on condition (b).
    private static func isBundleOwnedTopLevelSymlink(
        relativePath: String,
        resolvedBundle: URL
    ) -> Bool {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard let firstComponent = components.first else { return false }
        let topLevelMember = resolvedBundle.appendingPathComponent(String(firstComponent))

        // The top-level member itself must exist and be a symlink whose parent
        // (after resolving) is the resolved bundle root — i.e. the bundle owns it
        // at top level, not via a deeper symlinked intermediate directory.
        let attributes = try? FileManager.default.attributesOfItem(atPath: topLevelMember.path)
        guard (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink else {
            return false
        }
        let parentOfMember = topLevelMember.deletingLastPathComponent().resolvingSymlinksInPath()
        return sameFileIdentity(parentOfMember, resolvedBundle)
    }

    /// Condition (b): the resolved candidate is contained within one of the
    /// allowed roots, decided by walking the candidate's resolved parent chain
    /// and comparing FILE IDENTITY (device + inode) — never string prefixes.
    private static func isContainedByFileIdentity(
        resolvedCandidate: URL,
        allowedRoots: [URL]
    ) -> Bool {
        let rootIdentities = allowedRoots.compactMap { fileIdentity(for: $0.resolvingSymlinksInPath()) }
        guard !rootIdentities.isEmpty else { return false }

        // Walk from the candidate's directory upward to the filesystem root,
        // checking each ancestor's identity against the allowed roots. Also
        // accept the candidate itself matching a root (a member equal to a root
        // is trivially contained).
        var current = resolvedCandidate
        while true {
            if let identity = fileIdentity(for: current),
               rootIdentities.contains(identity) {
                return true
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { break }
            current = parent
        }
        return false
    }

    /// A device+inode file identity used for symlink-safe containment checks.
    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private static func fileIdentity(for url: URL) -> FileIdentity? {
        var info = stat()
        // `stat` follows symlinks; both sides are resolved before comparison so
        // aliasing (/var -> /private/var), case-insensitivity, and NFC/NFD
        // normalization all collapse to the same identity.
        guard url.withUnsafeFileSystemRepresentation({ rep -> Bool in
            guard let rep else { return false }
            return stat(rep, &info) == 0
        }) else {
            return nil
        }
        return FileIdentity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: info.st_ino)
    }

    private static func sameFileIdentity(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let a = fileIdentity(for: lhs), let b = fileIdentity(for: rhs) else {
            return false
        }
        return a == b
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
    /// A declared value is outside the supported scientific data contract.
    case invalidValue(String, String, String)

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
        case .invalidValue(let field, let value, let expected):
            return "Manifest field '\(field)' has unsupported value '\(value)' (expected \(expected))"
        }
    }
}
