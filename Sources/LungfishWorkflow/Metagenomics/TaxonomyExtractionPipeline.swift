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
            keepReadPairs: config.keepReadPairs,
            progress: progress
        )

        if matchingReadIds.isEmpty {
            throw TaxonomyExtractionError.noMatchingReads
        }

        let matchCount = matchingReadIds.count
        logger.info("Found \(matchCount, privacy: .public) matching reads")
        progress?(0.30, "Extracting \(matchCount) reads...")

        // Phase 3: Filter each FASTQ file using ReadExtractionService (0.30 -- 0.95)
        // ReadExtractionService delegates to seqkit grep, which is 10-50x faster than
        // line-by-line Swift FASTQ parsing because it uses optimized C I/O and handles .gz natively.
        try Task.checkCancellation()

        let outputDir = config.outputFile.deletingLastPathComponent()
        let baseName = config.outputFile.deletingPathExtension().lastPathComponent

        let extractionConfig = ReadIDExtractionConfig(
            sourceFASTQs: config.sourceFiles,
            readIDs: matchingReadIds,
            keepReadPairs: config.keepReadPairs,
            outputDirectory: outputDir,
            outputBaseName: baseName
        )

        let service = ReadExtractionService(toolRunner: NativeToolRunner.shared)
        let extractionResult = try await service.extractByReadIDs(
            config: extractionConfig,
            progress: { fraction, message in
                // Map service progress (0..1) into our pipeline range (0.30..0.95)
                progress?(0.30 + fraction * 0.65, message)
            }
        )

        let totalExtracted = extractionResult.readCount
        let outputURLs = extractionResult.fastqURLs

        // Phase 4: Provenance recording (0.95 -- 1.00)
        progress?(0.95, "Recording provenance...")

        let runtime = Date().timeIntervalSince(startTime)
        try await recordProvenance(
            config: config,
            resolvedTaxIds: targetTaxIds,
            outputURLs: outputURLs,
            extractedCount: totalExtracted,
            runtime: runtime
        )

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
                classificationOutput: classificationResult.outputURL,
                taxonomyReport: target.includeChildren ? classificationResult.reportURL : nil
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
        keepReadPairs: Bool = true,
        progress: (@Sendable (Double, String) -> Void)?
    ) throws -> Set<String> {
        let indexURL = KrakenIndexDatabase.indexURL(for: classificationURL)
        if FileManager.default.fileExists(atPath: indexURL.path),
           let index = try? KrakenIndexDatabase(url: indexURL) {
            defer { index.close() }
            if index.canResolve(taxIds: targetTaxIds) {
                let readIds = try index.readIds(forTaxIds: targetTaxIds)
                progress?(0.30, "Loaded \(readIds.count) read IDs from Kraken2 index")
                return normalizeReadIds(readIds, keepReadPairs: keepReadPairs)
            }
        }

        guard FileManager.default.fileExists(atPath: classificationURL.path) else {
            throw TaxonomyExtractionError.classificationOutputNotFound(classificationURL)
        }

        let isGzipped = ["gz", "gzip"].contains(classificationURL.pathExtension.lowercased())
        let fileHandle: FileHandle
        let gzipProcess: Process?
        if isGzipped {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", classificationURL.path]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw TaxonomyExtractionError.classificationOutputNotFound(classificationURL)
            }
            fileHandle = stdout.fileHandleForReading
            gzipProcess = process
        } else {
            guard let handle = FileHandle(forReadingAtPath: classificationURL.path) else {
                throw TaxonomyExtractionError.classificationOutputNotFound(classificationURL)
            }
            fileHandle = handle
            gzipProcess = nil
        }

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
                collectMatchingReadIds(
                    from: text,
                    targetTaxIds: targetTaxIds,
                    keepReadPairs: keepReadPairs,
                    into: &matchingReadIds
                )
            }

            // Report progress
            if fileSize > 0 {
                let fraction = 0.10 + 0.20 * (Double(bytesRead) / Double(fileSize))
                progress?(min(fraction, 0.30), "Scanning classification: \(matchingReadIds.count) matches...")
            }
        }

        // Process remaining residual
        if !residual.isEmpty, let text = String(data: residual, encoding: .utf8) {
            collectMatchingReadIds(
                from: text,
                targetTaxIds: targetTaxIds,
                keepReadPairs: keepReadPairs,
                into: &matchingReadIds
            )
        }

        fileHandle.closeFile()
        if let gzipProcess {
            gzipProcess.waitUntilExit()
            guard gzipProcess.terminationStatus == 0 else {
                throw TaxonomyExtractionError.classificationOutputNotFound(classificationURL)
            }
        }

        return matchingReadIds
    }

    private func normalizeReadIds(_ readIds: Set<String>, keepReadPairs: Bool) -> Set<String> {
        guard keepReadPairs else { return readIds }
        return Set(readIds.map { readId in
            if readId.hasSuffix("/1") || readId.hasSuffix("/2") {
                return String(readId.dropLast(2))
            }
            return readId
        })
    }

    private func collectMatchingReadIds(
        from text: String,
        targetTaxIds: Set<Int>,
        keepReadPairs: Bool,
        into matchingReadIds: inout Set<String>
    ) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Kraken2 output format: C/U \t readId \t taxId \t length \t kmerHits
            let columns = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }

            let status = columns[0].trimmingCharacters(in: .whitespaces)
            guard status == "C" || status == "U" else { continue }

            let taxIdStr = columns[2].trimmingCharacters(in: .whitespaces)
            guard let taxId = Int(taxIdStr), targetTaxIds.contains(taxId) else { continue }
            guard status == "C" || taxId == 0 else { continue }

            var readId = String(columns[1].trimmingCharacters(in: .whitespaces))
            if keepReadPairs, readId.hasSuffix("/1") || readId.hasSuffix("/2") {
                readId = String(readId.dropLast(2))
            }
            matchingReadIds.insert(readId)
        }
    }

    // MARK: - Provenance

    /// Records provenance for the extraction operation.
    private func recordProvenance(
        config: TaxonomyExtractionConfig,
        resolvedTaxIds: Set<Int>,
        outputURLs: [URL],
        extractedCount: Int,
        runtime: TimeInterval
    ) async throws {
        let recorder = ProvenanceRecorder.shared
        let runID = await recorder.beginRun(
            name: "Taxonomy Read Extraction",
            parameters: extractionProvenanceParameters(
                config: config,
                resolvedTaxIds: resolvedTaxIds,
                outputURLs: outputURLs,
                extractedCount: extractedCount
            )
        )

        var inputs = config.sourceFiles.map { url in
            ProvenanceRecorder.fileRecord(url: url, format: .fastq, role: .input)
        } + [
            ProvenanceRecorder.fileRecord(url: config.classificationOutput, format: .text, role: .input),
        ]
        if let taxonomyReport = config.taxonomyReport {
            inputs.append(ProvenanceRecorder.fileRecord(url: taxonomyReport, format: .text, role: .input))
        }
        let outputs = outputURLs.map { url in
            ProvenanceRecorder.fileRecord(url: url, format: .fastq, role: .output)
        }

        await recorder.recordStep(
            runID: runID,
            toolName: "lungfish-cli conda extract",
            toolVersion: WorkflowRun.currentAppVersion,
            command: extractionReplayCommand(config: config, resolvedTaxIds: resolvedTaxIds),
            inputs: inputs,
            outputs: outputs,
            exitCode: 0,
            wallTime: runtime
        )

        await recorder.completeRun(runID, status: .completed)

        let outputDir = outputURLs.first?.deletingLastPathComponent()
            ?? config.outputFile.deletingLastPathComponent()
        try await recorder.save(runID: runID, to: outputDir)
        try await writeFocusedOutputSidecars(
            recorder: recorder,
            runID: runID,
            outputs: outputs
        )
    }

    private func writeFocusedOutputSidecars(
        recorder: ProvenanceRecorder,
        runID: UUID,
        outputs: [FileRecord]
    ) async throws {
        guard let run = await recorder.getRun(runID) else {
            throw ProvenanceError.runNotFound(runID)
        }

        let envelope = run.canonicalEnvelope()
        let writer = ProvenanceWriter()
        for output in outputs {
            let outputURL = URL(fileURLWithPath: output.path)
            let focusedEnvelope = envelope.focusedOnOutput(ProvenanceFileDescriptor(fileRecord: output))
            try writer.write(
                focusedEnvelope,
                toSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)
            )
        }
    }

    private func extractionProvenanceParameters(
        config: TaxonomyExtractionConfig,
        resolvedTaxIds: Set<Int>,
        outputURLs: [URL],
        extractedCount: Int
    ) -> [String: ParameterValue] {
        var parameters: [String: ParameterValue] = [
            "taxIds": .array(config.taxIds.sorted().map { .integer($0) }),
            "resolvedTaxIds": .array(resolvedTaxIds.sorted().map { .integer($0) }),
            "includeChildren": .boolean(config.includeChildren),
            "keepReadPairs": .boolean(config.keepReadPairs),
            "extractedReads": .integer(extractedCount),
            "pairedEnd": .boolean(config.isPairedEnd),
            "sourceFiles": .array(config.sourceFiles.map { .string($0.path) }),
            "requestedOutputFiles": .array(config.outputFiles.map { .string($0.path) }),
            "actualOutputFiles": .array(outputURLs.map { .string($0.path) }),
            "classificationOutput": .string(config.classificationOutput.path),
        ]
        if let taxonomyReport = config.taxonomyReport {
            parameters["taxonomyReport"] = .string(taxonomyReport.path)
        }
        return parameters
    }

    private func extractionReplayCommand(
        config: TaxonomyExtractionConfig,
        resolvedTaxIds: Set<Int>
    ) -> [String] {
        let replayTaxIds = config.includeChildren && config.taxonomyReport == nil
            ? resolvedTaxIds
            : config.taxIds
        var command = [
            CLICommandIdentity.executableName,
            "conda",
            "extract",
            "--kraken-output",
            config.classificationOutput.path,
        ]
        for sourceFile in config.sourceFiles {
            command.append(contentsOf: ["--source", sourceFile.path])
        }
        command.append(contentsOf: [
            "--taxid",
            replayTaxIds.sorted().map(String.init).joined(separator: ","),
        ])
        for outputFile in config.outputFiles {
            command.append(contentsOf: ["--output", outputFile.path])
        }
        if config.includeChildren {
            command.append("--include-children")
            if let taxonomyReport = config.taxonomyReport {
                command.append(contentsOf: ["--kreport", taxonomyReport.path])
            }
        }
        if !config.keepReadPairs {
            command.append("--no-read-pairs")
        }
        return command
    }
}
