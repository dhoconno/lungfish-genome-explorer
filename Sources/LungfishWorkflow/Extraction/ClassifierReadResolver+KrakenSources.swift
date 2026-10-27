// ClassifierReadResolver+KrakenSources.swift - The Kraken2 dispatch of ClassifierReadResolver and its source reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "ClassifierReadResolver")

/// The layout an extraction's output records (D7d): interleaved when it
/// holds only pairs, single-end with read roles in the form a merge recipe
/// records when it mixes pairs with single reads, and single-end otherwise.
/// The app's bundle destination records it, and so does `lungfish-cli
/// extract reads --by-classifier --bundle`, which wraps a file output.
public struct ClassifierExtractionLayout: Sendable, Equatable {
    public let pairingMode: IngestionMetadata.PairingMode
    public let roles: ReadClassification?

    public init(pairingMode: IngestionMetadata.PairingMode, roles: ReadClassification?) {
        self.pairingMode = pairingMode
        self.roles = roles
    }

    /// Single-end with no roles, the layout of every output that holds no
    /// mates.
    public static let singleEnd = ClassifierExtractionLayout(pairingMode: .singleEnd, roles: nil)

    /// The roles with every entry naming `payload`, the one file that holds
    /// all of them.
    public func roles(namedFor payload: URL) -> ReadClassification? {
        roles.map { roles in
            ReadClassification(files: roles.files.map {
                .init(filename: payload.lastPathComponent, role: $0.role, readCount: $0.readCount)
            })
        }
    }
}

extension ClassifierReadResolver {
    // MARK: - Kraken2 dispatch

    /// The Kraken2 extraction of `selections`. A job with no sample reads `resolvedSources` when the
    /// caller gives them, the read files a taxa collection resolves once for all its taxa (the review of
    /// lane 12.11 c4, fix 5), and resolves the files its result records otherwise.
    func extractViaKraken2(
        selections: [ClassifierRowSelector],
        resultPath: URL,
        options: ExtractionOptions,
        destination: ExtractionDestination,
        runClock: ProvenanceRunClock,
        resolvedSources: KrakenResultReadSources? = nil,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> (outcome: ExtractionOutcome, layout: ClassifierExtractionLayout, sourceFiles: [URL]) {
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
        // Every read file the samples were extracted from, which a collection file's record names.
        var readFiles: [URL] = []
        // The R1 and R2 reads of every pair of files, each R1 record followed
        // by its R2 record, go into one file, and the reads of every other
        // file follow it: all pairs first, then the single reads (D7d). The
        // loop only extracts. The two files are written after it through
        // DurableReplace, since a staged write cannot span the awaits of the
        // loop (Phase 2.10 lane S31).
        let pairsFile = tempDir.appendingPathComponent("kraken2-pairs.fastq")
        let readsFile = tempDir.appendingPathComponent("kraken2-reads.fastq")
        var extractedSamples: [(outputs: [URL?], files: [KrakenResultReadSources.File])] = []
        // Whether any sample's reads hold mates, so the output may too.
        var sourcesHoldMates = false
        var singleReadRole = ReadClassification.FileRole.unpaired
        // The completion message's note for each sample whose files changed but whose reads did not.
        var readChangeNotes: [String] = []
        // How many samples were skipped because their reads changed, so a batch that skips all of them says so.
        var readsChangedSkips = 0

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
            // oriented subset is materialized into the temp folder, unless
            // the caller resolved the files of a single result already.
            let sources: KrakenResultReadSources
            do {
                if job.sampleId == nil, let resolvedSources {
                    sources = resolvedSources
                } else {
                    sources = try await KrakenResultReadSources.resolve(
                        result: classResult,
                        materializationDirectory: tempDir.appendingPathComponent("sources-\(jobIndex)", isDirectory: true)
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch ClassifierExtractionError.sourceNotInProject(let place, let action) where job.sampleId == nil {
                // One result refuses in its own words rather than as a skipped sample (WF-3).
                throw ClassifierExtractionError.sourceNotInProject(place: place, action: action)
            } catch {
                logger.warning(
                    "Skipping sample \(sampleLabel, privacy: .private(mask: .hash)) — source FASTQ not found: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                skippedSamples.append(sampleLabel)
                continue
            }
            let sourceFASTQs = sources.urls
            readFiles.append(contentsOf: sourceFASTQs)
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
                includeChildren: options.taxonScope.includesChildren,
                sourceFiles: sourceFASTQs,
                outputFiles: outputFiles,
                classificationOutput: classResult.outputURL,
                taxonomyReport: options.taxonScope.includesChildren ? classResult.reportURL : nil,
                keepReadPairs: true
            )

            progress?(baseFraction * 0.8 + 0.1 * sampleWeight, "Extracting \(sampleLabel)…")

            let pipeline = TaxonomyExtractionPipeline()
            let extraction = try await pipeline.extractEachFile(
                config: config,
                files: sources.files,
                tree: classResult.tree,
                progress: { fraction, message in
                    progress?(baseFraction * 0.8 + fraction * 0.7 * sampleWeight, "\(sampleLabel): \(message)")
                }
            )

            // Every read the selection names must be there with the length kraken2 recorded, or the files at the
            // result's place hold other reads under the same names (BIO-READ-IDENTITY 4.1). One result refuses in
            // words, and a batch skips the sample with the same words.
            guard extraction.check.passes else {
                for case let output? in extraction.outputs { try? FileManager.default.removeItem(at: output) }
                let refusal = ClassifierExtractionError.readsChanged(
                    place: KrakenResultReadSources.place(of: sources.inputs), check: extraction.check
                )
                guard job.sampleId != nil else { throw refusal }
                logger.warning("Skipping sample \(sampleLabel, privacy: .private(mask: .hash)): \(refusal.localizedDescription, privacy: .public)")
                progress?(baseFraction * 0.8 + 0.7 * sampleWeight, "\(sampleLabel): \(refusal.localizedDescription)")
                skippedSamples.append(sampleLabel)
                readsChangedSkips += 1
                continue
            }
            // The files changed since the run, by the sizes it recorded, though every read it names is there (4.2, 4.3).
            if KrakenResultReadSources.readFilesChanged(since: classResult.config) {
                readChangeNotes.append(KrakenResultReadSources.changedReadsNote(place: KrakenResultReadSources.place(of: sources.inputs)))
            }
            extractedSamples.append((extraction.outputs, sources.files))
        }

        // The pairs of every sample go into one file and the other reads into
        // the other, in sample order. Each is named once it is whole and
        // synced, the reads file first, and the two share one full flush.
        try DurableReplace.transaction {
            try ReadFileWriters.publish(pairsFile) { pairsStage in
                try ReadFileWriters.publish(readsFile) { readsStage in
                    for sample in extractedSamples {
                        try Task.checkCancellation()
                        _ = try TaxonomyExtractionPipeline.writeExtractedReads(
                            sample.outputs,
                            of: sample.files,
                            pairs: pairsStage,
                            reads: readsStage
                        )
                    }
                }
            }
        }

        let producedURLs = [pairsFile, readsFile].filter {
            ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? UInt64) ?? 0) > 0
        }
        guard !producedURLs.isEmpty else {
            if !skippedSamples.isEmpty {
                throw readsChangedSkips == skippedSamples.count
                    ? ClassifierExtractionError.allSamplesReadsChanged(skippedSamples)
                    : ClassifierExtractionError.allSamplesSkipped(skippedSamples)
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
        let recorded = Self.recordingReadChangeNotes(readChangeNotes, in: destination, options: options)
        let outcome = try await routeToDestination(
            finalFile: finalFile,
            readCount: readCount,
            destination: recorded.destination,
            options: recorded.options,
            provenanceSourceURLs: existingUniqueURLs(provenanceSourceURLs),
            extractionClock: runClock,
            outputPairingMode: layout.mode,
            outputRoles: layout.roles,
            progress: progress
        )
        for note in readChangeNotes {
            progress?(1.0, note)
        }
        if !skippedSamples.isEmpty {
            progress?(
                1.0,
                "Extracted \(readCount) reads. Skipped \(skippedSamples.count) sample(s) with unresolvable source data: \(skippedSamples.joined(separator: ", "))"
            )
        }
        return (outcome, ClassifierExtractionLayout(pairingMode: layout.mode, roles: layout.roles), readFiles)
    }

    /// `destination` and `options` that carry `notes`, the words that the files changed but the reads did not, into
    /// the extraction's record as well as its completion message (BIO-READ-IDENTITY 4.3): a bundle's parameters, from
    /// which its provenance step takes its own, and a file export's resolved options.
    static func recordingReadChangeNotes(
        _ notes: [String], in destination: ExtractionDestination, options: ExtractionOptions
    ) -> (destination: ExtractionDestination, options: ExtractionOptions) {
        guard !notes.isEmpty else { return (destination, options) }
        let note = notes.joined(separator: " ")
        var recorded = destination
        if case .bundle(let projectRoot, let displayName, let metadata) = destination {
            recorded = .bundle(
                projectRoot: projectRoot, displayName: displayName,
                metadata: metadata.mergingParameters(["classifierExtractionReadsChangedNote": note])
            )
        }
        let recordedOptions = options.fileProvenance.map {
            options.recordingFileProvenance($0.mergingResolved(["readsChangedNote": .string(note)]))
        } ?? options
        return (recorded, recordedOptions)
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
