// VCFAutoIngestor.swift - Creates naked .lungfishref bundles from standalone VCF files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "VCFAutoIngestor")

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
        preferredBundleName: String? = nil,
        replaceExistingBundle: Bool = false,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) async throws -> IngestResult {
        guard !vcfURLs.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }

        logger.info("ingest: Starting auto-ingestion of \(vcfURLs.count) VCF file(s)")

        // Phase 1: Probe files to gather reference hints and skip unusable empties.
        progressHandler?(0.02, "Analyzing VCF files\u{2026}")
        var probes: [(url: URL, probe: ProbeResult)] = []
        probes.reserveCapacity(vcfURLs.count)
        for (index, url) in vcfURLs.enumerated() {
            if shouldCancel?() == true { throw CancellationError() }
            let probe = try await probeVCF(url: url)
            probes.append((url, probe))
            let fraction = 0.02 + (Double(index + 1) / Double(max(vcfURLs.count, 1))) * 0.08
            progressHandler?(fraction, "Analyzing VCF files (\(index + 1)/\(vcfURLs.count))\u{2026}")
        }

        let ignoredEmptyNoReference = probes.filter { candidate in
            !candidate.probe.hasVariantRecords && !candidate.probe.hasReferenceHint
        }.map { $0.url }
        if !ignoredEmptyNoReference.isEmpty {
            logger.warning(
                "ingest: Ignoring \(ignoredEmptyNoReference.count) empty VCF file(s) with no reference hint: \(ignoredEmptyNoReference.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)"
            )
        }

        let acceptedProbes = probes.filter { candidate in
            candidate.probe.hasVariantRecords || candidate.probe.hasReferenceHint
        }
        let importProbes = acceptedProbes.filter { $0.probe.hasVariantRecords }
        guard let firstImportURL = importProbes.first?.url else {
            throw VariantDatabaseError.createFailed("No variants were found in the selected VCF file(s).")
        }
        let importURLs = importProbes.map { $0.url }
        let fileCount = importURLs.count

        // Phase 2: Infer reference assembly
        progressHandler?(0.11, "Inferring reference genome\u{2026}")
        let referenceProbe = importProbes.first?.probe ?? acceptedProbes.first?.probe ?? probes[0].probe
        var combinedChromosomeNames = Set<String>()
        var combinedMaxPositions: [String: Int] = [:]
        for candidate in acceptedProbes {
            combinedChromosomeNames.formUnion(candidate.probe.chromosomeNames)
            for (chromosome, maxPos) in candidate.probe.maxPositions {
                combinedMaxPositions[chromosome] = max(combinedMaxPositions[chromosome] ?? 0, maxPos)
            }
        }
        let inferredRef = VCFReferenceInference.infer(
            from: referenceProbe.header,
            chromosomeMaxPositions: combinedMaxPositions
        )
        let accessions = VCFReferenceInference.extractNCBIAccessions(from: combinedChromosomeNames)
        logger.info("ingest: Inferred assembly=\(inferredRef.assembly ?? "unknown", privacy: .public), organism=\(inferredRef.organism ?? "unknown", privacy: .public), confidence=\(String(describing: inferredRef.confidence), privacy: .public), accessions=\(accessions, privacy: .public)")

        // Phase 3: Create bundle directory structure
        progressHandler?(0.14, "Creating bundle\u{2026}")
        let defaultBundleName = makeBundleName(vcfURLs: importURLs, inferredRef: inferredRef)
        let bundleName = normalizedBundleName(preferredBundleName ?? defaultBundleName)
        let bundleURL = outputDirectory.appendingPathComponent("\(bundleName).lungfishref", isDirectory: true)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: bundleURL.path) {
            if replaceExistingBundle {
                try fileManager.removeItem(at: bundleURL)
            } else {
                throw CocoaError(.fileWriteFileExists, userInfo: [
                    NSFilePathErrorKey: bundleURL.path,
                ])
            }
        }
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Clean up the bundle directory if anything throws after this point
        var bundleComplete = false
        defer {
            if !bundleComplete {
                try? fileManager.removeItem(at: bundleURL)
            }
        }

        let variantsDir = bundleURL.appendingPathComponent("variants", isDirectory: true)
        try fileManager.createDirectory(at: variantsDir, withIntermediateDirectories: true)

        if shouldCancel?() == true {
            throw CancellationError()
        }

        // Phase 4: Import VCF(s) into SQLite variant database
        let dbFilename = "variants.db"
        let dbURL = variantsDir.appendingPathComponent(dbFilename)
        var totalVariantCount = 0

        if fileCount == 1 {
            progressHandler?(0.18, "Importing variants\u{2026}")
            totalVariantCount = try VariantDatabase.createFromVCF(
                vcfURL: firstImportURL,
                outputURL: dbURL,
                parseGenotypes: true,
                sourceFile: firstImportURL.lastPathComponent,
                progressHandler: { progress, message in
                    let scaled = 0.18 + progress * 0.70
                    progressHandler?(scaled, message)
                },
                shouldCancel: shouldCancel,
                importProfile: .auto
            )
            logger.info("ingest: Imported \(totalVariantCount) variants from single VCF")
        } else {
            let importProgressRange = 0.70  // 0.18 to 0.88
            let perFileRange = importProgressRange / Double(fileCount)

            for (index, vcfURL) in importURLs.enumerated() {
                if shouldCancel?() == true {
                    throw CancellationError()
                }

                let fileBase = 0.18 + Double(index) * perFileRange
                let label = "Importing \(index + 1)/\(fileCount): \(vcfURL.lastPathComponent)"
                progressHandler?(fileBase, label)

                if index == 0 {
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
            throw CancellationError()
        }

        // Phase 5: Write manifest
        progressHandler?(0.92, "Writing manifest\u{2026}")

        let trackName = fileCount == 1
            ? firstImportURL.deletingPathExtension().lastPathComponent
            : "\(fileCount) VCF files"
        let trackDescription = fileCount == 1
            ? "Imported from \(firstImportURL.lastPathComponent)"
            : "Merged from \(fileCount) VCF files"

        let variantTrack = VariantTrackInfo(
            id: "vcf-\(firstImportURL.deletingPathExtension().lastPathComponent)",
            name: trackName,
            description: trackDescription,
            path: "variants/variants.bcf",  // placeholder — SQLite-only track
            indexPath: "variants/variants.bcf.csi",  // placeholder
            databasePath: "variants/\(dbFilename)",
            variantType: .mixed,
            variantCount: totalVariantCount,
            source: firstImportURL.lastPathComponent
        )

        let defaultPloidy = vcfURLs.count > 1 ? "haploid" : "auto"
        let manifest = BundleManifest(
            name: bundleName,
            identifier: "vcf-auto-\(UUID().uuidString)",
            description: fileCount == 1
                ? "Auto-ingested from \(firstImportURL.lastPathComponent)"
                : "Auto-ingested from \(fileCount) VCF files",
            source: SourceInfo(
                organism: inferredRef.organism ?? "Unknown",
                assembly: inferredRef.assembly ?? "Unknown",
                assemblyAccession: inferredRef.accession,
                database: accessions.isEmpty ? nil : "NCBI",
                notes: "Variant-only bundle created by auto-ingestion"
            ),
            genome: nil,
            variants: [variantTrack],
            metadata: [
                MetadataGroup(
                    name: "Import Settings",
                    items: [
                        MetadataItem(label: "Default Ploidy", value: defaultPloidy),
                        MetadataItem(label: "Imported VCF Files", value: "\(fileCount)"),
                        MetadataItem(label: "Ignored Empty Files", value: "\(ignoredEmptyNoReference.count)")
                    ]
                )
            ]
        )

        try manifest.save(to: bundleURL)
        logger.info("ingest: Manifest written to \(bundleURL.lastPathComponent, privacy: .public)")

        progressHandler?(1.0, "Complete")
        bundleComplete = true

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
        preferredBundleName: String? = nil,
        replaceExistingBundle: Bool = false,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) async throws -> IngestResult {
        try await ingest(
            vcfURLs: [vcfURL],
            outputDirectory: outputDirectory,
            preferredBundleName: preferredBundleName,
            replaceExistingBundle: replaceExistingBundle,
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
        let hasVariantRecords: Bool
        let hasReferenceHint: Bool
    }

    /// Reads VCF header + first N data lines to extract chromosome names without parsing the whole file.
    private static func probeVCF(url: URL, maxDataLines: Int = 1000) async throws -> ProbeResult {
        // Parse header using VCFReader (async, streams the file)
        let reader = VCFReader()
        let header = try await reader.readHeader(from: url)

        var chromosomeNames = Set<String>(header.contigs.keys)
        var maxPositions: [String: Int] = [:]
        var hasVariantRecords = false

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
                hasVariantRecords = true
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
            maxPositions: maxPositions,
            hasVariantRecords: hasVariantRecords,
            hasReferenceHint: !header.contigs.isEmpty || header.otherHeaders.keys.contains(where: { $0.caseInsensitiveCompare("reference") == .orderedSame })
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

    /// Produces a filesystem-safe non-empty bundle name.
    private static func normalizedBundleName(_ raw: String) -> String {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "VCF Variants" : cleaned
    }
}
