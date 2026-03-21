// FASTQSourceFiles.swift - Multi-file source manifest for virtual concatenation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Source File Manifest

/// Manifest listing constituent FASTQ files that form a virtual concatenation.
///
/// Used by `.lungfishfastq` bundles that reference multiple source files
/// (e.g., ONT chunk files) instead of a single concatenated `reads.fastq.gz`.
/// Files are listed in the order they should be read for deterministic results.
///
/// ```
/// experiment.lungfishfastq/
///   source-files.json          ← this manifest
///   chunks/
///     FAD12345_0.fastq.gz      ← symlink to original
///     FAD12345_1.fastq.gz
///     ...
///   preview.fastq
/// ```
public struct FASTQSourceFileManifest: Codable, Sendable, Equatable {
    /// Standard filename for the manifest inside a bundle.
    public static let filename = "source-files.json"

    /// Schema version (currently 1).
    public let version: Int

    /// Ordered list of constituent FASTQ files.
    public let files: [SourceFileEntry]

    /// Total number of files.
    public var fileCount: Int { files.count }

    /// Total size across all files.
    public var totalSizeBytes: Int64 {
        files.reduce(0) { $0 + $1.sizeBytes }
    }

    /// A single constituent FASTQ file.
    public struct SourceFileEntry: Codable, Sendable, Equatable {
        /// Path relative to the bundle directory (e.g., "chunks/FAD12345_0.fastq.gz").
        public let filename: String

        /// Absolute path of the original file (for provenance tracking).
        public let originalPath: String

        /// File size in bytes.
        public let sizeBytes: Int64

        /// Whether this entry is a symlink to the original file.
        public let isSymlink: Bool

        public init(filename: String, originalPath: String, sizeBytes: Int64, isSymlink: Bool) {
            self.filename = filename
            self.originalPath = originalPath
            self.sizeBytes = sizeBytes
            self.isSymlink = isSymlink
        }
    }

    public init(version: Int = 1, files: [SourceFileEntry]) {
        self.version = version
        self.files = files
    }

    // MARK: - Persistence

    /// Saves the manifest to a bundle directory.
    public func save(to bundleURL: URL) throws {
        let url = bundleURL.appendingPathComponent(Self.filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Loads the manifest from a bundle directory.
    public static func load(from bundleURL: URL) throws -> FASTQSourceFileManifest {
        let url = bundleURL.appendingPathComponent(filename)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FASTQSourceFileManifest.self, from: data)
    }

    /// Whether a bundle contains a source file manifest.
    public static func exists(in bundleURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(filename).path)
    }

    /// Resolves all constituent file URLs relative to the bundle directory.
    ///
    /// - Parameter bundleURL: The `.lungfishfastq` bundle URL.
    /// - Returns: Ordered list of resolved file URLs.
    public func resolveFileURLs(relativeTo bundleURL: URL) -> [URL] {
        files.map { bundleURL.appendingPathComponent($0.filename) }
    }
}
