// FASTQDisplayNameResolver.swift — Resolves human-readable display names for FASTQ bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Resolves human-readable display names for FASTQ bundles and sample IDs.
///
/// Virtual FASTQ bundles have internal file names (e.g., "materialized.fastq") that
/// should not be shown to users. This utility checks the bundle manifest's `.name`
/// field first, then falls back to the URL's last path component.
enum FASTQDisplayNameResolver {

    /// Resolve a display name for a sample ID.
    ///
    /// Resolution order:
    /// 1. FASTQDerivedBundleManifest.name if the sample ID matches a bundle in the project
    /// 2. Bundle URL's last path component minus extension
    /// 3. Raw sample ID as fallback
    static func resolveDisplayName(sampleId: String, projectURL: URL? = nil) -> String {
        if let projectURL {
            let fm = FileManager.default
            // Scan project directory for .lungfishfastq bundles
            if let enumerator = fm.enumerator(
                at: projectURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) {
                for case let url as URL in enumerator {
                    if url.pathExtension == "lungfishfastq" {
                        if let name = manifestDisplayName(bundleURL: url, matchingSampleId: sampleId) {
                            return name
                        }
                    }
                    // Check one level of subdirectories
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir {
                        if let subUrls = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                            for subUrl in subUrls where subUrl.pathExtension == "lungfishfastq" {
                                if let name = manifestDisplayName(bundleURL: subUrl, matchingSampleId: sampleId) {
                                    return name
                                }
                            }
                        }
                    }
                }
            }
        }
        return sampleId
    }

    /// Read a bundle's derived manifest and return its display name if the bundle matches the sample ID.
    private static func manifestDisplayName(bundleURL: URL, matchingSampleId: String) -> String? {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(FASTQDerivedBundleManifest.self, from: data) else {
            return nil
        }
        let bundleName = bundleURL.deletingPathExtension().lastPathComponent
        if sampleIdMatches(manifestName: manifest.name, bundleName: bundleName, sampleId: matchingSampleId) {
            return manifest.name
        }
        return nil
    }

    /// Check if a sample ID matches a bundle (case-insensitive, handles common variations).
    private static func sampleIdMatches(manifestName: String, bundleName: String, sampleId: String) -> Bool {
        let lower = sampleId.lowercased()
        return manifestName.lowercased() == lower
            || bundleName.lowercased() == lower
            || bundleName.lowercased().hasPrefix(lower)
            || lower.hasPrefix(bundleName.lowercased())
    }
}
