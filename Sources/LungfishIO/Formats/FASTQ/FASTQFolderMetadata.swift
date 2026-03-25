// FASTQFolderMetadata.swift - Folder-level sample metadata for FASTQ bundles
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.io", category: "FASTQFolderMetadata")

// MARK: - FASTQFolderMetadata

/// Manages batch-level sample metadata stored in `samples.csv` at a folder root.
///
/// Each row maps to one `.lungfishfastq` bundle in the folder, matched by
/// `sample_name` column to the bundle directory name.
///
/// ## Resolution Rules
///
/// 1. Per-bundle `metadata.csv` takes precedence over folder `samples.csv`.
/// 2. Folder `samples.csv` rows are matched to bundles by `sample_name` column
///    matching the bundle directory name (minus `.lungfishfastq` extension).
/// 3. When saving from the folder-level editor, both `samples.csv` and per-bundle
///    `metadata.csv` files are updated.
public struct FASTQFolderMetadata: Sendable, Equatable {

    /// Filename for the folder-level metadata CSV.
    public static let filename = "samples.csv"

    /// Parsed metadata per sample, keyed by sample name.
    public let samples: [String: FASTQSampleMetadata]

    /// Ordered sample names (preserves CSV row order).
    public let sampleOrder: [String]

    /// Creates folder metadata from a dictionary and ordering.
    public init(samples: [String: FASTQSampleMetadata], sampleOrder: [String]) {
        self.samples = samples
        self.sampleOrder = sampleOrder
    }

    /// Creates folder metadata from an ordered array.
    public init(orderedSamples: [FASTQSampleMetadata]) {
        var dict: [String: FASTQSampleMetadata] = [:]
        var order: [String] = []
        for sample in orderedSamples {
            dict[sample.sampleName] = sample
            order.append(sample.sampleName)
        }
        self.samples = dict
        self.sampleOrder = order
    }
}

// MARK: - Load / Save

extension FASTQFolderMetadata {

    /// Returns the URL for the samples CSV in a folder.
    public static func metadataURL(in folderURL: URL) -> URL {
        folderURL.appendingPathComponent(filename)
    }

    /// Returns true if a `samples.csv` exists in the folder.
    public static func exists(in folderURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: metadataURL(in: folderURL).path)
    }

    /// Loads folder metadata from `samples.csv`, if present.
    public static func load(from folderURL: URL) -> FASTQFolderMetadata? {
        let url = metadataURL(in: folderURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            return parse(csv: content)
        } catch {
            logger.warning("Failed to load folder metadata from \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Saves folder metadata to `samples.csv`.
    public static func save(_ metadata: FASTQFolderMetadata, to folderURL: URL) throws {
        let url = metadataURL(in: folderURL)
        let orderedSamples = metadata.sampleOrder.compactMap { metadata.samples[$0] }
        let csv = FASTQSampleMetadata.serializeMultiSampleCSV(orderedSamples)
        try csv.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Saved folder metadata to \(url.lastPathComponent) (\(metadata.samples.count) samples)")
    }

    /// Saves folder metadata and also writes per-bundle `metadata.csv` files.
    public static func saveWithPerBundleSync(
        _ metadata: FASTQFolderMetadata,
        to folderURL: URL
    ) throws {
        // Save folder-level samples.csv
        try save(metadata, to: folderURL)

        // Sync to per-bundle metadata.csv
        for (name, sampleMeta) in metadata.samples {
            let bundleName = name.hasSuffix(".lungfishfastq") ? name : "\(name).lungfishfastq"
            let bundleURL = folderURL.appendingPathComponent(bundleName)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else { continue }

            let legacyCSV = sampleMeta.toLegacyCSV()
            try FASTQBundleCSVMetadata.save(legacyCSV, to: bundleURL)
        }
    }

    /// Deletes the folder metadata CSV.
    public static func delete(from folderURL: URL) {
        let url = metadataURL(in: folderURL)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - CSV Parsing

    /// Parses a CSV string into folder metadata.
    public static func parse(csv: String) -> FASTQFolderMetadata? {
        guard let samples = FASTQSampleMetadata.parseMultiSampleCSV(csv) else { return nil }
        guard !samples.isEmpty else { return nil }

        var dict: [String: FASTQSampleMetadata] = [:]
        var order: [String] = []

        for sample in samples {
            dict[sample.sampleName] = sample
            order.append(sample.sampleName)
        }

        return FASTQFolderMetadata(samples: dict, sampleOrder: order)
    }

    // MARK: - Bundle Discovery

    /// Discovers `.lungfishfastq` bundles in a folder and loads metadata
    /// from both folder-level `samples.csv` and per-bundle `metadata.csv`.
    ///
    /// Resolution: per-bundle metadata takes precedence over folder-level.
    public static func loadResolved(from folderURL: URL) -> FASTQFolderMetadata {
        let fm = FileManager.default

        // Discover bundles
        var bundleNames: [String] = []
        if let contents = try? fm.contentsOfDirectory(atPath: folderURL.path) {
            bundleNames = contents
                .filter { $0.hasSuffix(".lungfishfastq") }
                .sorted()
        }

        // Load folder-level metadata
        let folderMeta = load(from: folderURL)

        // Build resolved metadata
        var resolved: [String: FASTQSampleMetadata] = [:]
        var order: [String] = []

        for bundleName in bundleNames {
            let sampleName = String(bundleName.dropLast(".lungfishfastq".count))
            let bundleURL = folderURL.appendingPathComponent(bundleName)

            // Try per-bundle metadata first
            if let bundleCSV = FASTQBundleCSVMetadata.load(from: bundleURL) {
                let meta = FASTQSampleMetadata(from: bundleCSV, fallbackName: sampleName)
                resolved[sampleName] = meta
            } else if let folderSample = folderMeta?.samples[sampleName] {
                // Fall back to folder-level
                resolved[sampleName] = folderSample
            } else {
                // No metadata at all; create minimal entry
                resolved[sampleName] = FASTQSampleMetadata(sampleName: sampleName)
            }

            order.append(sampleName)
        }

        return FASTQFolderMetadata(samples: resolved, sampleOrder: order)
    }
}
