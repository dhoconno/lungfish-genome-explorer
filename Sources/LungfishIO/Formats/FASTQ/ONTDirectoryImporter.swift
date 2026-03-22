// ONTDirectoryImporter.swift - Import ONT instrument output directories
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Compression
import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.io", category: "ONTDirectoryImporter")

// MARK: - ONT Read Header Parser

/// Parsed metadata from an Oxford Nanopore FASTQ read header.
///
/// ONT headers have the format:
/// ```
/// @readid runid=... ch=... start_time=... flow_cell_id=... sample_id=... barcode=...
/// ```
public struct ONTReadMetadata: Sendable, Equatable, Codable {
    public let readID: String
    public let runID: String?
    public let channel: Int?
    public let flowCellID: String?
    public let sampleID: String?
    public let barcode: String?
    public let barcodeAlias: String?
    public let basecallModel: String?
    public let protocolGroupID: String?
    public let basecallGPU: String?
}

public enum ONTReadHeaderParser {
    /// Parses an ONT read header line into structured metadata.
    ///
    /// - Parameter headerLine: The full header line (with or without leading `@`).
    /// - Returns: Parsed metadata, or `nil` if the line doesn't look like an ONT header.
    public static func parse(headerLine: String) -> ONTReadMetadata? {
        let line = headerLine.hasPrefix("@") ? String(headerLine.dropFirst()) : headerLine
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = tokens.first else { return nil }

        let readID = String(first)
        var fields: [String: String] = [:]

        for token in tokens.dropFirst() {
            guard let eqIdx = token.firstIndex(of: "=") else { continue }
            let key = String(token[token.startIndex..<eqIdx])
            let value = String(token[token.index(after: eqIdx)...])
            fields[key] = value
        }

        // Require at least one ONT-specific field to confirm this is ONT
        guard fields["runid"] != nil || fields["flow_cell_id"] != nil || fields["barcode"] != nil else {
            return nil
        }

        return ONTReadMetadata(
            readID: readID,
            runID: fields["runid"],
            channel: fields["ch"].flatMap { Int($0) },
            flowCellID: fields["flow_cell_id"],
            sampleID: fields["sample_id"],
            barcode: fields["barcode"],
            barcodeAlias: fields["barcode_alias"],
            basecallModel: fields["basecall_model_version_id"],
            protocolGroupID: fields["protocol_group_id"],
            basecallGPU: fields["basecall_gpu"]
        )
    }
}

// MARK: - ONT Directory Layout

/// Detected ONT output directory structure.
public struct ONTDirectoryLayout: Sendable {
    /// Root directory being scanned.
    public let rootDirectory: URL

    /// Detected barcode directories, sorted by name.
    public let barcodeDirectories: [ONTBarcodeDirectory]

    /// Whether an "unclassified" directory was found.
    public let hasUnclassified: Bool

    /// Total number of FASTQ chunk files across all barcodes.
    public var totalChunkCount: Int {
        barcodeDirectories.reduce(0) { $0 + $1.chunkFiles.count }
    }

    /// Total size of all chunk files in bytes.
    public var totalSizeBytes: Int64 {
        barcodeDirectories.reduce(0) { $0 + $1.totalSizeBytes }
    }
}

/// A single barcode directory within an ONT output.
public struct ONTBarcodeDirectory: Sendable {
    /// URL of the barcode directory.
    public let url: URL

    /// Barcode name (e.g., "barcode01", "unclassified").
    public let barcodeName: String

    /// Sorted list of .fastq.gz chunk files in this directory.
    public let chunkFiles: [URL]

    /// Total size of chunk files in bytes.
    public let totalSizeBytes: Int64

    /// Whether this is the "unclassified" directory.
    public var isUnclassified: Bool {
        barcodeName.lowercased() == "unclassified"
    }
}

// MARK: - ONT Import Configuration

/// Configuration for ONT directory import.
public struct ONTImportConfig: Sendable {
    /// Source directory (fastq_pass/ or a single barcode directory).
    public let sourceDirectory: URL

    /// Output directory where .lungfishfastq bundles will be created.
    public let outputDirectory: URL

    /// Maximum concurrent barcode concatenations.
    public let maxConcurrentBarcodes: Int

    /// Whether to include the "unclassified" directory.
    public let includeUnclassified: Bool

    /// When true, creates symlink-based bundles with `source-files.json` instead of
    /// byte-concatenating chunks into a single `reads.fastq.gz`. This avoids duplicating
    /// data and enables virtual concatenation for downstream operations.
    public let useVirtualConcatenation: Bool

    public init(
        sourceDirectory: URL,
        outputDirectory: URL,
        maxConcurrentBarcodes: Int = 4,
        includeUnclassified: Bool = false,
        useVirtualConcatenation: Bool = true
    ) {
        self.sourceDirectory = sourceDirectory
        self.outputDirectory = outputDirectory
        self.maxConcurrentBarcodes = maxConcurrentBarcodes
        self.includeUnclassified = includeUnclassified
        self.useVirtualConcatenation = useVirtualConcatenation
    }
}

// MARK: - ONT Import Result

/// Result of an ONT directory import.
public struct ONTImportResult: Sendable {
    /// Generated demultiplex manifest.
    public let manifest: DemultiplexManifest

    /// URLs of created .lungfishfastq bundles.
    public let bundleURLs: [URL]

    /// Flow cell ID extracted from read headers.
    public let flowCellID: String?

    /// Sample ID extracted from read headers.
    public let sampleID: String?

    /// Basecall model extracted from read headers.
    public let basecallModel: String?

    /// Total reads concatenated.
    public let totalReadCount: Int

    /// Wall clock time in seconds.
    public let wallClockSeconds: Double
}

// MARK: - ONT Import Error

public enum ONTImportError: Error, LocalizedError {
    case notONTDirectory(URL)
    case noBarcodesFound
    case concatenationFailed(barcode: String, underlying: Error)
    case readCountFailed(barcode: String)

    public var errorDescription: String? {
        switch self {
        case .notONTDirectory(let url):
            return "'\(url.lastPathComponent)' does not appear to be an ONT output directory"
        case .noBarcodesFound:
            return "No barcode directories found"
        case .concatenationFailed(let barcode, let error):
            return "Failed to concatenate \(barcode): \(error)"
        case .readCountFailed(let barcode):
            return "Failed to count reads for \(barcode)"
        }
    }
}

// MARK: - ONT Directory Importer

/// Imports ONT instrument output directories into per-barcode `.lungfishfastq` bundles.
///
/// ONT instruments (MinKNOW/Dorado) output reads split into chunks:
/// ```
/// fastq_pass/
///   barcode01/
///     FBC_pass_barcode01_hash_0.fastq.gz
///     FBC_pass_barcode01_hash_1.fastq.gz
///     ...
///   barcode02/
///     ...
///   unclassified/
///     ...
/// ```
///
/// This importer detects the layout, concatenates chunks per barcode into single
/// `.fastq.gz` files inside `.lungfishfastq` bundles, and generates a
/// `DemultiplexManifest`.
///
/// **Concatenation strategy:** Since each chunk is an individually valid gzip file,
/// byte-level concatenation produces a valid multi-member gzip archive without
/// decompressing or recompressing.
public final class ONTDirectoryImporter: @unchecked Sendable {

    public init() {}

    // MARK: - Layout Detection

    /// Detects the ONT directory layout at the given URL.
    ///
    /// Works for:
    /// - A `fastq_pass/` parent directory containing `barcode*` subdirectories
    /// - A directory containing `barcode*` subdirectories directly
    /// - A single `barcode*` directory with `.fastq.gz` files
    public func detectLayout(at url: URL) throws -> ONTDirectoryLayout {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ONTImportError.notONTDirectory(url)
        }

        // Check if this IS a single barcode directory
        let dirName = url.lastPathComponent.lowercased()
        if dirName.hasPrefix("barcode") || dirName == "unclassified" {
            let chunks = try listFASTQChunks(in: url)
            if !chunks.isEmpty {
                let totalSize = chunks.reduce(Int64(0)) { total, chunkURL in
                    total + fileSize(chunkURL)
                }
                let barcodeDir = ONTBarcodeDirectory(
                    url: url,
                    barcodeName: url.lastPathComponent,
                    chunkFiles: chunks,
                    totalSizeBytes: totalSize
                )
                return ONTDirectoryLayout(
                    rootDirectory: url.deletingLastPathComponent(),
                    barcodeDirectories: [barcodeDir],
                    hasUnclassified: barcodeDir.isUnclassified
                )
            }
        }

        // Scan subdirectories for barcode*/unclassified
        let contents = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var barcodeDirs: [ONTBarcodeDirectory] = []
        var hasUnclassified = false

        for subdir in contents {
            guard (try? subdir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let name = subdir.lastPathComponent.lowercased()
            guard name.hasPrefix("barcode") || name == "unclassified" else { continue }

            let chunks = try listFASTQChunks(in: subdir)
            guard !chunks.isEmpty else { continue }

            let totalSize = chunks.reduce(Int64(0)) { total, chunkURL in
                total + fileSize(chunkURL)
            }

            if name == "unclassified" { hasUnclassified = true }

            barcodeDirs.append(ONTBarcodeDirectory(
                url: subdir,
                barcodeName: subdir.lastPathComponent,
                chunkFiles: chunks,
                totalSizeBytes: totalSize
            ))
        }

        // No barcode subdirs found — check for FASTQ chunks directly in this directory
        if barcodeDirs.isEmpty {
            let directChunks = try listFASTQChunks(in: url)
            if !directChunks.isEmpty {
                let totalSize = directChunks.reduce(Int64(0)) { $0 + fileSize($1) }
                let dir = ONTBarcodeDirectory(
                    url: url,
                    barcodeName: url.lastPathComponent,
                    chunkFiles: directChunks,
                    totalSizeBytes: totalSize
                )
                return ONTDirectoryLayout(
                    rootDirectory: url.deletingLastPathComponent(),
                    barcodeDirectories: [dir],
                    hasUnclassified: false
                )
            }
        }

        guard !barcodeDirs.isEmpty else {
            throw ONTImportError.notONTDirectory(url)
        }

        // Sort by barcode name for deterministic ordering
        barcodeDirs.sort { $0.barcodeName.localizedStandardCompare($1.barcodeName) == .orderedAscending }

        return ONTDirectoryLayout(
            rootDirectory: url,
            barcodeDirectories: barcodeDirs,
            hasUnclassified: hasUnclassified
        )
    }

    // MARK: - Import

    /// Imports an ONT output directory into per-barcode `.lungfishfastq` bundles.
    ///
    /// - Parameters:
    ///   - config: Import configuration.
    ///   - progress: Progress callback (fraction 0-1, status message).
    /// - Returns: Import result with manifest and bundle URLs.
    public func importDirectory(
        config: ONTImportConfig,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ONTImportResult {
        let startTime = Date()
        progress(0.0, "Detecting ONT directory layout...")

        let layout = try detectLayout(at: config.sourceDirectory)
        let barcodesToImport = layout.barcodeDirectories.filter { dir in
            config.includeUnclassified || !dir.isUnclassified
        }

        guard !barcodesToImport.isEmpty else {
            throw ONTImportError.noBarcodesFound
        }

        let fm = FileManager.default
        try fm.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)

        // Extract ONT metadata from first read of first barcode
        let headerMetadata = extractHeaderMetadata(from: barcodesToImport[0])

        // Process barcodes with bounded concurrency
        let results = try await withThrowingTaskGroup(
            of: (Int, URL, Int, Int64).self
        ) { group in
            var activeTasks = 0
            var barcodeIndex = 0
            var collected: [(Int, URL, Int, Int64)] = []

            while barcodeIndex < barcodesToImport.count || activeTasks > 0 {
                while activeTasks < config.maxConcurrentBarcodes && barcodeIndex < barcodesToImport.count {
                    let barcodeDir = barcodesToImport[barcodeIndex]
                    let idx = barcodeIndex
                    barcodeIndex += 1
                    activeTasks += 1

                    let useVirtual = config.useVirtualConcatenation
                    group.addTask {
                        let (bundleURL, readCount, baseCount): (URL, Int, Int64)
                        if useVirtual {
                            (bundleURL, readCount, baseCount) = try await self.importBarcodeVirtual(
                                barcodeDir: barcodeDir,
                                outputDirectory: config.outputDirectory,
                                progress: { msg in
                                    progress(
                                        Double(idx) / Double(barcodesToImport.count),
                                        "\(barcodeDir.barcodeName): \(msg)"
                                    )
                                }
                            )
                        } else {
                            (bundleURL, readCount, baseCount) = try await self.importBarcode(
                                barcodeDir: barcodeDir,
                                outputDirectory: config.outputDirectory,
                                progress: { msg in
                                    progress(
                                        Double(idx) / Double(barcodesToImport.count),
                                        "\(barcodeDir.barcodeName): \(msg)"
                                    )
                                }
                            )
                        }
                        return (idx, bundleURL, readCount, baseCount)
                    }
                }

                if let result = try await group.next() {
                    collected.append(result)
                    activeTasks -= 1

                    progress(
                        Double(collected.count) / Double(barcodesToImport.count),
                        "Completed \(collected.count)/\(barcodesToImport.count) barcodes"
                    )
                }
            }

            return collected
        }

        // Sort by original index
        let sorted = results.sorted { $0.0 < $1.0 }

        // Build BarcodeResult entries
        var barcodeResults: [BarcodeResult] = []
        var bundleURLs: [URL] = []
        var totalReadCount = 0

        for (_, bundleURL, readCount, baseCount) in sorted {
            let barcodeName = bundleURL.deletingPathExtension().lastPathComponent
            barcodeResults.append(BarcodeResult(
                barcodeID: barcodeName,
                readCount: readCount,
                baseCount: baseCount,
                bundleRelativePath: bundleURL.lastPathComponent
            ))
            bundleURLs.append(bundleURL)
            totalReadCount += readCount
        }

        // Build manifest
        let manifest = DemultiplexManifest(
            barcodeKit: BarcodeKit(
                name: "ONT Native Barcoding",
                vendor: "oxford_nanopore",
                barcodeCount: barcodeResults.count,
                barcodeType: .symmetric
            ),
            parameters: DemultiplexParameters(
                tool: "ont-directory-import",
                wallClockSeconds: Date().timeIntervalSince(startTime)
            ),
            barcodes: barcodeResults,
            unassigned: UnassignedReadsSummary(readCount: 0, baseCount: 0, disposition: .discard),
            outputDirectoryRelativePath: ".",
            inputReadCount: totalReadCount
        )

        try manifest.save(to: config.outputDirectory)

        let elapsed = Date().timeIntervalSince(startTime)
        progress(1.0, "Import complete (\(totalReadCount) reads, \(String(format: "%.1f", elapsed))s)")

        logger.info("ONT import: \(barcodesToImport.count) barcodes, \(totalReadCount) reads in \(String(format: "%.1f", elapsed))s")

        return ONTImportResult(
            manifest: manifest,
            bundleURLs: bundleURLs,
            flowCellID: headerMetadata?.flowCellID,
            sampleID: headerMetadata?.sampleID,
            basecallModel: headerMetadata?.basecallModel,
            totalReadCount: totalReadCount,
            wallClockSeconds: elapsed
        )
    }

    // MARK: - Per-Barcode Import

    /// Imports a single barcode directory: concatenates chunks, creates bundle.
    private func importBarcode(
        barcodeDir: ONTBarcodeDirectory,
        outputDirectory: URL,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> (URL, Int, Int64) {
        let bundleName = "\(barcodeDir.barcodeName).\(FASTQBundle.directoryExtension)"
        let bundleURL = outputDirectory.appendingPathComponent(bundleName, isDirectory: true)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            let outputFASTQ = bundleURL.appendingPathComponent("reads.fastq.gz")

            progress("Concatenating \(barcodeDir.chunkFiles.count) chunks...")

            // Byte-level concatenation: each chunk is a valid gzip member.
            // Concatenation of gzip members produces a valid gzip stream.
            fm.createFile(atPath: outputFASTQ.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: outputFASTQ)
            defer { try? outputHandle.close() }

            var totalBytesWritten: Int64 = 0

            for (i, chunk) in barcodeDir.chunkFiles.enumerated() {
                try Task.checkCancellation()

                let inputHandle = try FileHandle(forReadingFrom: chunk)
                defer { try? inputHandle.close() }

                // Stream in 4 MB blocks to avoid memory pressure
                let blockSize = 4 * 1024 * 1024
                while true {
                    let data = inputHandle.readData(ofLength: blockSize)
                    if data.isEmpty { break }
                    outputHandle.write(data)
                    totalBytesWritten += Int64(data.count)
                }

                if (i + 1) % 5 == 0 || i == barcodeDir.chunkFiles.count - 1 {
                    progress("Concatenated \(i + 1)/\(barcodeDir.chunkFiles.count) chunks")
                }
            }

            // Close output before reading for count
            try outputHandle.close()

            // Count reads in the concatenated file
            progress("Counting reads...")
            let readCount = try countReadsInFASTQ(url: outputFASTQ)

            // Estimate base count (compressed bytes × ~1.5 accounts for FASTQ overhead)
            let baseCount = Int64(Double(totalBytesWritten) * 1.5)

            logger.info("Imported \(barcodeDir.barcodeName): \(readCount) reads, \(totalBytesWritten) bytes")

            return (bundleURL, readCount, baseCount)
        } catch {
            // Clean up partial bundle on failure
            try? fm.removeItem(at: bundleURL)
            throw ONTImportError.concatenationFailed(
                barcode: barcodeDir.barcodeName,
                underlying: error
            )
        }
    }

    // MARK: - Virtual Per-Barcode Import

    /// Imports a single barcode directory using symlinks (no byte concatenation).
    ///
    /// Creates a `.lungfishfastq` bundle with symlinks to the original chunk files
    /// and a `source-files.json` manifest listing them in order. This avoids
    /// duplicating data while enabling virtual concatenation for downstream operations.
    private func importBarcodeVirtual(
        barcodeDir: ONTBarcodeDirectory,
        outputDirectory: URL,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> (URL, Int, Int64) {
        let bundleName = "\(barcodeDir.barcodeName).\(FASTQBundle.directoryExtension)"
        let bundleURL = outputDirectory.appendingPathComponent(bundleName, isDirectory: true)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            let chunksDir = bundleURL.appendingPathComponent("chunks", isDirectory: true)
            try fm.createDirectory(at: chunksDir, withIntermediateDirectories: true)

            progress("Copying \(barcodeDir.chunkFiles.count) chunks...")

            // Copy chunk files and build manifest entries
            var entries: [FASTQSourceFileManifest.SourceFileEntry] = []
            for (i, chunk) in barcodeDir.chunkFiles.enumerated() {
                try Task.checkCancellation()
                let chunkName = chunk.lastPathComponent
                let destURL = chunksDir.appendingPathComponent(chunkName)
                try fm.copyItem(at: chunk, to: destURL)

                entries.append(FASTQSourceFileManifest.SourceFileEntry(
                    filename: "chunks/\(chunkName)",
                    originalPath: chunk.path,
                    sizeBytes: fileSize(chunk),
                    isSymlink: false
                ))

                if (i + 1) % 5 == 0 || i == barcodeDir.chunkFiles.count - 1 {
                    progress("Copied \(i + 1)/\(barcodeDir.chunkFiles.count) chunks")
                }
            }

            // Write source file manifest
            let manifest = FASTQSourceFileManifest(files: entries)
            try manifest.save(to: bundleURL)

            progress("Counting reads across \(barcodeDir.chunkFiles.count) chunks...")

            // Count reads across all chunks
            var totalReads = 0
            var totalBaseEstimate: Int64 = 0
            for chunk in barcodeDir.chunkFiles {
                try Task.checkCancellation()
                let count = try countReadsInFASTQ(url: chunk)
                totalReads += count
                totalBaseEstimate += Int64(Double(fileSize(chunk)) * 1.5)
            }

            // Generate preview.fastq from the first chunk (first 1000 reads)
            progress("Generating preview...")
            let previewURL = bundleURL.appendingPathComponent("preview.fastq")
            try await generatePreview(
                fromChunks: barcodeDir.chunkFiles,
                to: previewURL,
                maxReads: 1000
            )

            logger.info("Virtual import \(barcodeDir.barcodeName): \(totalReads) reads, \(entries.count) chunks")

            return (bundleURL, totalReads, totalBaseEstimate)
        } catch {
            try? fm.removeItem(at: bundleURL)
            throw ONTImportError.concatenationFailed(
                barcode: barcodeDir.barcodeName,
                underlying: error
            )
        }
    }

    // MARK: - Helpers

    /// Generates a preview FASTQ from the first N reads across chunk files.
    private func generatePreview(
        fromChunks chunks: [URL],
        to outputURL: URL,
        maxReads: Int
    ) async throws {
        var previewLines: [String] = []
        previewLines.reserveCapacity(maxReads * 4)
        var readsCollected = 0
        var lineBuffer: [String] = []
        lineBuffer.reserveCapacity(4)

        outer: for chunk in chunks {
            for try await line in chunk.linesAutoDecompressing() {
                if line.isEmpty && lineBuffer.isEmpty { continue }
                lineBuffer.append(line)
                guard lineBuffer.count == 4 else { continue }

                previewLines.append(contentsOf: lineBuffer)
                lineBuffer.removeAll(keepingCapacity: true)
                readsCollected += 1
                if readsCollected >= maxReads { break outer }
            }
            lineBuffer.removeAll(keepingCapacity: true)
        }

        let content = previewLines.joined(separator: "\n") + (previewLines.isEmpty ? "" : "\n")
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    /// Lists .fastq.gz and .fastq files in a directory, sorted by name.
    private func listFASTQChunks(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return contents
            .filter { url in
                let name = url.lastPathComponent.lowercased()
                return name.hasSuffix(".fastq.gz") || name.hasSuffix(".fq.gz")
                    || name.hasSuffix(".fastq") || name.hasSuffix(".fq")
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Returns the file size in bytes, or 0 on failure.
    private func fileSize(_ url: URL) -> Int64 {
        url.fileSizeBytes
    }

    /// Extracts ONT metadata from the first read of the first chunk in a barcode directory.
    private func extractHeaderMetadata(from barcodeDir: ONTBarcodeDirectory) -> ONTReadMetadata? {
        guard let firstChunk = barcodeDir.chunkFiles.first else { return nil }

        // Read just enough to get the first header line
        guard let handle = try? FileHandle(forReadingFrom: firstChunk) else { return nil }
        defer { try? handle.close() }

        let headerData = handle.readData(ofLength: 16384)

        // Check for gzip magic bytes and decompress if needed
        if headerData.count >= 2, headerData[0] == 0x1F, headerData[1] == 0x8B {
            // Gzipped — decompress a small chunk to get the header
            guard let decompressed = decompressGzipPrefix(data: headerData) else { return nil }
            guard let headerLine = String(data: decompressed, encoding: .utf8)?
                .components(separatedBy: .newlines)
                .first else { return nil }
            return ONTReadHeaderParser.parse(headerLine: headerLine)
        } else {
            // Plain text
            guard let headerLine = String(data: headerData, encoding: .utf8)?
                .components(separatedBy: .newlines)
                .first else { return nil }
            return ONTReadHeaderParser.parse(headerLine: headerLine)
        }
    }

    /// Decompresses the beginning of a gzip stream using Apple's Compression framework.
    private func decompressGzipPrefix(data: Data) -> Data? {
        // Skip gzip header (10-byte minimum: magic + method + flags + mtime + xfl + os)
        guard data.count > 10 else { return nil }
        var offset = 10
        let flags = data[3]
        // FEXTRA
        if flags & 0x04 != 0, data.count > offset + 2 {
            let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + xlen
        }
        // FNAME
        if flags & 0x08 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        // FCOMMENT
        if flags & 0x10 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        // FHCRC
        if flags & 0x02 != 0 { offset += 2 }

        guard offset < data.count else { return nil }

        // Decompress raw DEFLATE stream
        let compressed = data.subdata(in: offset..<data.count)
        let bufferSize = 8192
        var output = Data(count: bufferSize)
        let decompressedSize: Int = compressed.withUnsafeBytes { (srcBuffer: UnsafeRawBufferPointer) -> Int in
            output.withUnsafeMutableBytes { (dstBuffer: UnsafeMutableRawBufferPointer) -> Int in
                guard let src = srcBuffer.baseAddress, let dst = dstBuffer.baseAddress else { return 0 }
                return compression_decode_buffer(
                    dst.assumingMemoryBound(to: UInt8.self), bufferSize,
                    src.assumingMemoryBound(to: UInt8.self), compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decompressedSize > 0 else { return nil }
        return output.prefix(decompressedSize)
    }

    /// Counts FASTQ reads by counting lines and dividing by 4.
    ///
    /// Handles both gzip-compressed and uncompressed FASTQ files.
    /// For gzip files, uses `gzcat` for decompression. For plain text, uses `wc -l` directly.
    private func countReadsInFASTQ(url: URL) throws -> Int {
        let isGzipped = url.pathExtension.lowercased() == "gz"

        let wcProcess = Process()
        wcProcess.executableURL = URL(fileURLWithPath: "/usr/bin/wc")
        wcProcess.arguments = ["-l"]

        let outputPipe = Pipe()
        wcProcess.standardOutput = outputPipe
        wcProcess.standardError = FileHandle.nullDevice

        var decompressProcess: Process?

        if isGzipped {
            let gzcat = Process()
            gzcat.executableURL = URL(fileURLWithPath: "/usr/bin/gzcat")
            gzcat.arguments = [url.path]
            gzcat.standardError = FileHandle.nullDevice

            let interPipe = Pipe()
            gzcat.standardOutput = interPipe
            wcProcess.standardInput = interPipe

            try gzcat.run()
            decompressProcess = gzcat
        } else {
            let inputPipe = Pipe()
            wcProcess.standardInput = inputPipe
            // Feed file content to wc via pipe
            let inputHandle = try FileHandle(forReadingFrom: url)
            inputPipe.fileHandleForWriting.writeabilityHandler = { handle in
                let data = inputHandle.readData(ofLength: 4 * 1024 * 1024)
                if data.isEmpty {
                    handle.writeabilityHandler = nil
                    handle.closeFile()
                    try? inputHandle.close()
                } else {
                    handle.write(data)
                }
            }
        }

        try wcProcess.run()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        decompressProcess?.waitUntilExit()
        wcProcess.waitUntilExit()

        if let dp = decompressProcess, dp.terminationStatus != 0 {
            logger.warning("gzcat failed for \(url.lastPathComponent) with exit code \(dp.terminationStatus)")
            return 0
        }

        if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let lineCount = Int(str) {
            return lineCount / 4  // 4 lines per FASTQ record
        }

        return 0
    }
}
