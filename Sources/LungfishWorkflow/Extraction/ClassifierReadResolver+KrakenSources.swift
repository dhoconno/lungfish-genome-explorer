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
        let readsFile = tempDir.appendingPathComponent("kraken2-reads.fastq")
        FileManager.default.createFile(atPath: pairsFile.path, contents: nil)
        FileManager.default.createFile(atPath: readsFile.path, contents: nil)
        let pairsHandle = try FileHandle(forWritingTo: pairsFile)
        defer { try? pairsHandle.close() }
        let readsHandle = try FileHandle(forWritingTo: readsFile)
        defer { try? readsHandle.close() }
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
            if KrakenResultReadSources.singleReadFileRole(of: sources.files) == .merged {
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
            let extraction = try await pipeline.extractEachSource(
                config: config,
                tree: classResult.tree,
                progress: { fraction, message in
                    progress?(baseFraction * 0.8 + fraction * 0.7 * sampleWeight, "\(sampleLabel): \(message)")
                }
            )

            _ = try TaxonomyExtractionPipeline.writeExtractedReads(
                extraction.outputs,
                of: sources.files,
                pairs: pairsHandle,
                reads: readsHandle
            )
        }
        try pairsHandle.close()
        try readsHandle.close()

        let producedURLs = [pairsFile, readsFile].filter {
            ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? UInt64) ?? 0) > 0
        }
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
                ? try TaxonomyExtractionPipeline.extractedLayout(of: concatenated, singleReadRole: singleReadRole)
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

    /// The pairing alone of an extracted FASTQ, from
    /// ``TaxonomyExtractionPipeline/extractedLayout(of:singleReadRole:)``.
    static func extractedPairingMode(ofInterleavedSourceOutput fastqURL: URL) -> IngestionMetadata.PairingMode {
        (try? TaxonomyExtractionPipeline.extractedLayout(of: fastqURL, singleReadRole: .unpaired).mode) ?? .singleEnd
    }
}
