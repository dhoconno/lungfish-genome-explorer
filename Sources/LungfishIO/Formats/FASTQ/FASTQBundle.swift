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

    /// Resolves the read ID list URL for a derived bundle.
    public static func readIDListURL(forDerivedBundle bundleURL: URL) -> URL? {
        guard let manifest = loadDerivedManifest(in: bundleURL) else { return nil }
        return bundleURL.appendingPathComponent(manifest.readIDListFilename)
    }

    /// Resolves a relative bundle path from an anchor bundle URL.
    public static func resolveBundle(relativePath: String, from anchorBundleURL: URL) -> URL {
        URL(fileURLWithPath: relativePath, relativeTo: anchorBundleURL).standardizedFileURL
    }

    /// Derives a stable base name by stripping all extensions from a FASTQ filename.
    public static func deriveBaseName(from fastqURL: URL) -> String {
        var strippedURL = fastqURL
        while !strippedURL.pathExtension.isEmpty {
            strippedURL = strippedURL.deletingPathExtension()
        }
        return strippedURL.lastPathComponent
    }
}
