// MetagenomicsBatchResultStore.swift - Batch result sidecars for metagenomics workflows
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A persisted pointer to one sample-level result within a batch run.
public struct MetagenomicsBatchSampleRecord: Codable, Sendable, Equatable {
    public let sampleId: String
    public let resultDirectory: String
    public let inputFiles: [String]
    public let isPairedEnd: Bool

    public init(sampleId: String, resultDirectory: String, inputFiles: [String], isPairedEnd: Bool) {
        self.sampleId = sampleId
        self.resultDirectory = resultDirectory
        self.inputFiles = inputFiles
        self.isPairedEnd = isPairedEnd
    }
}

/// Shared manifest metadata for a batch run.
public struct MetagenomicsBatchManifestHeader: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let createdAt: Date
    public let sampleCount: Int

    public init(schemaVersion: Int, createdAt: Date, sampleCount: Int) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.sampleCount = sampleCount
    }
}

/// Batch sidecar for Kraken2/Bracken runs.
public struct ClassificationBatchResultManifest: Codable, Sendable, Equatable {
    public static let filename = "classification-batch-result.json"

    public let header: MetagenomicsBatchManifestHeader
    public let goal: String
    public let databaseName: String
    public let databaseVersion: String
    public let summaryTSV: String
    public let samples: [MetagenomicsBatchSampleRecord]

    public init(
        header: MetagenomicsBatchManifestHeader,
        goal: String,
        databaseName: String,
        databaseVersion: String,
        summaryTSV: String,
        samples: [MetagenomicsBatchSampleRecord]
    ) {
        self.header = header
        self.goal = goal
        self.databaseName = databaseName
        self.databaseVersion = databaseVersion
        self.summaryTSV = summaryTSV
        self.samples = samples
    }
}

/// Batch sidecar for EsViritu runs.
public struct EsVirituBatchResultManifest: Codable, Sendable, Equatable {
    public static let filename = "esviritu-batch-result.json"

    public let header: MetagenomicsBatchManifestHeader
    public let summaryTSV: String
    public let samples: [MetagenomicsBatchSampleRecord]

    public init(
        header: MetagenomicsBatchManifestHeader,
        summaryTSV: String,
        samples: [MetagenomicsBatchSampleRecord]
    ) {
        self.header = header
        self.summaryTSV = summaryTSV
        self.samples = samples
    }
}

/// Cross-reference sidecar written into each source bundle after a TaxTriage batch run.
///
/// Enables the sidebar to discover and display TaxTriage results under every bundle
/// that contributed samples, not just the bundle that physically hosts the output directory.
public struct TaxTriageCrossRef: Codable, Sendable, Equatable {
    /// Absolute path to the TaxTriage result output directory.
    public let resultDirectory: String

    /// Unique run identifier (derived from the output directory name, e.g. "taxtriage-20250325-143022").
    public let runId: String

    /// The sample ID from this particular source bundle.
    public let sampleId: String

    /// ISO 8601 timestamp when the run completed.
    public let createdAt: Date

    /// Number of samples in the batch (for display purposes).
    public let batchSampleCount: Int

    public init(
        resultDirectory: String,
        runId: String,
        sampleId: String,
        createdAt: Date,
        batchSampleCount: Int
    ) {
        self.resultDirectory = resultDirectory
        self.runId = runId
        self.sampleId = sampleId
        self.createdAt = createdAt
        self.batchSampleCount = batchSampleCount
    }
}

/// Materialized flat-table cache for a TaxTriage batch group.
///
/// Written once after the first parse of per-sample result files. Subsequent opens load
/// this manifest directly, skipping all per-sample file I/O for near-instant display.
public struct TaxTriageBatchManifest: Codable, Sendable {
    public static let filename = "taxtriage-batch-manifest.json"

    public struct CachedRow: Codable, Sendable {
        public let sample: String
        public let organism: String
        public let tassScore: Double
        public let reads: Int
        /// Nil until background BAM-based unique reads computation has completed.
        public let uniqueReads: Int?
        public let confidence: String?
        public let coverageBreadth: Double?
        public let coverageDepth: Double?
        public let abundance: Double?

        public init(
            sample: String,
            organism: String,
            tassScore: Double,
            reads: Int,
            uniqueReads: Int?,
            confidence: String?,
            coverageBreadth: Double?,
            coverageDepth: Double?,
            abundance: Double?
        ) {
            self.sample = sample
            self.organism = organism
            self.tassScore = tassScore
            self.reads = reads
            self.uniqueReads = uniqueReads
            self.confidence = confidence
            self.coverageBreadth = coverageBreadth
            self.coverageDepth = coverageDepth
            self.abundance = abundance
        }
    }

    public let createdAt: Date
    public let sampleCount: Int
    public let sampleIds: [String]
    public var cachedRows: [CachedRow]

    public init(createdAt: Date, sampleCount: Int, sampleIds: [String], cachedRows: [CachedRow]) {
        self.createdAt = createdAt
        self.sampleCount = sampleCount
        self.sampleIds = sampleIds
        self.cachedRows = cachedRows
    }
}

/// Materialized flat-table cache for an EsViritu batch run.
///
/// Written once after the first parse of per-sample detection files. Subsequent opens load
/// this manifest directly, skipping all per-sample file I/O for near-instant display.
public struct EsVirituBatchAggregatedManifest: Codable, Sendable {
    public static let filename = "esviritu-batch-aggregated.json"

    public struct CachedRow: Codable, Sendable {
        public let sample: String
        public let virusName: String
        public let family: String?
        public let assembly: String
        public let readCount: Int
        public let uniqueReads: Int
        public let rpkmf: Double
        public let coverageBreadth: Double
        public let coverageDepth: Double

        public init(
            sample: String,
            virusName: String,
            family: String?,
            assembly: String,
            readCount: Int,
            uniqueReads: Int,
            rpkmf: Double,
            coverageBreadth: Double,
            coverageDepth: Double
        ) {
            self.sample = sample
            self.virusName = virusName
            self.family = family
            self.assembly = assembly
            self.readCount = readCount
            self.uniqueReads = uniqueReads
            self.rpkmf = rpkmf
            self.coverageBreadth = coverageBreadth
            self.coverageDepth = coverageDepth
        }
    }

    public let createdAt: Date
    public let sampleCount: Int
    public let sampleIds: [String]
    public var cachedRows: [CachedRow]

    public init(createdAt: Date, sampleCount: Int, sampleIds: [String], cachedRows: [CachedRow]) {
        self.createdAt = createdAt
        self.sampleCount = sampleCount
        self.sampleIds = sampleIds
        self.cachedRows = cachedRows
    }
}

public enum MetagenomicsBatchResultStore {
    public static func saveClassification(
        _ manifest: ClassificationBatchResultManifest,
        to batchDirectory: URL
    ) throws {
        let url = batchDirectory.appendingPathComponent(ClassificationBatchResultManifest.filename)
        try writeJSON(manifest, to: url)
    }

    public static func loadClassification(from batchDirectory: URL) -> ClassificationBatchResultManifest? {
        let url = batchDirectory.appendingPathComponent(ClassificationBatchResultManifest.filename)
        return readJSON(ClassificationBatchResultManifest.self, from: url)
    }

    public static func saveEsViritu(
        _ manifest: EsVirituBatchResultManifest,
        to batchDirectory: URL
    ) throws {
        let url = batchDirectory.appendingPathComponent(EsVirituBatchResultManifest.filename)
        try writeJSON(manifest, to: url)
    }

    public static func loadEsViritu(from batchDirectory: URL) -> EsVirituBatchResultManifest? {
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
    public static func taxTriageRefFilename(runId: String) -> String {
        "taxtriage-ref-\(runId).json"
    }

    /// Writes a TaxTriage cross-reference sidecar into a source bundle directory.
    public static func saveTaxTriageRef(
        _ ref: TaxTriageCrossRef,
        to bundleDirectory: URL
    ) throws {
        let filename = taxTriageRefFilename(runId: ref.runId)
        let url = bundleDirectory.appendingPathComponent(filename)
        try writeJSON(ref, to: url)
    }

    /// Loads all TaxTriage cross-reference sidecars from a bundle directory.
    public static func loadTaxTriageRefs(from bundleDirectory: URL) -> [TaxTriageCrossRef] {
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

    public static func saveTaxTriageBatchManifest(
        _ manifest: TaxTriageBatchManifest,
        to directory: URL
    ) throws {
        let url = directory.appendingPathComponent(TaxTriageBatchManifest.filename)
        try writeJSON(manifest, to: url)
    }

    public static func loadTaxTriageBatchManifest(from directory: URL) -> TaxTriageBatchManifest? {
        let url = directory.appendingPathComponent(TaxTriageBatchManifest.filename)
        return readJSON(TaxTriageBatchManifest.self, from: url)
    }

    // MARK: - EsViritu Batch Aggregated Manifest

    public static func saveEsVirituBatchAggregatedManifest(
        _ manifest: EsVirituBatchAggregatedManifest,
        to directory: URL
    ) throws {
        let url = directory.appendingPathComponent(EsVirituBatchAggregatedManifest.filename)
        try writeJSON(manifest, to: url)
    }

    public static func loadEsVirituBatchAggregatedManifest(from directory: URL) -> EsVirituBatchAggregatedManifest? {
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
