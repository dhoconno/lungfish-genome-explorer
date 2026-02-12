// SequenceExtractionPipeline.swift - Background bundle creation from extracted sequences
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

private let extractionLogger = Logger(subsystem: "com.lungfish.browser", category: "SequenceExtraction")

/// Builds a `.lungfishref` bundle from an extracted sequence.
///
/// This class is `@unchecked Sendable` (not `@MainActor`) so it can run
/// from `Task.detached` contexts. Progress is reported via `DownloadCenter`
/// singleton, following the same pattern as `GenBankBundleDownloadViewModel`.
public final class SequenceExtractionPipeline: @unchecked Sendable {

    private let toolRunner: NativeToolRunner

    public init(toolRunner: NativeToolRunner = .shared) {
        self.toolRunner = toolRunner
    }

    /// Creates a `.lungfishref` bundle from an extraction result.
    ///
    /// Pipeline: write temp FASTA -> bgzip -> samtools faidx -> write manifest -> return bundle URL.
    ///
    /// - Parameters:
    ///   - result: The extraction result containing the nucleotide sequence.
    ///   - outputDirectory: Where to create the bundle.
    ///   - sourceBundle: Optional source bundle for metadata inheritance.
    ///   - progressHandler: Optional progress callback (fraction, message).
    /// - Returns: URL of the created `.lungfishref` bundle.
    public func buildBundle(
        from result: ExtractionResult,
        outputDirectory: URL,
        sourceBundleName: String? = nil,
        desiredBundleName: String? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let fileManager = FileManager.default

        progressHandler?(0.05, "Checking tools...")
        try await BundleBuildHelpers.validateTools(using: toolRunner)

        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("lungfish-extract-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Cleanup is best-effort and asynchronous to avoid blocking return after
        // bundle creation on platforms where temp dir removal can stall.
        defer {
            let cleanupURL = tempDir
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }

        // Write plain FASTA
        progressHandler?(0.15, "Writing FASTA...")
        let seqName = BundleBuildHelpers.sanitizedFilename(result.sourceName)
        let plainFASTA = tempDir.appendingPathComponent("sequence.fa")
        let fastaContent = SequenceExtractor.formatFASTA(result)
        try fastaContent.write(to: plainFASTA, atomically: true, encoding: .utf8)

        // Bgzip compress
        progressHandler?(0.30, "Compressing (bgzip)...")
        let bgzipResult = try await toolRunner.bgzipCompress(inputPath: plainFASTA, keepOriginal: false)
        guard bgzipResult.isSuccess else {
            throw BundleBuildError.compressionFailed(bgzipResult.combinedOutput)
        }
        let compressedFASTA = tempDir.appendingPathComponent("sequence.fa.gz")

        // Index FASTA
        progressHandler?(0.50, "Indexing (samtools faidx)...")
        let faiResult = try await toolRunner.indexFASTA(fastaPath: compressedFASTA)
        guard faiResult.isSuccess else {
            throw BundleBuildError.indexingFailed(faiResult.combinedOutput)
        }

        let faiURL = compressedFASTA.appendingPathExtension("fai")
        let gziURL = compressedFASTA.appendingPathExtension("gzi")

        // Parse chromosome info from fai
        let chromosomes = try BundleBuildHelpers.parseFai(at: faiURL)
        let totalLength = chromosomes.reduce(Int64(0)) { $0 + $1.length }

        // Create bundle directory structure
        progressHandler?(0.70, "Creating bundle...")
        let bundleName: String
        if let desired = desiredBundleName, !desired.isEmpty {
            bundleName = BundleBuildHelpers.sanitizedFilename(desired)
        } else {
            bundleName = seqName.isEmpty ? "extracted_sequence" : seqName
        }
        let bundleURL = BundleBuildHelpers.makeUniqueBundleURL(
            baseName: bundleName,
            in: outputDirectory
        )
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try fileManager.createDirectory(at: genomeDir, withIntermediateDirectories: true)

        // Move files into bundle
        try fileManager.moveItem(at: compressedFASTA, to: genomeDir.appendingPathComponent("sequence.fa.gz"))
        try fileManager.moveItem(at: faiURL, to: genomeDir.appendingPathComponent("sequence.fa.gz.fai"))
        let hasGzi = fileManager.fileExists(atPath: gziURL.path)
        if hasGzi {
            try fileManager.moveItem(at: gziURL, to: genomeDir.appendingPathComponent("sequence.fa.gz.gzi"))
        }

        // Write manifest
        progressHandler?(0.85, "Writing manifest...")
        let coordinateLabel = "\(result.chromosome):\(result.effectiveStart)-\(result.effectiveEnd)"
        let description: String
        if let source = sourceBundleName {
            description = "Extracted from \(source) at \(coordinateLabel)"
        } else {
            description = "Extracted sequence at \(coordinateLabel)"
        }

        let sourceInfo = SourceInfo(
            organism: sourceBundleName ?? "Unknown",
            commonName: nil,
            taxonomyId: nil,
            assembly: "Extracted",
            assemblyAccession: nil,
            database: nil,
            sourceURL: nil,
            downloadDate: Date(),
            notes: description
        )

        let genomeInfo = GenomeInfo(
            path: "genome/sequence.fa.gz",
            indexPath: "genome/sequence.fa.gz.fai",
            gzipIndexPath: hasGzi ? "genome/sequence.fa.gz.gzi" : nil,
            totalLength: totalLength,
            chromosomes: chromosomes,
            md5Checksum: nil
        )

        let identifier = "org.lungfish.extracted.\(bundleName.lowercased().replacingOccurrences(of: " ", with: "-"))"

        let manifestName = desiredBundleName ?? result.sourceName
        let manifest = BundleManifest(
            name: manifestName,
            identifier: identifier,
            description: description,
            source: sourceInfo,
            genome: genomeInfo
        )

        try manifest.save(to: bundleURL)

        // Notify app-level import pipeline immediately when the bundle exists on disk.
        // This is posted from the current background context on purpose; AppDelegate
        // re-schedules UI work onto the main run loop.
        NotificationCenter.default.post(
            name: .bundleBuiltOnDisk,
            object: nil,
            userInfo: [NotificationUserInfoKey.bundleURL: bundleURL]
        )

        progressHandler?(1.0, "Bundle ready: \(bundleURL.lastPathComponent)")
        extractionLogger.info("buildBundle: Bundle complete at \(bundleURL.path, privacy: .public)")
        return bundleURL
    }
}
