// ONTImportWorkflow+ChunkBinning.swift - Quality binning of the chunks a chunked ONT import stores
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension ONTImportWorkflow {
    /// The reads a chunked bundle's preview holds, as the importer writes it.
    static let chunkedPreviewReadCount = 1000

    /// Whether an import's binning reaches the reads it stores. Optimize Storage bins through clumpify, and a chunked
    /// import bins each chunk (lane C2-ONTBIN, owner answer OQ1). A flattened import without Optimize Storage keeps
    /// every score.
    static func appliesQualityBinning(storageMode: ONTImportStorageMode, optimization: OptimizationConfig) -> Bool {
        optimization.qualityBinning != .none && (optimization.optimizeStorage || storageMode == .chunked)
    }

    /// Bins every chunk of each chunked bundle and rebuilds the bundle's preview from the binned chunks.
    ///
    /// Each pass reads the run's own chunk and writes the bundle's stored copy with `reformat.sh`, so a step's input
    /// is the source file and its output the stored one. The bundles sit in the import's staging folder, which a
    /// failure removes whole. The source manifest takes each chunk's new size.
    static func binChunkedPayloads(
        bundleURLs: [URL],
        config: ONTImportConfig,
        optimization: OptimizationConfig,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [String: [ProvenanceStep]] {
        guard config.storageMode == .chunked,
              appliesQualityBinning(storageMode: config.storageMode, optimization: optimization) else {
            return [:]
        }
        let pipeline = FASTQIngestionPipeline()
        let fm = FileManager.default
        var stepsByBundle: [String: [ProvenanceStep]] = [:]
        for (bundleIndex, bundleURL) in bundleURLs.enumerated() {
            let manifest = try FASTQSourceFileManifest.load(from: bundleURL)
            let chunkURLs = manifest.resolveFileURLs(relativeTo: bundleURL)
            guard chunkURLs.count == manifest.files.count else {
                throw FASTQIngestionError.qualityBinningFailed("\(bundleURL.lastPathComponent) lists a chunk outside the bundle")
            }
            let barcode = bundleURL.deletingPathExtension().lastPathComponent
            var entries: [FASTQSourceFileManifest.SourceFileEntry] = []
            var steps: [ProvenanceStep] = []
            for (entry, chunkURL) in zip(manifest.files, chunkURLs) {
                try Task.checkCancellation()
                let done = Double(bundleIndex) + Double(entries.count) / Double(max(1, chunkURLs.count))
                progress(done / Double(max(1, bundleURLs.count)), "\(barcode): binning quality scores of \(chunkURL.lastPathComponent)")
                // The copy goes first, so the pass writes a new file and never writes through a link into the run.
                try fm.removeItem(at: chunkURL)
                let step = try await pipeline.binQualities(
                    of: URL(fileURLWithPath: entry.originalPath),
                    into: chunkURL,
                    scheme: optimization.qualityBinning,
                    threads: optimization.threads
                )
                steps.append(ProvenanceStep(stepExecution: step))
                let size = ((try? fm.attributesOfItem(atPath: chunkURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
                entries.append(FASTQSourceFileManifest.SourceFileEntry(
                    filename: entry.filename,
                    originalPath: entry.originalPath,
                    sizeBytes: size,
                    isSymlink: false
                ))
            }
            try FASTQSourceFileManifest(version: manifest.version, files: entries).save(to: bundleURL)
            let previewURL = bundleURL.appendingPathComponent("preview.fastq")
            if fm.fileExists(atPath: previewURL.path) {
                try await ONTDirectoryImporter().generatePreview(
                    fromChunks: chunkURLs,
                    to: previewURL,
                    maxReads: chunkedPreviewReadCount
                )
            }
            stepsByBundle[bundleURL.standardizedFileURL.resolvingSymlinksInPath().path] = steps
        }
        return stepsByBundle
    }
}
