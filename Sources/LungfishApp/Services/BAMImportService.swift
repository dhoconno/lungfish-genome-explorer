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
/// 1. Validates the alignment file exists and has an index
/// 2. Runs samtools idxstats to get per-chromosome statistics
/// 3. Runs samtools flagstat for QC metrics
/// 4. Parses @RG headers for read group/sample info
/// 5. Creates an `AlignmentMetadataDatabase` in the bundle's `alignments/` directory
/// 6. Creates an `AlignmentTrackInfo` sidecar and updates the manifest
///
/// The BAM/CRAM file itself is NOT copied into the bundle — it is referenced
/// by path with an optional security-scoped bookmark for file relocation.
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
        /// Whether the index was pre-existing or had to be created.
        public let indexWasCreated: Bool
        /// Whether the BAM file had to be coordinate-sorted before indexing.
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
        let format = detectFormat(bamURL)

        // 2. Validate index exists (or create it); may sort if unsorted
        let indexResult = try await ensureIndex(bamURL: bamURL, format: format, progressHandler: progressHandler)
        let effectiveBAMURL = indexResult.bamURL
        let indexPath = indexResult.indexPath
        let indexCreated = indexResult.wasCreated
        let wasSorted = indexResult.wasSorted
        progressHandler?(0.15, "Index validated.")

        // 3. Create alignments directory in bundle
        let alignmentsDir = bundleURL.appendingPathComponent("alignments")
        try FileManager.default.createDirectory(at: alignmentsDir, withIntermediateDirectories: true)

        // 4. Create data provider for stats collection
        let provider = AlignmentDataProvider(
            alignmentPath: effectiveBAMURL.path,
            indexPath: indexPath,
            format: format,
            referenceFastaPath: findReferenceFASTA(in: bundleURL)
        )

        // 5. Run samtools idxstats
        progressHandler?(0.2, "Collecting chromosome statistics...")
        let idxstatsOutput: String
        do {
            idxstatsOutput = try await provider.fetchIdxstats()
        } catch {
            throw BAMImportError.statsFailed(error.localizedDescription)
        }

        // 6. Run samtools flagstat
        progressHandler?(0.4, "Collecting alignment statistics...")
        let flagstatOutput: String
        do {
            flagstatOutput = try await provider.fetchFlagstat()
        } catch {
            throw BAMImportError.statsFailed(error.localizedDescription)
        }

        // 7. Parse header for read groups
        progressHandler?(0.6, "Parsing read group information...")
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
        progressHandler?(0.7, "Creating metadata database...")
        let trackId = "aln_\(UUID().uuidString.prefix(8))"
        let dbFileName = "\(trackId).stats.db"
        let dbURL = alignmentsDir.appendingPathComponent(dbFileName)

        let metadataDB = try AlignmentMetadataDatabase.create(at: dbURL)
        metadataDB.setFileInfo("source_path", value: effectiveBAMURL.path)
        if wasSorted {
            metadataDB.setFileInfo("original_source_path", value: bamURL.path)
        }
        metadataDB.setFileInfo("format", value: format.rawValue)
        metadataDB.setFileInfo("import_date", value: ISO8601DateFormatter().string(from: Date()))
        metadataDB.setFileInfo("file_name", value: fileName)

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

        // 10. Create bookmark for file relocation
        let bookmark: String?
        do {
            let bookmarkData = try effectiveBAMURL.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            bookmark = bookmarkData.base64EncodedString()
        } catch {
            importLogger.warning("Could not create bookmark for \(effectiveBAMURL.path): \(error)")
            bookmark = nil
        }

        let indexBookmark: String?
        do {
            let indexURL = URL(fileURLWithPath: indexPath)
            let bookmarkData = try indexURL.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            indexBookmark = bookmarkData.base64EncodedString()
        } catch {
            indexBookmark = nil
        }

        // 11. Create AlignmentTrackInfo
        progressHandler?(0.9, "Updating manifest...")
        let trackInfo = AlignmentTrackInfo(
            id: trackId,
            name: name ?? fileName,
            format: format,
            sourcePath: effectiveBAMURL.path,
            sourceBookmark: bookmark,
            indexPath: indexPath,
            indexBookmark: indexBookmark,
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

    /// Result of the index-ensuring step, which may also sort the BAM.
    private struct EnsureIndexResult {
        let bamURL: URL
        let indexPath: String
        let wasCreated: Bool
        let wasSorted: Bool
    }

    /// Ensures an index exists for the alignment file.
    ///
    /// If the BAM is not coordinate-sorted (detected when `samtools index` fails with
    /// "nsorted" in stderr), automatically creates a sorted copy and indexes that instead.
    private static func ensureIndex(
        bamURL: URL,
        format: AlignmentFormat,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> EnsureIndexResult {
        // Check for existing index
        let possibleIndexes: [String]
        switch format {
        case .bam:
            possibleIndexes = [
                bamURL.path + ".bai",
                bamURL.deletingPathExtension().path + ".bai",
                bamURL.path + ".csi"
            ]
        case .cram:
            possibleIndexes = [
                bamURL.path + ".crai"
            ]
        case .sam:
            throw BAMImportError.unsupportedFormat("SAM files must be converted to BAM before import")
        }

        for indexPath in possibleIndexes {
            if FileManager.default.fileExists(atPath: indexPath) {
                return EnsureIndexResult(bamURL: bamURL, indexPath: indexPath, wasCreated: false, wasSorted: false)
            }
        }

        // No index found — try to create one
        importLogger.info("No index found for \(bamURL.lastPathComponent), creating one...")
        progressHandler?(0.05, "Creating index (this may take a few minutes for large files)...")

        let runner = NativeToolRunner.shared
        let result = try await runner.run(.samtools, arguments: ["index", bamURL.path], timeout: 3600)

        if result.isSuccess {
            // Determine which index was created
            let expectedIndex = format == .cram ? bamURL.path + ".crai" : bamURL.path + ".bai"
            guard FileManager.default.fileExists(atPath: expectedIndex) else {
                throw BAMImportError.indexCreationFailed("Index file not found after creation")
            }
            return EnsureIndexResult(bamURL: bamURL, indexPath: expectedIndex, wasCreated: true, wasSorted: false)
        }

        // Index creation failed — check if the file is unsorted
        let isUnsorted = result.stderr.contains("nsorted") || result.stderr.contains("not coordinate sorted")
        guard isUnsorted else {
            throw BAMImportError.indexCreationFailed(result.stderr)
        }

        // File is unsorted — sort it first
        importLogger.info("BAM is unsorted, creating coordinate-sorted copy...")
        progressHandler?(0.05, "Sorting BAM file (this may take several minutes for large files)...")

        let sortedURL = sortedBAMURL(for: bamURL)

        // Dynamic timeout based on file size (same lesson as NativeToolRunner/bgzip)
        let fileSizeBytes: Int64 = (try? FileManager.default.attributesOfItem(atPath: bamURL.path))?[.size] as? Int64 ?? 0
        let sortTimeout = max(600, Double(fileSizeBytes) / 10_000_000)

        let sortResult = try await runner.run(
            .samtools,
            arguments: ["sort", "-o", sortedURL.path, bamURL.path],
            timeout: sortTimeout
        )

        guard sortResult.isSuccess else {
            throw BAMImportError.indexCreationFailed("Failed to sort BAM: \(sortResult.stderr)")
        }

        guard FileManager.default.fileExists(atPath: sortedURL.path) else {
            throw BAMImportError.indexCreationFailed("Sorted BAM file not found after sorting")
        }

        importLogger.info("Sorted BAM created at \(sortedURL.lastPathComponent), now indexing...")
        progressHandler?(0.10, "Indexing sorted BAM file...")

        let indexResult = try await runner.run(
            .samtools,
            arguments: ["index", sortedURL.path],
            timeout: 3600
        )

        guard indexResult.isSuccess else {
            throw BAMImportError.indexCreationFailed("Failed to index sorted BAM: \(indexResult.stderr)")
        }

        let sortedIndex = sortedURL.path + ".bai"
        guard FileManager.default.fileExists(atPath: sortedIndex) else {
            throw BAMImportError.indexCreationFailed("Index file not found after indexing sorted BAM")
        }

        importLogger.info("Sorted and indexed successfully: \(sortedURL.lastPathComponent)")
        return EnsureIndexResult(bamURL: sortedURL, indexPath: sortedIndex, wasCreated: true, wasSorted: true)
    }

    /// Computes the sorted BAM URL by inserting `.sorted` before the `.bam` extension.
    private static func sortedBAMURL(for bamURL: URL) -> URL {
        let dir = bamURL.deletingLastPathComponent()
        let stem = bamURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(stem).sorted.bam")
    }

    /// Finds the reference FASTA path within a bundle (needed for CRAM).
    private static func findReferenceFASTA(in bundleURL: URL) -> String? {
        let manifest = try? BundleManifest.load(from: bundleURL)
        guard let path = manifest?.genome.path else { return nil }
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
