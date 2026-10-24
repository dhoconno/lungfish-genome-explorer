// FASTQBatchImporter.swift - Batch FASTQ pair detection and recipe-driven import
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore
import LungfishIO

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "FASTQBatchImporter")

// MARK: - ImportLogEvent

/// Structured log events emitted during a batch import run.
public enum ImportLogEvent: Sendable {
    case importStart(sampleCount: Int, recipeName: String?)
    /// The platform one sample is imported as, decided before it starts.
    case platformResolved(
        sample: String, platform: String, source: String, confidence: String,
        readClass: String?, evidence: [String], message: String
    )
    /// `unpaired` names a run's third file joined to the pair and is nil otherwise.
    case sampleStart(sample: String, index: Int, total: Int, r1: String, r2: String?, unpaired: String? = nil)
    case stepStart(sample: String, step: String, stepIndex: Int, totalSteps: Int)
    case stepComplete(sample: String, step: String, durationSeconds: Double)
    case notice(sample: String, message: String)
    case recipeReadDelta(
        sample: String,
        label: String,
        inputReads: Int,
        outputReads: Int,
        readsRemoved: Int,
        percentRemoved: Double
    )
    case sampleComplete(sample: String, bundle: String, durationSeconds: Double, originalBytes: Int64, finalBytes: Int64)
    case sampleSkip(sample: String, reason: String)
    case sampleFailed(sample: String, error: String)
    case importComplete(completed: Int, skipped: Int, failed: Int, totalDurationSeconds: Double)
}

// MARK: - FASTQBatchImporter

/// Namespace for FASTQ batch import utilities.
///
/// Provides pair detection, recipe resolution, skip logic, structured logging,
/// and sequential batch processing with memory-safe inter-sample cleanup.
public enum FASTQBatchImporter {

    // MARK: - Nested Types

    /// Configuration for a batch import run.
    /// How input files pair up, as chosen in the Import FASTQ sheet's Pairing
    /// popup or `lungfish-cli import fastq --pairing`.
    ///
    /// `auto` and `paired` pair files by their R1/R2 names (the historical
    /// behaviour); `single` imports every file as its own single-end sample;
    /// `interleaved` also imports every file on its own but records each one
    /// as interleaved mates, so downstream tools treat it as pairs.
    public enum ImportPairing: String, Sendable, CaseIterable {
        case auto
        case single
        case paired
        case interleaved

        /// Whether detected R1/R2 pairs are kept together.
        public var keepsDetectedPairs: Bool {
            switch self {
            case .auto, .paired: return true
            case .single, .interleaved: return false
            }
        }
    }

    /// Result of a completed batch import run.
    public struct ImportResult: Sendable {
        public let completed: Int
        public let skipped: Int
        public let failed: Int
        public let totalDurationSeconds: Double
        public let errors: [(sample: String, error: String)]
        public let cancelled: Bool // a cancel stopped the batch before every sample was done
    }

    struct RequiredSeqkitStats: Sendable, Equatable {
        let metadata: SeqkitStatsMetadata
        let medianReadLength: Int
        let n50ReadLength: Int
    }

    static func resolveHumanScrubberDatabasePath(
        databaseID: String,
        registry: DatabaseRegistry = .shared
    ) async throws -> URL {
        let resolvedID = canonicalHumanScrubDatabaseID(for: databaseID)
        return try await registry.requiredDatabasePath(for: resolvedID)
    }

    private static func canonicalHumanScrubDatabaseID(for databaseID: String) -> String {
        let canonical = DatabaseRegistry.canonicalDatabaseID(for: databaseID)
        if canonical == HumanScrubberDatabaseInstaller.databaseID {
            return DeaconPanhumanDatabaseInstaller.databaseID
        }
        return canonical
    }

    // MARK: - Pair Detection

    /// Scans `directory` for FASTQ or BAM read inputs and groups FASTQ files into pairs.
    ///
    /// - Throws: `BatchImportError.noFASTQFilesFound` when no supported read files are present.
    public static func detectPairsFromDirectory(_ directory: URL) throws -> [SamplePair] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let fastqURLs = contents
            .filter(SequencingReadImportSource.isSupported)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !fastqURLs.isEmpty else {
            throw BatchImportError.noFASTQFilesFound(directory)
        }

        return detectPairs(from: fastqURLs)
    }

    /// The pairing an import records for one sample, and where it came from.
    public struct RecordedPairing: Sendable, Equatable {
        public let mode: IngestionMetadata.PairingMode
        public let source: IngestionMetadata.PairingSource
    }

    /// Decides the pairing an import records in `ingestion.pairingMode`.
    ///
    /// - An R1/R2 pair is stored interleaved: `explicit` under `--pairing
    ///   paired`, `detected` (from the file names) under `auto`.
    /// - `--pairing single` and `--pairing interleaved` are explicit choices.
    /// - `auto` (or `paired`) on a single file reads its records: a strictly
    ///   interleaved file records `interleaved`, anything else `single_end`,
    ///   both `detected`. A mixed file (merged reads between pairs) records
    ///   `single_end` so no tool pairs it by position; consumers still scan it
    ///   because a detected `single_end` is not final
    ///   (``FASTQPairingMetadataHints/recordsExplicitSingleEnd``).
    public static func recordedPairing(
        pairing: ImportPairing,
        r1: URL,
        hasR2: Bool
    ) -> RecordedPairing {
        if hasR2 {
            return RecordedPairing(mode: .interleaved, source: pairing == .paired ? .explicit : .detected)
        }
        switch pairing {
        case .single:
            return RecordedPairing(mode: .singleEnd, source: .explicit)
        case .interleaved:
            return RecordedPairing(mode: .interleaved, source: .explicit)
        case .auto, .paired:
            let layout = FASTQReadLayoutClassifier.classify(inputURL: r1).layout
            return RecordedPairing(
                mode: layout == .strictlyInterleaved ? .interleaved : .singleEnd,
                source: .detected
            )
        }
    }

    /// The pairing to record once a recipe has rewritten the reads.
    ///
    /// A file of merged reads and adjacent unmerged pairs, or of pairs and a
    /// run's reads whose mate is missing, is labelled by its count with the
    /// convention every importer follows (`FASTQMixedLayoutHint.pairingMode`).
    /// It is `single_end` when it holds any single read and `interleaved` for
    /// pairs alone, and the sidecar's read classification carries the counts.
    /// Both are `detected`. Paired-file input the recipe left paired keeps
    /// the import's own record.
    static func recordedPairing(
        afterRecipeOutput format: RecipeFileFormat,
        mixedLayout: RecipeMixedLayoutCounts?,
        importedAs imported: RecordedPairing
    ) -> RecordedPairing {
        switch format {
        case .mixed:
            let pairs = mixedLayout?.pairs ?? 0, singles = (mixedLayout?.mergedReads ?? 0) + (mixedLayout?.unpairedReads ?? 0)
            return RecordedPairing(mode: FASTQMixedLayoutHint.pairingMode(pairs: pairs, singles: singles), source: .detected)
        case .single:
            return RecordedPairing(mode: .singleEnd, source: .detected)
        case .interleaved:
            return RecordedPairing(mode: .interleaved, source: imported.mode == .interleaved ? imported.source : .detected)
        case .pairedR1R2, .merged:
            return imported
        }
    }

    /// The sidecar read classification for a recipe's mixed output, or nil
    /// when no recipe produced one. Every role names the bundle's one FASTQ:
    /// the counts describe kinds of records inside it, not separate files.
    static func readClassification(
        forMixedLayout layout: RecipeMixedLayoutCounts?,
        bundleFASTQName: String
    ) -> ReadClassification? {
        guard let layout else { return nil }
        var entries: [ReadClassification.FileEntry] = []
        if layout.mergedReads > 0 {
            entries.append(ReadClassification.FileEntry(filename: bundleFASTQName, role: .merged, readCount: layout.mergedReads))
        }
        if layout.pairs > 0 {
            entries.append(ReadClassification.FileEntry(filename: bundleFASTQName, role: .pairedR1, readCount: layout.pairs))
            entries.append(ReadClassification.FileEntry(filename: bundleFASTQName, role: .pairedR2, readCount: layout.pairs))
        }
        if layout.unpairedReads > 0 {
            entries.append(ReadClassification.FileEntry(filename: bundleFASTQName, role: .unpaired, readCount: layout.unpairedReads))
        }
        guard !entries.isEmpty else { return nil }
        return ReadClassification(files: entries)
    }

    /// Applies a pairing choice to detected samples.
    ///
    /// `single` and `interleaved` split every R1/R2 pair, and its unpaired
    /// reads, into single-file samples named after each file's stem (so `s_R1`
    /// and `s_R2` do not collide); `auto` and `paired` leave the detection untouched.
    public static func applyPairing(_ pairing: ImportPairing, to pairs: [SamplePair]) -> [SamplePair] {
        guard !pairing.keepsDetectedPairs else { return pairs }
        return pairs.flatMap { pair -> [SamplePair] in
            guard pair.r2 != nil else { return [pair] }
            return pair.inputFiles.map { url in
                SamplePair(
                    sampleName: fastqStem(url),
                    r1: url,
                    r2: nil,
                    relativePath: pair.relativePath,
                    metadata: pair.metadata,
                    sampleSheetURL: pair.sampleSheetURL
                )
            }
        }.sorted { $0.sampleName < $1.sampleName }
    }

    // MARK: - Recipe Resolution

    /// Resolves a short recipe name to a built-in `ProcessingRecipe`.
    ///
    /// - Parameter named: Case-insensitive short name. Valid values: `"vsp2"`, `"wgs"`, `"hifi"`.
    ///   Pass `nil` recipe in `ImportConfig` rather than `"none"` to skip recipe processing.
    /// - Throws: `BatchImportError.unknownRecipe` for unrecognized names.
    public static func resolveRecipe(named name: String) throws -> ProcessingRecipe {
        switch name.lowercased() {
        case "vsp2":
            return .illuminaVSP2TargetEnrichment
        case "wgs":
            return .illuminaWGS
        case "amplicon":
            throw BatchImportError.unsupportedRecipe(
                name,
                reason: "the legacy amplicon template includes primer removal, which batch import cannot execute without concrete primer parameters."
            )
        case "hifi":
            return .pacbioHiFi
        default:
            throw BatchImportError.unknownRecipe(name)
        }
    }

    // MARK: - Bundle Output Path

    /// Computes the output bundle URL, incorporating `relativePath` for
    /// recursive directory imports.
    ///
    /// - Standard: `<project>/Imports/<sampleName>.lungfishfastq`
    /// - Recursive: `<project>/Imports/<relativePath>/<sampleName>.lungfishfastq`
    public static func bundleOutputURL(for pair: SamplePair, in projectDirectory: URL) -> URL {
        var importsDir = projectDirectory.appendingPathComponent("Imports")
        if let rel = pair.relativePath {
            importsDir = importsDir.appendingPathComponent(rel)
        }
        return importsDir.appendingPathComponent("\(pair.sampleName).\(FASTQBundle.directoryExtension)")
    }

    // MARK: - Skip Logic

    /// Returns `true` when a `.lungfishfastq` bundle already exists for `pair` in `projectDir`.
    public static func bundleExists(for pair: SamplePair, in projectDir: URL) -> Bool {
        let bundleURL = bundleOutputURL(for: pair, in: projectDir)
        return isCompleteFASTQImportBundle(at: bundleURL)
    }

    enum ExistingImportBundleStatus {
        case missing
        case complete
        case incomplete(URL)
    }

    static func existingImportBundleStatus(
        for pair: SamplePair,
        in projectDir: URL
    ) -> ExistingImportBundleStatus {
        let bundleURL = bundleOutputURL(for: pair, in: projectDir)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            return .missing
        }
        return isCompleteFASTQImportBundle(at: bundleURL) ? .complete : .incomplete(bundleURL)
    }

    private static func isCompleteFASTQImportBundle(at bundleURL: URL) -> Bool {
        guard FASTQBundle.isBundleURL(bundleURL),
              let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL),
              let metadata = FASTQMetadataStore.load(for: fastqURL),
              metadata.computedStatistics != nil,
              metadata.seqkitStats != nil,
              ((try? ProvenanceEnvelopeReader.load(from: bundleURL)) ?? nil) != nil else {
            return false
        }

        let rollupURL = bundleURL
            .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
        guard ((try? ProvenanceEnvelopeReader.load(fromSidecar: rollupURL)) ?? nil) != nil else {
            return false
        }

        guard let focusedSidecarURL = ProvenanceWriter.bundleOutputSidecarURL(for: fastqURL, inBundle: bundleURL),
              let focusedEnvelope = (try? ProvenanceEnvelopeReader.load(fromSidecar: focusedSidecarURL)) ?? nil,
              provenanceEnvelope(focusedEnvelope, matchesCurrentFASTQAt: fastqURL) else {
            return false
        }

        return true
    }

    private static func provenanceEnvelope(_ envelope: ProvenanceEnvelope, matchesCurrentFASTQAt fastqURL: URL) -> Bool {
        let currentPath = fastqURL.standardizedFileURL.path
        guard let currentSize = try? ProvenanceFileHasher.fileSize(of: fastqURL),
              let currentChecksum = try? ProvenanceFileHasher.sha256(of: fastqURL) else {
            return false
        }

        let descriptors = envelope.files
            + envelope.outputs
            + envelope.steps.flatMap(\.outputs)
            + (envelope.output.map { [$0] } ?? [])
        return descriptors.contains { descriptor in
            URL(fileURLWithPath: descriptor.path).standardizedFileURL.path == currentPath
                && descriptor.role == .output
                && descriptor.fileSize == currentSize
                && descriptor.checksumSHA256 == currentChecksum
        }
    }

    static func prepareFASTQBundleParent(for bundleURL: URL) throws {
        try FileManager.default.createDirectory(
            at: bundleURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    static func makeStagingFASTQBundleURL(for publishedBundleURL: URL) throws -> URL {
        let parentURL = publishedBundleURL.deletingLastPathComponent()
        let baseName = publishedBundleURL.deletingPathExtension().lastPathComponent
        let stagingName = ".\(baseName).building-\(UUID().uuidString)"
        return parentURL.appendingPathComponent(stagingName, isDirectory: true)
    }

    private static func replacementBackupName(for publishedBundleURL: URL) -> String {
        ".\(publishedBundleURL.lastPathComponent).replacing-\(UUID().uuidString)"
    }

    static func publishFASTQBundle(
        from stagingBundleURL: URL,
        to publishedBundleURL: URL,
        replaceExisting: Bool
    ) throws {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: publishedBundleURL.path) {
            guard replaceExisting else {
                throw BatchImportError.outputBundleAlreadyExists(publishedBundleURL)
            }
            let backupName = replacementBackupName(for: publishedBundleURL)
            _ = try fileManager.replaceItemAt(
                publishedBundleURL,
                withItemAt: stagingBundleURL,
                backupItemName: backupName,
                options: []
            )
            let backupURL = publishedBundleURL
                .deletingLastPathComponent()
                .appendingPathComponent(backupName, isDirectory: true)
            // Move the replaced bundle to the Trash rather than
            // permanently deleting it, so a Replace during FASTQ re-import
            // stays recoverable. Fall back to a hard delete only if Trash is
            // unavailable (e.g. a non-user-domain volume).
            do {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: backupURL, resultingItemURL: &resultingURL)
            } catch {
                try? fileManager.removeItem(at: backupURL)
            }
            return
        }

        try fileManager.moveItem(at: stagingBundleURL, to: publishedBundleURL)
    }

    // MARK: - Structured Logging

    /// Writes a human-readable progress message to stderr.
    public static func printProgress(_ message: String) {
        let standardError = FileHandle.standardError
        let output = message + "\n"
        if let data = output.data(using: .utf8) {
            // A progress line never ends the import, as the raising
            // `write(_:)` did when stderr had closed.
            try? standardError.write(contentsOf: data)
        }
    }

    static func recipeReadDeltaEvents(sample: String, recipeApplied: RecipeAppliedInfo) -> [ImportLogEvent] {
        var events: [ImportLogEvent] = []
        if let summary = recipeApplied.deduplicationSummary {
            events.append(readDeltaEvent(sample: sample, label: "Deduplication", summary: summary))
        }
        if let summary = recipeApplied.humanScrubSummary {
            events.append(readDeltaEvent(sample: sample, label: "Human scrub", summary: summary))
        }
        return events
    }

    private static func readDeltaEvent(
        sample: String,
        label: String,
        summary: RecipeAppliedInfo.ReadDeltaSummary
    ) -> ImportLogEvent {
        .recipeReadDelta(
            sample: sample,
            label: label,
            inputReads: summary.inputReads,
            outputReads: summary.outputReads,
            readsRemoved: summary.readsRemoved,
            percentRemoved: summary.percentRemoved
        )
    }

    /// Resolves the storage tool once for an ingestion invocation and records
    /// any filtering disclosure before the invocation begins.
    static func runIngestionPipeline(
        sample: String,
        config: FASTQIngestionConfig,
        estimatedInputBytes: Int64? = nil,
        physicalMemoryBytes: Int64 = Int64(clamping: ProcessInfo.processInfo.physicalMemory),
        log: (@Sendable (ImportLogEvent) -> Void)?,
        invoke: @escaping @Sendable (ClumpingToolResolution) async throws -> FASTQIngestionResult
    ) async throws -> FASTQIngestionResult {
        let estimatedBytes = estimatedInputBytes
            ?? FASTQIngestionPipeline.estimatedUncompressedInputBytes(for: config.inputFiles)
        let resolution = config.clumpingTool.resolve(
            estimatedInputBytes: estimatedBytes,
            physicalMemoryBytes: physicalMemoryBytes,
            pinnedHeapGB: config.clumpifyHeapGB
        )
        if let message = resolution.resolved.operationNotice {
            log?(.notice(sample: sample, message: message))
        }
        return try await invoke(resolution)
    }

    // MARK: - Main Entry Point

    /// Processes all samples in `pairs` sequentially using the provided configuration.
    ///
    /// Uses `autoreleasepool` between samples to bound peak memory usage.
    /// Samples that already have bundles are skipped (logged as `sampleSkip`).
    /// No sample writes a bundle an earlier sample of the batch wrote or failed to write (``start(of:config:after:)``).
    ///
    /// - Parameters:
    ///   - pairs: Detected sample pairs to process.
    ///   - config: Import configuration (recipe, threads, directories).
    ///   - log: Optional callback for structured log events.
    /// - Returns: Summary of completed, skipped, and failed sample counts.
    static func runBatchImportInScope(
        _ pairs: [SamplePair], _ config: ImportConfig, _ log: (@Sendable (ImportLogEvent) -> Void)?, _ databaseRegistry: DatabaseRegistry
    ) async -> ImportResult {
        let startTime = Date()
        let recipeName = config.newRecipe?.name ?? config.recipe?.name

        log?(.importStart(sampleCount: pairs.count, recipeName: recipeName))
        logger.info("Batch import starting: \(pairs.count) samples, recipe=\(recipeName ?? "none")")

        var completed = 0
        var skipped = 0
        var cancelled = false
        var errors: [(sample: String, error: String)] = []
        var written = BundlesWrittenByThisImport() // no sample writes one of these, whatever --force says

        for (index, pair) in pairs.enumerated() {
            if Task.isCancelled { cancelled = true; break } // a cancel (lungfish-cli turns SIGTERM into one) stops the batch
            // Decide before allocating anything
            switch start(of: pair, config: config, after: written) {
            case .skip(let reason):
                log?(.sampleSkip(sample: pair.sampleName, reason: reason))
                logger.info("Skipping \(pair.sampleName): \(reason)")
                skipped += 1
                continue
            case .fail(let error):
                recordFailure(error, of: pair.sampleName, log: log, into: &errors)
                continue
            case .run:
                break
            }

            // Process this sample; autoreleasepool drains synchronous ObjC objects between iterations
            let result = await processSingleSample(
                pair: pair,
                config: sampleConfig(for: pair, config: config, log: log),
                sampleIndex: index,
                totalSamples: pairs.count,
                log: log,
                databaseRegistry: databaseRegistry
            )
            autoreleasepool { }

            switch result {
            case .success(let bundleURL):
                completed += 1
                written.insert(bundleURL)
            case .failure where failureEndedByCancel():
                recordCancel(of: pair.sampleName) // a cancel, not a failed sample
                cancelled = true
            case .failure(let error):
                recordFailure(error, of: pair.sampleName, log: log, into: &errors)
                written.insertFailed(bundleOutputURL(for: pair, in: config.projectDirectory))
            }
        }

        let totalDuration = Date().timeIntervalSince(startTime)
        log?(.importComplete(
            completed: completed, skipped: skipped, failed: errors.count, totalDurationSeconds: totalDuration
        ))
        logger.info("Batch import complete: \(completed) completed, \(skipped) skipped, \(errors.count) failed in \(String(format: "%.1f", totalDuration))s")

        return ImportResult(
            completed: completed, skipped: skipped, failed: errors.count,
            totalDurationSeconds: totalDuration, errors: errors, cancelled: cancelled
        )
    }

    // MARK: - Single Sample Processing

    /// Processes one sample pair: runs the ingestion pipeline, optionally applies recipe steps.
    private static func processSingleSample(
        pair: SamplePair,
        config: ImportConfig,
        sampleIndex: Int,
        totalSamples: Int,
        log: (@Sendable (ImportLogEvent) -> Void)?,
        databaseRegistry: DatabaseRegistry
    ) async -> Result<URL, Error> {
        let sampleClock = ProvenanceRunClock()
        log?(.sampleStart(
            sample: pair.sampleName, index: sampleIndex, total: totalSamples, r1: pair.r1.lastPathComponent,
            r2: pair.r2?.lastPathComponent, unpaired: pair.unpaired?.lastPathComponent
        ))

        let originalBytes = fileSizeSum(pair.inputFiles)

        do {
            let outputDir = config.projectDirectory
                .appendingPathComponent("Imports")
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            // Create a temp workspace for intermediate files inside the project's
            // .tmp/ directory. This keeps intermediates co-located with the project
            // (on the same volume) and avoids confusion with system temp files.
            let workspace = try ProjectTempDirectory.create(
                prefix: "fastq-import-", in: config.projectDirectory
            )
            defer { try? FileManager.default.removeItem(at: workspace) }

            let materialization = try await ONTBAMImportMaterializer.materializeIfNeeded(
                pair: pair,
                platform: config.sequencingPlatform,
                workspace: workspace,
                threads: config.threads
            )
            let processingPair = materialization.processingPair
            try validateRecipeApplicability(pair: processingPair, config: config)
            // Decided on the reads as imported, before any recipe or storage
            // step: clumpify must keep the mates of an interleaved file
            // adjacent, and the sidecar records what the user chose or what
            // the records showed.
            var recordedPairing = Self.recordedPairing(
                pairing: config.pairing,
                r1: processingPair.r1,
                hasR2: processingPair.r2 != nil
            )
            let importedPairing = recordedPairing // what the durable command names, ``durablePairing``
            // Filled in when a recipe merged pairs: the bundle then holds
            // merged reads and adjacent pairs, which the sidecar records by
            // count so consumers do not take "interleaved" at face value.
            var recipeMixedLayout: RecipeMixedLayoutCounts? = nil

            // Step 1: Apply recipe if provided (BEFORE clumpify — recipe changes the
            // read population, so k-mer grouping must be computed on the final reads)
            var recipeOutputFASTQ: URL? = nil
            var isPairedAfterRecipe = processingPair.r2 != nil
            var recipeStepResults: [RecipeStepResult] = []
            var reportableRecipeStepCount = config.recipe?.steps.count ?? 0

            if let newRecipe = config.newRecipe {
                // New-format declarative recipe: delegate to RecipeEngine
                let engine = RecipeEngine()
                let inputFormat: RecipeFileFormat = processingPair.r2 != nil ? .pairedR1R2 : .single
                let stepInput = StepInput(r1: processingPair.r1, r2: processingPair.r2, format: inputFormat)
                reportableRecipeStepCount = try engine.reportableStepCount(
                    recipe: newRecipe,
                    inputFormat: inputFormat
                )

                // Track the in-progress step so we can emit stepComplete when the next step starts
                // (or after execute() returns for the final step). Uses a class for shared mutation
                // across the @Sendable progress closure and the post-execute cleanup block.
                final class RecipeStepTracker: @unchecked Sendable {
                    var currentStep: String? = nil
                    var stepStart: Date = Date()
                    var stepIndex: Int = 0
                    var totalSteps: Int = 0
                }
                let tracker = RecipeStepTracker()
                // Total includes recipe steps + clumpify + stats
                tracker.totalSteps = reportableRecipeStepCount + 2

                let stepContext = StepContext(
                    workspace: workspace,
                    threads: config.threads,
                    sampleName: pair.sampleName,
                    runner: NativeToolRunner.shared,
                    progress: { [tracker] _, message in
                        let now = Date()
                        // Emit stepComplete for any step that was already in progress
                        if let prev = tracker.currentStep {
                            log?(.stepComplete(sample: pair.sampleName, step: prev,
                                               durationSeconds: now.timeIntervalSince(tracker.stepStart)))
                        }
                        tracker.currentStep = message
                        tracker.stepStart = now
                        tracker.stepIndex += 1
                        log?(.stepStart(sample: pair.sampleName, step: message,
                                        stepIndex: tracker.stepIndex, totalSteps: tracker.totalSteps))
                    }
                )
                let result = try await engine.execute(recipe: newRecipe, input: stepInput, context: stepContext)
                let output = result.output
                recipeStepResults = result.stepRecords
                // Emit stepComplete for the last recipe step
                if let lastStep = tracker.currentStep {
                    log?(.stepComplete(sample: pair.sampleName, step: lastStep,
                                       durationSeconds: Date().timeIntervalSince(tracker.stepStart)))
                }
                var currentURL = output.r1
                var outputFormat = output.format
                recipeMixedLayout = output.mixedLayout
                // The engine normalizes a merged layout to one mixed file
                // itself; this keeps the same shape (merged reads first,
                // then each pair adjacent) should a step contract ever hand
                // the three files back.
                if output.format == .merged {
                    let combined = workspace.appendingPathComponent("\(pair.sampleName)_mixed.fastq")
                    recipeMixedLayout = try await RecipeEngine.writeMixedLayout(
                        merged: output.r1,
                        unmergedR1: output.r2,
                        unmergedR2: output.r3,
                        to: combined
                    )
                    currentURL = combined
                    outputFormat = .mixed
                }
                recipeOutputFASTQ = currentURL
                // New-format recipes produce interleaved, mixed, or single output.
                isPairedAfterRecipe = outputFormat == .interleaved || outputFormat == .mixed
                recordedPairing = Self.recordedPairing(
                    afterRecipeOutput: outputFormat,
                    mixedLayout: recipeMixedLayout,
                    importedAs: recordedPairing
                )
            } else if let recipe = config.recipe, !recipe.steps.isEmpty {
                // Old-format recipe: use existing applyRecipe() code path
                recipeOutputFASTQ = try await applyRecipe(
                    recipe: recipe,
                    inputR1: processingPair.r1,
                    inputR2: processingPair.r2,
                    workspace: workspace,
                    pair: processingPair,
                    config: config,
                    log: log,
                    databaseRegistry: databaseRegistry
                )
                // After VSP2 recipe, output is interleaved (PE merge step produces mixed reads)
                isPairedAfterRecipe = true
            }

            // A run's reads without a mate join its pairs in one mixed file,
            // whose sidecar records the reads of each kind.
            let unpairedReads = try await writePairsThenUnpairedReads(of: processingPair, in: workspace, log: log)
            if let unpairedReads {
                recipeMixedLayout = unpairedReads.counts
                recordedPairing = Self.recordedPairing(
                    afterRecipeOutput: .mixed, mixedLayout: unpairedReads.counts, importedAs: recordedPairing
                )
            }

            // Step 2: Clumpify + compress (on recipe output, or raw input if no recipe)
            let originalInputURLs = pair.inputFiles
            let rawOriginalSizeBytes = totalFileSize(originalInputURLs)
            let clumpifyInput: [URL]
            let clumpifyPairingMode: FASTQIngestionConfig.PairingMode
            let deleteIngestionInputsAfterRun: Bool
            if let unpairedReads {
                clumpifyInput = [unpairedReads.file]
                clumpifyPairingMode = .interleaved // its pairs stay adjacent, whatever the label says
                deleteIngestionInputsAfterRun = true
            } else if let recipeOutput = recipeOutputFASTQ {
                clumpifyInput = [recipeOutput]
                clumpifyPairingMode = isPairedAfterRecipe ? .interleaved : .singleEnd
                deleteIngestionInputsAfterRun = true
            } else {
                let rawInputs = processingPair.r2 != nil
                    ? [processingPair.r1, processingPair.r2!]
                    : [processingPair.r1]
                if config.optimizeStorage && config.clumpingTool != .none {
                    clumpifyInput = rawInputs
                    deleteIngestionInputsAfterRun = false
                } else {
                    clumpifyInput = try stageRawInputsForIngestion(rawInputs, in: workspace)
                    deleteIngestionInputsAfterRun = true
                }
                // A single file is interleaved when the user said so or, under
                // auto, when its records alternate mates; the pipeline then
                // keeps pairs together and the metadata records them.
                clumpifyPairingMode = processingPair.r2 != nil
                    ? .pairedEnd
                    : (recordedPairing.mode == .interleaved ? .interleaved : .singleEnd)
            }

            let ingestionConfig = FASTQIngestionConfig(
                inputFiles: clumpifyInput,
                pairingMode: clumpifyPairingMode,
                outputDirectory: workspace,
                threads: config.threads,
                deleteOriginals: deleteIngestionInputsAfterRun,
                qualityBinning: config.qualityBinning,
                skipClumpify: config.clumpingTool == .none,
                compressionLevel: config.compressionLevel,
                clumpingTool: config.clumpingTool,
                clumpifyHeapGB: config.clumpifyHeapGB
            )

            // Total steps = recipe steps + clumpify + stats
            let recipeStepCount = reportableRecipeStepCount
            let totalSteps = recipeStepCount + 2  // +1 clumpify, +1 stats
            let clumpifyStepIndex = recipeStepCount + 1
            let statsStepIndex = recipeStepCount + 2
            let clumpifyLabel = config.optimizeStorage ? "Optimize storage + Compress" : "Compress"
            log?(.stepStart(sample: pair.sampleName, step: clumpifyLabel, stepIndex: clumpifyStepIndex, totalSteps: totalSteps))
            printProgress("  \u{2192} \(clumpifyLabel)...")
            let clumpifyClock = ProvenanceRunClock()

            let pipeline = FASTQIngestionPipeline()
            let ingestionResult = try await runIngestionPipeline(
                sample: pair.sampleName,
                config: ingestionConfig,
                log: log,
                invoke: { clumpingResolution in
                    try await pipeline.run(
                        config: ingestionConfig,
                        clumpingResolution: clumpingResolution,
                        progress: { _, msg in
                            logger.debug("\(pair.sampleName): \(msg)")
                        }
                    )
                }
            )

            log?(.stepComplete(
                sample: pair.sampleName,
                step: clumpifyLabel,
                durationSeconds: Date().timeIntervalSince(clumpifyClock.startedAt)
            ))
            if let removal = ingestionResult.readsRemovedByStorage { log?(.notice(sample: pair.sampleName, message: removal.notice)) }
            recipeStepResults.append(RecipeStepResult(
                stepName: clumpifyLabel,
                tool: ingestionResult.processingTool ?? (config.optimizeStorage ? ingestionResult.resolvedClumpingTool.rawValue : "compression"),
                toolVersion: ingestionResult.processingToolVersion, commandLine: ingestionResult.processingCommandLine,
                inputReadCount: ingestionResult.readsRemovedByStorage?.recordsRead,
                outputReadCount: ingestionResult.readsRemovedByStorage?.recordsStored,
                durationSeconds: clumpifyClock.elapsed
            ))
            printProgress("  \u{2192} \(clumpifyLabel)... done (\(Int(Date().timeIntervalSince(clumpifyClock.startedAt)))s)")

            let ingestionOutputURL = ingestionResult.outputFile

            // Step 3: Build the bundle under a hidden sibling directory, then
            // publish it with one same-volume rename after provenance succeeds.
            let bundleURL = bundleOutputURL(for: pair, in: config.projectDirectory)
            try prepareFASTQBundleParent(for: bundleURL)
            let stagingBundleURL = try makeStagingFASTQBundleURL(for: bundleURL)
            var didPublishBundle = false
            defer {
                if !didPublishBundle {
                    try? FileManager.default.removeItem(at: stagingBundleURL)
                }
            }
            try FileManager.default.createDirectory(at: stagingBundleURL, withIntermediateDirectories: true)

            let bundleFASTQName = "\(pair.sampleName).fastq.gz"
            let stagingBundleFASTQURL = stagingBundleURL.appendingPathComponent(bundleFASTQName)
            let publishedBundleFASTQURL = bundleURL.appendingPathComponent(bundleFASTQName)
            if ingestionOutputURL != stagingBundleFASTQURL {
                try? FileManager.default.removeItem(at: stagingBundleFASTQURL)
                try FileManager.default.moveItem(at: ingestionOutputURL, to: stagingBundleFASTQURL)
            }
            if !pair.metadata.isEmpty {
                var metadataPairs = pair.metadata
                metadataPairs["sample"] = pair.sampleName
                try FASTQBundleCSVMetadata.save(FASTQBundleCSVMetadata(keyValuePairs: metadataPairs), to: stagingBundleURL)
            }
            recipeStepResults = try materializeRecipeAuxiliaryOutputs(
                recipeStepResults,
                stagingBundleURL: stagingBundleURL,
                publishedBundleURL: bundleURL
            )

            // Write ingestion metadata sidecar
            let ingestion = IngestionMetadata(
                isClumpified: ingestionResult.wasClumpified,
                isCompressed: true,
                pairingMode: recordedPairing.mode,
                pairingSource: recordedPairing.source,
                qualityBinning: ingestionResult.qualityBinning.rawValue,
                originalFilenames: originalInputURLs.map(\.lastPathComponent),
                ingestionDate: Date(),
                originalSizeBytes: rawOriginalSizeBytes,
                storageInputSizeBytes: ingestionResult.originalSizeBytes,
                storageOutputSizeBytes: ingestionResult.finalSizeBytes
            )
            var metadata = PersistedFASTQMetadata()
            metadata.ingestion = ingestion
            metadata.readClassification = Self.readClassification(
                forMixedLayout: Self.storedMixedLayout(recipeMixedLayout, removing: ingestionResult.readsRemovedByStorage),
                bundleFASTQName: bundleFASTQName
            )
            applyPlatformMetadata(to: &metadata, config: config)
            if let recipe = config.newRecipe, !recipeStepResults.isEmpty {
                metadata.ingestion?.recipeApplied = RecipeAppliedInfo(
                    recipeID: recipe.id,
                    recipeName: recipe.name,
                    appliedDate: Date(),
                    stepResults: recipeStepResults,
                    recipeSHA256: recipe.sourceSHA256, recipeFormatVersion: recipe.formatVersion,
                    requestedName: recipe.requestedName,
                    presetID: recipe.resolution?.preset?.id,
                    presetName: recipe.resolution?.preset?.name,
                    switchSettings: recipe.switches.isEmpty ? nil : recipe.switchSettings
                )
            } else if let recipe = config.recipe, !recipeStepResults.isEmpty {
                metadata.ingestion?.recipeApplied = RecipeAppliedInfo(
                    recipeID: recipe.id.uuidString,
                    recipeName: recipe.name,
                    appliedDate: Date(),
                    stepResults: recipeStepResults
                )
            }
            FASTQMetadataStore.save(metadata, for: stagingBundleFASTQURL)
            if let recipeApplied = metadata.ingestion?.recipeApplied {
                for event in recipeReadDeltaEvents(sample: pair.sampleName, recipeApplied: recipeApplied) {
                    log?(event)
                }
            }

            // Write per-sample log if logDirectory is set
            if let logDir = config.logDirectory {
                writePerSampleLog(pair: pair, bundleURL: bundleURL, logDir: logDir)
            }

            // Step: Compute FASTQ statistics
            let statsLabel = "Compute statistics"
            log?(.stepStart(sample: pair.sampleName, step: statsLabel, stepIndex: statsStepIndex, totalSteps: totalSteps))
            let statsClock = ProvenanceRunClock()
            var statsError: String?
            do {
                try await computeAndCacheStatistics(for: stagingBundleFASTQURL)
            } catch {
                statsError = error.localizedDescription
                logger.warning("Stats computation failed for \(pair.sampleName): \(error)")
                throw error
            }
            let statsCompletedAt = statsClock.now
            log?(.stepComplete(sample: pair.sampleName, step: statsLabel,
                               durationSeconds: statsCompletedAt.timeIntervalSince(statsClock.startedAt)))
            recipeStepResults.append(RecipeStepResult(
                stepName: statsLabel,
                tool: "seqkit",
                toolVersion: nil,
                commandLine: nil,
                inputReadCount: nil,
                outputReadCount: nil,
                durationSeconds: statsCompletedAt.timeIntervalSince(statsClock.startedAt)
            ))

            try await writeImportProvenance(
                pair: pair,
                processingPair: processingPair,
                materializationSteps: materialization.provenanceSteps + (unpairedReads.map { [$0.step] } ?? []),
                unpairedReads: unpairedReads,
                config: config,
                importedPairing: importedPairing,
                stagingBundleURL: stagingBundleURL,
                stagingBundleFASTQURL: stagingBundleFASTQURL,
                publishedBundleURL: bundleURL,
                publishedBundleFASTQURL: publishedBundleFASTQURL,
                sourceIngestionOutputURL: ingestionResult.outputFile,
                ingestionResult: ingestionResult,
                recipeStepResults: recipeStepResults,
                runClock: sampleClock, statsStartedAt: statsClock.startedAt,
                statsCompletedAt: statsCompletedAt,
                statsError: statsError
            )
            try Task.checkCancellation() // the throw runs the defers that remove the staging bundle and workspace
            try publishFASTQBundle(
                from: stagingBundleURL,
                to: bundleURL,
                replaceExisting: config.forceReimport
            )
            didPublishBundle = true

            let finalBytes = bundleFileSize(bundleURL)
            let duration = sampleClock.elapsed

            log?(.sampleComplete(
                sample: pair.sampleName,
                bundle: bundleURL.lastPathComponent,
                durationSeconds: duration,
                originalBytes: originalBytes,
                finalBytes: finalBytes
            ))
            logger.info("Sample \(pair.sampleName) complete in \(String(format: "%.1f", duration))s")

            return .success(bundleURL)

        } catch {
            return .failure(error)
        }
    }

    private static func validateRecipeApplicability(pair: SamplePair, config: ImportConfig) throws {
        try validateImportKeepsUnpairedReads(pair: pair, config: config)
        if let recipe = config.newRecipe {
            try validateNewRecipeInputRequirement(recipe, pair: pair)
        }

        if let recipe = config.recipe {
            try validateLegacyRecipeInputRequirement(recipe, pair: pair)
        }
    }

    private static func validateNewRecipeInputRequirement(_ recipe: Recipe, pair: SamplePair) throws {
        switch recipe.requiredInput {
        case .any:
            return
        case .paired:
            guard pair.r2 != nil else {
                throw BatchImportError.recipeNotApplicable(
                    recipe: recipe.name,
                    sample: pair.sampleName,
                    reason: "requires paired-end reads (R1 and R2), but only R1 was detected."
                )
            }
        case .single:
            guard pair.r2 == nil else {
                throw BatchImportError.recipeNotApplicable(
                    recipe: recipe.name,
                    sample: pair.sampleName,
                    reason: "requires single-end reads, but both R1 and R2 were detected."
                )
            }
        }
    }

    private static func validateLegacyRecipeInputRequirement(_ recipe: ProcessingRecipe, pair: SamplePair) throws {
        if let unsupportedStep = recipe.steps.first(where: { !legacyBatchImportSupportedStepKinds.contains($0.kind) }) {
            throw BatchImportError.unsupportedRecipeStep(
                recipe: recipe.name,
                step: unsupportedStep.kind.rawValue
            )
        }

        if recipe.requiredPairingMode == .singleEnd, pair.r2 != nil {
            throw BatchImportError.recipeNotApplicable(
                recipe: recipe.name,
                sample: pair.sampleName,
                reason: "requires single-end reads, but both R1 and R2 were detected."
            )
        }

        guard legacyRecipeRequiresPairedReads(recipe) else { return }
        guard pair.r2 != nil else {
            throw BatchImportError.recipeNotApplicable(
                recipe: recipe.name,
                sample: pair.sampleName,
                reason: "requires paired-end reads (R1 and R2), but only R1 was detected."
            )
        }
    }

    private static func legacyRecipeRequiresPairedReads(_ recipe: ProcessingRecipe) -> Bool {
        switch recipe.requiredPairingMode {
        case .pairedEnd, .interleaved:
            return true
        case .singleEnd:
            return false
        case nil:
            break
        }

        return recipe.steps.contains { step in
            OperationContract.input(for: step.kind).requiredPairing != nil
        }
    }

    private static let legacyBatchImportSupportedStepKinds: Set<FASTQDerivativeOperationKind> = [
        .deduplicate,
        .adapterTrim,
        .qualityTrim,
        .humanReadScrub,
        .pairedEndMerge,
        .lengthFilter,
    ]

    private static func stageRawInputsForIngestion(_ inputs: [URL], in workspace: URL) throws -> [URL] {
        try inputs.enumerated().map { index, source in
            let destination = workspace.appendingPathComponent(
                "raw-\(index + 1)-\(source.lastPathComponent)"
            )
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        }
    }

    private static func materializeRecipeAuxiliaryOutputs(
        _ stepResults: [RecipeStepResult],
        stagingBundleURL: URL,
        publishedBundleURL: URL
    ) throws -> [RecipeStepResult] {
        let fm = FileManager.default
        let stagingDirectory = stagingBundleURL
            .appendingPathComponent("metadata", isDirectory: true)
            .appendingPathComponent("recipe-step-artifacts", isDirectory: true)
        let publishedDirectory = publishedBundleURL
            .appendingPathComponent("metadata", isDirectory: true)
            .appendingPathComponent("recipe-step-artifacts", isDirectory: true)

        var materialized: [RecipeStepResult] = []
        for (stepIndex, result) in stepResults.enumerated() {
            guard !result.auxiliaryOutputPaths.isEmpty else {
                materialized.append(result)
                continue
            }

            try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            var finalPaths: [String] = []
            var rewrites = result.auxiliaryCommandPathRewrites
            for (artifactIndex, sourcePath) in result.auxiliaryOutputPaths.enumerated() {
                let sourceURL = URL(fileURLWithPath: sourcePath)
                guard fm.fileExists(atPath: sourceURL.path) else {
                    throw BatchImportError.recipeArtifactMissing(sourceURL)
                }

                let filename = recipeArtifactFilename(
                    stepIndex: stepIndex,
                    artifactIndex: artifactIndex,
                    stepName: result.stepName,
                    sourceURL: sourceURL
                )
                let stagingURL = stagingDirectory.appendingPathComponent(filename)
                let publishedURL = publishedDirectory.appendingPathComponent(filename)
                if sourceURL.standardizedFileURL != stagingURL.standardizedFileURL {
                    try? fm.removeItem(at: stagingURL)
                    try fm.copyItem(at: sourceURL, to: stagingURL)
                }
                finalPaths.append(publishedURL.path)
                rewrites[sourceURL.path] = publishedURL.path
            }

            materialized.append(result.replacingAuxiliaryOutputs(
                paths: finalPaths,
                commandPathRewrites: rewrites
            ))
        }
        return materialized
    }

    private static func recipeArtifactFilename(
        stepIndex: Int,
        artifactIndex: Int,
        stepName: String,
        sourceURL: URL
    ) -> String {
        let stem = stepName
            .lowercased()
            .unicodeScalars
            .map { scalar -> String in
                CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
            }
            .joined()
        let slug = String(stem)
            .split(separator: "-")
            .joined(separator: "-")
            .prefix(48)
        return "\(stepIndex + 1)-\(artifactIndex + 1)-\(slug)-\(sourceURL.lastPathComponent)"
    }

    // MARK: - Provenance

    static func writeImportProvenance(
        pair: SamplePair,
        processingPair: SamplePair,
        materializationSteps: [StepExecution],
        unpairedReads: UnpairedReadsLayout?,
        config: ImportConfig,
        importedPairing: RecordedPairing,
        stagingBundleURL: URL,
        stagingBundleFASTQURL: URL,
        publishedBundleURL: URL,
        publishedBundleFASTQURL: URL,
        sourceIngestionOutputURL: URL,
        ingestionResult: FASTQIngestionResult,
        recipeStepResults: [RecipeStepResult],
        runClock: ProvenanceRunClock, statsStartedAt: Date,
        statsCompletedAt: Date,
        statsError: String?,
        adoption: ExecutorAdoptionProvenance? = nil
    ) async throws {
        let originalInputURLs = pair.inputFiles
        let processingInputURLs = processingPair.inputFiles
        let sampleSheetInput = pair.sampleSheetURL.map {
            ProvenanceRecorder.fileRecord(url: $0, format: .text, role: .input)
        }
        let stagingMetadataURL = FASTQMetadataStore.metadataURL(for: stagingBundleFASTQURL)
        let stagingCSVMetadataURL = FASTQBundleCSVMetadata.metadataURL(in: stagingBundleURL)
        let publishedMetadataURL = FASTQMetadataStore.metadataURL(for: publishedBundleFASTQURL)
        let publishedCSVMetadataURL = FASTQBundleCSVMetadata.metadataURL(in: publishedBundleURL)
        var steps: [StepExecution] = materializationSteps
        steps.append(contentsOf: recipeProvenanceSteps(
            recipeStepResults: recipeStepResults,
            originalInputURLs: processingInputURLs,
            bundleFASTQURL: stagingBundleFASTQURL,
            stagingBundleURL: stagingBundleURL,
            publishedBundleURL: publishedBundleURL
        ))
        steps.append(contentsOf: rehydratedIngestionSteps(
            ingestionResult.provenanceSteps,
            sourceOutputURL: sourceIngestionOutputURL,
            finalOutputURL: stagingBundleFASTQURL,
            originalInputURLs: processingInputURLs
        ))

        let finalizedAt = Date()
        // Every other step of the record ran under the import step (plan decision S6).
        let importStepID = UUID()
        steps.append(StepExecution(
            id: importStepID,
            toolName: "lungfish import fastq",
            toolVersion: WorkflowRun.currentAppVersion,
            command: adoption?.argv ?? reproducibleImportCommand(pair: pair, config: config, durable: true, imported: importedPairing),
            inputs: originalInputURLs.map {
                ProvenanceRecorder.fileRecord(url: $0, format: provenanceFormat(for: $0), role: .input)
            }
                + (sampleSheetInput.map { [$0] } ?? []),
            outputs: [
                ProvenanceRecorder.fileRecord(url: stagingBundleFASTQURL, format: .fastq, role: .output),
                ProvenanceRecorder.fileRecord(url: stagingMetadataURL, format: .json, role: .output),
            ] + (FileManager.default.fileExists(atPath: stagingCSVMetadataURL.path)
                ? [ProvenanceRecorder.fileRecord(url: stagingCSVMetadataURL, format: .text, role: .output)]
                : []),
            exitCode: 0,
            wallTime: 0,
            stderr: nil,
            startTime: finalizedAt,
            endTime: finalizedAt
        ))

        // An adopt's statistics step ran on the node, and its record names it (C4 design section 2).
        if adoption == nil { steps.append(StepExecution(
            toolName: "seqkit",
            toolVersion: await NativeToolRunner.shared.getToolVersion(.seqkit) ?? "unknown",
            command: ["seqkit", "stats", "-a", "-T", stagingBundleFASTQURL.path],
            inputs: [ProvenanceRecorder.fileRecord(url: stagingBundleFASTQURL, format: .fastq, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: stagingMetadataURL, format: .json, role: .output)],
            exitCode: statsError == nil ? 0 : 1,
            wallTime: statsCompletedAt.timeIntervalSince(statsStartedAt),
            stderr: statsError,
            startTime: statsStartedAt,
            endTime: statsCompletedAt
        )) }

        let completedAt = runClock.now
        let command = reproducibleImportCommand(pair: pair, config: config)
        let durableCommand = reproducibleImportCommand(
            pair: pair, config: config, durable: true, imported: importedPairing
        )
        var builder = ProvenanceRunBuilder(
            workflowName: "lungfish import fastq",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish import fastq",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(adoption?.argv ?? command)
        .durableReplayArgv(adoption?.argv ?? durableCommand)
            .options(
            explicit: provenanceParameters(pair: pair, config: config, bundleURL: publishedBundleURL),
            defaults: provenanceDefaultParameters(config: config),
            resolved: provenanceResolvedParameters(
                pair: pair,
                config: config,
                bundleURL: publishedBundleURL,
                bundleFASTQURL: publishedBundleFASTQURL,
                metadataURL: publishedMetadataURL,
                csvMetadataURL: publishedCSVMetadataURL,
                ingestionResult: ingestionResult,
                unpairedReads: unpairedReads
            ).merging(adoption?.resolvedParameters ?? [:]) { _, adopted in adopted }
        )
        .runtime(adoption?.runtime ?? ProvenanceRuntimeIdentity())
        for inputURL in originalInputURLs {
            builder = try builder.input(inputURL, format: provenanceFormat(for: inputURL), role: .input)
        }
        if let sampleSheetURL = pair.sampleSheetURL {
            builder = try builder.input(sampleSheetURL, format: .text, role: .input)
        }
        builder = try builder
            .output(stagingBundleFASTQURL, format: .fastq, role: .output)
            .output(stagingMetadataURL, format: .json, role: .output)
        if FileManager.default.fileExists(atPath: stagingCSVMetadataURL.path) {
            builder = try builder.output(stagingCSVMetadataURL, format: .text, role: .output)
        }
        for var step in steps {
            if step.id != importStepID, adoption?.childStepIDs.contains(step.id) != true { step.parentStepID = importStepID }
            builder = builder.step(ProvenanceStep(stepExecution: step))
        }

        let envelope = try builder.complete(
            exitStatus: 0,
            stderr: statsError,
            startedAt: runClock.startedAt,
            endedAt: completedAt
        )
        let finalEnvelope = rewriteStagedBundlePaths(
            in: envelope,
            stagingBundleURL: stagingBundleURL,
            publishedBundleURL: publishedBundleURL
        )
        let writer = adoption.map { ProvenanceWriter(signingProvider: ProvenanceSigningConfiguration.defaultProvider(environment: $0.signingEnvironment)) }
        try (writer ?? ProvenanceWriter()).write(
            finalEnvelope,
            to: stagingBundleURL,
            bundleLayoutRoot: publishedBundleURL
        )
    }

    static func provenanceFormat(for url: URL) -> FileFormat {
        SequencingReadImportSource.isBAM(url) ? .bam : .fastq
    }

    static func rewriteStagedBundlePaths(
        in envelope: ProvenanceEnvelope,
        stagingBundleURL: URL,
        publishedBundleURL: URL
    ) -> ProvenanceEnvelope {
        func value(_ parameter: ParameterValue) -> ParameterValue {
            rewriteStagedParameterValue(parameter, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
        }
        func descriptor(_ file: ProvenanceFileDescriptor) -> ProvenanceFileDescriptor {
            rewriteStagedDescriptor(file, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
        }
        func arguments(_ argv: [String]) -> [String] {
            rewriteStagedArguments(argv, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
        }
        let options = ProvenanceOptions(
            explicit: envelope.options.explicit.mapValues(value),
            defaults: envelope.options.defaults.mapValues(value),
            resolvedDefaults: envelope.options.resolvedDefaults.mapValues(value)
        )
        let steps = envelope.steps.map { step in
            step.with {
                let replayArgv = arguments(step.durableReplayArgv ?? step.argv)
                $0.durableReplayArgv = replayArgv
                $0.reproducibleCommand = replayArgv.map(shellEscape).joined(separator: " ")
                $0.resolvedOptions = step.resolvedOptions.mapValues(value)
                $0.inputs = step.inputs.map(descriptor)
                $0.outputs = step.outputs.map(descriptor)
            }
        }

        let durableReplayArgv = arguments(envelope.durableReplayArgv ?? envelope.argv)
        let reproducibleCommand = durableReplayArgv.map(shellEscape).joined(separator: " ")

        return ProvenanceEnvelope(
            schemaVersion: envelope.schemaVersion,
            id: envelope.id,
            createdAt: envelope.createdAt,
            workflowName: envelope.workflowName,
            workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName,
            toolVersion: envelope.toolVersion,
            githubReleaseVersion: envelope.githubReleaseVersion,
            tool: envelope.tool,
            argv: envelope.argv,
            durableReplayArgv: durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            options: options,
            runtimeIdentity: envelope.runtimeIdentity,
            files: envelope.files.map(descriptor),
            output: envelope.output.map(descriptor),
            outputs: envelope.outputs.map(descriptor),
            steps: steps,
            wallTimeSeconds: envelope.wallTimeSeconds,
            exitStatus: envelope.exitStatus,
            stderr: envelope.stderr,
            signatures: [],
            status: envelope.status,
            legacyWorkflowRun: nil
        )
    }

    private static func rewriteStagedDescriptor(
        _ descriptor: ProvenanceFileDescriptor,
        stagingBundleURL: URL,
        publishedBundleURL: URL
    ) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: rewriteStagedPath(
                descriptor.path,
                stagingBundleURL: stagingBundleURL,
                publishedBundleURL: publishedBundleURL
            ),
            checksumSHA256: descriptor.checksumSHA256,
            fileSize: descriptor.fileSize,
            format: descriptor.format,
            role: descriptor.role,
            originPath: descriptor.originPath.map {
                rewriteStagedPath($0, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
            },
            sourceProvenancePath: descriptor.sourceProvenancePath.map {
                rewriteStagedPath($0, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
            }
        )
    }

    private static func rewriteStagedParameterValue(
        _ value: ParameterValue,
        stagingBundleURL: URL,
        publishedBundleURL: URL
    ) -> ParameterValue {
        switch value {
        case .file(let url):
            let path = rewriteStagedPath(url.path, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
            return .file(URL(fileURLWithPath: path))
        case .array(let values):
            return .array(values.map {
                rewriteStagedParameterValue($0, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
            })
        case .dictionary(let values):
            return .dictionary(values.mapValues {
                rewriteStagedParameterValue($0, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
            })
        default:
            return value
        }
    }

    private static func rewriteStagedArguments(
        _ arguments: [String],
        stagingBundleURL: URL,
        publishedBundleURL: URL
    ) -> [String] {
        arguments.map {
            rewriteStagedPathInArgument($0, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
        }
    }

    private static func rewriteStagedPathInArgument(
        _ argument: String,
        stagingBundleURL: URL,
        publishedBundleURL: URL
    ) -> String {
        let exactPath = rewriteStagedPath(
            argument,
            stagingBundleURL: stagingBundleURL,
            publishedBundleURL: publishedBundleURL
        )
        if exactPath != argument {
            return exactPath
        }

        return argument.replacingOccurrences(
            of: stagingBundleURL.standardizedFileURL.path,
            with: publishedBundleURL.standardizedFileURL.path
        )
    }

    private static func rewriteStagedPath(
        _ path: String,
        stagingBundleURL: URL,
        publishedBundleURL: URL
    ) -> String {
        let stagingPath = stagingBundleURL.standardizedFileURL.path
        let publishedPath = publishedBundleURL.standardizedFileURL.path
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if standardizedPath == stagingPath {
            return publishedPath
        }
        if standardizedPath.hasPrefix(stagingPath + "/") {
            return publishedPath + String(standardizedPath.dropFirst(stagingPath.count))
        }
        return path
    }

    static func recipeProvenanceSteps(
        recipeStepResults: [RecipeStepResult],
        originalInputURLs: [URL],
        bundleFASTQURL: URL,
        stagingBundleURL: URL? = nil,
        publishedBundleURL: URL? = nil
    ) -> [StepExecution] {
        recipeStepResults.compactMap { result in
            guard result.didRun,
                  result.stepName != "Compute statistics",
                  !result.stepName.localizedCaseInsensitiveContains("Clumpify"),
                  !result.stepName.localizedCaseInsensitiveContains("Compress") else {
                return nil
            }
            let command = recipeStepCommandArguments(for: result)
            let durableReplayArgv = durableRecipeStepArguments(
                command,
                pathRewrites: result.auxiliaryCommandPathRewrites
            )
            let timestamp = Date()
            return StepExecution(
                toolName: result.tool,
                toolVersion: result.toolVersion ?? "unknown",
                command: command,
                durableReplayArgv: durableReplayArgv == command ? nil : durableReplayArgv,
                resolvedOptions: recipeResolvedOptions(for: result),
                runtimeIdentity: recipeRuntimeIdentity(for: result, command: command),
                inputs: originalInputURLs.map {
                    ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input)
                } + recipeDatabaseInputRecords(for: result),
                outputs: recipePrimaryOutputRecords(
                    for: result,
                    legacyBundleFASTQURL: bundleFASTQURL
                )
                    + result.auxiliaryOutputPaths.map {
                        recipeAuxiliaryOutputRecord(
                            finalPath: $0,
                            stagingBundleURL: stagingBundleURL,
                            publishedBundleURL: publishedBundleURL
                        )
                    },
                exitCode: result.exitStatus.flatMap { Int32(exactly: $0) },
                wallTime: result.effectiveDurationSeconds,
                stderr: result.stderr,
                startTime: result.startedAt ?? timestamp.addingTimeInterval(-result.effectiveDurationSeconds),
                endTime: result.completedAt ?? timestamp
            )
        }
    }

    private static func recipePrimaryOutputRecords(
        for result: RecipeStepResult,
        legacyBundleFASTQURL: URL
    ) -> [FileRecord] {
        if !result.executionOutputFiles.isEmpty {
            return result.executionOutputFiles.map {
                FileRecord(
                    path: $0.path,
                    sha256: $0.checksumSHA256,
                    sizeBytes: $0.sizeBytes,
                    format: .fastq,
                    role: .output
                )
            }
        }
        if result.tool == NativeTool.fastp.rawValue {
            return []
        }
        return [ProvenanceRecorder.fileRecord(
            url: legacyBundleFASTQURL,
            format: .fastq,
            role: .output
        )]
    }

    private static func recipeRuntimeIdentity(
        for result: RecipeStepResult,
        command: [String]
    ) -> ProvenanceRuntimeIdentity? {
        guard let tool = NativeTool(rawValue: result.tool), tool == .fastp,
              case .managed(let environment, let executableName) = tool.location,
              let executablePath = command.first,
              !executablePath.isEmpty else {
            return nil
        }

        let executableURL = URL(fileURLWithPath: executablePath)
        let binDirectory = executableURL.deletingLastPathComponent()
        guard executableURL.lastPathComponent == executableName,
              binDirectory.lastPathComponent == "bin" else {
            return nil
        }

        return ProvenanceRuntimeIdentity(
            executablePath: executableURL.path,
            condaEnvironment: environment,
            condaPrefix: binDirectory.deletingLastPathComponent().path
        )
    }

    private static func recipeResolvedOptions(for result: RecipeStepResult) -> [String: ParameterValue]? {
        var options = recipeDatabaseOptions(for: result)
        if !result.logicalComponents.isEmpty {
            options["recipeLogicalComponents"] = .array(result.logicalComponents.map { component in
                .dictionary([
                    "typeID": .string(component.typeID),
                    "displayName": .string(component.displayName),
                ])
            })
        }
        return options.isEmpty ? nil : options
    }

    private static func durableRecipeStepArguments(
        _ command: [String],
        pathRewrites: [String: String]
    ) -> [String] {
        guard !pathRewrites.isEmpty else { return command }
        return command.map { argument in
            pathRewrites[argument] ?? argument
        }
    }

    private static func recipeAuxiliaryOutputRecord(
        finalPath: String,
        stagingBundleURL: URL?,
        publishedBundleURL: URL?
    ) -> FileRecord {
        let finalURL = URL(fileURLWithPath: finalPath)
        let checksumURL = stagedURLForPublishedBundlePath(
            finalPath,
            stagingBundleURL: stagingBundleURL,
            publishedBundleURL: publishedBundleURL
        ) ?? finalURL
        let baseRecord = ProvenanceRecorder.fileRecord(
            url: checksumURL,
            format: recipeAuxiliaryOutputFormat(for: finalURL),
            role: .output
        )
        return FileRecord(
            path: finalURL.path,
            sha256: baseRecord.sha256,
            sizeBytes: baseRecord.sizeBytes,
            format: baseRecord.format,
            role: baseRecord.role
        )
    }

    private static func stagedURLForPublishedBundlePath(
        _ path: String,
        stagingBundleURL: URL?,
        publishedBundleURL: URL?
    ) -> URL? {
        guard let stagingBundleURL, let publishedBundleURL else { return nil }
        let publishedPath = publishedBundleURL.standardizedFileURL.path
        let stagingPath = stagingBundleURL.standardizedFileURL.path
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized == publishedPath || standardized.hasPrefix(publishedPath + "/") else {
            return nil
        }
        return URL(fileURLWithPath: stagingPath + String(standardized.dropFirst(publishedPath.count)))
    }

    private static func recipeAuxiliaryOutputFormat(for url: URL) -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "json":
            return .json
        case "txt", "log":
            return .text
        default:
            return .unknown
        }
    }

    private static func recipeStepCommandArguments(for result: RecipeStepResult) -> [String] {
        if let commandArguments = result.commandArguments, !commandArguments.isEmpty {
            return commandArguments
        }
        if let commandLine = result.commandLine,
           let parsed = shellCommandArguments(from: commandLine),
           !parsed.isEmpty {
            return parsed
        }
        return [result.tool]
    }

    private static func shellCommandArguments(from commandLine: String) -> [String]? {
        let backslash = UnicodeScalar("\\")
        let singleQuote = UnicodeScalar("'")
        let doubleQuote = UnicodeScalar("\"")

        var arguments: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaping = false
        var sawToken = false

        for scalar in commandLine.unicodeScalars {
            if escaping {
                current.unicodeScalars.append(scalar)
                escaping = false
                sawToken = true
                continue
            }

            if scalar == backslash && !inSingleQuote {
                escaping = true
                sawToken = true
                continue
            }

            if scalar == singleQuote && !inDoubleQuote {
                inSingleQuote.toggle()
                sawToken = true
                continue
            }

            if scalar == doubleQuote && !inSingleQuote {
                inDoubleQuote.toggle()
                sawToken = true
                continue
            }

            if scalar.properties.isWhitespace && !inSingleQuote && !inDoubleQuote {
                if sawToken {
                    arguments.append(current)
                    current.removeAll(keepingCapacity: true)
                    sawToken = false
                }
                continue
            }

            current.unicodeScalars.append(scalar)
            sawToken = true
        }

        guard !escaping, !inSingleQuote, !inDoubleQuote else {
            return nil
        }
        if sawToken {
            arguments.append(current)
        }
        return arguments
    }

    static func rehydratedIngestionSteps(
        _ steps: [StepExecution],
        sourceOutputURL: URL,
        finalOutputURL: URL,
        originalInputURLs: [URL]
    ) -> [StepExecution] {
        steps.map { step in
            let pathMappings = durableReplayPathMappings(
                for: step,
                sourceOutputURL: sourceOutputURL,
                finalOutputURL: finalOutputURL,
                originalInputURLs: originalInputURLs
            )
            let durableReplayArgv = rewriteArguments(
                step.durableReplayArgv ?? step.command,
                using: pathMappings
            )
            let outputs = step.outputs.map { record -> FileRecord in
                guard URL(fileURLWithPath: record.path).standardizedFileURL == sourceOutputURL.standardizedFileURL else {
                    return record
                }
                return ProvenanceRecorder.fileRecord(url: finalOutputURL, format: record.format, role: record.role)
            }
            // A staged `raw-N-<name>` copy in the import workspace is byte
            // identical to the original it was copied from; the durable
            // record names the original, which outlives the workspace.
            let inputs = step.inputs.map { record -> FileRecord in
                let inputURL = URL(fileURLWithPath: record.path)
                guard let originalURL = durableOriginalInputURL(for: inputURL, originalInputURLs: originalInputURLs),
                      originalURL != inputURL.standardizedFileURL else {
                    return record
                }
                return ProvenanceRecorder.fileRecord(url: originalURL, format: record.format, role: record.role)
            }
            return StepExecution(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                githubReleaseVersion: step.githubReleaseVersion,
                containerImage: step.containerImage,
                containerDigest: step.containerDigest,
                command: step.command,
                durableReplayArgv: durableReplayArgv,
                resolvedOptions: step.resolvedOptions,
                runtimeIdentity: step.runtimeIdentity,
                inputs: inputs,
                outputs: outputs,
                exitCode: step.exitCode,
                wallTime: step.wallTime,
                peakMemoryBytes: step.peakMemoryBytes,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                parentStepID: step.parentStepID,
                managedToolID: step.managedToolID,
                toolVersionEvidence: step.toolVersionEvidence,
                startTime: step.startTime,
                endTime: step.endTime
            )
        }
    }

    private static func durableReplayPathMappings(
        for step: StepExecution,
        sourceOutputURL: URL,
        finalOutputURL: URL,
        originalInputURLs: [URL]
    ) -> [(source: URL, destination: URL)] {
        var mappings: [(source: URL, destination: URL)] = [(sourceOutputURL, finalOutputURL)]
        for input in step.inputs {
            let inputURL = URL(fileURLWithPath: input.path)
            guard let originalURL = durableOriginalInputURL(for: inputURL, originalInputURLs: originalInputURLs) else {
                continue
            }
            mappings.append((inputURL, originalURL))
        }
        return mappings
    }

    private static func durableOriginalInputURL(for inputURL: URL, originalInputURLs: [URL]) -> URL? {
        let standardizedInput = inputURL.standardizedFileURL
        for originalURL in originalInputURLs {
            let standardizedOriginal = originalURL.standardizedFileURL
            if standardizedInput == standardizedOriginal {
                return standardizedOriginal
            }
            let originalLeaf = standardizedOriginal.lastPathComponent
            if standardizedInput.lastPathComponent == originalLeaf
                || standardizedInput.lastPathComponent.hasSuffix("-\(originalLeaf)") {
                return standardizedOriginal
            }
        }
        return nil
    }

    private static func rewriteArguments(
        _ arguments: [String],
        using mappings: [(source: URL, destination: URL)]
    ) -> [String] {
        arguments.map { argument in
            mappings.reduce(argument) { rewritten, mapping in
                rewritePathInArgument(
                    rewritten,
                    source: mapping.source,
                    destination: mapping.destination
                )
            }
        }
    }

    private static func rewritePathInArgument(_ argument: String, source: URL, destination: URL) -> String {
        argument.replacingOccurrences(
            of: source.standardizedFileURL.path,
            with: destination.standardizedFileURL.path
        )
    }

    private static func provenanceParameters(
        pair: SamplePair,
        config: ImportConfig,
        bundleURL: URL
    ) -> [String: ParameterValue] {
        platformProvenanceParameters(config: config).merging([
            "sampleName": .string(pair.sampleName),
            "r1": .file(pair.r1),
            "r2": pair.r2.map(ParameterValue.file) ?? .null,
            "sampleSheet": pair.sampleSheetURL.map(ParameterValue.file) ?? .null,
            "sampleSheetMetadata": pair.metadata.isEmpty ? .null : .dictionary(
                pair.metadata.mapValues { .string($0) }
            ),
            "projectDirectory": .file(config.projectDirectory),
            "outputBundle": .file(bundleURL),
            "platform": .string(config.sequencingPlatform.importCLIValue),
            "recipe": .string(config.newRecipe?.id ?? config.recipe?.name ?? "none"),
            "qualityBinning": .string(config.qualityBinning.rawValue),
            "optimizeStorage": .boolean(config.optimizeStorage),
            "clumpingTool": .string(config.clumpingTool.rawValue),
            "compressionLevel": .string(config.compressionLevel.rawValue),
            "threads": .integer(config.threads),
            "clumpifyHeapGB": config.clumpifyHeapGB.map(ParameterValue.integer) ?? .null,
            "forceReimport": .boolean(config.forceReimport),
        ]) { platform, _ in platform }.merging(unpairedReadsParameters(of: pair)) { _, unpaired in unpaired }
    }

    private static func provenanceDefaultParameters(config: ImportConfig) -> [String: ParameterValue] {
        [
            "platform": .string(ImportPlatformRequest.auto.cliValue),
            "recipe": .string("none"),
            "qualityBinning": .string(ImportConfig.commandDefaultQualityBinning.rawValue),
            "optimizeStorage": .boolean(config.sequencingPlatform.supportsStorageClumping),
            "clumpingTool": .string(config.sequencingPlatform.supportsStorageClumping ? ClumpingTool.default.rawValue : ClumpingTool.none.rawValue),
            "compressionLevel": .string(CompressionLevel.balanced.rawValue),
            "threads": .integer(ImportConfig.hostThreadCount),
            "clumpifyHeapGB": .null,
            "forceReimport": .boolean(false),
            "r2": .null,
            "sampleSheet": .null,
            "sampleSheetMetadata": .null,
        ]
    }

    private static func provenanceResolvedParameters(
        pair: SamplePair,
        config: ImportConfig,
        bundleURL: URL,
        bundleFASTQURL: URL,
        metadataURL: URL,
        csvMetadataURL: URL,
        ingestionResult: FASTQIngestionResult,
        unpairedReads: UnpairedReadsLayout?
    ) -> [String: ParameterValue] {
        var parameters = provenanceParameters(pair: pair, config: config, bundleURL: bundleURL)
        parameters["inputReadCounts"] = unpairedReads.map { .dictionary($0.inputReadCounts) }
        parameters["primaryFASTQ"] = .file(bundleFASTQURL)
        parameters["metadataJSON"] = .file(metadataURL)
        parameters["metadataCSV"] = FileManager.default.fileExists(atPath: csvMetadataURL.path)
            ? .file(csvMetadataURL)
            : .null
        parameters["pairedEndInput"] = .boolean(pair.r2 != nil)
        parameters["pairing"] = .string(config.pairing.rawValue)
        parameters["outputPairingMode"] = .string(ingestionResult.pairingMode.rawValue)
        parameters["wasClumpified"] = .boolean(ingestionResult.wasClumpified)
        parameters["requestedClumpingTool"] = .string(ingestionResult.requestedClumpingTool.rawValue)
        parameters["resolvedClumpingTool"] = .string(ingestionResult.resolvedClumpingTool.rawValue)
        parameters["clumpingEstimatedInputBytes"] = .integer(Int(ingestionResult.clumpingResolution.estimatedInputBytes))
        parameters["clumpingPhysicalMemoryBytes"] = .integer(Int(ingestionResult.clumpingResolution.physicalMemoryBytes))
        parameters.merge(hostChoiceParameters(config: config, ingestionResult: ingestionResult)) { _, choice in choice }
        parameters["clumpingThresholdBytes"] = .integer(Int(ingestionResult.clumpingResolution.thresholdBytes))
        parameters["clumpingResolutionReason"] = .string(ingestionResult.clumpingResolution.reason)
        parameters["originalFilenames"] = .array(pair.inputFiles.map { .string($0.lastPathComponent) })
        parameters["originalSizeBytes"] = .integer(Int(totalFileSize(pair.inputFiles)))
        let sourceIsBAM = SequencingReadImportSource.isBAM(pair.r1)
        parameters["sourceFormat"] = .string(sourceIsBAM ? FileFormat.bam.rawValue : FileFormat.fastq.rawValue)
        parameters["materializedInputFormat"] = .string(FileFormat.fastq.rawValue)
        parameters["bamPrimaryReadFilter"] = sourceIsBAM
            ? .integer(ONTBAMImportMaterializer.primaryReadFlagFilter)
            : .null
        parameters["finalSizeBytes"] = .integer(Int(ingestionResult.finalSizeBytes))
        parameters["processingTool"] = ingestionResult.processingTool.map(ParameterValue.string) ?? .null
        parameters["processingToolVersion"] = ingestionResult.processingToolVersion.map(ParameterValue.string) ?? .null
        parameters["processingCommandLine"] = ingestionResult.processingCommandLine.map(ParameterValue.string) ?? .null
        if let recipe = config.newRecipe {
            parameters["recipeSHA256"] = recipe.sourceSHA256.map(ParameterValue.string) ?? .null
            parameters["recipeFormatVersion"] = .integer(recipe.formatVersion)
            parameters.merge(recipe.resolutionParameters) { _, resolved in resolved }
        }
        return parameters
    }

    private static func totalFileSize(_ urls: [URL]) -> Int64 {
        urls.reduce(Int64(0)) { total, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return total + size
        }
    }

    /// The import command line. `argv` names what was asked. `durable` names the platform the sample resolved to and
    /// the pairing it ran with (``durablePairing(pair:config:imported:)``), so a replay never depends on the detector.
    static func reproducibleImportCommand(
        pair: SamplePair, config: ImportConfig, durable: Bool = false, imported: RecordedPairing? = nil
    ) -> [String] {
        let platform = durable ? config.sequencingPlatform.importCLIValue : config.platformRequest.cliValue
        let pairing = durable ? durablePairing(pair: pair, config: config, imported: imported) : config.pairing.rawValue
        var command = [CLICommandIdentity.executableName, "import", "fastq"]
            + (pair.sampleSheetURL.map { ["--samplesheet", $0.path] } ?? pair.inputFiles.map(\.path))
        command += [
            "--project", config.projectDirectory.path,
            "--platform", platform,
            "--pairing", pairing,
            "--recipe", config.newRecipe?.requestedName ?? config.recipe?.name ?? "none",
            "--quality-binning", config.qualityBinning.rawValue,
            "--clumping-tool", config.clumpingTool.rawValue,
            "--compression", config.compressionLevel.rawValue,
            "--threads", String(config.threads),
        ] + (config.clumpifyHeapGB.map { ["--clumpify-heap-gb", String($0)] } ?? [])
        command += config.newRecipe?.switchOptionArguments ?? []
        if !config.optimizeStorage {
            command.append("--no-optimize-storage")
        }
        if config.forceReimport {
            command.append("--force")
        }
        return command
    }

    /// The pairing a durable command names: a choice the user made as given, `paired` for an R1/R2 pair, and
    /// `interleaved` for a lone file whose records alternate mates. A lone file detected single-end names `auto`, so a
    /// replay keeps its single-end detected, not final (``FASTQPairingMetadataHints/recordsExplicitSingleEnd``). A
    /// sample sheet's command replays every sample with one value, so a lone file there names `auto`, since
    /// `interleaved` would split the sheet's R1/R2 pairs.
    static func durablePairing(pair: SamplePair, config: ImportConfig, imported: RecordedPairing?) -> String {
        guard config.pairing == .auto else { return config.pairing.rawValue }
        if pair.r2 != nil { return ImportPairing.paired.rawValue }
        let alternates = pair.sampleSheetURL == nil && imported?.mode == .interleaved
        return (alternates ? ImportPairing.interleaved : ImportPairing.auto).rawValue
    }

    // MARK: - Recipe Execution

    /// Applies all recipe steps to paired-end FASTQ inputs, returning the final output URL.
    ///
    /// For the VSP2 delayed-interleave pattern, paired-prefix steps (deduplicate,
    /// adapterTrim, qualityTrim) run on SEPARATE R1/R2 files first (preserving pairing
    /// without interleaving overhead), then interleaves the result for the remaining
    /// steps (humanReadScrub, pairedEndMerge, lengthFilter).
    private static func applyRecipe(
        recipe: ProcessingRecipe,
        inputR1: URL,
        inputR2: URL?,
        workspace: URL,
        pair: SamplePair,
        config: ImportConfig,
        log: (@Sendable (ImportLogEvent) -> Void)?,
        databaseRegistry: DatabaseRegistry
    ) async throws -> URL {
        let runner = NativeToolRunner.shared

        // Determine which prefix steps can run on split R1/R2 files
        let pairedPrefixKinds: Set<FASTQDerivativeOperationKind> = [.deduplicate, .adapterTrim, .qualityTrim]
        var currentR1 = inputR1
        var currentR2 = inputR2
        var previousR1: URL? = nil
        var previousR2: URL? = nil
        var consumedPairedSteps = 0

        let steps = recipe.steps
        let totalSteps = steps.count

        // Phase 1: Run paired-prefix steps on separate R1/R2 files
        if let r2 = currentR2 {
            for (stepIndex, step) in steps.enumerated() {
                guard pairedPrefixKinds.contains(step.kind) else { break }

                let stepName = step.shortLabel
                log?(.stepStart(sample: pair.sampleName, step: stepName, stepIndex: stepIndex + 1, totalSteps: totalSteps))
                printProgress("  \u{2192} \(step.displaySummary)...")
                let stepStart = Date()

                let outR1 = workspace.appendingPathComponent("step_\(stepIndex)_R1.fastq")
                let outR2 = workspace.appendingPathComponent("step_\(stepIndex)_R2.fastq")
                let env = await bbToolsEnvironment()
                let heapGB = ManagedJavaHeapPolicy.heapGB(minimumGB: 4)

                switch step.kind {
                case .deduplicate:
                    let args = FASTQBatchImporter.pairedDedupeArguments(
                        r1: currentR1, r2: r2, outR1: outR1, outR2: outR2, heapGB: heapGB,
                        substitutions: step.deduplicateSubstitutions ?? 0,
                        optical: step.deduplicateOptical == true,
                        opticalDistance: step.deduplicateOpticalDistance ?? 2500,
                        threads: config.threads)
                    let result = try await runner.run(.clumpify, arguments: args, environment: env, timeout: ImportToolTimeout.seconds(for: .clumpify, atLeast: 3600, inputs: [currentR1, r2]))
                    if let failure = BBToolsOutOfMemory.error(
                        exitCode: result.exitCode, tool: "clumpify.sh", arguments: args, optionPinsHeap: false) {
                        throw failure
                    }
                    guard result.isSuccess else {
                        throw BatchImportError.unknownRecipe("paired dedup failed: \(String(result.stderr.suffix(500)))")
                    }

                case .adapterTrim:
                    var args = [
                        "-i", currentR1.path, "-I", currentR2!.path,
                        "-o", outR1.path, "-O", outR2.path,
                        "-w", String(config.threads),
                        "--disable_quality_filtering", "--disable_length_filtering",
                        "--json", "/dev/null", "--html", "/dev/null",
                    ]
                    if let seq = step.adapterSequence { args += ["--adapter_sequence", seq] }
                    if let seqR2 = step.adapterSequenceR2 { args += ["--adapter_sequence_r2", seqR2] }
                    let result = try await runner.run(.fastp, arguments: args, timeout: ImportToolTimeout.seconds(for: .fastp, atLeast: 3600, inputs: [currentR1, currentR2!]))
                    guard result.isSuccess else {
                        throw BatchImportError.unknownRecipe("paired adapter trim failed: \(String(result.stderr.suffix(500)))")
                    }

                case .qualityTrim:
                    var args = [
                        "-i", currentR1.path, "-I", currentR2!.path,
                        "-o", outR1.path, "-O", outR2.path,
                        "-w", String(config.threads),
                        "-W", String(step.windowSize ?? 4),
                        "-M", String(step.qualityThreshold ?? 20),
                        "--disable_adapter_trimming", "--disable_quality_filtering",
                        "--disable_length_filtering",
                        "--json", "/dev/null", "--html", "/dev/null",
                    ]
                    switch step.qualityTrimMode ?? .cutRight {
                    case .cutRight: args.append("--cut_right")
                    case .cutFront: args.append("--cut_front")
                    case .cutTail: args.append("--cut_tail")
                    case .cutBoth: args += ["--cut_front", "--cut_right"]
                    }
                    let result = try await runner.run(.fastp, arguments: args, timeout: ImportToolTimeout.seconds(for: .fastp, atLeast: 3600, inputs: [currentR1, currentR2!]))
                    guard result.isSuccess else {
                        throw BatchImportError.unknownRecipe("paired quality trim failed: \(String(result.stderr.suffix(500)))")
                    }

                default:
                    break
                }

                let duration = Date().timeIntervalSince(stepStart)
                log?(.stepComplete(sample: pair.sampleName, step: stepName, durationSeconds: duration))
                printProgress("  \u{2192} \(step.displaySummary)... done (\(Int(duration))s)")

                // CRITICAL: Clean up previous step's intermediate files
                if let prev1 = previousR1 { try? FileManager.default.removeItem(at: prev1) }
                if let prev2 = previousR2 { try? FileManager.default.removeItem(at: prev2) }

                previousR1 = outR1
                previousR2 = outR2
                currentR1 = outR1
                currentR2 = outR2
                consumedPairedSteps += 1
            }
        }

        // Phase 2: Interleave if we have remaining steps that need it
        let remainingSteps = Array(steps.dropFirst(consumedPairedSteps))

        var currentURL: URL
        var currentIsInterleaved: Bool

        if !remainingSteps.isEmpty, let r2 = currentR2 {
            // Interleave for the remaining steps
            let interleavedURL = workspace.appendingPathComponent("interleaved_for_remaining.fastq")
            try await interleavePairedInput(r1: currentR1, r2: r2, output: interleavedURL)
            // Clean up last paired intermediates
            if let prev1 = previousR1 { try? FileManager.default.removeItem(at: prev1) }
            if let prev2 = previousR2 { try? FileManager.default.removeItem(at: prev2) }
            currentURL = interleavedURL
            currentIsInterleaved = true
        } else if consumedPairedSteps > 0, let r2 = currentR2 {
            // All steps were paired-prefix — interleave the final result
            let interleavedURL = workspace.appendingPathComponent("final_interleaved.fastq")
            try await interleavePairedInput(r1: currentR1, r2: r2, output: interleavedURL)
            if let prev1 = previousR1 { try? FileManager.default.removeItem(at: prev1) }
            if let prev2 = previousR2 { try? FileManager.default.removeItem(at: prev2) }
            return interleavedURL
        } else if let r2 = inputR2 {
            // No paired prefix steps consumed, interleave the raw inputs
            let interleavedURL = workspace.appendingPathComponent("interleaved_raw.fastq")
            try await interleavePairedInput(r1: inputR1, r2: r2, output: interleavedURL)
            currentURL = interleavedURL
            currentIsInterleaved = true
        } else {
            // One file: pair-aware only when its records strictly alternate
            // mates (any naming, identical names included). The steps below
            // state interleaved=t or =f from this, never leaving BBTools to
            // guess from the first read names.
            currentURL = inputR1
            currentIsInterleaved = FASTQReadLayoutClassifier.classify(inputURL: inputR1).layout == .strictlyInterleaved
        }

        // Phase 3: Run remaining steps on interleaved file
        guard !remainingSteps.isEmpty else { return currentURL }

        for (relIndex, step) in remainingSteps.enumerated() {
            let absIndex = consumedPairedSteps + relIndex
            let stepName = step.shortLabel
            log?(.stepStart(sample: pair.sampleName, step: stepName, stepIndex: absIndex + 1, totalSteps: totalSteps))
            printProgress("  \u{2192} \(step.displaySummary)...")
            let stepStart = Date()

            let outputURL = workspace.appendingPathComponent(
                "step_\(absIndex)_\(pair.sampleName).fastq.gz"
            )

            switch step.kind {
            case .deduplicate:
                // Run clumpify.sh deduplicate on the current file
                let env = await bbToolsEnvironment()
                let dedupeArgs = FASTQBatchImporter.interleavedDedupeArguments(
                    input: currentURL, output: outputURL, optical: step.deduplicateOptical == true,
                    threads: config.threads, interleaved: currentIsInterleaved)
                let result = try await runner.run(.clumpify, arguments: dedupeArgs, environment: env, timeout: ImportToolTimeout.seconds(for: .clumpify, atLeast: 3600, inputs: [currentURL]))
                if let failure = BBToolsOutOfMemory.error(
                    exitCode: result.exitCode, tool: "clumpify.sh", arguments: dedupeArgs, optionPinsHeap: false) {
                    throw failure
                }
                guard result.isSuccess else {
                    throw BatchImportError.unknownRecipe("clumpify dedupe failed: \(result.stderr.suffix(500))")
                }

            case .adapterTrim:
                // Run fastp adapter trim
                let r2OutputURL = workspace.appendingPathComponent("step_\(absIndex)_\(pair.sampleName)_R2.fastq.gz")
                var args = ["-i", currentURL.path, "-o", outputURL.path,
                            "-w", String(config.threads), "--json", "/dev/null", "--html", "/dev/null"]
                if currentIsInterleaved {
                    args += ["--interleaved_in"]
                    args += ["-O", r2OutputURL.path]
                }
                let result = try await runner.run(.fastp, arguments: args, timeout: ImportToolTimeout.seconds(for: .fastp, atLeast: 3600, inputs: [currentURL]))
                guard result.isSuccess else {
                    throw BatchImportError.unknownRecipe("fastp adapter trim failed: \(result.stderr.suffix(500))")
                }
                // If interleaved, re-interleave R1+R2 outputs
                if currentIsInterleaved && FileManager.default.fileExists(atPath: r2OutputURL.path) {
                    let interleavedURL = workspace.appendingPathComponent("step_\(absIndex)_\(pair.sampleName)_il.fastq.gz")
                    try await interleavePairedInput(r1: outputURL, r2: r2OutputURL, output: interleavedURL)
                    try? FileManager.default.removeItem(at: outputURL)
                    try? FileManager.default.removeItem(at: r2OutputURL)
                    try FileManager.default.moveItem(at: interleavedURL, to: outputURL)
                }

            case .qualityTrim:
                let threshold = step.qualityThreshold ?? 20
                let window = step.windowSize ?? 4
                let r2OutputURL = workspace.appendingPathComponent("step_\(absIndex)_\(pair.sampleName)_R2.fastq.gz")
                var args = ["-i", currentURL.path, "-o", outputURL.path,
                            "-w", String(config.threads),
                            "-W", String(window), "-M", String(threshold),
                            "--disable_adapter_trimming",
                            "--disable_length_filtering",
                            "--json", "/dev/null", "--html", "/dev/null"]
                if currentIsInterleaved {
                    args += ["--interleaved_in"]
                    args += ["-O", r2OutputURL.path]
                }
                switch step.qualityTrimMode ?? .cutRight {
                case .cutRight: args.append("--cut_right")
                case .cutFront: args.append("--cut_front")
                case .cutTail: args.append("--cut_tail")
                case .cutBoth: args += ["--cut_front", "--cut_right"]
                }
                let result = try await runner.run(.fastp, arguments: args, timeout: ImportToolTimeout.seconds(for: .fastp, atLeast: 3600, inputs: [currentURL]))
                guard result.isSuccess else {
                    throw BatchImportError.unknownRecipe("fastp quality trim failed: \(result.stderr.suffix(500))")
                }
                if currentIsInterleaved && FileManager.default.fileExists(atPath: r2OutputURL.path) {
                    let interleavedURL = workspace.appendingPathComponent("step_\(absIndex)_\(pair.sampleName)_il.fastq.gz")
                    try await interleavePairedInput(r1: outputURL, r2: r2OutputURL, output: interleavedURL)
                    try? FileManager.default.removeItem(at: outputURL)
                    try? FileManager.default.removeItem(at: r2OutputURL)
                    try FileManager.default.moveItem(at: interleavedURL, to: outputURL)
                }

            case .humanReadScrub:
                let dbID = step.humanScrubDatabaseID ?? DeaconPanhumanDatabaseInstaller.databaseID
                let dbPath = try await resolveHumanScrubberDatabasePath(
                    databaseID: dbID,
                    registry: databaseRegistry
                )

                // Decompress if gzipped so the paired/single-end tools can read plain text.
                let inputForScrub: URL
                var decompTemp: URL? = nil
                if currentURL.pathExtension.lowercased() == "gz" {
                    let tmp = workspace.appendingPathComponent("scrub_in_\(UUID().uuidString).fastq")
                    let pigzResult = try await runner.runWithFileOutput(
                        .pigz, arguments: ["-d", "-c", currentURL.path], outputFile: tmp,
                        timeout: ImportToolTimeout.seconds(for: .pigz, atLeast: 300, inputs: [currentURL]))
                    guard pigzResult.isSuccess else {
                        throw BatchImportError.unknownRecipe("Decompression before Deacon scrub failed: \(pigzResult.stderr.suffix(500))")
                    }
                    inputForScrub = tmp
                    decompTemp = tmp
                } else {
                    inputForScrub = currentURL
                }
                defer { if let t = decompTemp { try? FileManager.default.removeItem(at: t) } }

                // Deacon writes plain FASTQ; batch import stores gzipped outputs.
                let scrubOutputURL = workspace.appendingPathComponent("step_\(absIndex)_\(pair.sampleName).fastq")
                if currentIsInterleaved {
                    let inputR1 = workspace.appendingPathComponent("scrub_in_\(UUID().uuidString)_R1.fastq")
                    let inputR2 = workspace.appendingPathComponent("scrub_in_\(UUID().uuidString)_R2.fastq")
                    let outputR1 = workspace.appendingPathComponent("scrub_out_\(UUID().uuidString)_R1.fastq")
                    let outputR2 = workspace.appendingPathComponent("scrub_out_\(UUID().uuidString)_R2.fastq")
                    defer {
                        try? FileManager.default.removeItem(at: inputR1)
                        try? FileManager.default.removeItem(at: inputR2)
                        try? FileManager.default.removeItem(at: outputR1)
                        try? FileManager.default.removeItem(at: outputR2)
                    }

                    try await deinterleavePairedInput(
                        sourceFASTQ: inputForScrub,
                        outputR1: inputR1,
                        outputR2: inputR2
                    )

                    let deaconResult = try await runner.run(
                        .deacon,
                        arguments: [
                            "filter",
                            "-d", dbPath.path,
                            inputR1.path,
                            inputR2.path,
                            "-o", outputR1.path,
                            "-O", outputR2.path,
                            "-t", String(config.threads),
                        ],
                        timeout: ImportToolTimeout.seconds(for: .deacon, atLeast: 7200, inputs: [inputR1, inputR2])
                    )
                    guard deaconResult.isSuccess else {
                        throw BatchImportError.unknownRecipe("deacon filter failed: \(deaconResult.stderr.suffix(500))")
                    }

                    try await interleavePairedInput(r1: outputR1, r2: outputR2, output: scrubOutputURL)
                } else {
                    let deaconResult = try await runner.run(
                        .deacon,
                        arguments: [
                            "filter",
                            "-d", dbPath.path,
                            inputForScrub.path,
                            "-o", scrubOutputURL.path,
                            "-t", String(config.threads),
                        ],
                        timeout: ImportToolTimeout.seconds(for: .deacon, atLeast: 7200, inputs: [inputForScrub])
                    )
                    guard deaconResult.isSuccess else {
                        throw BatchImportError.unknownRecipe("deacon filter failed: \(deaconResult.stderr.suffix(500))")
                    }
                }

                let compResult = try await runner.runWithFileOutput(
                    .pigz, arguments: ["-p", String(config.threads), "-c", scrubOutputURL.path], outputFile: outputURL,
                    timeout: ImportToolTimeout.seconds(for: .pigz, atLeast: 300, inputs: [scrubOutputURL])
                )
                try? FileManager.default.removeItem(at: scrubOutputURL)
                guard compResult.isSuccess else {
                    throw BatchImportError.unknownRecipe("Compression after Deacon scrub failed: \(compResult.stderr.suffix(500))")
                }

            case .pairedEndMerge:
                let strictness = step.mergeStrictness ?? .normal
                let minOverlap = step.mergeMinOverlap ?? 12
                let mergedURL = workspace.appendingPathComponent("step_\(absIndex)_merged.fastq")
                let unmergedURL = workspace.appendingPathComponent("step_\(absIndex)_unmerged.fastq")

                var args = [
                    "in=\(currentURL.path)",
                    "out=\(mergedURL.path)",
                    "outu=\(unmergedURL.path)",
                    "minoverlap=\(minOverlap)",
                    "threads=\(config.threads)",
                    // bbmerge only pairs identically named mates when told to.
                    currentIsInterleaved ? "interleaved=t" : "interleaved=f",
                ]
                if strictness == .strict { args.append("strict=t") }

                let env = await bbToolsEnvironment()
                let mergeResult = try await runner.run(.bbmerge, arguments: args, environment: env, timeout: ImportToolTimeout.seconds(for: .bbmerge, atLeast: 1800, inputs: [currentURL]))
                guard mergeResult.isSuccess else {
                    throw BatchImportError.unknownRecipe("bbmerge failed: \(mergeResult.stderr.suffix(500))")
                }

                // Concatenate interleaved unmerged reads and merged reads into a single output file.
                let hasUnmerged = FileManager.default.fileExists(atPath: unmergedURL.path)
                let hasMerged = FileManager.default.fileExists(atPath: mergedURL.path)

                let combinedURL = workspace.appendingPathComponent("step_\(absIndex)_combined.fastq")

                if hasUnmerged {
                    var catParts: [URL] = [unmergedURL]
                    if hasMerged { catParts.append(mergedURL) }
                    try concatenateFiles(catParts, to: combinedURL)
                } else if hasMerged {
                    try FileManager.default.copyItem(at: mergedURL, to: combinedURL)
                }
                // Compress combined
                let compResult = try await runner.runWithFileOutput(
                    .pigz, arguments: ["-p", String(config.threads), "-c", combinedURL.path], outputFile: outputURL,
                    timeout: ImportToolTimeout.seconds(for: .pigz, atLeast: 300, inputs: [combinedURL])
                )
                try? FileManager.default.removeItem(at: combinedURL)
                try? FileManager.default.removeItem(at: mergedURL)
                try? FileManager.default.removeItem(at: unmergedURL)
                guard compResult.isSuccess else {
                    throw BatchImportError.unknownRecipe("Compression after merge failed: \(compResult.stderr.suffix(500))")
                }
                // After merge, content is a mix of interleaved pairs and single merged reads — treat as not simply interleaved
                currentIsInterleaved = false

            case .lengthFilter:
                let minLen = step.minLength
                let maxLen = step.maxLength

                if currentIsInterleaved {
                    // Use bbduk for paired-aware length filter on interleaved data
                    var args = ["in=\(currentURL.path)", "out=\(outputURL.path)"]
                    if let m = minLen { args.append("minlen=\(m)") }
                    if let m = maxLen { args.append("maxlen=\(m)") }
                    args.append("interleaved=t")
                    args.append("threads=\(config.threads)")
                    let env = await bbToolsEnvironment()
                    let result = try await runner.run(.bbduk, arguments: args, environment: env, timeout: ImportToolTimeout.seconds(for: .bbduk, atLeast: 1800, inputs: [currentURL]))
                    guard result.isSuccess else {
                        throw BatchImportError.unknownRecipe("bbduk length filter failed: \(result.stderr.suffix(500))")
                    }
                } else {
                    // Use seqkit seq for single-ended or mixed content
                    var seqkitArgs = ["seq", "-j", String(config.threads), currentURL.path, "-o", outputURL.path]
                    if let m = minLen { seqkitArgs += ["-m", String(m)] }
                    if let m = maxLen { seqkitArgs += ["-M", String(m)] }
                    let result = try await runner.run(.seqkit, arguments: seqkitArgs, timeout: ImportToolTimeout.seconds(for: .seqkit, atLeast: 1800, inputs: [currentURL]))
                    guard result.isSuccess else {
                        throw BatchImportError.unknownRecipe("seqkit length filter failed: \(result.stderr.suffix(500))")
                    }
                }

            default:
                throw BatchImportError.unsupportedRecipeStep(
                    recipe: recipe.name,
                    step: step.kind.rawValue
                )
            }

            // Delete the previous intermediate file and advance current pointer
            try? FileManager.default.removeItem(at: currentURL)
            currentURL = outputURL

            let duration = Date().timeIntervalSince(stepStart)
            log?(.stepComplete(sample: pair.sampleName, step: stepName, durationSeconds: duration))
            printProgress("  \u{2192} \(step.displaySummary)... done (\(Int(duration))s)")
        }

        return currentURL
    }

    // MARK: - Statistics Computation

    /// Computes FASTQ statistics (via seqkit + read scan) and caches them in the metadata sidecar.
    ///
    /// This runs seqkit stats for summary metrics (read count, Q20/Q30, GC%, mean quality)
    /// and scans the FASTQ to build a read-length histogram for N50/median/distribution.
    /// Results are stored in the `.fastq.metadata.json` sidecar so the GUI can display
    /// them immediately when the bundle is opened.
    private static func computeAndCacheStatistics(for fastqURL: URL) async throws {
        let runner = NativeToolRunner.shared

        // 1. Run seqkit stats -a -T for summary metrics
        let seqkitResult = try await runner.run(
            .seqkit,
            arguments: ["stats", "-a", "-T", fastqURL.path],
            timeout: ImportToolTimeout.seconds(for: .seqkit, atLeast: 900, inputs: [fastqURL])
        )
        guard seqkitResult.isSuccess else {
            logger.warning("seqkit stats failed: \(seqkitResult.stderr)")
            throw BatchImportError.statisticsUnavailable(
                "seqkit stats exited \(seqkitResult.exitCode): \(seqkitResult.stderr)"
            )
        }

        try await cacheStatistics(for: fastqURL, seqkitStdout: seqkitResult.stdout, fractions: nil)
    }

    /// The sidecar's statistics from one `seqkit stats -a -T` table: the exact metrics from the table, Q20 and Q30 from
    /// `counted` when given (the adopt passes its run record's counts) or else from a count of the file's bases, and the
    /// charts from a 100,000-read head sample. The import and the adopt share it (CHTC C4 lane A, BIO O1).
    static func cacheStatistics(for fastqURL: URL, seqkitStdout: String, fractions counted: FASTQQualityFractions?) async throws {
        let runner = NativeToolRunner.shared
        let requiredStats = try parseRequiredSeqkitStats(stdout: seqkitStdout)
        // seqkit 2.13 prints Q20(%) and Q30(%) as whole percents (95, 91),
        // while Refresh QC Summary counts every base (94.57, 91.28). Count
        // the bases here too, so the cards read the same from both paths.
        let seqkitMeta: SeqkitStatsMetadata
        do {
            let fractions: FASTQQualityFractions
            if let counted { fractions = counted } else { fractions = try await FASTQQualityFractions.scan(fastqURL) }
            seqkitMeta = exactQualityMetadata(seqkit: requiredStats.metadata, fractions: fractions)
        } catch {
            logger.warning("Exact Q20/Q30 count failed for \(fastqURL.lastPathComponent): \(error) — keeping seqkit's rounded values")
            seqkitMeta = requiredStats.metadata
        }

        // 2. Sampled distributions from first 100k reads (~1-2s).
        //    Extract a subset via seqkit head, then run FASTQStatisticsCollector
        //    for length histogram + quality score histogram + per-position quality.
        //    These are used for charts only — approximate is fine.
        //    Exact numeric metrics (N50, median, Q20/Q30) come from the full seqkit
        //    stats pass above.
        let sampleSize = 100_000
        var sampledHistogram: [Int: Int] = [:]
        var qualityScoreHistogram: [UInt8: Int] = [:]
        var perPositionQuality: [PositionQualitySummary] = []

        do {
            let seqkitURL = try await runner.findTool(.seqkit)
            let sampleFile = fastqURL.deletingLastPathComponent()
                .appendingPathComponent(".stats-sample-\(UUID().uuidString).fq.gz")
            defer { try? FileManager.default.removeItem(at: sampleFile) }

            // Extract first 100k reads to temp file
            let headResult = try await runner.runProcess(
                executableURL: seqkitURL,
                arguments: ["head", "-n", "\(sampleSize)", "-o", sampleFile.path, fastqURL.path],
                timeout: 120
            )
            guard headResult.isSuccess else {
                logger.warning("seqkit head failed: \(headResult.stderr) — quality plots will be empty")
                throw NSError(domain: "stats", code: 1)
            }

            // Run FASTQStatisticsCollector on the sample for distributions
            let collector = FASTQStatisticsCollector()
            let reader = FASTQReader(validateSequence: false)
            for try await record in reader.records(from: sampleFile) {
                collector.process(record)
            }
            let sampled = collector.finalize()
            sampledHistogram = sampled.readLengthHistogram
            qualityScoreHistogram = sampled.qualityScoreHistogram
            perPositionQuality = sampled.perPositionQuality
        } catch {
            logger.warning("Sampled quality distributions failed: \(error) — charts may be empty")
        }

        // 3. Build final statistics: exact metrics from seqkit, distributions from sample.
        //    Q2 = median length, N50 reported directly by seqkit stats -a.
        let statistics = FASTQDatasetStatistics(
            readCount: seqkitMeta.numSeqs,
            baseCount: seqkitMeta.sumLen,
            meanReadLength: seqkitMeta.avgLen,
            minReadLength: seqkitMeta.minLen,
            maxReadLength: seqkitMeta.maxLen,
            medianReadLength: requiredStats.medianReadLength,
            n50ReadLength: requiredStats.n50ReadLength,
            meanQuality: seqkitMeta.averageQuality,
            q20Percentage: seqkitMeta.q20Percentage,
            q30Percentage: seqkitMeta.q30Percentage,
            gcContent: seqkitMeta.gcPercentage / 100.0,
            readLengthHistogram: sampledHistogram,
            qualityScoreHistogram: qualityScoreHistogram,
            perPositionQuality: perPositionQuality
        )

        // 4. Cache in metadata sidecar
        var metadata = FASTQMetadataStore.load(for: fastqURL) ?? PersistedFASTQMetadata()
        metadata.computedStatistics = statistics
        metadata.seqkitStats = seqkitMeta
        FASTQMetadataStore.save(metadata, for: fastqURL)

        logger.info("Statistics cached: \(seqkitMeta.numSeqs) reads, N50=\(requiredStats.n50ReadLength), Q30=\(String(format: "%.1f", seqkitMeta.q30Percentage))%, histogram bins=\(sampledHistogram.count), qPositions=\(perPositionQuality.count)")
    }

    /// The seqkit summary with Q20/Q30 taken from counted bases, when the
    /// count covers the same bases seqkit summed. A count over a different
    /// number of bases means the file changed underneath the two passes,
    /// and seqkit's values stand.
    static func exactQualityMetadata(
        seqkit: SeqkitStatsMetadata,
        fractions: FASTQQualityFractions
    ) -> SeqkitStatsMetadata {
        guard fractions.baseCount == seqkit.sumLen, fractions.baseCount > 0 else {
            return seqkit
        }
        return seqkit.replacingQualityPercentages(with: fractions)
    }

    static func parseRequiredSeqkitStats(stdout: String) throws -> RequiredSeqkitStats {
        let lines = stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            throw BatchImportError.statisticsUnavailable("seqkit stats returned incomplete output")
        }

        let headers = lines[0]
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        let values = lines[1]
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        guard headers.count == values.count else {
            throw BatchImportError.statisticsUnavailable("seqkit stats returned mismatched headers and values")
        }

        var map: [String: String] = [:]
        for (header, value) in zip(headers, values) {
            map[header] = value
        }

        func requiredString(_ key: String) throws -> String {
            guard let value = map[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BatchImportError.statisticsUnavailable("seqkit stats missing required column '\(key)'")
            }
            return value
        }

        func int(_ key: String) throws -> Int {
            let value = try requiredString(key)
            guard let parsed = Int(value) else {
                throw BatchImportError.statisticsUnavailable("seqkit stats column '\(key)' is not an integer: \(value)")
            }
            return parsed
        }

        func int64(_ key: String) throws -> Int64 {
            let value = try requiredString(key)
            guard let parsed = Int64(value) else {
                throw BatchImportError.statisticsUnavailable("seqkit stats column '\(key)' is not an integer: \(value)")
            }
            return parsed
        }

        func dbl(_ key: String) throws -> Double {
            let value = try requiredString(key)
            guard let parsed = Double(value) else {
                throw BatchImportError.statisticsUnavailable("seqkit stats column '\(key)' is not numeric: \(value)")
            }
            return parsed
        }

        let metadata = SeqkitStatsMetadata(
            numSeqs: try int("num_seqs"),
            sumLen: try int64("sum_len"),
            minLen: try int("min_len"),
            avgLen: try dbl("avg_len"),
            maxLen: try int("max_len"),
            q20Percentage: try dbl("Q20(%)"),
            q30Percentage: try dbl("Q30(%)"),
            averageQuality: try dbl("AvgQual"),
            gcPercentage: try dbl("GC(%)")
        )
        return RequiredSeqkitStats(
            metadata: metadata,
            medianReadLength: try int("Q2"),
            n50ReadLength: try int("N50")
        )
    }

    // MARK: - Private Helpers

    /// Interleaves R1/R2 FASTQ files into a single interleaved output using reformat.sh.
    private static func interleavePairedInput(r1: URL, r2: URL, output: URL) async throws {
        let runner = NativeToolRunner.shared
        let env = await bbToolsEnvironment()
        let result = try await runner.run(
            .reformat,
            arguments: [
                "in1=\(r1.path)",
                "in2=\(r2.path)",
                "out=\(output.path)",
                "interleaved=t",
            ],
            environment: env,
            timeout: ImportToolTimeout.seconds(for: .reformat, atLeast: 1800, inputs: [r1, r2])
        )
        guard result.isSuccess else {
            throw BatchImportError.unknownRecipe("reformat.sh interleave failed: \(result.stderr.suffix(500))")
        }
    }

    /// Splits an interleaved FASTQ into separate R1/R2 files using reformat.sh.
    private static func deinterleavePairedInput(sourceFASTQ: URL, outputR1: URL, outputR2: URL) async throws {
        let runner = NativeToolRunner.shared
        let env = await bbToolsEnvironment()
        let result = try await runner.run(
            .reformat,
            arguments: [
                "in=\(sourceFASTQ.path)",
                "out1=\(outputR1.path)",
                "out2=\(outputR2.path)",
                "interleaved=t",
            ],
            environment: env,
            timeout: ImportToolTimeout.seconds(for: .reformat, atLeast: 1800, inputs: [sourceFASTQ])
        )
        guard result.isSuccess else {
            throw BatchImportError.unknownRecipe("reformat.sh deinterleave failed: \(result.stderr.suffix(500))")
        }
    }

    private static func bbToolsEnvironment() async -> [String: String] {
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return CoreToolLocator.bbToolsEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            existingPath: existingPath
        )
    }

    /// Sums file sizes for the given URLs.
    private static func fileSizeSum(_ urls: [URL]) -> Int64 {
        urls.reduce(Int64(0)) { total, url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return total + ((attrs?[.size] as? Int64) ?? 0)
        }
    }

    /// Returns the total on-disk size of all files inside a bundle directory.
    private static func bundleFileSize(_ bundleURL: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let attrs = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(attrs?.fileSize ?? 0)
        }
        return total
    }

    /// Writes a per-sample JSON log to the specified log directory.
    private static func writePerSampleLog(pair: SamplePair, bundleURL: URL, logDir: URL) {
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let logFile = logDir.appendingPathComponent("\(pair.sampleName).import.log")
            let entry: [String: Any] = unpairedReadsLogEntry(of: pair).merging([
                "sample": pair.sampleName,
                "r1": pair.r1.lastPathComponent,
                "r2": pair.r2?.lastPathComponent ?? NSNull(),
                "bundle": bundleURL.lastPathComponent,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
            ]) { unpaired, _ in unpaired }
            let data = try JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: logFile, options: .atomic)
        } catch {
            logger.warning("Failed to write per-sample log for \(pair.sampleName): \(error.localizedDescription)")
        }
    }

    // MARK: - Private Utilities

    /// Strips FASTQ extensions from a URL, returning the base stem.
    static func fastqStem(_ url: URL) -> String {
        var name = url.lastPathComponent
        let extensions = [".fastq.gz", ".fq.gz", ".fastq", ".fq", ".bam"]
        for ext in extensions {
            if name.lowercased().hasSuffix(ext) {
                name = String(name.dropLast(ext.count))
                return name
            }
        }
        return name
    }
}
