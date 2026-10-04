// ClassifierReadResolver+KrakenSources.swift - The Kraken2 dispatch of ClassifierReadResolver and its source reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "ClassifierReadResolver")

extension ClassifierReadResolver {
    // MARK: - Kraken2 dispatch

    func extractViaKraken2(
        selections: [ClassifierRowSelector],
        resultPath: URL,
        options: ExtractionOptions,
        destination: ExtractionDestination,
        startedAt: Date,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> ExtractionOutcome {
        let hasSingleSampleSelectors = selections.contains { $0.sampleId == nil }
        let hasBatchSampleSelectors = selections.contains { $0.sampleId != nil }
        guard !(hasSingleSampleSelectors && hasBatchSampleSelectors) else {
            throw ClassifierExtractionError.mixedSampleSelectionModes
        }

        // Locate a writable temp directory under the enclosing project.
        let projectRoot = Self.resolveProjectRoot(from: resultPath)
        let tempDir = try ProjectTempDirectory.create(
            prefix: "kraken2-extract-",
            in: projectRoot
        )
        let cleanTempDir = tempDir  // capture for defer
        defer { try? FileManager.default.removeItem(at: cleanTempDir) }

        // Build the list of per-sample result paths to process.
        // In batch mode, each selector carries a sampleId and the resultPath
        // is the batch root directory containing per-sample subdirectories.
        // In single-sample mode, sampleId is nil and resultPath points directly
        // at the sample's classification output directory.
        let sampleJobs: [(sampleId: String?, sampleResultPath: URL, taxIds: Set<Int>)] =
            groupBySample(selections).compactMap { sampleId, group in
                let taxIds = Set(group.flatMap(\.taxIds))
                guard !taxIds.isEmpty else { return nil }
                let sampleResultPath = sampleId.map {
                    resultPath.appendingPathComponent($0, isDirectory: true)
                } ?? resultPath
                return (sampleId, sampleResultPath, taxIds)
            }
        guard !sampleJobs.isEmpty else {
            throw ClassifierExtractionError.zeroReadsExtracted
        }

        var provenanceSourceURLs = existingUniqueURLs([resultPath])
        // Samples whose sidecar or source FASTQ could not be resolved. These
        // used to be dropped silently, so the user saw a "success" that
        // omitted whole samples.
        var skippedSamples: [String] = []
        // The R1 and R2 reads of every pair of files, each R1 record followed
        // by its R2 record, go into one file, and the reads of every other
        // file follow it: all pairs first, then the single reads (D7d).
        let pairsFile = tempDir.appendingPathComponent("kraken2-pairs.fastq")
        FileManager.default.createFile(atPath: pairsFile.path, contents: nil)
        let pairsHandle = try FileHandle(forWritingTo: pairsFile)
        defer { try? pairsHandle.close() }
        var pairCount = 0
        var readURLs: [URL] = []
        // Whether any sample's reads hold mates, so the output may too.
        var sourcesHoldMates = false
        var singleReadRole = ReadClassification.FileRole.unpaired

        for (jobIndex, job) in sampleJobs.enumerated() {
            try Task.checkCancellation()

            let sampleLabel = job.sampleId ?? "sample"
            let baseFraction = Double(jobIndex) / Double(sampleJobs.count)
            let sampleWeight = 1.0 / Double(sampleJobs.count)

            progress?(baseFraction * 0.8, "Loading \(sampleLabel) classification…")

            // Load this sample's ClassificationResult.
            let classResult: ClassificationResult
            do {
                classResult = try ClassificationResult.load(from: job.sampleResultPath)
            } catch {
                logger.warning(
                    "Skipping sample \(sampleLabel, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                skippedSamples.append(sampleLabel)
                continue
            }
            provenanceSourceURLs.append(job.sampleResultPath)
            provenanceSourceURLs.append(classResult.outputURL)

            // Every read file of this sample (D7a, D7b). A trimmed or
            // oriented subset is materialized into the temp folder.
            let sources: KrakenResultReadSources
            do {
                sources = try await KrakenResultReadSources.resolve(
                    result: classResult,
                    materializationDirectory: tempDir.appendingPathComponent("sources-\(jobIndex)", isDirectory: true)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.warning(
                    "Skipping sample \(sampleLabel, privacy: .private(mask: .hash)) — source FASTQ not found: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                skippedSamples.append(sampleLabel)
                continue
            }
            let sourceFASTQs = sources.urls
            provenanceSourceURLs.append(contentsOf: sourceFASTQs)
            sourcesHoldMates = sourcesHoldMates || sources.holdsMates
                || Self.sourceHoldsInterleavedPairs(config: classResult.config, sourceFASTQs: sourceFASTQs)
            if sources.files.contains(where: { $0.singleReadRole == .merged || $0.singleReadRole == .mergedOrOrphan }) {
                singleReadRole = .merged
            }

            // Build per-sample output paths in the shared temp dir.
            let stem = "\(jobIndex)_\(sampleLabel)"
            let outputFiles: [URL]
            if sourceFASTQs.count == 1 {
                outputFiles = [tempDir.appendingPathComponent("\(stem).fastq")]
            } else {
                outputFiles = sourceFASTQs.enumerated().map { idx, _ in
                    tempDir.appendingPathComponent("\(stem)_R\(idx + 1).fastq")
                }
            }

            let config = TaxonomyExtractionConfig(
                taxIds: job.taxIds,
                includeChildren: true,
                sourceFiles: sourceFASTQs,
                outputFiles: outputFiles,
                classificationOutput: classResult.outputURL,
                taxonomyReport: classResult.reportURL,
                keepReadPairs: true
            )

            progress?(baseFraction * 0.8 + 0.1 * sampleWeight, "Extracting \(sampleLabel)…")

            let pipeline = TaxonomyExtractionPipeline()
            let outputs = try await pipeline.extractEachSource(
                config: config,
                tree: classResult.tree,
                progress: { fraction, message in
                    progress?(baseFraction * 0.8 + fraction * 0.7 * sampleWeight, "\(sampleLabel): \(message)")
                }
            )

            var readOutputs: [URL] = []
            for (index, file) in sources.files.enumerated() {
                switch file.role {
                case .r1:
                    pairCount += try Self.interleaveMates(of: sources.files, at: index, outputs: outputs, into: pairsHandle)
                case .r2:
                    continue
                case .adjacentMates, .reads:
                    if let output = outputs[index] { readOutputs.append(output) }
                }
            }
            // Decompress .fastq.gz output from seqkit.
            readURLs += try await decompressGzippedFiles(readOutputs)
        }
        try pairsHandle.close()

        let producedURLs = (pairCount > 0 ? [pairsFile] : []) + readURLs
        guard !producedURLs.isEmpty else {
            if !skippedSamples.isEmpty {
                throw ClassifierExtractionError.allSamplesSkipped(skippedSamples)
            }
            throw ClassifierExtractionError.zeroReadsExtracted
        }
        try Task.checkCancellation()

        // Concatenate all per-sample outputs into a single FASTQ.
        let concatenated = tempDir.appendingPathComponent("kraken2-concat.fastq")
        try concatenateFiles(producedURLs, into: concatenated)
        try Task.checkCancellation()

        let readCount = try await countFASTQRecords(in: concatenated)
        if readCount == 0 {
            throw ClassifierExtractionError.zeroReadsExtracted
        }
        try Task.checkCancellation()

        let layout: (mode: IngestionMetadata.PairingMode, roles: ReadClassification?) =
            options.format == .fastq && sourcesHoldMates
                ? try Self.extractedLayout(of: concatenated, singleReadRole: singleReadRole)
                : (.singleEnd, nil)

        // Format conversion.
        let finalFile: URL
        if options.format == .fasta {
            finalFile = tempDir.appendingPathComponent("kraken2-concat.fasta")
            try convertFASTQToFASTA(input: concatenated, output: finalFile)
            try Task.checkCancellation()
        } else {
            finalFile = concatenated
        }

        progress?(0.9, "Routing to destination…")
        let outcome = try await routeToDestination(
            finalFile: finalFile,
            readCount: readCount,
            destination: destination,
            options: options,
            provenanceSourceURLs: existingUniqueURLs(provenanceSourceURLs),
            extractionStartedAt: startedAt,
            outputPairingMode: layout.mode,
            outputRoles: layout.roles,
            progress: progress
        )
        if !skippedSamples.isEmpty {
            progress?(
                1.0,
                "Extracted \(readCount) reads. Skipped \(skippedSamples.count) sample(s) with unresolvable source data: \(skippedSamples.joined(separator: ", "))"
            )
        }
        return outcome
    }

    /// Writes the reads extracted from the pair of files at `index` (R1)
    /// and `index + 1` (R2), each R1 record followed by its R2 record, and
    /// returns the number of pairs. The two outputs come from files whose
    /// records correspond by position, filtered by one ID set, so they hold
    /// the same fragments in the same order. Names are checked record by
    /// record, and files out of step throw rather than mis-pair (D7d).
    static func interleaveMates(
        of files: [KrakenResultReadSources.File],
        at index: Int,
        outputs: [URL?],
        into handle: FileHandle
    ) throws -> Int {
        guard index + 1 < files.count, files[index + 1].role == .r2 else {
            throw ClassifierExtractionError.kraken2SourceMissing
        }
        let r1Source = files[index].url.lastPathComponent
        let r2Source = files[index + 1].url.lastPathComponent
        switch (outputs[index], outputs[index + 1]) {
        case (nil, nil):
            return 0
        case (let r1?, let r2?):
            do {
                return try FASTQPairInterleaver.interleave(r1: r1, r2: r2, to: handle, requireMates: true).r1Records
            } catch FASTQPairInterleaver.InterleaveError.mateNameMismatch(let record, _, let r1Name, _, let r2Name) {
                throw FASTQPairInterleaver.InterleaveError.mateNameMismatch(
                    recordNumber: record, r1File: r1Source, r1Name: r1Name, r2File: r2Source, r2Name: r2Name
                )
            } catch FASTQPairInterleaver.InterleaveError.mateCountMismatch(_, let r1Records, _, let r2Records) {
                throw FASTQPairInterleaver.InterleaveError.mateCountMismatch(
                    r1File: r1Source, r1Records: r1Records, r2File: r2Source, r2Records: r2Records
                )
            }
        case (let r1?, nil):
            throw FASTQPairInterleaver.InterleaveError.mateCountMismatch(
                r1File: r1Source, r1Records: try FASTQPairInterleaver.countRecords(in: r1), r2File: r2Source, r2Records: 0
            )
        case (nil, let r2?):
            throw FASTQPairInterleaver.InterleaveError.mateCountMismatch(
                r1File: r1Source, r1Records: 0, r2File: r2Source, r2Records: try FASTQPairInterleaver.countRecords(in: r2)
            )
        }
    }

    /// How an extracted FASTQ pairs (D7d), counted over the whole file by
    /// the layout scan's pairing rule: interleaved when it holds only pairs,
    /// single-end with roles in the form a merge recipe records when it mixes
    /// pairs with single reads, and single-end when it holds no pair.
    static func extractedLayout(
        of fastqURL: URL,
        singleReadRole: ReadClassification.FileRole
    ) throws -> (mode: IngestionMetadata.PairingMode, roles: ReadClassification?) {
        let counts = try FASTQMixedLayoutHint.countPairsAndSingles(in: fastqURL)
        guard counts.pairs > 0 else { return (.singleEnd, nil) }
        guard counts.singles > 0 else { return (.interleaved, nil) }
        let roles = FASTQMixedLayoutHint.classification(
            pairs: counts.pairs,
            singles: counts.singles,
            singleRole: singleReadRole,
            filename: fastqURL.lastPathComponent
        )
        return (.singleEnd, roles)
    }

    /// Whether a Kraken 2 sample's source is one FASTQ holding interleaved
    /// mate pairs, from the layout the classification recorded or, failing
    /// that, the source bundle's pairing metadata.
    static func sourceHoldsInterleavedPairs(
        config: ClassificationConfig,
        sourceFASTQs: [URL]
    ) -> Bool {
        guard sourceFASTQs.count == 1, let source = sourceFASTQs.first else { return false }
        if config.interleavedInput { return true }
        if let layout = config.inputLayout?.layout {
            return layout != .singleEnd
        }
        return FASTQReadLayoutClassifier.metadataHints(for: source).pairingMode == .interleaved
    }

    /// The pairing alone of an extracted FASTQ, from ``extractedLayout(of:singleReadRole:)``.
    static func extractedPairingMode(ofInterleavedSourceOutput fastqURL: URL) -> IngestionMetadata.PairingMode {
        (try? extractedLayout(of: fastqURL, singleReadRole: .unpaired).mode) ?? .singleEnd
    }

    /// Shared implementation of Kraken2 source FASTQ resolution.
    ///
    /// Exposed as a static so non-extraction callers (notably the BLAST
    /// verification handlers in the viewer, which previously used
    /// `config.inputFiles.first` raw) resolve the same source file. Using
    /// `inputFiles` directly breaks whenever the classification ran against a
    /// materialized temp FASTQ that has since been deleted.
    public static func resolveKraken2SourceFASTQs(
        classResult: ClassificationResult
    ) throws -> [URL] {
        let fm = FileManager.default
        let config = classResult.config

        // 1. originalInputFiles
        if let originals = config.originalInputFiles,
           let first = originals.first,
           fm.fileExists(atPath: first.path) {
            if let resolved = resolveBundlePayloadIfNeeded(first) {
                return [resolved]
            }
            return originals
        }

        // 2. Walk up from outputDirectory to find the enclosing bundle.
        //    outputDirectory = bundle.lungfishfastq/derivatives/classification-xxx/
        let derivativesDir = config.outputDirectory.deletingLastPathComponent()
        let bundleDir = derivativesDir.deletingLastPathComponent()
        if FASTQBundle.isBundleURL(bundleDir),
           let resolved = FASTQBundle.resolvePrimarySequenceURL(for: bundleDir) {
            return [resolved]
        }

        // 3. Fall back to config.inputFiles if they exist.
        if let first = config.inputFiles.first, fm.fileExists(atPath: first.path) {
            if let resolved = resolveBundlePayloadIfNeeded(first) {
                return [resolved]
            }
            return config.inputFiles
        }

        throw ClassifierExtractionError.kraken2SourceMissing
    }

    /// When `url` names a `.lungfishfastq` bundle directory, resolves it to the
    /// payload file inside. Returns `nil` when `url` is not a bundle (callers
    /// then use the URL as-is).
    private static func resolveBundlePayloadIfNeeded(_ url: URL) -> URL? {
        guard FASTQBundle.isBundleURL(url) else { return nil }
        return FASTQBundle.resolvePrimarySequenceURL(for: url)
    }

    /// Resolves the single primary source FASTQ (or FASTA) for a Kraken2
    /// classification result.
    ///
    /// Convenience wrapper for callers that need exactly one file, such as
    /// BLAST verification read extraction.
    public static func resolveKraken2PrimarySource(
        classResult: ClassificationResult
    ) throws -> URL {
        guard let first = try resolveKraken2SourceFASTQs(classResult: classResult).first else {
            throw ClassifierExtractionError.kraken2SourceMissing
        }
        return first
    }
}
