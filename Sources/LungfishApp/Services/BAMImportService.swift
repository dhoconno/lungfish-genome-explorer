// BAMImportService.swift - Imports BAM/CRAM files into reference bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

/// Logger for BAM import operations
private let importLogger = Logger(subsystem: "com.lungfish.browser", category: "BAMImport")

// MARK: - BAMImportService

/// Service for importing BAM/CRAM alignment files into `.lungfishref` bundles.
///
/// The import process:
/// 1. Validates the alignment file exists
/// 2. Materializes a normalized, coordinate-sorted alignment copy inside `alignments/`
/// 3. Creates an index for the in-bundle alignment copy
/// 4. Runs samtools idxstats/flagstat and parses @RG headers
/// 5. Creates an `AlignmentMetadataDatabase` in the bundle's `alignments/` directory
/// 6. Creates an `AlignmentTrackInfo` sidecar and updates the manifest
///
/// Alignments are stored inside the bundle to ensure reproducible access and avoid
/// stale external path/bookmark issues.
public final class BAMImportService: @unchecked Sendable {

    // MARK: - Import Result

    /// Result of a BAM import operation.
    public struct ImportResult: Sendable {
        /// The alignment track info that was added to the manifest.
        public let trackInfo: AlignmentTrackInfo
        /// Total mapped reads.
        public let mappedReads: Int64
        /// Total unmapped reads.
        public let unmappedReads: Int64
        /// Sample names found in @RG headers.
        public let sampleNames: [String]
        /// Whether the in-bundle index file was created during import.
        public let indexWasCreated: Bool
        /// Whether a coordinate-sort step was performed during normalization.
        public let wasSorted: Bool
    }

    // MARK: - Import

    /// Imports a BAM/CRAM file into a bundle.
    ///
    /// - Parameters:
    ///   - bamURL: URL to the BAM/CRAM file
    ///   - bundleURL: URL to the `.lungfishref` bundle directory
    ///   - name: Display name for the alignment track (defaults to filename)
    ///   - progressHandler: Progress callback (0.0-1.0, status message)
    /// - Returns: Import result with track info and statistics
    /// - Throws: `BAMImportError` on failure
    public static func importBAM(
        bamURL: URL,
        bundleURL: URL,
        name: String? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ImportResult {
        let startTime = Date()
        let fileName = bamURL.lastPathComponent

        importLogger.info("Starting BAM import: \(fileName) into \(bundleURL.lastPathComponent)")
        progressHandler?(0.0, "Validating alignment file...")

        guard FileManager.default.fileExists(atPath: bamURL.path) else {
            throw BAMImportError.fileNotFound(bamURL.path)
        }

        // 1. Detect format
        let sourceFormat = detectFormat(bamURL)
        let trackId = "aln_\(UUID().uuidString.prefix(8))"

        // 2. Create alignments directory in bundle
        let alignmentsDir = bundleURL.appendingPathComponent("alignments")
        try FileManager.default.createDirectory(at: alignmentsDir, withIntermediateDirectories: true)

        // 3. Create sorted/indexed alignment copy in the bundle
        let materialized = try await materializeAlignmentIntoBundle(
            sourceURL: bamURL,
            sourceFormat: sourceFormat,
            bundleURL: bundleURL,
            alignmentsDir: alignmentsDir,
            trackId: trackId,
            progressHandler: progressHandler
        )
        let effectiveBAMURL = materialized.alignmentURL
        let indexPath = materialized.indexURL.path
        let format = materialized.format
        let indexCreated = materialized.indexWasCreated
        let wasSorted = materialized.wasSorted
        progressHandler?(0.20, "Alignment prepared.")

        // 4. Create data provider for stats collection
        let provider = AlignmentDataProvider(
            alignmentPath: effectiveBAMURL.path,
            indexPath: indexPath,
            format: format,
            referenceFastaPath: findReferenceFASTA(in: bundleURL)
        )

        // 5. Run samtools idxstats
        progressHandler?(0.25, "Collecting chromosome statistics...")
        let idxstatsOutput: String
        do {
            idxstatsOutput = try await provider.fetchIdxstats()
        } catch {
            throw BAMImportError.statsFailed(error.localizedDescription)
        }

        // 6. Run samtools flagstat
        progressHandler?(0.45, "Collecting alignment statistics...")
        let flagstatOutput: String
        do {
            flagstatOutput = try await provider.fetchFlagstat()
        } catch {
            throw BAMImportError.statsFailed(error.localizedDescription)
        }

        // 7. Parse header for read groups
        progressHandler?(0.62, "Parsing read group information...")
        let headerText: String
        do {
            headerText = try await provider.fetchHeader()
        } catch {
            throw BAMImportError.statsFailed(error.localizedDescription)
        }
        let readGroups = SAMParser.parseReadGroups(from: headerText)
        let sampleNames = Array(Set(readGroups.compactMap { $0.sample })).sorted()
        let programRecords = SAMParser.parseProgramRecords(from: headerText)
        let headerRecord = SAMParser.parseHeaderRecord(from: headerText)
        let refSeqCount = SAMParser.referenceSequenceCount(from: headerText)
        let refSequences = SAMParser.parseReferenceSequences(from: headerText)
        let inferredRef = ReferenceInference.infer(from: refSequences)

        // 8. Create metadata database
        progressHandler?(0.74, "Creating metadata database...")
        let dbFileName = "\(trackId).stats.db"
        let dbURL = alignmentsDir.appendingPathComponent(dbFileName)

        let metadataDB = try AlignmentMetadataDatabase.create(at: dbURL)
        metadataDB.setFileInfo("source_path", value: effectiveBAMURL.path)
        metadataDB.setFileInfo("source_path_in_bundle", value: "alignments/\(effectiveBAMURL.lastPathComponent)")
        metadataDB.setFileInfo("original_source_path", value: bamURL.path)
        metadataDB.setFileInfo("original_source_format", value: sourceFormat.rawValue)
        metadataDB.setFileInfo("format", value: format.rawValue)
        metadataDB.setFileInfo("import_date", value: ISO8601DateFormatter().string(from: Date()))
        metadataDB.setFileInfo("file_name", value: effectiveBAMURL.lastPathComponent)

        // Populate from samtools output
        metadataDB.populateFromIdxstats(idxstatsOutput)
        metadataDB.populateFromFlagstat(flagstatOutput)
        metadataDB.populateFromReadGroups(readGroups)
        metadataDB.populateFromProgramRecords(programRecords)

        // Store header metadata
        if let hd = headerRecord {
            if let ver = hd.version { metadataDB.setFileInfo("sam_version", value: ver) }
            if let so = hd.sortOrder { metadataDB.setFileInfo("sort_order", value: so) }
            if let go = hd.groupOrder { metadataDB.setFileInfo("group_order", value: go) }
        }
        metadataDB.setFileInfo("reference_sequence_count", value: "\(refSeqCount)")

        // Store reference inference results
        if let assembly = inferredRef.assembly {
            metadataDB.setFileInfo("inferred_assembly", value: assembly)
        }
        if let organism = inferredRef.organism {
            metadataDB.setFileInfo("inferred_organism", value: organism)
        }
        if let naming = inferredRef.namingConvention {
            metadataDB.setFileInfo("naming_convention", value: naming)
        }
        metadataDB.setFileInfo("inference_confidence", value: "\(inferredRef.confidence)")
        metadataDB.setFileInfo("genome_size", value: "\(inferredRef.totalLength)")

        if inferredRef.confidence >= .medium {
            importLogger.info("Reference inference: \(inferredRef.assembly ?? "unknown") (\(inferredRef.organism ?? "?")) confidence=\(String(describing: inferredRef.confidence))")
        }

        let mappedReads = metadataDB.totalMappedReads()
        let unmappedReads = metadataDB.totalUnmappedReads()

        metadataDB.setFileInfo("total_reads", value: "\(mappedReads + unmappedReads)")
        metadataDB.setFileInfo("mapped_reads", value: "\(mappedReads)")
        metadataDB.setFileInfo("unmapped_reads", value: "\(unmappedReads)")

        // Record import in provenance
        let duration = Date().timeIntervalSince(startTime)
        metadataDB.addProvenanceRecord(
            tool: "lungfish",
            subcommand: "import-bam",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            command: "import \(fileName)",
            inputFile: bamURL.path,
            outputFile: dbURL.path,
            exitCode: 0,
            duration: duration
        )

        // 9. Get file size for staleness detection
        let fileSize: Int64?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: effectiveBAMURL.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = nil
        }

        // 11. Create AlignmentTrackInfo
        progressHandler?(0.9, "Updating manifest...")
        let relativeSourcePath = "alignments/\(effectiveBAMURL.lastPathComponent)"
        let relativeIndexPath = "alignments/\(URL(fileURLWithPath: indexPath).lastPathComponent)"
        let trackInfo = AlignmentTrackInfo(
            id: trackId,
            name: name ?? fileName,
            format: format,
            sourcePath: relativeSourcePath,
            sourceBookmark: nil,
            indexPath: relativeIndexPath,
            indexBookmark: nil,
            metadataDBPath: "alignments/\(dbFileName)",
            fileSizeBytes: fileSize,
            addedDate: Date(),
            mappedReadCount: mappedReads,
            unmappedReadCount: unmappedReads,
            sampleNames: sampleNames
        )

        // 12. Update bundle manifest
        do {
            let manifest = try BundleManifest.load(from: bundleURL)
            let updatedManifest = manifest.addingAlignmentTrack(trackInfo)
            try updatedManifest.save(to: bundleURL)
        } catch {
            throw BAMImportError.manifestUpdateFailed(error.localizedDescription)
        }

        progressHandler?(1.0, "Import complete.")
        let sortedNote = wasSorted ? " (sorted)" : ""
        importLogger.info("BAM import complete\(sortedNote): \(mappedReads) mapped reads, \(sampleNames.count) samples, \(String(format: "%.1f", duration))s")

        return ImportResult(
            trackInfo: trackInfo,
            mappedReads: mappedReads,
            unmappedReads: unmappedReads,
            sampleNames: sampleNames,
            indexWasCreated: indexCreated,
            wasSorted: wasSorted
        )
    }

    // MARK: - Helpers

    /// Detects the alignment format from the file extension.
    private static func detectFormat(_ url: URL) -> AlignmentFormat {
        switch url.pathExtension.lowercased() {
        case "cram": return .cram
        case "sam": return .sam
        default: return .bam
        }
    }

    /// Result of alignment materialization into the bundle.
    private struct MaterializedAlignmentResult {
        let alignmentURL: URL
        let indexURL: URL
        let format: AlignmentFormat
        let indexWasCreated: Bool
        let wasSorted: Bool
    }

    /// Creates a normalized, sorted and indexed alignment file inside the bundle.
    ///
    /// All imported inputs are converted into an in-bundle coordinate-sorted alignment:
    /// - BAM -> sorted BAM + BAI/CSI
    /// - CRAM -> sorted CRAM + CRAI
    /// - SAM -> sorted BAM + BAI/CSI
    private static func materializeAlignmentIntoBundle(
        sourceURL: URL,
        sourceFormat: AlignmentFormat,
        bundleURL: URL,
        alignmentsDir: URL,
        trackId: String,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> MaterializedAlignmentResult {
        let outputFormat: AlignmentFormat
        let outputExt: String
        switch sourceFormat {
        case .sam:
            // Normalize SAM input to BAM for indexed random access.
            outputFormat = .bam
            outputExt = "bam"
        case .bam:
            outputFormat = .bam
            outputExt = "bam"
        case .cram:
            outputFormat = .cram
            outputExt = "cram"
        }

        let outputURL = alignmentsDir.appendingPathComponent("\(trackId).sorted.\(outputExt)")
        let runner = NativeToolRunner.shared
        let referenceFasta = findReferenceFASTA(in: bundleURL)
        if sourceFormat == .cram && referenceFasta == nil {
            throw BAMImportError.unsupportedFormat("CRAM import requires a reference FASTA in the target bundle")
        }

        progressHandler?(0.05, "Sorting alignment into bundle...")
        let inputSize = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64) ?? 0
        let sortTimeout = max(600, Double(inputSize) / 10_000_000)

        var sortArgs = ["sort"]
        if outputFormat == .cram {
            sortArgs += ["-O", "CRAM"]
        }
        sortArgs += ["-o", outputURL.path]
        if sourceFormat == .cram || outputFormat == .cram, let referenceFasta {
            sortArgs += ["--reference", referenceFasta]
        }
        sortArgs.append(sourceURL.path)

        let sortResult = try await runner.run(.samtools, arguments: sortArgs, timeout: sortTimeout)
        guard sortResult.isSuccess else {
            throw BAMImportError.indexCreationFailed("Failed to sort alignment: \(sortResult.stderr)")
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw BAMImportError.indexCreationFailed("Sorted alignment file not found after sorting")
        }

        progressHandler?(0.12, "Indexing sorted alignment...")
        var indexArgs = ["index", outputURL.path]
        if outputFormat == .cram, let referenceFasta {
            indexArgs = ["index", "--reference", referenceFasta, outputURL.path]
        }
        let indexResult = try await runner.run(.samtools, arguments: indexArgs, timeout: 3600)
        guard indexResult.isSuccess else {
            throw BAMImportError.indexCreationFailed("Failed to index sorted alignment: \(indexResult.stderr)")
        }

        let indexURL = try resolveCreatedIndexURL(alignmentURL: outputURL, format: outputFormat)
        return MaterializedAlignmentResult(
            alignmentURL: outputURL,
            indexURL: indexURL,
            format: outputFormat,
            indexWasCreated: true,
            wasSorted: true
        )
    }

    /// Resolves whichever index extension samtools created for the alignment.
    private static func resolveCreatedIndexURL(alignmentURL: URL, format: AlignmentFormat) throws -> URL {
        let candidates: [String]
        switch format {
        case .bam:
            candidates = [
                alignmentURL.path + ".bai",
                alignmentURL.deletingPathExtension().path + ".bai",
                alignmentURL.path + ".csi",
            ]
        case .cram:
            candidates = [
                alignmentURL.path + ".crai",
                alignmentURL.path + ".csi",
            ]
        case .sam:
            throw BAMImportError.unsupportedFormat("SAM output is not supported for indexed bundle tracks")
        }
        if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return URL(fileURLWithPath: existing)
        }
        throw BAMImportError.indexCreationFailed("Index file not found after creation for \(alignmentURL.lastPathComponent)")
    }

    /// Finds the reference FASTA path within a bundle (needed for CRAM).
    private static func findReferenceFASTA(in bundleURL: URL) -> String? {
        let manifest = try? BundleManifest.load(from: bundleURL)
        guard let path = manifest?.genome?.path else { return nil }
        let fastaURL = bundleURL.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: fastaURL.path) ? fastaURL.path : nil
    }
}

// MARK: - BAMImportError

/// Errors from BAM import operations.
public enum BAMImportError: Error, LocalizedError, Sendable {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case indexCreationFailed(String)
    case statsFailed(String)
    case manifestUpdateFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Alignment file not found: \(path)"
        case .unsupportedFormat(let msg):
            return "Unsupported format: \(msg)"
        case .indexCreationFailed(let msg):
            return "Failed to create index: \(msg)"
        case .statsFailed(let msg):
            return "Failed to collect statistics: \(msg)"
        case .manifestUpdateFailed(let msg):
            return "Failed to update manifest: \(msg)"
        }
    }
}
