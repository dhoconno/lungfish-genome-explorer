// FASTQBundle.swift - FASTQ package helper utilities
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Helpers for `.lungfishfastq` package directories.
///
/// A FASTQ package is a directory that keeps the FASTQ payload and sidecars
/// (`.fai`, `.lungfish-meta.json`) together so they travel as one unit.
public enum FASTQBundle {
    /// Directory extension for FASTQ packages.
    public static let directoryExtension = "lungfishfastq"

    /// Derived dataset manifest filename.
    public static let derivedManifestFilename = "derived.manifest.json"

    /// Trim positions filename for trim derivative bundles.
    public static let trimPositionFilename = "trim-positions.tsv"

    /// Returns `true` when the URL is a `.lungfishfastq` directory.
    public static func isBundleURL(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == directoryExtension else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Returns `true` when the URL points to a FASTQ/FQ file
    /// (including gzip-compressed `.fastq.gz` / `.fq.gz`).
    public static func isFASTQFileURL(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return false
        }

        var checkURL = url
        if checkURL.pathExtension.lowercased() == "gz" {
            checkURL = checkURL.deletingPathExtension()
        }
        let ext = checkURL.pathExtension.lowercased()
        return ext == "fastq" || ext == "fq"
    }

    /// Resolves the primary FASTQ file for a candidate URL.
    ///
    /// - Returns: The FASTQ file URL when `candidateURL` is a FASTQ file or
    ///   a FASTQ bundle with a physical FASTQ payload; otherwise `nil`.
    public static func resolvePrimaryFASTQURL(for candidateURL: URL) -> URL? {
        if isFASTQFileURL(candidateURL) {
            return candidateURL
        }
        guard isBundleURL(candidateURL) else { return nil }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: candidateURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let fastqFiles = contents
                .filter { isFASTQFileURL($0) }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            return fastqFiles.first
        } catch {
            return nil
        }
    }

    /// Returns true when a bundle stores a derived pointer manifest.
    public static func isDerivedBundle(_ bundleURL: URL) -> Bool {
        guard isBundleURL(bundleURL) else { return false }
        let manifestURL = bundleURL.appendingPathComponent(derivedManifestFilename)
        return FileManager.default.fileExists(atPath: manifestURL.path)
    }

    /// Returns URL to the derived manifest in a bundle.
    public static func derivedManifestURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(derivedManifestFilename)
    }

    /// Loads a derived bundle manifest, if present and valid.
    public static func loadDerivedManifest(in bundleURL: URL) -> FASTQDerivedBundleManifest? {
        let manifestURL = derivedManifestURL(in: bundleURL)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(FASTQDerivedBundleManifest.self, from: data)
        } catch {
            return nil
        }
    }

    /// Saves a derived manifest in a bundle.
    public static func saveDerivedManifest(_ manifest: FASTQDerivedBundleManifest, in bundleURL: URL) throws {
        let manifestURL = derivedManifestURL(in: bundleURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    /// Resolves the read ID list URL for a derived bundle (subset derivatives only).
    public static func readIDListURL(forDerivedBundle bundleURL: URL) -> URL? {
        guard let manifest = loadDerivedManifest(in: bundleURL),
              case .subset(let filename) = manifest.payload else { return nil }
        return bundleURL.appendingPathComponent(filename)
    }

    /// Resolves the trim positions URL for a derived bundle (trim derivatives only).
    public static func trimPositionsURL(forDerivedBundle bundleURL: URL) -> URL? {
        guard let manifest = loadDerivedManifest(in: bundleURL),
              case .trim(let filename) = manifest.payload else { return nil }
        return bundleURL.appendingPathComponent(filename)
    }

    /// Resolves paired R1/R2 FASTQ URLs for a fullPaired payload derived bundle.
    public static func pairedFASTQURLs(forDerivedBundle bundleURL: URL) -> (r1: URL, r2: URL)? {
        guard let manifest = loadDerivedManifest(in: bundleURL),
              case .fullPaired(let r1, let r2) = manifest.payload else { return nil }
        return (bundleURL.appendingPathComponent(r1), bundleURL.appendingPathComponent(r2))
    }

    /// Resolves the materialized FASTQ URL for a full payload derived bundle.
    public static func fullPayloadFASTQURL(forDerivedBundle bundleURL: URL) -> URL? {
        guard let manifest = loadDerivedManifest(in: bundleURL),
              case .full(let filename) = manifest.payload else { return nil }
        return bundleURL.appendingPathComponent(filename)
    }

    /// Resolves role-based FASTQ file URLs for a multi-file bundle.
    ///
    /// Checks for a `read-manifest.json` first, then falls back to the derived
    /// manifest's `.fullMixed` payload. Returns nil for homogeneous bundles.
    public static func classifiedFileURLs(for bundleURL: URL) -> [ReadClassification.FileRole: URL]? {
        // Try standalone read manifest first
        if let readManifest = ReadManifest.load(from: bundleURL) {
            return buildRoleMap(from: readManifest.classification, in: bundleURL)
        }
        // Try derived bundle manifest with fullMixed payload
        if let manifest = loadDerivedManifest(in: bundleURL),
           case .fullMixed(let classification) = manifest.payload {
            return buildRoleMap(from: classification, in: bundleURL)
        }
        return nil
    }

    /// Builds a role → URL map from a ReadClassification, filtering to files that exist.
    private static func buildRoleMap(
        from classification: ReadClassification,
        in bundleURL: URL
    ) -> [ReadClassification.FileRole: URL] {
        var result: [ReadClassification.FileRole: URL] = [:]
        for entry in classification.files {
            let url = bundleURL.appendingPathComponent(entry.filename)
            if FileManager.default.fileExists(atPath: url.path) {
                result[entry.role] = url
            }
        }
        return result
    }

    /// Finds the `.lungfish` project root directory by walking up from a bundle URL.
    ///
    /// Returns `nil` if no `.lungfish` directory is found within 10 levels.
    public static func findProjectRoot(from url: URL) -> URL? {
        var current = url.standardizedFileURL
        for _ in 0..<10 {
            if current.pathExtension == "lungfish" {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return nil
    }

    /// Computes a path relative to the `.lungfish` project root.
    ///
    /// Project-relative paths are prefixed with `@/` to distinguish them from
    /// legacy `../`-style relative paths. For example:
    /// `@/FBC38282...extraction.lungfishfastq`
    ///
    /// Returns `nil` if no project root can be found from either URL.
    public static func projectRelativePath(for targetURL: URL, from anyBundleURL: URL) -> String? {
        guard let projectRoot = findProjectRoot(from: anyBundleURL) ?? findProjectRoot(from: targetURL) else {
            return nil
        }
        let rootPath = projectRoot.standardizedFileURL.path
        let normalizedRoot = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let targetPath = targetURL.standardizedFileURL.path
        guard targetPath.hasPrefix(normalizedRoot) else { return nil }
        return "@/" + String(targetPath.dropFirst(normalizedRoot.count))
    }

    /// Resolves a relative bundle path from an anchor bundle URL.
    ///
    /// Supports two path formats:
    /// - **Project-relative** (`@/path/to/bundle.lungfishfastq`): resolved from
    ///   the `.lungfish` project root found by walking up from the anchor URL.
    /// - **Legacy relative** (`../../bundle.lungfishfastq`): resolved directly
    ///   relative to the anchor bundle URL.
    public static func resolveBundle(relativePath: String, from anchorBundleURL: URL) -> URL {
        if relativePath.hasPrefix("@/") {
            let innerPath = String(relativePath.dropFirst(2))
            if let projectRoot = findProjectRoot(from: anchorBundleURL) {
                return projectRoot.appendingPathComponent(innerPath).standardizedFileURL
            }
        }
        return URL(fileURLWithPath: relativePath, relativeTo: anchorBundleURL).standardizedFileURL
    }

    /// Searches the project root for a `.lungfishfastq` bundle containing a specific FASTQ file.
    ///
    /// Used as a recovery path when legacy `../../` relative paths no longer resolve
    /// (e.g. after bundles were moved within the project). Searches top-level bundles
    /// in the project root directory.
    ///
    /// - Parameters:
    ///   - fastqFilename: The FASTQ filename expected inside the root bundle.
    ///   - anchorURL: Any URL within the project (used to find the project root).
    /// - Returns: The bundle URL containing the file, or `nil` if not found.
    public static func findBundleContaining(fastqFilename: String, from anchorURL: URL) -> URL? {
        guard let projectRoot = findProjectRoot(from: anchorURL) else { return nil }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: projectRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for url in contents where url.pathExtension == directoryExtension {
            let candidateFASTQ = url.appendingPathComponent(fastqFilename)
            if FileManager.default.fileExists(atPath: candidateFASTQ.path) {
                return url
            }
        }
        return nil
    }

    /// Derives a stable base name by stripping known FASTQ/compression extensions.
    ///
    /// Only removes `.fastq`, `.fq`, `.gz`, `.bz2`, `.zst`, and `.lungfishfastq`
    /// extensions rather than stripping all extensions, so filenames like
    /// `patient.42.sample.fastq.gz` become `patient.42.sample` (not `patient`).
    public static func deriveBaseName(from fastqURL: URL) -> String {
        let knownExtensions: Set<String> = ["fastq", "fq", "gz", "bz2", "zst", "lungfishfastq"]
        var url = fastqURL
        while knownExtensions.contains(url.pathExtension.lowercased()) {
            url = url.deletingPathExtension()
        }
        return url.lastPathComponent
    }
}
