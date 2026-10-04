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

        var allProducedURLs: [URL] = []
        var provenanceSourceURLs = existingUniqueURLs([resultPath])
        // Samples whose sidecar or source FASTQ could not be resolved. These
        // used to be dropped silently, so the user saw a "success" that
        // omitted whole samples.
        var skippedSamples: [String] = []
        // Whether every extracted sample came from one interleaved paired
        // FASTQ. Extraction keeps both mates in source order, so such an
        // output is itself interleaved and must be recorded that way.
        var everySourceInterleaved = true

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

            // Resolve the source FASTQ(s) for this sample.
            let sourceFASTQs: [URL]
            do {
                sourceFASTQs = try resolveKraken2SourceFASTQs(classResult: classResult)
            } catch {
                logger.warning(
                    "Skipping sample \(sampleLabel, privacy: .private(mask: .hash)) — source FASTQ not found: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                skippedSamples.append(sampleLabel)
                continue
            }
            provenanceSourceURLs.append(contentsOf: sourceFASTQs)
            everySourceInterleaved = everySourceInterleaved
                && Self.sourceHoldsInterleavedPairs(config: classResult.config, sourceFASTQs: sourceFASTQs)

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
            let producedURLs = try await pipeline.extract(
                config: config,
                tree: classResult.tree,
                progress: { fraction, message in
                    progress?(baseFraction * 0.8 + fraction * 0.7 * sampleWeight, "\(sampleLabel): \(message)")
                }
            )

            // Decompress .fastq.gz output from seqkit.
            let decompressed = try await decompressGzippedFiles(producedURLs)
            allProducedURLs.append(contentsOf: decompressed)
        }

        guard !allProducedURLs.isEmpty else {
            if !skippedSamples.isEmpty {
                throw ClassifierExtractionError.allSamplesSkipped(skippedSamples)
            }
            throw ClassifierExtractionError.zeroReadsExtracted
        }
        try Task.checkCancellation()

        // Concatenate all per-sample outputs into a single FASTQ.
        let concatenated = tempDir.appendingPathComponent("kraken2-concat.fastq")
        try concatenateFiles(allProducedURLs, into: concatenated)
        try Task.checkCancellation()

        let readCount = try await countFASTQRecords(in: concatenated)
        if readCount == 0 {
            throw ClassifierExtractionError.zeroReadsExtracted
        }
        try Task.checkCancellation()

        let outputPairingMode: IngestionMetadata.PairingMode =
            options.format == .fastq && everySourceInterleaved
                ? Self.extractedPairingMode(ofInterleavedSourceOutput: concatenated)
                : .singleEnd

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
            outputPairingMode: outputPairingMode,
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

    /// The pairing to record for an extraction whose sources were all
    /// interleaved pairs. Confirms from the output's own records that mates
    /// are still adjacent; a selection that kept no adjacent mates is
    /// recorded as single-end.
    static func extractedPairingMode(ofInterleavedSourceOutput fastqURL: URL) -> IngestionMetadata.PairingMode {
        guard let scan = try? FASTQReadLayoutClassifier.readHeaders(from: fastqURL) else {
            return .singleEnd
        }
        let classification = FASTQReadLayoutClassifier.classify(
            headers: scan.headers,
            scannedWholeFile: scan.scannedWholeFile,
            metadata: FASTQPairingMetadataHints(pairingMode: .interleaved)
        )
        return classification.matePairs > 0 ? .interleaved : .singleEnd
    }

    /// Resolves the Kraken2 source FASTQ(s) for extraction.
    ///
    /// Tries (in order):
    /// 1. `config.originalInputFiles` if non-nil (preserved before
    ///    materialization). If the resulting URL is a bundle, uses the
    ///    `FASTQBundle.resolvePrimaryFASTQURL` resolver.
    /// 2. Walking up from `config.outputDirectory` to find the enclosing
    ///    `.lungfishfastq` bundle.
    /// 3. Falls back to `config.inputFiles` directly.
    private func resolveKraken2SourceFASTQs(
        classResult: ClassificationResult
    ) throws -> [URL] {
        try Self.resolveKraken2SourceFASTQs(classResult: classResult)
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
