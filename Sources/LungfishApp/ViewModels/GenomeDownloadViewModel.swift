// GenomeDownloadViewModel.swift - Genome assembly download and bundle building
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: NCBI Integration Lead (Role 12)

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

/// Logger for genome download operations.
private let logger = Logger(subsystem: "com.lungfish.browser", category: "GenomeDownload")

// MARK: - GenomeDownloadViewModel

/// Downloads NCBI genome assemblies (FASTA + GFF3) and builds `.lungfishref` bundles.
///
/// This implementation avoids `@MainActor` isolation so it can run from `Task.detached`
/// contexts without cooperative executor scheduling issues. It follows the same pattern as
/// ``GenBankBundleDownloadViewModel``: direct `NativeToolRunner` usage for all tool
/// invocations, with progress reported via a `@Sendable` callback.
///
/// ## Usage
/// ```swift
/// let viewModel = GenomeDownloadViewModel()
/// let bundleURL = try await viewModel.downloadAndBuild(
///     assembly: assemblySummary,
///     outputDirectory: downloadsDir
/// ) { progress, message in
///     print("\(Int(progress * 100))%: \(message)")
/// }
/// ```
public final class GenomeDownloadViewModel: @unchecked Sendable {

    private let ncbiService: NCBIService
    private let toolRunner: NativeToolRunner

    // MARK: - Initialization

    public init(
        ncbiService: NCBIService = NCBIService(),
        toolRunner: NativeToolRunner = .shared
    ) {
        self.ncbiService = ncbiService
        self.toolRunner = toolRunner
    }

    // MARK: - Tool Validation

    /// Validates that required native tools are available.
    public func validateTools() async throws {
        try await BundleBuildHelpers.validateTools(using: toolRunner)
    }

    // MARK: - Public API

    /// Downloads FASTA and GFF3 files for an assembly and builds a `.lungfishref` bundle.
    ///
    /// Pipeline:
    /// 1. Validate tools (bgzip, samtools)
    /// 2. Get FASTA + GFF3 file info from NCBI FTP
    /// 3. Download FASTA (compressed .fna.gz) with progress
    /// 4. Download GFF3 (optional, may not exist)
    /// 5. Decompress FASTA (bgzip -d), re-compress with bgzip for random access
    /// 6. Index FASTA (samtools faidx)
    /// 7. Convert GFF3 directly to SQLite annotation DB
    /// 8. Write manifest.json
    ///
    /// - Parameters:
    ///   - assembly: The NCBI assembly summary describing the genome.
    ///   - outputDirectory: Where to create the `.lungfishref` bundle.
    ///   - progressHandler: Called with (0.0–1.0, message) during the pipeline.
    /// - Returns: URL of the completed `.lungfishref` bundle.
    public func downloadAndBuild(
        assembly: NCBIAssemblySummary,
        outputDirectory: URL,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let fileManager = FileManager.default
        let accession = assembly.assemblyAccession ?? assembly.uid
        let organismName = assembly.organism ?? assembly.speciesName ?? "Unknown"
        let assemblyName = assembly.assemblyName ?? accession

        logger.info("downloadAndBuild: Starting pipeline for \(accession, privacy: .public) (\(organismName, privacy: .public))")

        // Pre-flight: verify tools
        progressHandler?(0.01, "Checking tools...")
        try await validateTools()

        // Create temp working directory
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("lungfish-genome-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        // Steps 1–4: Download FASTA + GFF3 (FTP path or Datasets API fallback)
        var fastaDestination: URL
        var gffDestination: URL?
        var fastaIsGzipped: Bool

        let hasFTPPath = (assembly.ftpPathRefSeq ?? assembly.ftpPathGenBank) != nil

        if hasFTPPath {
            // --- FTP path available: download individual files ---
            progressHandler?(0.02, "Locating genome FASTA...")
            logger.info("downloadAndBuild: Getting FASTA file info for \(accession, privacy: .public)")

            let fastaFileInfo = try await ncbiService.getGenomeFileInfo(for: assembly)
            let fastaSizeStr = fastaFileInfo.estimatedSize.map { BundleBuildHelpers.formatBytes($0) } ?? "unknown size"
            logger.info("downloadAndBuild: FASTA file found: \(fastaFileInfo.filename, privacy: .public) (\(fastaSizeStr, privacy: .public))")

            progressHandler?(0.03, "Checking for GFF3 annotations...")
            let gffFileInfo = try await ncbiService.getAnnotationFileInfo(for: assembly)
            if let gffInfo = gffFileInfo {
                let gffSizeStr = gffInfo.estimatedSize.map { BundleBuildHelpers.formatBytes($0) } ?? "unknown size"
                logger.info("downloadAndBuild: GFF3 file found: \(gffInfo.filename, privacy: .public) (\(gffSizeStr, privacy: .public))")
            } else {
                logger.info("downloadAndBuild: No GFF3 annotations available for \(accession, privacy: .public)")
            }

            progressHandler?(0.05, "Downloading FASTA (\(fastaSizeStr))...")
            logger.info("downloadAndBuild: Downloading FASTA to temp directory")

            fastaDestination = tempDir.appendingPathComponent(fastaFileInfo.filename)
            let fastaExpectedBytes = fastaFileInfo.estimatedSize

            _ = try await ncbiService.downloadGenomeFile(
                fastaFileInfo,
                to: fastaDestination
            ) { bytesDownloaded, expectedTotal in
                let total = expectedTotal ?? fastaExpectedBytes
                let fraction: Double
                if let total, total > 0 {
                    fraction = Double(bytesDownloaded) / Double(total)
                } else {
                    fraction = 0.5
                }
                let overallProgress = 0.05 + (fraction * 0.40)
                let downloadedStr = BundleBuildHelpers.formatBytes(bytesDownloaded)
                let totalStr = total.map { BundleBuildHelpers.formatBytes($0) } ?? "?"
                progressHandler?(overallProgress, "Downloading FASTA: \(downloadedStr) / \(totalStr)")
            }
            logger.info("downloadAndBuild: FASTA download complete")
            fastaIsGzipped = fastaDestination.pathExtension.lowercased() == "gz"

            if let gffInfo = gffFileInfo {
                progressHandler?(0.45, "Downloading GFF3 annotations...")
                logger.info("downloadAndBuild: Downloading GFF3 to temp directory")

                let gffDest = tempDir.appendingPathComponent(gffInfo.filename)
                let gffExpectedBytes = gffInfo.estimatedSize

                do {
                    _ = try await ncbiService.downloadGenomeFile(
                        gffInfo,
                        to: gffDest
                    ) { bytesDownloaded, expectedTotal in
                        let total = expectedTotal ?? gffExpectedBytes
                        let fraction: Double
                        if let total, total > 0 {
                            fraction = Double(bytesDownloaded) / Double(total)
                        } else {
                            fraction = 0.5
                        }
                        let overallProgress = 0.45 + (fraction * 0.10)
                        let downloadedStr = BundleBuildHelpers.formatBytes(bytesDownloaded)
                        let totalStr = total.map { BundleBuildHelpers.formatBytes($0) } ?? "?"
                        progressHandler?(overallProgress, "Downloading GFF3: \(downloadedStr) / \(totalStr)")
                    }
                    gffDestination = gffDest
                    logger.info("downloadAndBuild: GFF3 download complete")
                } catch {
                    logger.warning("downloadAndBuild: GFF3 download failed (non-fatal): \(error.localizedDescription)")
                }
            }
        } else {
            // --- No FTP paths: use NCBI Datasets API (downloads ZIP with FASTA + GFF3) ---
            logger.info("downloadAndBuild: No FTP paths available, using NCBI Datasets API for \(accession, privacy: .public)")
            progressHandler?(0.02, "Downloading via NCBI Datasets API...")

            let result = try await ncbiService.downloadViaDatasets(
                accession: accession,
                destination: tempDir
            ) { bytesDownloaded, expectedTotal in
                let fraction: Double
                if let total = expectedTotal, total > 0 {
                    fraction = Double(bytesDownloaded) / Double(total)
                } else {
                    fraction = min(Double(bytesDownloaded) / 500_000_000, 0.95)
                }
                let overallProgress = 0.02 + (fraction * 0.50)
                let downloadedStr = BundleBuildHelpers.formatBytes(bytesDownloaded)
                let totalStr = expectedTotal.map { BundleBuildHelpers.formatBytes($0) } ?? "?"
                progressHandler?(overallProgress, "Downloading: \(downloadedStr) / \(totalStr)")
            }

            fastaDestination = result.fastaURL
            gffDestination = result.gffURL
            // Datasets API returns uncompressed FASTA
            fastaIsGzipped = fastaDestination.pathExtension.lowercased() == "gz"
            logger.info("downloadAndBuild: Datasets API download complete (gzipped=\(fastaIsGzipped))")
        }

        // Step 5: Build bundle structure
        progressHandler?(0.55, "Creating bundle...")

        let bundleName = BundleBuildHelpers.sanitizedFilename("\(organismName) - \(assemblyName)")
        let bundleURL = BundleBuildHelpers.makeUniqueBundleURL(baseName: bundleName, in: outputDirectory)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let annotationsDir = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try fileManager.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: annotationsDir, withIntermediateDirectories: true)

        // Step 6: Get plain FASTA → re-compress with bgzip for random access
        // FTP downloads are standard gzip (.fna.gz); Datasets API may be uncompressed (.fna)
        let plainFASTA = genomeDir.appendingPathComponent("sequence.fa")
        if fastaIsGzipped {
            progressHandler?(0.56, "Decompressing FASTA...")
            logger.info("downloadAndBuild: Decompressing downloaded FASTA")

            let decompressResult = try await toolRunner.bgzipDecompress(inputPath: fastaDestination)
            guard decompressResult.isSuccess else {
                throw BundleBuildError.compressionFailed("bgzip decompress failed: \(decompressResult.combinedOutput)")
            }
            var decompressedFASTA = fastaDestination
            if decompressedFASTA.pathExtension.lowercased() == "gz" {
                decompressedFASTA = decompressedFASTA.deletingPathExtension()
            }
            try fileManager.moveItem(at: decompressedFASTA, to: plainFASTA)
        } else {
            progressHandler?(0.56, "Preparing FASTA...")
            try fileManager.moveItem(at: fastaDestination, to: plainFASTA)
        }

        // bgzip compress for random access
        progressHandler?(0.62, "Compressing FASTA (bgzip)...")
        logger.info("downloadAndBuild: bgzip compressing FASTA")

        let bgzipResult = try await toolRunner.bgzipCompress(inputPath: plainFASTA, keepOriginal: false)
        guard bgzipResult.isSuccess else {
            throw BundleBuildError.compressionFailed("bgzip failed: \(bgzipResult.combinedOutput)")
        }

        let compressedFASTA = genomeDir.appendingPathComponent("sequence.fa.gz")
        logger.info("downloadAndBuild: FASTA compressed successfully")

        // Step 7: Index FASTA (samtools faidx)
        progressHandler?(0.70, "Indexing FASTA (samtools faidx)...")
        logger.info("downloadAndBuild: Creating FASTA index")

        let faiResult = try await toolRunner.indexFASTA(fastaPath: compressedFASTA)
        guard faiResult.isSuccess else {
            throw BundleBuildError.indexingFailed("samtools faidx failed: \(faiResult.combinedOutput)")
        }

        let faiURL = compressedFASTA.appendingPathExtension("fai")
        let gziURL = compressedFASTA.appendingPathExtension("gzi")
        var chromosomes = try BundleBuildHelpers.parseFai(at: faiURL)
        let totalLength = chromosomes.reduce(Int64(0)) { $0 + $1.length }
        logger.info("downloadAndBuild: Indexed \(chromosomes.count) chromosomes, total \(totalLength) bp")

        // Step 7b: Download assembly report for chromosome aliases (non-fatal)
        var assemblyReportMetadata: [MetadataItem] = []
        var assemblyReportTempURL: URL?

        progressHandler?(0.72, "Downloading assembly report...")
        if let reportInfo = try? await ncbiService.getAssemblyReportInfo(for: assembly) {
            let reportDest = tempDir.appendingPathComponent(reportInfo.filename)
            do {
                _ = try await ncbiService.downloadGenomeFile(reportInfo, to: reportDest) { _, _ in }
                if let entries = try? BundleBuildHelpers.parseAssemblyReport(at: reportDest) {
                    chromosomes = BundleBuildHelpers.augmentChromosomesWithAssemblyReport(
                        chromosomes, report: entries
                    )
                    let aliasCount = chromosomes.filter { !$0.aliases.isEmpty }.count
                    logger.info("downloadAndBuild: Augmented \(aliasCount) chromosomes with assembly report aliases")
                }
                assemblyReportMetadata = (try? BundleBuildHelpers.parseAssemblyReportHeader(at: reportDest)) ?? []
                assemblyReportTempURL = reportDest
            } catch {
                logger.warning("downloadAndBuild: Assembly report download failed (non-fatal): \(error.localizedDescription)")
            }
        } else {
            logger.info("downloadAndBuild: No assembly report available")
        }

        // Step 8: Process GFF3 annotations directly to SQLite (no BigBed intermediate)
        let chromosomeSizes = chromosomes.map { ($0.name, $0.length) }
        var annotationTracks: [AnnotationTrackInfo] = []

        if let gffURL = gffDestination {
            progressHandler?(0.75, "Building annotation database...")
            logger.info("downloadAndBuild: Converting GFF3 annotations directly to SQLite")

            do {
                // Decompress GFF3 if gzipped
                var gffInput = gffURL
                if gffInput.pathExtension.lowercased() == "gz" {
                    let gffDecompressResult = try await toolRunner.bgzipDecompress(inputPath: gffInput)
                    if gffDecompressResult.isSuccess {
                        gffInput = gffInput.deletingPathExtension()
                    } else {
                        logger.warning("downloadAndBuild: GFF3 decompress failed, trying as-is")
                    }
                }

                // GFF3 → SQLite directly (no BED/BigBed intermediate)
                let dbURL = annotationsDir.appendingPathComponent("ncbi_genes.db")
                let dbRecordCount = try await AnnotationDatabase.createFromGFF3(
                    gffURL: gffInput,
                    outputURL: dbURL,
                    chromosomeSizes: chromosomeSizes
                )
                logger.info("downloadAndBuild: Created annotation database with \(dbRecordCount) records")

                annotationTracks.append(
                    AnnotationTrackInfo(
                        id: "ncbi_genes",
                        name: "Gene Annotations",
                        description: "GFF3 annotations from NCBI for \(assemblyName)",
                        path: "annotations/ncbi_genes.db",
                        databasePath: dbRecordCount > 0 ? "annotations/ncbi_genes.db" : nil,
                        annotationType: .gene,
                        featureCount: dbRecordCount,
                        source: "NCBI",
                        version: nil
                    )
                )
            } catch {
                logger.error("downloadAndBuild: Annotation conversion failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        // Step 9: Write manifest
        progressHandler?(0.93, "Writing bundle manifest...")

        let sourceInfo = SourceInfo(
            organism: organismName,
            commonName: nil,
            taxonomyId: assembly.taxid,
            assembly: assemblyName,
            assemblyAccession: assembly.assemblyAccession,
            database: "NCBI",
            sourceURL: URL(string: "https://www.ncbi.nlm.nih.gov/assembly/\(accession)"),
            downloadDate: Date(),
            notes: "Downloaded via Lungfish Genome Explorer"
        )

        let genomeInfo = GenomeInfo(
            path: "genome/sequence.fa.gz",
            indexPath: "genome/sequence.fa.gz.fai",
            gzipIndexPath: fileManager.fileExists(atPath: gziURL.path) ? "genome/sequence.fa.gz.gzi" : nil,
            totalLength: totalLength,
            chromosomes: chromosomes,
            md5Checksum: nil
        )

        let bundleIdentifier = "org.ncbi.assembly.\(accession.lowercased().replacingOccurrences(of: ".", with: "-"))"

        // Convert assembly summary to metadata groups for rich metadata storage
        var metadataGroups = assembly.toMetadataGroups()

        // Add assembly report metadata if available
        if !assemblyReportMetadata.isEmpty {
            metadataGroups.append(MetadataGroup(name: "Assembly Report", items: assemblyReportMetadata))
        }

        // Copy raw assembly report into bundle for Inspector and future use
        if let reportTempURL = assemblyReportTempURL {
            let bundleReportDest = bundleURL.appendingPathComponent("assembly_report.txt")
            try? fileManager.copyItem(at: reportTempURL, to: bundleReportDest)
        }

        let manifest = BundleManifest(
            name: "\(organismName) - \(assemblyName)",
            identifier: bundleIdentifier,
            description: "\(organismName) genome assembly \(assemblyName)",
            source: sourceInfo,
            genome: genomeInfo,
            annotations: annotationTracks,
            variants: [],
            tracks: [],
            metadata: metadataGroups.isEmpty ? nil : metadataGroups
        )

        let validationErrors = manifest.validate()
        if !validationErrors.isEmpty {
            throw BundleBuildError.validationFailed(validationErrors.map { $0.localizedDescription })
        }

        try manifest.save(to: bundleURL)

        progressHandler?(1.0, "Bundle ready: \(bundleURL.lastPathComponent)")
        logger.info("downloadAndBuild: Pipeline complete. Bundle at \(bundleURL.path, privacy: .public)")
        return bundleURL
    }
}
