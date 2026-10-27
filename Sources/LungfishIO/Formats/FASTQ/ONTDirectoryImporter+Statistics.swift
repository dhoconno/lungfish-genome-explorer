// ONTDirectoryImporter+Statistics.swift - The statistics an ONT import measures from the reads it stores
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ONTDirectoryImporter {

    /// Measures every record of `files`, read in order as one dataset.
    ///
    /// The import reads each record once, so the counts, lengths, GC and scores it stores are the ones it read. It
    /// once counted lines and estimated the bases as compressed bytes times 1.5, and stored 0 for every other
    /// statistic (Phase 3.0 lane ONT, walk WF-8).
    static func measureStatistics(of files: [URL]) async throws -> FASTQDatasetStatistics {
        let collector = FASTQStatisticsCollector()
        let reader = FASTQReader(validateSequence: false)
        var processed = 0
        for file in files {
            for try await record in reader.records(from: file) {
                collector.process(record)
                processed += 1
                if processed % 2_000 == 0 { try Task.checkCancellation() }
            }
            // The record stream ends early when the task is cancelled, so a cancelled import never stores a part.
            try Task.checkCancellation()
        }
        return collector.finalize()
    }

    /// Counts the reads and bases of folders the import leaves out, for the manifest's `unassigned` record.
    static func countReadsAndBases(of files: [URL]) async throws -> (reads: Int, bases: Int64) {
        let reader = FASTQReader(validateSequence: false)
        var reads = 0
        var bases: Int64 = 0
        for file in files {
            let summary = try await reader.computeSummaryStatistics(from: file)
            reads += summary.readCount
            bases += summary.baseCount
        }
        try Task.checkCancellation()
        return (reads, bases)
    }

    /// Measures the reads a bundle stores now and writes them to its sidecar, keeping every other field.
    ///
    /// Optimize Storage and chunk binning rewrite the scores after the import measured them, so the import workflow
    /// calls this once they end and the stored statistics describe the stored reads.
    public static func remeasureStoredStatistics(ofBundle bundleURL: URL) async throws {
        guard let payloads = FASTQBundle.resolveAllFASTQURLs(for: bundleURL), !payloads.isEmpty else { return }
        saveStatistics(try await measureStatistics(of: payloads), forBundle: bundleURL)
    }

    /// Stores measured statistics on the bundle's sidecar, and on a single-file bundle's payload sidecar too.
    static func saveStatistics(_ statistics: FASTQDatasetStatistics, forBundle bundleURL: URL) {
        var metadata = FASTQMetadataStore.load(for: bundleURL) ?? PersistedFASTQMetadata()
        metadata.computedStatistics = statistics
        FASTQMetadataStore.save(metadata, for: bundleURL)
        guard !FASTQBundle.isMultiFileBundle(bundleURL),
              let payloadURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL)?.standardizedFileURL,
              payloadURL != bundleURL.standardizedFileURL else {
            return
        }
        var payloadMetadata = FASTQMetadataStore.load(for: payloadURL) ?? metadata
        payloadMetadata.computedStatistics = statistics
        FASTQMetadataStore.save(payloadMetadata, for: payloadURL)
    }

    /// The first chunk of an ONT folder, preferring a barcode's reads to the unclassified ones, or nil when the
    /// folder holds no ONT layout. The import sheet's platform check reads it when it is handed the folder.
    static func firstChunk(in folder: URL) -> URL? {
        guard let layout = try? ONTDirectoryImporter().detectLayout(at: folder) else { return nil }
        let directories = layout.barcodeDirectories
        return (directories.first { !$0.isUnclassified } ?? directories.first)?.chunkFiles.first
    }
}
