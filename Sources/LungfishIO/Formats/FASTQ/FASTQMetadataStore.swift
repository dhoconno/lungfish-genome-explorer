// FASTQMetadataStore.swift - Sidecar JSON metadata persistence for FASTQ files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: "com.lungfish.io", category: "FASTQMetadataStore")

// MARK: - FASTQMetadataStore

/// Reads and writes sidecar metadata JSON files alongside FASTQ files.
///
/// ```swift
/// // Save after computing statistics
/// let metadata = PersistedFASTQMetadata(
///     computedStatistics: stats,
///     enaReadRecord: enaRecord
/// )
/// FASTQMetadataStore.save(metadata, for: fastqURL)
///
/// // Load on next open
/// if let cached = FASTQMetadataStore.load(for: fastqURL) {
///     // Use cached.computedStatistics instead of re-computing
/// }
/// ```
public enum FASTQMetadataStore {

    /// Returns the sidecar metadata URL for a given FASTQ file.
    ///
    /// Example: `/path/to/SRR123.fastq.gz` → `/path/to/SRR123.fastq.gz.lungfish-meta.json`
    public static func metadataURL(for fastqURL: URL) -> URL {
        fastqURL.appendingPathExtension("lungfish-meta.json")
    }

    /// Loads persisted metadata from the sidecar JSON, if it exists.
    ///
    /// - Parameter fastqURL: The URL of the FASTQ file.
    /// - Returns: The persisted metadata, or nil if no sidecar exists or it
    ///   cannot be read.
    public static func load(for fastqURL: URL) -> PersistedFASTQMetadata? {
        do {
            return try loadIfPresent(for: fastqURL)
        } catch {
            logger.warning("Failed to load FASTQ metadata: \(error)")
            return nil
        }
    }

    /// Loads the sidecar, or nil when there is none. Unlike ``load(for:)`` it
    /// throws when a sidecar exists but cannot be read or decoded, so a caller
    /// that rewrites the sidecar never replaces a file it could not read.
    public static func loadIfPresent(for fastqURL: URL) throws -> PersistedFASTQMetadata? {
        let url = metadataURL(for: fastqURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PersistedFASTQMetadata.self, from: Data(contentsOf: url))
    }

    /// Saves metadata to the sidecar JSON file. A failed write is logged, not
    /// reported. Use ``write(_:for:)`` when the caller must know.
    ///
    /// - Parameters:
    ///   - metadata: The metadata to persist.
    ///   - fastqURL: The URL of the FASTQ file.
    public static func save(_ metadata: PersistedFASTQMetadata, for fastqURL: URL) {
        // Do not create orphan metadata files when the FASTQ was deleted.
        guard FileManager.default.fileExists(atPath: fastqURL.path) else {
            logger.debug("Skipping FASTQ metadata save because source file is missing: \(fastqURL.lastPathComponent, privacy: .public)")
            return
        }
        do {
            try write(metadata, for: fastqURL)
            logger.info("Saved FASTQ metadata to \(metadataURL(for: fastqURL).lastPathComponent)")
        } catch {
            logger.warning("Failed to save FASTQ metadata: \(error)")
        }
    }

    /// Writes the sidecar like ``save(_:for:)``, but throws when it was not
    /// written, including when the FASTQ it describes is missing.
    public static func write(_ metadata: PersistedFASTQMetadata, for fastqURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fastqURL.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: fastqURL.path])
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: metadataURL(for: fastqURL), options: .atomic)
    }

    /// Deletes the sidecar metadata file if it exists.
    ///
    /// - Parameter fastqURL: The URL of the FASTQ file.
    public static func delete(for fastqURL: URL) {
        let url = metadataURL(for: fastqURL)
        try? FileManager.default.removeItem(at: url)
    }
}
