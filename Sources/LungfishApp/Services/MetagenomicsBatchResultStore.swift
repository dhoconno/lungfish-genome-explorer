// MetagenomicsBatchResultStore.swift - Batch result sidecars for metagenomics workflows
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A persisted pointer to one sample-level result within a batch run.
struct MetagenomicsBatchSampleRecord: Codable, Sendable, Equatable {
    let sampleId: String
    let resultDirectory: String
    let inputFiles: [String]
    let isPairedEnd: Bool
}

/// Shared manifest metadata for a batch run.
struct MetagenomicsBatchManifestHeader: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let createdAt: Date
    let sampleCount: Int
}

/// Batch sidecar for Kraken2/Bracken runs.
struct ClassificationBatchResultManifest: Codable, Sendable, Equatable {
    static let filename = "classification-batch-result.json"

    let header: MetagenomicsBatchManifestHeader
    let goal: String
    let databaseName: String
    let databaseVersion: String
    let summaryTSV: String
    let samples: [MetagenomicsBatchSampleRecord]
}

/// Batch sidecar for EsViritu runs.
struct EsVirituBatchResultManifest: Codable, Sendable, Equatable {
    static let filename = "esviritu-batch-result.json"

    let header: MetagenomicsBatchManifestHeader
    let summaryTSV: String
    let samples: [MetagenomicsBatchSampleRecord]
}

/// Cross-reference sidecar written into each source bundle after a TaxTriage batch run.
///
/// Enables the sidebar to discover and display TaxTriage results under every bundle
/// that contributed samples, not just the bundle that physically hosts the output directory.
struct TaxTriageCrossRef: Codable, Sendable, Equatable {
    /// Absolute path to the TaxTriage result output directory.
    let resultDirectory: String

    /// Unique run identifier (derived from the output directory name, e.g. "taxtriage-20250325-143022").
    let runId: String

    /// The sample ID from this particular source bundle.
    let sampleId: String

    /// ISO 8601 timestamp when the run completed.
    let createdAt: Date

    /// Number of samples in the batch (for display purposes).
    let batchSampleCount: Int
}

/// Materialized flat-table cache for a TaxTriage batch group.
///
/// Written once after the first parse of per-sample result files. Subsequent opens load
/// this manifest directly, skipping all per-sample file I/O for near-instant display.
struct TaxTriageBatchManifest: Codable, Sendable {
    static let filename = "taxtriage-batch-manifest.json"

    struct CachedRow: Codable, Sendable {
        let sample: String
        let organism: String
        let tassScore: Double
        let reads: Int
        /// Nil until background BAM-based unique reads computation has completed.
        let uniqueReads: Int?
        let confidence: String?
        let coverageBreadth: Double?
        let coverageDepth: Double?
        let abundance: Double?
    }

    let createdAt: Date
    let sampleCount: Int
    let sampleIds: [String]
    var cachedRows: [CachedRow]
}

/// Materialized flat-table cache for an EsViritu batch run.
///
/// Written once after the first parse of per-sample detection files. Subsequent opens load
/// this manifest directly, skipping all per-sample file I/O for near-instant display.
struct EsVirituBatchAggregatedManifest: Codable, Sendable {
    static let filename = "esviritu-batch-aggregated.json"

    struct CachedRow: Codable, Sendable {
        let sample: String
        let virusName: String
        let family: String?
        let assembly: String
        let readCount: Int
        let uniqueReads: Int
        let rpkmf: Double
        let coverageBreadth: Double
        let coverageDepth: Double
    }

    let createdAt: Date
    let sampleCount: Int
    let sampleIds: [String]
    var cachedRows: [CachedRow]
}

enum MetagenomicsBatchResultStore {
    static func saveClassification(
        _ manifest: ClassificationBatchResultManifest,
        to batchDirectory: URL
    ) throws {
        let url = batchDirectory.appendingPathComponent(ClassificationBatchResultManifest.filename)
        try writeJSON(manifest, to: url)
    }

    static func loadClassification(from batchDirectory: URL) -> ClassificationBatchResultManifest? {
        let url = batchDirectory.appendingPathComponent(ClassificationBatchResultManifest.filename)
        return readJSON(ClassificationBatchResultManifest.self, from: url)
    }

    static func saveEsViritu(
        _ manifest: EsVirituBatchResultManifest,
        to batchDirectory: URL
    ) throws {
        let url = batchDirectory.appendingPathComponent(EsVirituBatchResultManifest.filename)
        try writeJSON(manifest, to: url)
    }

    static func loadEsViritu(from batchDirectory: URL) -> EsVirituBatchResultManifest? {
        let url = batchDirectory.appendingPathComponent(EsVirituBatchResultManifest.filename)
        return readJSON(EsVirituBatchResultManifest.self, from: url)
    }

    // MARK: - TaxTriage Cross-Reference Sidecars

    /// Filename pattern for TaxTriage cross-reference sidecars written into source bundles.
    ///
    /// Each source bundle that contributed samples to a TaxTriage batch run gets a
    /// `taxtriage-ref-{runId}.json` sidecar so the sidebar can discover TaxTriage
    /// results under every contributing bundle, not just the one that physically
    /// contains the output directory.
    static func taxTriageRefFilename(runId: String) -> String {
        "taxtriage-ref-\(runId).json"
    }

    /// Writes a TaxTriage cross-reference sidecar into a source bundle directory.
    static func saveTaxTriageRef(
        _ ref: TaxTriageCrossRef,
        to bundleDirectory: URL
    ) throws {
        let filename = taxTriageRefFilename(runId: ref.runId)
        let url = bundleDirectory.appendingPathComponent(filename)
        try writeJSON(ref, to: url)
    }

    /// Loads all TaxTriage cross-reference sidecars from a bundle directory.
    static func loadTaxTriageRefs(from bundleDirectory: URL) -> [TaxTriageCrossRef] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: bundleDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { url in
            guard url.lastPathComponent.hasPrefix("taxtriage-ref-"),
                  url.pathExtension == "json" else { return nil }
            return readJSON(TaxTriageCrossRef.self, from: url)
        }
    }

    // MARK: - TaxTriage Batch Manifest

    static func saveTaxTriageBatchManifest(
        _ manifest: TaxTriageBatchManifest,
        to directory: URL
    ) throws {
        let url = directory.appendingPathComponent(TaxTriageBatchManifest.filename)
        try writeJSON(manifest, to: url)
    }

    static func loadTaxTriageBatchManifest(from directory: URL) -> TaxTriageBatchManifest? {
        let url = directory.appendingPathComponent(TaxTriageBatchManifest.filename)
        return readJSON(TaxTriageBatchManifest.self, from: url)
    }

    // MARK: - EsViritu Batch Aggregated Manifest

    static func saveEsVirituBatchAggregatedManifest(
        _ manifest: EsVirituBatchAggregatedManifest,
        to directory: URL
    ) throws {
        let url = directory.appendingPathComponent(EsVirituBatchAggregatedManifest.filename)
        try writeJSON(manifest, to: url)
    }

    static func loadEsVirituBatchAggregatedManifest(from directory: URL) -> EsVirituBatchAggregatedManifest? {
        let url = directory.appendingPathComponent(EsVirituBatchAggregatedManifest.filename)
        return readJSON(EsVirituBatchAggregatedManifest.self, from: url)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
