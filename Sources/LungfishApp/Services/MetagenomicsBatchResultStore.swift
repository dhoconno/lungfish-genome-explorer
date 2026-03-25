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
