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
        let extraction = try await extractEachSource(config: config, tree: tree, progress: progress)
        let outputURLs = extraction.outputs.compactMap { $0 }

        // Phase 4: Provenance recording (0.95 -- 1.00)
        progress?(0.95, "Recording provenance...")

        let runtime = Date().timeIntervalSince(startTime)
        try await recordProvenance(
            config: config,
            resolvedTaxIds: extraction.taxIds,
            outputURLs: outputURLs,
            extractedCount: extraction.readCount,
            runtime: runtime
        )

        progress?(1.0, "Extraction complete: \(extraction.readCount) reads")
        return outputURLs
    }

    /// The extraction ``extract(config:tree:progress:)`` records: one output
    /// per source file of `config`, in order, nil for a source that holds
    /// none of the reads, with the tax IDs matched and the records written.
    /// Each index of `matePairStarts` is an R1 file whose R2 file follows
    /// it. That pair is read in step (``extractMatePairInStep(r1:r2:readIDs:to:)``)
    /// and its output, each R1 record followed by its R2 record, takes the
    /// R1 file's place, with nil in the R2 file's place.
    func extractEachSource(
        config: TaxonomyExtractionConfig,
        tree: TaxonTree,
        matePairStarts: [Int] = [],
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> (outputs: [URL?], taxIds: Set<Int>, readCount: Int) {
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
        // kraken2 --paired names every fragment by its R1 read with one final
        // /1 or /2 dropped, so the IDs of a paired run are fragment names
        // already and are matched as such, never trimmed a second time.
        let pairedRun = KrakenResultReadSources.classifiedPairs(in: config.classificationOutput)
        let matchingReadIds = try buildReadIdSet(
            classificationURL: config.classificationOutput,
            targetTaxIds: targetTaxIds,
            keepReadPairs: config.keepReadPairs && !pairedRun,
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

        let outputs = try await extractReadIDs(
            matchingReadIds,
            from: config.sourceFiles,
            matching: config.keepReadPairs || pairedRun ? .fragmentName : .firstWord,
            matePairStarts: Set(matePairStarts),
            outputDirectory: config.outputFile.deletingLastPathComponent(),
            baseName: config.outputFile.deletingPathExtension().lastPathComponent,
            progress: progress
        )
        return (outputs.urls, targetTaxIds, outputs.readCount)
    }

    /// Runs seqkit grep with the read IDs over each source file, one output
    /// per source in order. One source runs as it always has. Several sources
    /// run one at a time, and a source holding none of the reads gives nil,
    /// so the R1 and R2 files of a taxon whose reads were all merged do not
    /// fail its merged file (D7a). A pair of files that starts at an index of
    /// `matePairStarts` is read in step instead, as kraken2 read it.
    /// `matching` is the fragment-name rule when mates are kept together or
    /// kraken2 named fragments, so a mate named `X/1` matches `X` (D7c).
    private func extractReadIDs(
        _ readIDs: Set<String>,
        from sources: [URL],
        matching: ReadIDMatching,
        matePairStarts: Set<Int>,
        outputDirectory: URL,
        baseName: String,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> (urls: [URL?], readCount: Int) {
        let service = ReadExtractionService(toolRunner: NativeToolRunner.shared)
        func config(_ files: [URL], _ name: String) -> ReadIDExtractionConfig {
            ReadIDExtractionConfig(
                sourceFASTQs: files,
                readIDs: readIDs,
                keepReadPairs: matching == .fragmentName,
                outputDirectory: outputDirectory,
                outputBaseName: name
            )
        }
        guard matePairStarts.isEmpty else {
            return try await extractWithMatePairs(
                readIDs, from: sources, matePairStarts: matePairStarts, outputDirectory: outputDirectory, baseName: baseName,
                extractOne: { source, name, index in
                    try await service.extractByReadIDs(config: config([source], name), matching: matching) { fraction, message in
                        progress?(0.30 + (Double(index) + fraction) * 0.65 / Double(sources.count), message)
                    }
                }
            )
        }
        guard sources.count > 1 else {
            let result = try await service.extractByReadIDs(config: config(sources, baseName), matching: matching) { fraction, message in
                // Map service progress (0..1) into our pipeline range (0.30..0.95)
                progress?(0.30 + fraction * 0.65, message)
            }
            return (result.fastqURLs, result.readCount)
        }
        var urls: [URL?] = []
        var readCount = 0
        let share = 0.65 / Double(sources.count)
        for (index, source) in sources.enumerated() {
            let name = "\(baseName)_R\(index + 1)"
            do {
                let result = try await service.extractByReadIDs(config: config([source], name), matching: matching) { fraction, message in
                    progress?(0.30 + (Double(index) + fraction) * share, message)
                }
                urls.append(result.fastqURLs.first)
                readCount += result.readCount
            } catch ExtractionError.emptyExtraction {
                // seqkit leaves an empty output behind.
                let empty = outputDirectory.appendingPathComponent("\(ExtractionBundleNaming.sanitizeFilename(name)).fastq.gz")
                try? FileManager.default.removeItem(at: empty)
                urls.append(nil)
            }
        }
        guard readCount > 0 else { throw ExtractionError.emptyExtraction }
        return (urls, readCount)
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

        // Every read file of the result (D7e). A trimmed or oriented subset
        // is materialized once into a scratch folder that goes at the end.
        let scratch = outputDirectory.appendingPathComponent(".kraken2-sources-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let sources = try await KrakenResultReadSources.resolve(
            result: classificationResult,
            materializationDirectory: scratch.appendingPathComponent("materialized", isDirectory: true)
        )

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

            // Build config for this single target. One file of reads is
            // extracted as before. Several give one file per taxon, pairs
            // interleaved, then single reads (D7e).
            let config = TaxonomyExtractionConfig(
                taxIds: Set([target.taxId]),
                includeChildren: target.includeChildren,
                sourceFile: sources.urls[0],
                outputFile: outputFile,
                classificationOutput: classificationResult.outputURL,
                taxonomyReport: target.includeChildren ? classificationResult.reportURL : nil
            )
            let targetProgress: @Sendable (Double, String) -> Void = { fraction, message in
                let mappedFraction = overallBase + overallStep * fraction
                progress?(min(mappedFraction, overallBase + overallStep), message)
            }

            do {
                if sources.files.count == 1 {
                    outputURLs += try await extract(config: config, tree: tree, progress: targetProgress)
                } else {
                    outputURLs.append(try await extractIntoOneFile(
                        config: config,
                        files: sources.files,
                        scratch: scratch.appendingPathComponent("\(index)", isDirectory: true),
                        tree: tree,
                        progress: targetProgress
                    ))
                }
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
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do {
                let index = try KrakenIndexDatabase(url: indexURL)
                defer { index.close() }
                if index.canResolve(taxIds: targetTaxIds) {
                    let readIds = try index.readIds(forTaxIds: targetTaxIds)
                    progress?(0.30, "Loaded \(readIds.count) read IDs from Kraken2 index")
                    return normalizeReadIds(readIds, keepReadPairs: keepReadPairs)
                }
            } catch {
                logger.warning(
                    "Kraken index query failed at \(indexURL.path, privacy: .private(mask: .hash)); falling back to raw classification output: \(String(describing: error), privacy: .private(mask: .hash))"
                )
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
    func recordProvenance(
        config: TaxonomyExtractionConfig,
        resolvedTaxIds: Set<Int>,
        outputURLs: [URL],
        extractedCount: Int,
        runtime: TimeInterval,
        commandPrefix: [String]? = nil
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
            toolName: "TaxonomyExtractionPipeline",
            toolVersion: WorkflowRun.currentAppVersion,
            command: extractionReplayCommand(config: config, resolvedTaxIds: resolvedTaxIds, prefix: commandPrefix),
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
        resolvedTaxIds: Set<Int>,
        prefix: [String]? = nil
    ) -> [String] {
        // Legacy CLI replay for taxonomy-ID extraction. The supported
        // `extract reads --by-id` path needs a materialized read-ID file; until
        // this workflow writes one, provenance identifies the actor above.
        // A taxon extracted from several files into one names the workflow
        // step, since `conda extract` writes one output per file.
        let replayTaxIds = config.includeChildren && config.taxonomyReport == nil
            ? resolvedTaxIds
            : config.taxIds
        var command = (prefix ?? [CLICommandIdentity.executableName, "conda", "extract"]) + [
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
