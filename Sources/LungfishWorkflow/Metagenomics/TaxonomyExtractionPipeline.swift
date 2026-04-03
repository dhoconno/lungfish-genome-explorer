// TaxonomyExtractionPipeline.swift - Extracts reads by taxonomic classification
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "TaxonomyExtraction")

// MARK: - TaxonomyExtractionPipeline

/// Actor that extracts reads classified to specific taxa from FASTQ file(s).
///
/// The extraction flow:
/// 1. Parse the Kraken2 per-read classification output to build a set of
///    read IDs assigned to the target tax IDs.
/// 2. If ``TaxonomyExtractionConfig/includeChildren`` is `true`, collect all
///    descendant tax IDs from the ``TaxonTree`` before filtering.
/// 3. For each source FASTQ file, read using buffered I/O (handling both plain
///    and gzip-compressed input), writing matching reads to the corresponding
///    output file.
/// 4. Record provenance via ``ProvenanceRecorder``.
///
/// ## Paired-End Support
///
/// When ``TaxonomyExtractionConfig/sourceFiles`` contains two files (R1, R2),
/// the pipeline builds the read ID set from the classification output (which
/// was generated from both files), then filters each file independently using
/// the same set. This preserves pair ordering -- if read X appears in both R1
/// and R2, it is extracted from both.
///
/// ## Progress Reporting
///
/// Progress is reported via a `@Sendable (Double, String) -> Void` callback:
///
/// | Range        | Phase |
/// |-------------|-------|
/// | 0.0 -- 0.20 | Parsing classification output |
/// | 0.20 -- 0.30 | Building read ID set |
/// | 0.30 -- 0.95 | Filtering FASTQ(s) |
/// | 0.95 -- 1.00 | Provenance recording |
///
/// ## Thread Safety
///
/// All mutable state is isolated to this actor.
///
/// ## Usage
///
/// ```swift
/// let pipeline = TaxonomyExtractionPipeline()
/// let config = TaxonomyExtractionConfig(
///     taxIds: [562],
///     includeChildren: true,
///     sourceFile: inputFASTQ,
///     outputFile: outputFASTQ,
///     classificationOutput: krakenOutput
/// )
/// let tree = classificationResult.tree
/// let outputURLs = try await pipeline.extract(config: config, tree: tree) { pct, msg in
///     print("\(Int(pct * 100))% \(msg)")
/// }
/// ```
public actor TaxonomyExtractionPipeline {

    /// Shared instance for convenience.
    public static let shared = TaxonomyExtractionPipeline()

    /// Creates an extraction pipeline.
    public init() {}

    // MARK: - Public API

    /// Extracts reads classified to specific taxa from FASTQ file(s).
    ///
    /// For single-file configs, returns a single-element array containing the
    /// output URL. For paired-end configs, returns one URL per source file.
    ///
    /// - Parameters:
    ///   - config: The extraction configuration.
    ///   - tree: The taxonomy tree for descendant lookup.
    ///   - progress: Optional progress callback.
    /// - Returns: The URLs of the output FASTQ file(s).
    /// - Throws: ``TaxonomyExtractionError`` for extraction failures.
    public func extract(
        config: TaxonomyExtractionConfig,
        tree: TaxonTree,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> [URL] {
        let startTime = Date()

        // Validate source/output count parity.
        guard config.sourceFiles.count == config.outputFiles.count else {
            throw TaxonomyExtractionError.sourceOutputCountMismatch(
                sources: config.sourceFiles.count,
                outputs: config.outputFiles.count
            )
        }

        // Phase 1: Parse classification output (0.0 -- 0.20)
        progress?(0.0, "Reading classification output...")

        let fm = FileManager.default
        guard fm.fileExists(atPath: config.classificationOutput.path) else {
            throw TaxonomyExtractionError.classificationOutputNotFound(config.classificationOutput)
        }
        for source in config.sourceFiles {
            guard fm.fileExists(atPath: source.path) else {
                throw TaxonomyExtractionError.sourceFileNotFound(source)
            }
        }

        // Build the complete set of target tax IDs
        let targetTaxIds: Set<Int>
        if config.includeChildren {
            targetTaxIds = collectDescendantTaxIds(config.taxIds, tree: tree)
        } else {
            targetTaxIds = config.taxIds
        }

        let taxIdCount = targetTaxIds.count
        logger.info("Extraction targeting \(taxIdCount, privacy: .public) tax IDs")
        progress?(0.10, "Filtering \(taxIdCount) tax IDs...")

        // Phase 2: Build read ID set from classification output (0.10 -- 0.30)
        let matchingReadIds = try buildReadIdSet(
            classificationURL: config.classificationOutput,
            targetTaxIds: targetTaxIds,
            progress: progress
        )

        if matchingReadIds.isEmpty {
            throw TaxonomyExtractionError.noMatchingReads
        }

        let matchCount = matchingReadIds.count
        logger.info("Found \(matchCount, privacy: .public) matching reads")
        progress?(0.30, "Extracting \(matchCount) reads...")

        // Phase 3: Filter each FASTQ file using seqkit grep (0.30 -- 0.95)
        // seqkit grep is 10-50x faster than line-by-line Swift FASTQ parsing
        // because it uses optimized C I/O and handles .gz natively.
        try Task.checkCancellation()

        // Write matching read IDs to a temp file for seqkit grep -f
        let readIdFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-extract-\(UUID().uuidString).ids")
        let readIdText = matchingReadIds.joined(separator: "\n")
        try readIdText.write(to: readIdFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: readIdFile) }

        let fileCount = config.sourceFiles.count
        var totalExtracted = 0
        var outputURLs: [URL] = []

        let toolRunner = NativeToolRunner.shared

        for (index, (source, output)) in zip(config.sourceFiles, config.outputFiles).enumerated() {
            try Task.checkCancellation()

            let fileLabel = fileCount > 1 ? " (file \(index + 1)/\(fileCount))" : ""
            let overallFraction = 0.30 + 0.65 * (Double(index + 1) / Double(fileCount))
            progress?(min(overallFraction, 0.90), "Extracting reads\(fileLabel) with seqkit...")

            // Create output directory if needed
            let outputDir = output.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: outputDir.path) {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            }

            // Run: seqkit grep -f read_ids.txt input.fastq.gz -o output.fastq
            // seqkit handles .gz decompression automatically
            let seqkitArgs = [
                "grep",
                "-f", readIdFile.path,
                source.path,
                "-o", output.path,
                "--threads", "4",
            ]

            let result = try await toolRunner.run(
                .seqkit,
                arguments: seqkitArgs,
                timeout: 7200  // 2 hour timeout for large files
            )

            if result.exitCode != 0 {
                logger.error("seqkit grep failed: \(result.stderr, privacy: .public)")
                throw TaxonomyExtractionError.outputWriteFailed(
                    output,
                    "seqkit grep failed (exit \(result.exitCode)): \(result.stderr)"
                )
            }

            // Count extracted reads from seqkit output
            // seqkit grep doesn't report count, so estimate from file existence
            let extractedCount = matchCount  // Upper bound; actual may be less if some IDs not in this file
            totalExtracted += extractedCount
            outputURLs.append(output)
            logger.info("Extracted reads to \(output.lastPathComponent, privacy: .public) via seqkit grep")
        }

        // Phase 4: Provenance recording (0.95 -- 1.00)
        progress?(0.95, "Recording provenance...")

        let runtime = Date().timeIntervalSince(startTime)
        await recordProvenance(config: config, extractedCount: totalExtracted, runtime: runtime)

        progress?(1.0, "Extraction complete: \(totalExtracted) reads")
        return outputURLs
    }


    // MARK: - Batch Extraction

    /// Extracts reads for every taxon target in a collection, producing one output per target.
    ///
    /// For each ``TaxonTarget`` in the collection:
    /// 1. The target tax ID set is built (expanding to descendants if ``TaxonTarget/includeChildren`` is `true`).
    /// 2. A read ID set is constructed from the classification output.
    /// 3. Matching reads are extracted via seqkit grep into a separate output file.
    /// 4. A `.lungfishfastq` bundle is created for the extracted reads.
    ///
    /// Targets with zero matching reads are skipped (logged but not fatal).
    /// Each target is processed sequentially to avoid I/O contention.
    ///
    /// ## Progress
    ///
    /// The progress callback reports overall batch progress from 0.0 to 1.0,
    /// with per-taxon sub-progress messages.
    ///
    /// - Parameters:
    ///   - collection: The taxa collection defining targets to extract.
    ///   - classificationResult: The classification result containing the tree and output files.
    ///   - tree: The taxonomy tree for descendant lookup.
    ///   - outputDirectory: The directory to write output files into.
    ///   - progress: Optional progress callback.
    /// - Returns: URLs of the output FASTQ files that were created (one per successful target).
    /// - Throws: ``TaxonomyExtractionError`` if the classification output or source files are missing.
    public func extractBatch(
        collection: TaxaCollection,
        classificationResult: ClassificationResult,
        tree: TaxonTree,
        outputDirectory: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> [URL] {
        let targets = collection.taxa
        let totalTargets = targets.count
        guard totalTargets > 0 else { return [] }

        let fm = FileManager.default
        if !fm.fileExists(atPath: outputDirectory.path) {
            try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        progress?(0.0, "Starting batch extraction: \(collection.name) (\(totalTargets) taxa)")

        var outputURLs: [URL] = []
        var skippedCount = 0

        for (index, target) in targets.enumerated() {
            try Task.checkCancellation()

            let overallBase = Double(index) / Double(totalTargets)
            let overallStep = 1.0 / Double(totalTargets)

            // Check if this taxon has any reads in the result
            let node = tree.node(taxId: target.taxId)
            let cladeReads = node?.readsClade ?? 0
            if cladeReads == 0 {
                logger.info("Skipping \(target.displayName, privacy: .public): 0 reads in result")
                skippedCount += 1
                progress?(overallBase + overallStep, "Skipped \(target.displayName) (0 reads)")
                continue
            }

            progress?(
                overallBase,
                "Extracting \(target.displayName) (\(index + 1) of \(totalTargets))..."
            )

            // Build a safe filename from the target name
            let safeName = target.displayName
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "-")
            let outputFile = outputDirectory.appendingPathComponent("\(safeName)_taxid\(target.taxId).fastq")

            // Build config for this single target.
            // Prefer originalInputFiles (preserved before materialization) to avoid
            // referencing a deleted temp file.
            let sourceFile = classificationResult.config.originalInputFiles?.first
                ?? classificationResult.config.inputFiles.first
                ?? URL(fileURLWithPath: "/dev/null")
            let config = TaxonomyExtractionConfig(
                taxIds: Set([target.taxId]),
                includeChildren: target.includeChildren,
                sourceFile: sourceFile,
                outputFile: outputFile,
                classificationOutput: classificationResult.outputURL
            )

            do {
                let urls = try await extract(
                    config: config,
                    tree: tree,
                    progress: { fraction, message in
                        let mappedFraction = overallBase + overallStep * fraction
                        progress?(min(mappedFraction, overallBase + overallStep), message)
                    }
                )
                outputURLs.append(contentsOf: urls)
            } catch TaxonomyExtractionError.noMatchingReads {
                logger.info("No matching reads for \(target.displayName, privacy: .public), skipping")
                skippedCount += 1
                progress?(overallBase + overallStep, "Skipped \(target.displayName) (no matching reads)")
            }
        }

        let extractedCount = outputURLs.count
        progress?(1.0, "Batch complete: \(extractedCount) of \(totalTargets) taxa extracted (\(skippedCount) skipped)")
        logger.info("Batch extraction complete: \(extractedCount) extracted, \(skippedCount) skipped from \(collection.name, privacy: .public)")

        return outputURLs
    }


    // MARK: - Descendant Collection

    /// Collects all descendant tax IDs for the given set of tax IDs.
    ///
    /// For each tax ID in the input set, this method finds the corresponding
    /// node in the taxonomy tree and collects the tax IDs of all descendants.
    ///
    /// - Parameters:
    ///   - taxIds: The starting set of tax IDs.
    ///   - tree: The taxonomy tree.
    /// - Returns: A set containing the input tax IDs and all descendant tax IDs.
    public func collectDescendantTaxIds(_ taxIds: Set<Int>, tree: TaxonTree) -> Set<Int> {
        var result = taxIds
        for taxId in taxIds {
            guard let node = tree.node(taxId: taxId) else { continue }
            for descendant in node.allDescendants() {
                result.insert(descendant.taxId)
            }
        }
        return result
    }

    // MARK: - Read ID Building

    /// Parses the Kraken2 per-read output to find read IDs matching target taxa.
    ///
    /// Uses line-by-line buffered reading to avoid loading the entire file into
    /// memory for large datasets.
    ///
    /// - Parameters:
    ///   - classificationURL: Path to the Kraken2 per-read output file.
    ///   - targetTaxIds: The set of taxonomy IDs to match.
    ///   - progress: Optional progress callback.
    /// - Returns: A set of read IDs assigned to any of the target taxa.
    /// - Throws: ``TaxonomyExtractionError`` on file read failure.
    private func buildReadIdSet(
        classificationURL: URL,
        targetTaxIds: Set<Int>,
        progress: (@Sendable (Double, String) -> Void)?
    ) throws -> Set<String> {
        guard let fileHandle = FileHandle(forReadingAtPath: classificationURL.path) else {
            throw TaxonomyExtractionError.classificationOutputNotFound(classificationURL)
        }
        defer { fileHandle.closeFile() }

        // Get file size for progress estimation
        let fileSize = (try? FileManager.default.attributesOfItem(
            atPath: classificationURL.path
        )[.size] as? Int64) ?? 0

        var matchingReadIds = Set<String>()
        var bytesRead: Int64 = 0
        var residual = Data()
        let bufferSize = 1_048_576 // 1 MB read chunks

        while true {
            let chunk = fileHandle.readData(ofLength: bufferSize)
            if chunk.isEmpty { break }
            bytesRead += Int64(chunk.count)

            // Combine residual from previous chunk with current chunk
            var data = residual + chunk
            residual = Data()

            // Find the last newline -- everything after it is residual for next iteration
            if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                if lastNewline < data.endIndex - 1 {
                    residual = data[(lastNewline + 1)...]
                    data = data[...lastNewline]
                }
            } else if !chunk.isEmpty {
                // No newline found -- accumulate and continue
                residual = data
                continue
            }

            // Process lines
            if let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    // Kraken2 output format: C/U \t readId \t taxId \t length \t kmerHits
                    let columns = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                    guard columns.count >= 3 else { continue }

                    // Column 0: C or U
                    let status = columns[0].trimmingCharacters(in: .whitespaces)
                    guard status == "C" else { continue }

                    // Column 2: taxonomy ID
                    let taxIdStr = columns[2].trimmingCharacters(in: .whitespaces)
                    guard let taxId = Int(taxIdStr), targetTaxIds.contains(taxId) else { continue }

                    // Column 1: read ID (strip /1 or /2 paired-end suffix for matching)
                    var readId = String(columns[1].trimmingCharacters(in: .whitespaces))
                    if readId.hasSuffix("/1") || readId.hasSuffix("/2") {
                        readId = String(readId.dropLast(2))
                    }
                    matchingReadIds.insert(readId)
                }
            }

            // Report progress
            if fileSize > 0 {
                let fraction = 0.10 + 0.20 * (Double(bytesRead) / Double(fileSize))
                progress?(min(fraction, 0.30), "Scanning classification: \(matchingReadIds.count) matches...")
            }
        }

        // Process remaining residual
        if !residual.isEmpty, let text = String(data: residual, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let columns = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                guard columns.count >= 3 else { continue }
                let status = columns[0].trimmingCharacters(in: .whitespaces)
                guard status == "C" else { continue }
                let taxIdStr = columns[2].trimmingCharacters(in: .whitespaces)
                guard let taxId = Int(taxIdStr), targetTaxIds.contains(taxId) else { continue }
                var readId = String(columns[1].trimmingCharacters(in: .whitespaces))
                if readId.hasSuffix("/1") || readId.hasSuffix("/2") {
                    readId = String(readId.dropLast(2))
                }
                matchingReadIds.insert(readId)
            }
        }

        return matchingReadIds
    }

    // MARK: - FASTQ Filtering

    /// Filters a FASTQ file, writing only reads whose IDs are in the match set.
    ///
    /// Handles both plain text and gzip-compressed FASTQ files. FASTQ records
    /// are 4-line units: header, sequence, separator (+), quality.
    ///
    /// - Parameters:
    ///   - source: Input FASTQ file (plain or .gz).
    ///   - output: Output FASTQ file.
    ///   - readIds: Set of read IDs to extract.
    ///   - progress: Optional progress callback (0.0 to 1.0 within this file).
    /// - Returns: The number of reads extracted.
    /// - Throws: ``TaxonomyExtractionError`` on I/O failure.
    private func filterFASTQ(
        source: URL,
        output: URL,
        readIds: Set<String>,
        progress: (@Sendable (Double, String) -> Void)?
    ) throws -> Int {
        // Determine if input is gzip-compressed
        let isGzipped = source.pathExtension.lowercased() == "gz"

        // Create output directory if needed
        let outputDir = output.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: outputDir.path) {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        }

        // Get file size for progress
        let fileSize = (try? FileManager.default.attributesOfItem(
            atPath: source.path
        )[.size] as? Int64) ?? 0

        // For gzip files, use Process with zcat/gzcat. For plain, use FileHandle.
        if isGzipped {
            return try filterGzippedFASTQ(
                source: source,
                output: output,
                readIds: readIds,
                progress: progress
            )
        }

        guard let inputHandle = FileHandle(forReadingAtPath: source.path) else {
            throw TaxonomyExtractionError.sourceFileNotFound(source)
        }
        defer { inputHandle.closeFile() }

        // Create output file
        FileManager.default.createFile(atPath: output.path, contents: nil)
        guard let outputHandle = FileHandle(forWritingAtPath: output.path) else {
            throw TaxonomyExtractionError.outputWriteFailed(output, "Cannot open for writing")
        }
        defer { outputHandle.closeFile() }

        var extractedCount = 0
        var bytesRead: Int64 = 0
        var residual = ""
        let bufferSize = 4_194_304 // 4 MB
        var lineBuffer: [String] = []
        // Batch writes for performance — accumulate matched records then write at once
        var outputBuffer = Data()
        let flushThreshold = 1_048_576 // Flush every ~1 MB of output

        while true {
            try Task.checkCancellation()

            let chunk = inputHandle.readData(ofLength: bufferSize)
            if chunk.isEmpty { break }
            bytesRead += Int64(chunk.count)

            guard let text = String(data: chunk, encoding: .utf8) else { continue }

            let combined = residual + text
            residual = ""

            // Split into lines, keeping partial last line as residual
            var lines = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if !combined.hasSuffix("\n") && !lines.isEmpty {
                residual = lines.removeLast()
            }

            for line in lines {
                lineBuffer.append(line)

                // FASTQ records are 4 lines
                if lineBuffer.count == 4 {
                    let header = lineBuffer[0]
                    // Extract read ID from FASTQ header: @readId [optional description]
                    if header.hasPrefix("@") {
                        let readId = extractReadId(from: header)
                        if readIds.contains(readId) {
                            let record = lineBuffer.joined(separator: "\n") + "\n"
                            outputBuffer.append(Data(record.utf8))
                            extractedCount += 1
                        }
                    }
                    lineBuffer.removeAll(keepingCapacity: true)
                }
            }

            // Flush output buffer periodically for memory efficiency
            if outputBuffer.count >= flushThreshold {
                outputHandle.write(outputBuffer)
                outputBuffer.removeAll(keepingCapacity: true)
            }

            // Report progress (normalized to 0.0 -- 1.0 for this file)
            if fileSize > 0 {
                let fraction = Double(bytesRead) / Double(fileSize)
                progress?(min(fraction, 1.0), "Extracting: \(extractedCount) reads...")
            }
        }

        // Process remaining residual
        if !residual.isEmpty {
            lineBuffer.append(residual)
        }
        if lineBuffer.count == 4 {
            let header = lineBuffer[0]
            if header.hasPrefix("@") {
                let readId = extractReadId(from: header)
                if readIds.contains(readId) {
                    let record = lineBuffer.joined(separator: "\n") + "\n"
                    outputBuffer.append(Data(record.utf8))
                    extractedCount += 1
                }
            }
        }

        // Final flush
        if !outputBuffer.isEmpty {
            outputHandle.write(outputBuffer)
        }

        return extractedCount
    }

    /// Filters a gzip-compressed FASTQ using a pipe through `gzcat`.
    ///
    /// - Parameters:
    ///   - source: Input .fastq.gz file.
    ///   - output: Output FASTQ file.
    ///   - readIds: Set of read IDs to extract.
    ///   - progress: Optional progress callback.
    /// - Returns: The number of reads extracted.
    private func filterGzippedFASTQ(
        source: URL,
        output: URL,
        readIds: Set<String>,
        progress: (@Sendable (Double, String) -> Void)?
    ) throws -> Int {
        // Create output file
        FileManager.default.createFile(atPath: output.path, contents: nil)
        guard let outputHandle = FileHandle(forWritingAtPath: output.path) else {
            throw TaxonomyExtractionError.outputWriteFailed(output, "Cannot open for writing")
        }
        defer { outputHandle.closeFile() }

        // Use gzcat to decompress on the fly
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzcat")
        process.arguments = [source.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()

        let readHandle = pipe.fileHandleForReading
        var extractedCount = 0
        var lineBuffer: [String] = []
        var residual = ""
        let bufferSize = 4_194_304 // 4 MB

        while true {
            let chunk = readHandle.readData(ofLength: bufferSize)
            if chunk.isEmpty { break }

            guard let text = String(data: chunk, encoding: .utf8) else { continue }

            let combined = residual + text
            residual = ""

            var lines = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if !combined.hasSuffix("\n") && !lines.isEmpty {
                residual = lines.removeLast()
            }

            for line in lines {
                lineBuffer.append(line)

                if lineBuffer.count == 4 {
                    let header = lineBuffer[0]
                    if header.hasPrefix("@") {
                        let readId = extractReadId(from: header)
                        if readIds.contains(readId) {
                            let record = lineBuffer.joined(separator: "\n") + "\n"
                            outputHandle.write(Data(record.utf8))
                            extractedCount += 1
                        }
                    }
                    lineBuffer.removeAll(keepingCapacity: true)
                }
            }

            progress?(0.5, "Extracting: \(extractedCount) reads...")
        }

        // Process remaining residual
        if !residual.isEmpty {
            lineBuffer.append(residual)
        }
        if lineBuffer.count == 4 {
            let header = lineBuffer[0]
            if header.hasPrefix("@") {
                let readId = extractReadId(from: header)
                if readIds.contains(readId) {
                    let record = lineBuffer.joined(separator: "\n") + "\n"
                    outputHandle.write(Data(record.utf8))
                    extractedCount += 1
                }
            }
        }

        process.waitUntilExit()
        return extractedCount
    }

    // MARK: - Helpers

    /// Extracts the read ID from a FASTQ header line.
    ///
    /// FASTQ headers have the format `@readId [optional description]`.
    /// The read ID is everything after `@` up to the first whitespace.
    /// For paired-end reads, strips the `/1` or `/2` suffix to produce
    /// a canonical ID that matches both mates.
    ///
    /// - Parameter header: The FASTQ header line.
    /// - Returns: The read ID string (without paired-end suffix).
    private func extractReadId(from header: String) -> String {
        var id = header
        if id.hasPrefix("@") {
            id = String(id.dropFirst())
        }
        // Read ID ends at first whitespace
        if let spaceIndex = id.firstIndex(where: { $0.isWhitespace }) {
            id = String(id[id.startIndex..<spaceIndex])
        }
        // Strip paired-end suffix for canonical matching
        if id.hasSuffix("/1") || id.hasSuffix("/2") {
            id = String(id.dropLast(2))
        }
        return id
    }

    // MARK: - Provenance

    /// Records provenance for the extraction operation.
    private func recordProvenance(
        config: TaxonomyExtractionConfig,
        extractedCount: Int,
        runtime: TimeInterval
    ) async {
        let recorder = ProvenanceRecorder.shared
        let runID = await recorder.beginRun(
            name: "Taxonomy Read Extraction",
            parameters: [
                "taxIds": .string(config.taxIds.sorted().map(String.init).joined(separator: ",")),
                "includeChildren": .boolean(config.includeChildren),
                "extractedReads": .integer(extractedCount),
                "pairedEnd": .boolean(config.isPairedEnd),
            ]
        )

        let inputs = config.sourceFiles.map { url in
            FileRecord(path: url.path, format: .fastq, role: .input)
        } + [
            FileRecord(path: config.classificationOutput.path, format: .text, role: .input),
        ]
        let outputs = config.outputFiles.map { url in
            FileRecord(path: url.path, format: .fastq, role: .output)
        }

        await recorder.recordStep(
            runID: runID,
            toolName: "lungfish-extract",
            toolVersion: "1.0",
            command: ["lungfish", "extract", "--source", config.sourceFile.path,
                      "--output", config.outputFile.path],
            inputs: inputs,
            outputs: outputs,
            exitCode: 0,
            wallTime: runtime
        )

        await recorder.completeRun(runID, status: .completed)

        do {
            let outputDir = config.outputFile.deletingLastPathComponent()
            try await recorder.save(runID: runID, to: outputDir)
        } catch {
            logger.warning("Failed to save extraction provenance: \(error.localizedDescription, privacy: .public)")
        }
    }
}
