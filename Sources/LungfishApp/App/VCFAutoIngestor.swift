// VCFAutoIngestor.swift - Creates naked .lungfishref bundles from standalone VCF files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.browser", category: "VCFAutoIngestor")

// MARK: - VCFAutoIngestor

/// Creates variant-only `.lungfishref` bundles from standalone VCF files.
///
/// When a VCF file is opened without an existing reference bundle, this class:
/// 1. Parses the VCF header + first N data lines to extract chromosome names
/// 2. Infers the reference assembly from chromosome names
/// 3. Creates a naked `.lungfishref` bundle with only the variant database
/// 4. Optionally triggers background download of the reference genome from NCBI
public enum VCFAutoIngestor {

    /// Result of auto-ingestion.
    public struct IngestResult: Sendable {
        /// URL of the created `.lungfishref` bundle.
        public let bundleURL: URL

        /// Inferred reference information (assembly, organism, accession).
        public let inferredReference: ReferenceInference.Result

        /// NCBI accessions found in chromosome names, suitable for genome download.
        public let ncbiAccessions: [String]

        /// Number of variants imported.
        public let variantCount: Int
    }

    // MARK: - Public API

    /// Creates a naked `.lungfishref` bundle from one or more VCF files.
    ///
    /// When multiple VCFs are provided, they are merged into a single variant database.
    /// Each VCF's filename is used as the `sourceFile` for tracking origin in the samples table.
    ///
    /// - Parameters:
    ///   - vcfURLs: Paths to VCF files (at least one required)
    ///   - outputDirectory: Directory where the `.lungfishref` bundle will be created
    ///   - progressHandler: Optional callback for progress updates (0.0–1.0, message)
    ///   - shouldCancel: Optional cancellation check
    /// - Returns: IngestResult with bundle URL and reference inference
    public static func ingest(
        vcfURLs: [URL],
        outputDirectory: URL,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) async throws -> IngestResult {
        guard let firstURL = vcfURLs.first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let fileCount = vcfURLs.count
        logger.info("ingest: Starting auto-ingestion of \(fileCount) VCF file(s)")

        // Phase 1: Probe first VCF header for reference inference
        progressHandler?(0.02, "Analyzing VCF file\u{2026}")
        let probeResult = try await probeVCF(url: firstURL)
        logger.info("ingest: Found \(probeResult.chromosomeNames.count) chromosomes: \(probeResult.chromosomeNames.sorted().joined(separator: ", "), privacy: .public)")

        // Phase 2: Infer reference assembly
        progressHandler?(0.05, "Inferring reference genome\u{2026}")
        let inferredRef = VCFReferenceInference.infer(
            from: probeResult.header,
            chromosomeMaxPositions: probeResult.maxPositions
        )
        let accessions = VCFReferenceInference.extractNCBIAccessions(from: probeResult.chromosomeNames)
        logger.info("ingest: Inferred assembly=\(inferredRef.assembly ?? "unknown", privacy: .public), organism=\(inferredRef.organism ?? "unknown", privacy: .public), confidence=\(String(describing: inferredRef.confidence), privacy: .public), accessions=\(accessions, privacy: .public)")

        // Phase 3: Create bundle directory structure
        progressHandler?(0.08, "Creating bundle\u{2026}")
        let bundleName = makeBundleName(vcfURLs: vcfURLs, inferredRef: inferredRef)
        let bundleURL = outputDirectory.appendingPathComponent("\(bundleName).lungfishref", isDirectory: true)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let variantsDir = bundleURL.appendingPathComponent("variants", isDirectory: true)
        try fileManager.createDirectory(at: variantsDir, withIntermediateDirectories: true)

        if shouldCancel?() == true {
            try? fileManager.removeItem(at: bundleURL)
            throw CancellationError()
        }

        // Phase 4: Import VCF(s) into SQLite variant database
        let dbFilename = "variants.db"
        let dbURL = variantsDir.appendingPathComponent(dbFilename)
        var totalVariantCount = 0

        if fileCount == 1 {
            // Single file — use createFromVCF directly
            progressHandler?(0.10, "Importing variants\u{2026}")
            totalVariantCount = try VariantDatabase.createFromVCF(
                vcfURL: firstURL,
                outputURL: dbURL,
                parseGenotypes: true,
                sourceFile: firstURL.lastPathComponent,
                progressHandler: { progress, message in
                    let scaled = 0.10 + progress * 0.80
                    progressHandler?(scaled, message)
                },
                shouldCancel: shouldCancel,
                importProfile: .auto
            )
            logger.info("ingest: Imported \(totalVariantCount) variants from single VCF")
        } else {
            // Multiple files — create from first, then merge additional VCFs
            let importProgressRange = 0.80  // 0.10 to 0.90
            let perFileRange = importProgressRange / Double(fileCount)

            for (index, vcfURL) in vcfURLs.enumerated() {
                if shouldCancel?() == true {
                    try? fileManager.removeItem(at: bundleURL)
                    throw CancellationError()
                }

                let fileBase = 0.10 + Double(index) * perFileRange
                let label = "Importing \(index + 1)/\(fileCount): \(vcfURL.lastPathComponent)"
                progressHandler?(fileBase, label)

                if index == 0 {
                    // First file creates the database
                    let count = try VariantDatabase.createFromVCF(
                        vcfURL: vcfURL,
                        outputURL: dbURL,
                        parseGenotypes: true,
                        sourceFile: vcfURL.lastPathComponent,
                        progressHandler: { progress, message in
                            let scaled = fileBase + progress * perFileRange
                            progressHandler?(scaled, message)
                        },
                        shouldCancel: shouldCancel,
                        importProfile: .auto
                    )
                    totalVariantCount += count
                    logger.info("ingest: File 1/\(fileCount): \(count) variants from \(vcfURL.lastPathComponent, privacy: .public)")
                } else {
                    // Subsequent files: create temp DB, then merge into main
                    let tempDBURL = variantsDir.appendingPathComponent("_temp_merge_\(index).db")
                    defer { try? fileManager.removeItem(at: tempDBURL) }

                    let count = try VariantDatabase.createFromVCF(
                        vcfURL: vcfURL,
                        outputURL: tempDBURL,
                        parseGenotypes: true,
                        sourceFile: vcfURL.lastPathComponent,
                        progressHandler: { progress, message in
                            let scaled = fileBase + progress * perFileRange * 0.8
                            progressHandler?(scaled, message)
                        },
                        shouldCancel: shouldCancel,
                        importProfile: .auto,
                        deferIndexBuild: true
                    )

                    progressHandler?(fileBase + perFileRange * 0.9, "Merging \(vcfURL.lastPathComponent)\u{2026}")
                    let merged = try VariantDatabase.mergeImportedDatabase(into: dbURL, from: tempDBURL)
                    totalVariantCount += merged
                    logger.info("ingest: File \(index + 1)/\(fileCount): \(count) variants from \(vcfURL.lastPathComponent, privacy: .public), merged \(merged)")
                }
            }
            logger.info("ingest: Total \(totalVariantCount) variants from \(fileCount) files")
        }

        if shouldCancel?() == true {
            try? fileManager.removeItem(at: bundleURL)
            throw CancellationError()
        }

        // Phase 5: Write manifest
        progressHandler?(0.92, "Writing manifest\u{2026}")

        let trackName = fileCount == 1
            ? firstURL.deletingPathExtension().lastPathComponent
            : "\(fileCount) VCF files"
        let trackDescription = fileCount == 1
            ? "Imported from \(firstURL.lastPathComponent)"
            : "Merged from \(fileCount) VCF files"

        let variantTrack = VariantTrackInfo(
            id: "vcf-\(firstURL.deletingPathExtension().lastPathComponent)",
            name: trackName,
            description: trackDescription,
            path: "variants/variants.bcf",  // placeholder — SQLite-only track
            indexPath: "variants/variants.bcf.csi",  // placeholder
            databasePath: "variants/\(dbFilename)",
            variantType: .mixed,
            variantCount: totalVariantCount,
            source: firstURL.lastPathComponent
        )

        let manifest = BundleManifest(
            name: bundleName,
            identifier: "vcf-auto-\(UUID().uuidString)",
            description: fileCount == 1
                ? "Auto-ingested from \(firstURL.lastPathComponent)"
                : "Auto-ingested from \(fileCount) VCF files",
            source: SourceInfo(
                organism: inferredRef.organism ?? "Unknown",
                assembly: inferredRef.assembly ?? "Unknown",
                assemblyAccession: inferredRef.accession,
                database: accessions.isEmpty ? nil : "NCBI",
                notes: "Variant-only bundle created by auto-ingestion"
            ),
            genome: nil,
            variants: [variantTrack]
        )

        try manifest.save(to: bundleURL)
        logger.info("ingest: Manifest written to \(bundleURL.lastPathComponent, privacy: .public)")

        progressHandler?(1.0, "Complete")

        return IngestResult(
            bundleURL: bundleURL,
            inferredReference: inferredRef,
            ncbiAccessions: accessions,
            variantCount: totalVariantCount
        )
    }

    /// Convenience for single-file ingestion.
    public static func ingest(
        vcfURL: URL,
        outputDirectory: URL,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) async throws -> IngestResult {
        try await ingest(
            vcfURLs: [vcfURL],
            outputDirectory: outputDirectory,
            progressHandler: progressHandler,
            shouldCancel: shouldCancel
        )
    }

    // MARK: - VCF Probing

    /// Lightweight VCF probe result.
    private struct ProbeResult {
        let header: VCFHeader
        let chromosomeNames: Set<String>
        let maxPositions: [String: Int]
    }

    /// Reads VCF header + first N data lines to extract chromosome names without parsing the whole file.
    private static func probeVCF(url: URL, maxDataLines: Int = 1000) async throws -> ProbeResult {
        // Parse header using VCFReader (async, streams the file)
        let reader = VCFReader()
        let header = try await reader.readHeader(from: url)

        var chromosomeNames = Set<String>(header.contigs.keys)
        var maxPositions: [String: Int] = [:]

        // For contigs with known lengths, use those as max positions
        for (name, length) in header.contigs {
            maxPositions[name] = length
        }

        // Scan first N data lines for CHROM names (efficient line-by-line)
        var dataLineCount = 0
        for try await line in url.lines {
            guard !line.hasPrefix("#") else { continue }
            guard !line.isEmpty else { continue }

            let fields = line.split(separator: "\t", maxSplits: 2)
            if fields.count >= 2 {
                let chrom = String(fields[0])
                chromosomeNames.insert(chrom)
                if let pos = Int(fields[1]) {
                    let current = maxPositions[chrom] ?? 0
                    if pos > current {
                        maxPositions[chrom] = pos
                    }
                }
            }
            dataLineCount += 1
            if dataLineCount >= maxDataLines { break }
        }

        return ProbeResult(
            header: header,
            chromosomeNames: chromosomeNames,
            maxPositions: maxPositions
        )
    }

    // MARK: - Helpers

    /// Creates a human-readable bundle name from the VCF file(s) and inferred reference.
    private static func makeBundleName(vcfURLs: [URL], inferredRef: ReferenceInference.Result) -> String {
        if let assembly = inferredRef.assembly {
            return "\(assembly) Variants"
        }
        if let first = vcfURLs.first {
            return first.deletingPathExtension().lastPathComponent
        }
        return "VCF Variants"
    }

    private static func makeBundleName(vcfURL: URL, inferredRef: ReferenceInference.Result) -> String {
        makeBundleName(vcfURLs: [vcfURL], inferredRef: inferredRef)
    }
}
