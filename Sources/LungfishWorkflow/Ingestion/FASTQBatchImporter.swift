// FASTQBatchImporter.swift - Batch FASTQ pair detection and recipe-driven import
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore
import LungfishIO

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "FASTQBatchImporter")

// MARK: - SamplePair

/// A detected R1/R2 pair (or single-end sample) ready for batch import.
public struct SamplePair: Sendable {
    public let sampleName: String
    public let r1: URL
    public let r2: URL?
    public init(sampleName: String, r1: URL, r2: URL?) {
        self.sampleName = sampleName
        self.r1 = r1
        self.r2 = r2
    }
}

// MARK: - ImportLogEvent

/// Structured log events emitted during a batch import run.
public enum ImportLogEvent: Sendable {
    case importStart(sampleCount: Int, recipeName: String?)
    case sampleStart(sample: String, index: Int, total: Int, r1: String, r2: String?)
    case stepStart(sample: String, step: String, stepIndex: Int, totalSteps: Int)
    case stepComplete(sample: String, step: String, durationSeconds: Double)
    case sampleComplete(sample: String, bundle: String, durationSeconds: Double, originalBytes: Int64, finalBytes: Int64)
    case sampleSkip(sample: String, reason: String)
    case sampleFailed(sample: String, error: String)
    case importComplete(completed: Int, skipped: Int, failed: Int, totalDurationSeconds: Double)
}

// MARK: - BatchImportError

/// Errors thrown by the batch importer.
public enum BatchImportError: Error, LocalizedError {
    case noFASTQFilesFound(URL)
    case unknownRecipe(String)
    case projectNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case .noFASTQFilesFound(let url):
            return "No FASTQ files found in \(url.lastPathComponent)"
        case .unknownRecipe(let name):
            return "Unknown recipe '\(name)'. Valid names: vsp2, wgs, amplicon, hifi"
        case .projectNotFound(let url):
            return "No .lungfish project found at or above \(url.path)"
        }
    }
}

// MARK: - FASTQBatchImporter

/// Namespace for FASTQ batch import utilities.
///
/// Provides pair detection, recipe resolution, skip logic, structured logging,
/// and sequential batch processing with memory-safe inter-sample cleanup.
public enum FASTQBatchImporter {

    // MARK: - Nested Types

    /// Configuration for a batch import run.
    public struct ImportConfig: Sendable {
        public let projectDirectory: URL
        /// Sequencing platform. Drives default values for quality binning,
        /// storage optimisation, and compression level.
        public let platform: LungfishWorkflow.SequencingPlatform
        /// Old-format recipe (for unmigrated recipes like WGS, amplicon, HiFi).
        public let recipe: ProcessingRecipe?
        /// New-format declarative recipe (e.g., VSP2).
        public let newRecipe: Recipe?
        public let qualityBinning: QualityBinningScheme
        /// Whether to run clumpify for storage optimisation. Defaults to the
        /// platform default; can be overridden explicitly.
        public let optimizeStorage: Bool
        /// Gzip compression level. Defaults to `.balanced`.
        public let compressionLevel: CompressionLevel
        public let threads: Int
        public let logDirectory: URL?
        /// When `true`, reimport even if a bundle already exists for the sample.
        public let forceReimport: Bool

        public init(
            projectDirectory: URL,
            platform: LungfishWorkflow.SequencingPlatform = .illumina,
            recipe: ProcessingRecipe? = nil,
            newRecipe: Recipe? = nil,
            qualityBinning: QualityBinningScheme? = nil,
            optimizeStorage: Bool? = nil,
            compressionLevel: CompressionLevel? = nil,
            threads: Int = 4,
            logDirectory: URL? = nil,
            forceReimport: Bool = false
        ) {
            self.projectDirectory = projectDirectory
            self.platform = platform
            self.recipe = recipe
            self.newRecipe = newRecipe
            // Default resolution: explicit value > recipe suggestion > platform default
            self.qualityBinning = qualityBinning ?? newRecipe?.qualityBinning ?? platform.defaultQualityBinning
            self.optimizeStorage = optimizeStorage ?? platform.defaultOptimizeStorage
            self.compressionLevel = compressionLevel ?? platform.defaultCompressionLevel
            self.threads = threads
            self.logDirectory = logDirectory
            self.forceReimport = forceReimport
        }
    }

    /// Result of a completed batch import run.
    public struct ImportResult: Sendable {
        public let completed: Int
        public let skipped: Int
        public let failed: Int
        public let totalDurationSeconds: Double
        public let errors: [(sample: String, error: String)]
    }

    // MARK: - Pair Detection

    /// Scans `directory` for `.fastq.gz`/`.fq.gz` files and groups them into pairs.
    ///
    /// - Throws: `BatchImportError.noFASTQFilesFound` when no FASTQ files are present.
    public static func detectPairsFromDirectory(_ directory: URL) throws -> [SamplePair] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let fastqURLs = contents.filter { url in
            let name = url.lastPathComponent.lowercased()
            return name.hasSuffix(".fastq.gz") || name.hasSuffix(".fq.gz") ||
                   name.hasSuffix(".fastq") || name.hasSuffix(".fq")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !fastqURLs.isEmpty else {
            throw BatchImportError.noFASTQFilesFound(directory)
        }

        return detectPairs(from: fastqURLs)
    }

    /// Groups a flat list of FASTQ URLs into R1/R2 pairs using common naming conventions.
    ///
    /// Supported patterns (checked in priority order):
    /// - `_R1_001` / `_R2_001`  (Illumina bcl2fastq standard)
    /// - `_R1` / `_R2`           (simplified Illumina)
    /// - `_1` / `_2`             (older convention)
    ///
    /// Files that don't match any R1 pattern are treated as single-end samples.
    public static func detectPairs(from urls: [URL]) -> [SamplePair] {
        // Patterns ordered from most to least specific
        let r1Patterns: [(r1Suffix: String, r2Suffix: String)] = [
            ("_R1_001", "_R2_001"),
            ("_R1",     "_R2"),
            ("_1",      "_2"),
        ]

        // Build a stem→URL lookup for fast R2 matching
        var stemToURL: [String: URL] = [:]
        for url in urls {
            stemToURL[fastqStem(url)] = url
        }

        var consumed: Set<URL> = []
        var pairs: [SamplePair] = []

        // Process each pattern in priority order
        for pattern in r1Patterns {
            for url in urls {
                guard !consumed.contains(url) else { continue }
                let stem = fastqStem(url)
                guard stem.hasSuffix(pattern.r1Suffix) else { continue }

                let baseStem = String(stem.dropLast(pattern.r1Suffix.count))
                let r2Stem = baseStem + pattern.r2Suffix

                if let r2URL = stemToURL[r2Stem], !consumed.contains(r2URL) {
                    pairs.append(SamplePair(sampleName: baseStem, r1: url, r2: r2URL))
                    consumed.insert(url)
                    consumed.insert(r2URL)
                }
                // If no R2 found yet, leave url for the single-end pass
            }
        }

        // Everything not consumed is single-end
        for url in urls where !consumed.contains(url) {
            let name = fastqStem(url)
            pairs.append(SamplePair(sampleName: name, r1: url, r2: nil))
        }

        return pairs.sorted { $0.sampleName < $1.sampleName }
    }

    // MARK: - Recipe Resolution

    /// Resolves a short recipe name to a built-in `ProcessingRecipe`.
    ///
    /// - Parameter named: Case-insensitive short name. Valid values: `"vsp2"`, `"wgs"`, `"amplicon"`, `"hifi"`.
    ///   Pass `nil` recipe in `ImportConfig` rather than `"none"` to skip recipe processing.
    /// - Throws: `BatchImportError.unknownRecipe` for unrecognized names.
    public static func resolveRecipe(named name: String) throws -> ProcessingRecipe {
        switch name.lowercased() {
        case "vsp2":
            return .illuminaVSP2TargetEnrichment
        case "wgs":
            return .illuminaWGS
        case "amplicon":
            return .targetedAmplicon
        case "hifi":
            return .pacbioHiFi
        default:
            throw BatchImportError.unknownRecipe(name)
        }
    }

    // MARK: - Skip Logic

    /// Returns `true` when a `.lungfishfastq` bundle already exists for `pair` in `projectDir`.
    public static func bundleExists(for pair: SamplePair, in projectDir: URL) -> Bool {
        let bundleURL = projectDir
            .appendingPathComponent("Imports")
            .appendingPathComponent("\(pair.sampleName).\(FASTQBundle.directoryExtension)")
        return FASTQBundle.isBundleURL(bundleURL) &&
               FileManager.default.fileExists(atPath: bundleURL.path)
    }

    // MARK: - Structured Logging

    /// Encodes a log event to a single JSON line.
    public static func encodeLogEvent(_ event: ImportLogEvent) -> String {
        var dict: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date())]

        switch event {
        case .importStart(let sampleCount, let recipeName):
            dict["event"] = "importStart"
            dict["sampleCount"] = sampleCount
            if let name = recipeName { dict["recipeName"] = name }

        case .sampleStart(let sample, let index, let total, let r1, let r2):
            dict["event"] = "sampleStart"
            dict["sample"] = sample
            dict["index"] = index
            dict["total"] = total
            dict["r1"] = r1
            if let r2 { dict["r2"] = r2 }

        case .stepStart(let sample, let step, let stepIndex, let totalSteps):
            dict["event"] = "stepStart"
            dict["sample"] = sample
            dict["step"] = step
            dict["stepIndex"] = stepIndex
            dict["totalSteps"] = totalSteps

        case .stepComplete(let sample, let step, let durationSeconds):
            dict["event"] = "stepComplete"
            dict["sample"] = sample
            dict["step"] = step
            dict["durationSeconds"] = durationSeconds

        case .sampleComplete(let sample, let bundle, let durationSeconds, let originalBytes, let finalBytes):
            dict["event"] = "sampleComplete"
            dict["sample"] = sample
            dict["bundle"] = bundle
            dict["durationSeconds"] = durationSeconds
            dict["originalBytes"] = originalBytes
            dict["finalBytes"] = finalBytes

        case .sampleSkip(let sample, let reason):
            dict["event"] = "sampleSkip"
            dict["sample"] = sample
            dict["reason"] = reason

        case .sampleFailed(let sample, let error):
            dict["event"] = "sampleFailed"
            dict["sample"] = sample
            dict["error"] = error

        case .importComplete(let completed, let skipped, let failed, let totalDurationSeconds):
            dict["event"] = "importComplete"
            dict["completed"] = completed
            dict["skipped"] = skipped
            dict["failed"] = failed
            dict["totalDurationSeconds"] = totalDurationSeconds
        }

        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            return line
        }
        // Fallback: plain string if JSON encoding fails
        return "{\"event\":\"error\",\"message\":\"JSON encoding failed\"}"
    }

    /// Writes a human-readable progress message to stderr.
    public static func printProgress(_ message: String) {
        let standardError = FileHandle.standardError
        let output = message + "\n"
        if let data = output.data(using: .utf8) {
            standardError.write(data)
        }
    }

    // MARK: - Main Entry Point

    /// Processes all samples in `pairs` sequentially using the provided configuration.
    ///
    /// Uses `autoreleasepool` between samples to bound peak memory usage.
    /// Samples that already have bundles are skipped (logged as `sampleSkip`).
    ///
    /// - Parameters:
    ///   - pairs: Detected sample pairs to process.
    ///   - config: Import configuration (recipe, threads, directories).
    ///   - log: Optional callback for structured log events.
    /// - Returns: Summary of completed, skipped, and failed sample counts.
    public static func runBatchImport(
        pairs: [SamplePair],
        config: ImportConfig,
        log: (@Sendable (ImportLogEvent) -> Void)? = nil
    ) async -> ImportResult {
        let startTime = Date()
        let recipeName = config.recipe?.name

        log?(.importStart(sampleCount: pairs.count, recipeName: recipeName))
        logger.info("Batch import starting: \(pairs.count) samples, recipe=\(recipeName ?? "none")")

        var completed = 0
        var skipped = 0
        var failed = 0
        var errors: [(sample: String, error: String)] = []

        for (index, pair) in pairs.enumerated() {
            // Check for skip before allocating anything (unless forceReimport is set)
            if !config.forceReimport && bundleExists(for: pair, in: config.projectDirectory) {
                let reason = "Bundle already exists"
                log?(.sampleSkip(sample: pair.sampleName, reason: reason))
                logger.info("Skipping \(pair.sampleName): \(reason)")
                skipped += 1
                continue
            }

            // Process this sample; autoreleasepool drains synchronous ObjC objects between iterations
            let result = await processSingleSample(
                pair: pair,
                config: config,
                sampleIndex: index,
                totalSamples: pairs.count,
                log: log
            )
            // Drain autorelease pool for any Objective-C bridge objects created during processing
            autoreleasepool { }

            switch result {
            case .success:
                completed += 1
            case .failure(let error):
                let message = error.localizedDescription
                log?(.sampleFailed(sample: pair.sampleName, error: message))
                logger.error("Sample \(pair.sampleName) failed: \(message)")
                errors.append((sample: pair.sampleName, error: message))
                failed += 1
            }
        }

        let totalDuration = Date().timeIntervalSince(startTime)
        log?(.importComplete(
            completed: completed,
            skipped: skipped,
            failed: failed,
            totalDurationSeconds: totalDuration
        ))
        logger.info("Batch import complete: \(completed) completed, \(skipped) skipped, \(failed) failed in \(String(format: "%.1f", totalDuration))s")

        return ImportResult(
            completed: completed,
            skipped: skipped,
            failed: failed,
            totalDurationSeconds: totalDuration,
            errors: errors
        )
    }

    // MARK: - Single Sample Processing

    /// Processes one sample pair: runs the ingestion pipeline, optionally applies recipe steps.
    private static func processSingleSample(
        pair: SamplePair,
        config: ImportConfig,
        sampleIndex: Int,
        totalSamples: Int,
        log: (@Sendable (ImportLogEvent) -> Void)?
    ) async -> Result<URL, Error> {
        let sampleStart = Date()
        log?(.sampleStart(
            sample: pair.sampleName,
            index: sampleIndex,
            total: totalSamples,
            r1: pair.r1.lastPathComponent,
            r2: pair.r2?.lastPathComponent
        ))

        let originalBytes = fileSizeSum([pair.r1] + (pair.r2.map { [$0] } ?? []))

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

            // Step 1: Apply recipe if provided (BEFORE clumpify — recipe changes the
            // read population, so k-mer grouping must be computed on the final reads)
            var recipeOutputFASTQ: URL? = nil
            var isPairedAfterRecipe = pair.r2 != nil

            if let newRecipe = config.newRecipe {
                // New-format declarative recipe: delegate to RecipeEngine
                let engine = RecipeEngine()
                let inputFormat: RecipeFileFormat = pair.r2 != nil ? .pairedR1R2 : .single
                let stepInput = StepInput(r1: pair.r1, r2: pair.r2, format: inputFormat)

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
                tracker.totalSteps = newRecipe.steps.count

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
                let output = try await engine.execute(recipe: newRecipe, input: stepInput, context: stepContext)
                // Emit stepComplete for the last recipe step
                if let lastStep = tracker.currentStep {
                    log?(.stepComplete(sample: pair.sampleName, step: lastStep,
                                       durationSeconds: Date().timeIntervalSince(tracker.stepStart)))
                }
                var currentURL = output.r1
                // If output is merged format, concatenate r1/r2/r3 for bundle finalization
                if output.format == .merged, let r2 = output.r2 {
                    let combined = workspace.appendingPathComponent("\(pair.sampleName)_combined.fq.gz")
                    var data = try Data(contentsOf: output.r1)
                    data.append(try Data(contentsOf: r2))
                    if let r3 = output.r3 { data.append(try Data(contentsOf: r3)) }
                    try data.write(to: combined)
                    currentURL = combined
                }
                recipeOutputFASTQ = currentURL
                // New-format recipes produce interleaved or single output
                isPairedAfterRecipe = output.format == .interleaved || output.format == .merged
            } else if let recipe = config.recipe, !recipe.steps.isEmpty {
                // Old-format recipe: use existing applyRecipe() code path
                recipeOutputFASTQ = try await applyRecipe(
                    recipe: recipe,
                    inputR1: pair.r1,
                    inputR2: pair.r2,
                    workspace: workspace,
                    pair: pair,
                    config: config,
                    log: log
                )
                // After VSP2 recipe, output is interleaved (PE merge step produces mixed reads)
                isPairedAfterRecipe = true
            }

            // Step 2: Clumpify + compress (on recipe output, or raw input if no recipe)
            let clumpifyInput: [URL]
            let clumpifyPairingMode: FASTQIngestionConfig.PairingMode
            if let recipeOutput = recipeOutputFASTQ {
                clumpifyInput = [recipeOutput]
                clumpifyPairingMode = isPairedAfterRecipe ? .interleaved : .singleEnd
            } else {
                clumpifyInput = pair.r2 != nil ? [pair.r1, pair.r2!] : [pair.r1]
                clumpifyPairingMode = pair.r2 != nil ? .pairedEnd : .singleEnd
            }

            let ingestionConfig = FASTQIngestionConfig(
                inputFiles: clumpifyInput,
                pairingMode: clumpifyPairingMode,
                outputDirectory: workspace,
                threads: config.threads,
                deleteOriginals: true,
                qualityBinning: config.qualityBinning,
                skipClumpify: !config.optimizeStorage
            )

            let totalSteps = (config.recipe?.steps.count ?? config.newRecipe?.steps.count ?? 0) + 1
            let clumpifyStepIndex = totalSteps
            let clumpifyLabel = config.optimizeStorage ? "Clumpify + Compress" : "Compress"
            log?(.stepStart(sample: pair.sampleName, step: clumpifyLabel, stepIndex: clumpifyStepIndex, totalSteps: totalSteps))
            printProgress("  \u{2192} \(clumpifyLabel)...")
            let clumpifyStart = Date()

            let pipeline = FASTQIngestionPipeline()
            let ingestionResult = try await pipeline.run(config: ingestionConfig, progress: { _, msg in
                logger.debug("\(pair.sampleName): \(msg)")
            })

            log?(.stepComplete(
                sample: pair.sampleName,
                step: clumpifyLabel,
                durationSeconds: Date().timeIntervalSince(clumpifyStart)
            ))
            printProgress("  \u{2192} \(clumpifyLabel)... done (\(Int(Date().timeIntervalSince(clumpifyStart)))s)")

            let finalFASTQURL = ingestionResult.outputFile

            // Step 3: Build bundle directory
            let bundleURL = outputDir.appendingPathComponent(
                "\(pair.sampleName).\(FASTQBundle.directoryExtension)"
            )
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            let bundleFASTQName = "\(pair.sampleName).fastq.gz"
            let bundleFASTQURL = bundleURL.appendingPathComponent(bundleFASTQName)
            if finalFASTQURL != bundleFASTQURL {
                try? FileManager.default.removeItem(at: bundleFASTQURL)
                try FileManager.default.moveItem(at: finalFASTQURL, to: bundleFASTQURL)
            }

            // Write ingestion metadata sidecar
            let pairingMeta: IngestionMetadata.PairingMode = pair.r2 != nil ? .interleaved : .singleEnd
            let ingestion = IngestionMetadata(
                isClumpified: ingestionResult.wasClumpified,
                isCompressed: true,
                pairingMode: pairingMeta,
                qualityBinning: ingestionResult.qualityBinning.rawValue,
                originalFilenames: [pair.r1.lastPathComponent] + (pair.r2.map { [$0.lastPathComponent] } ?? []),
                ingestionDate: Date(),
                originalSizeBytes: ingestionResult.originalSizeBytes
            )
            var metadata = PersistedFASTQMetadata()
            metadata.ingestion = ingestion
            let stepResults: [RecipeStepResult] = []
            if let recipe = config.recipe, !stepResults.isEmpty {
                metadata.ingestion?.recipeApplied = RecipeAppliedInfo(
                    recipeID: recipe.id.uuidString,
                    recipeName: recipe.name,
                    appliedDate: Date(),
                    stepResults: stepResults
                )
            }
            FASTQMetadataStore.save(metadata, for: bundleFASTQURL)

            // Write per-sample log if logDirectory is set
            if let logDir = config.logDirectory {
                writePerSampleLog(pair: pair, bundleURL: bundleURL, logDir: logDir)
            }

            let finalBytes = bundleFileSize(bundleURL)
            let duration = Date().timeIntervalSince(sampleStart)

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
        log: (@Sendable (ImportLogEvent) -> Void)?
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
                let physicalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
                let heapGB = max(4, min(31, physicalMemoryGB * 60 / 100))

                switch step.kind {
                case .deduplicate:
                    var args = [
                        "in1=\(currentR1.path)", "in2=\(r2.path)",
                        "out1=\(outR1.path)", "out2=\(outR2.path)",
                        "-Xmx\(heapGB)g", "dedupe=t",
                        "subs=\(step.deduplicateSubstitutions ?? 0)", "ow=t",
                        "threads=\(config.threads)",
                    ]
                    if step.deduplicateOptical == true {
                        args += ["optical=t", "dupedist=\(step.deduplicateOpticalDistance ?? 2500)"]
                    }
                    let result = try await runner.run(.clumpify, arguments: args, environment: env, timeout: 3600)
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
                    let result = try await runner.run(.fastp, arguments: args, timeout: 3600)
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
                    let result = try await runner.run(.fastp, arguments: args, timeout: 3600)
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
            currentURL = inputR1
            currentIsInterleaved = false
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
                let dedupeArgs = [
                    "in=\(currentURL.path)",
                    "out=\(outputURL.path)",
                    "dedupe=t",
                    "optical=\(step.deduplicateOptical == true ? "t" : "f")",
                    "threads=\(config.threads)",
                ]
                let result = try await runner.run(.clumpify, arguments: dedupeArgs, environment: env, timeout: 3600)
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
                    args += ["-I", currentURL.path, "-O", r2OutputURL.path]
                }
                let result = try await runner.run(.fastp, arguments: args, timeout: 3600)
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
                    args += ["-I", currentURL.path, "-O", r2OutputURL.path]
                }
                let result = try await runner.run(.fastp, arguments: args, timeout: 3600)
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
                let dbID = step.humanScrubDatabaseID ?? "human-scrubber"
                let removeReads = step.humanScrubRemoveReads ?? false
                guard let dbPath = await DatabaseRegistry.shared.effectiveDatabasePath(for: dbID) else {
                    throw BatchImportError.unknownRecipe(
                        "Human scrub database '\(dbID)' not found. " +
                        "Place it in ~/Library/Application Support/Lungfish/databases/\(dbID)/")
                }
                let scrubSh = try await runner.findTool(.scrubSh)
                let scriptsDir = scrubSh.deletingLastPathComponent()

                // Decompress if gzipped (scrub.sh needs plain text)
                let inputForScrub: URL
                var decompTemp: URL? = nil
                if currentURL.pathExtension.lowercased() == "gz" {
                    let tmp = workspace.appendingPathComponent("scrub_in_\(UUID().uuidString).fastq")
                    let pigzResult = try await runner.runWithFileOutput(
                        .pigz, arguments: ["-d", "-c", currentURL.path], outputFile: tmp)
                    guard pigzResult.isSuccess else {
                        throw BatchImportError.unknownRecipe("Decompression before scrub failed: \(pigzResult.stderr.suffix(500))")
                    }
                    inputForScrub = tmp
                    decompTemp = tmp
                } else {
                    inputForScrub = currentURL
                }
                defer { if let t = decompTemp { try? FileManager.default.removeItem(at: t) } }

                // scrub.sh writes plain FASTQ, not gzip — we'll compress after
                let scrubOutputURL = workspace.appendingPathComponent("step_\(absIndex)_\(pair.sampleName).fastq")
                var scriptArgs = [scrubSh.path,
                    "-i", inputForScrub.path,
                    "-o", scrubOutputURL.path,
                    "-d", dbPath.path,
                    "-p", String(config.threads)]
                if currentIsInterleaved { scriptArgs.append("-s") }
                if removeReads { scriptArgs.append("-x") }

                let scrubResult = try await runner.runProcess(
                    executableURL: URL(fileURLWithPath: "/bin/bash"),
                    arguments: scriptArgs,
                    workingDirectory: scriptsDir,
                    environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                    timeout: 7200,
                    toolName: "scrub.sh"
                )
                guard scrubResult.isSuccess else {
                    throw BatchImportError.unknownRecipe("sra-human-scrubber failed: \(scrubResult.stderr.suffix(500))")
                }

                // Compress the scrub output
                let compResult = try await runner.runWithFileOutput(
                    .pigz,
                    arguments: ["-p", String(config.threads), "-c", scrubOutputURL.path],
                    outputFile: outputURL
                )
                try? FileManager.default.removeItem(at: scrubOutputURL)
                guard compResult.isSuccess else {
                    throw BatchImportError.unknownRecipe("Compression after scrub failed: \(compResult.stderr.suffix(500))")
                }

            case .pairedEndMerge:
                let strictness = step.mergeStrictness ?? .normal
                let minOverlap = step.mergeMinOverlap ?? 12
                let mergedURL = workspace.appendingPathComponent("step_\(absIndex)_merged.fastq")
                let unmergedR1URL = workspace.appendingPathComponent("step_\(absIndex)_unmerged_R1.fastq")
                let unmergedR2URL = workspace.appendingPathComponent("step_\(absIndex)_unmerged_R2.fastq")

                var args = [
                    "in=\(currentURL.path)",
                    "out=\(mergedURL.path)",
                    "outu1=\(unmergedR1URL.path)",
                    "outu2=\(unmergedR2URL.path)",
                    "minoverlap=\(minOverlap)",
                    "threads=\(config.threads)",
                ]
                if strictness == .strict { args.append("strict=t") }

                let env = await bbToolsEnvironment()
                let mergeResult = try await runner.run(.bbmerge, arguments: args, environment: env, timeout: 1800)
                guard mergeResult.isSuccess else {
                    throw BatchImportError.unknownRecipe("bbmerge failed: \(mergeResult.stderr.suffix(500))")
                }

                // Re-interleave unmerged + append merged into a single output file
                // If we have unmerged pairs, interleave them first
                let hasUnmergedR1 = FileManager.default.fileExists(atPath: unmergedR1URL.path)
                let hasUnmergedR2 = FileManager.default.fileExists(atPath: unmergedR2URL.path)
                let hasMerged = FileManager.default.fileExists(atPath: mergedURL.path)

                let combinedURL = workspace.appendingPathComponent("step_\(absIndex)_combined.fastq")

                if hasUnmergedR1 && hasUnmergedR2 {
                    let interleavedUnmergedURL = workspace.appendingPathComponent("step_\(absIndex)_unmerged_il.fastq")
                    try await interleavePairedInput(r1: unmergedR1URL, r2: unmergedR2URL, output: interleavedUnmergedURL)
                    // Cat interleaved unmerged + merged into combined
                    var catParts: [URL] = [interleavedUnmergedURL]
                    if hasMerged { catParts.append(mergedURL) }
                    try concatenateFiles(catParts, to: combinedURL)
                    try? FileManager.default.removeItem(at: interleavedUnmergedURL)
                } else if hasMerged {
                    try FileManager.default.copyItem(at: mergedURL, to: combinedURL)
                }
                // Compress combined
                let compResult = try await runner.runWithFileOutput(
                    .pigz,
                    arguments: ["-p", String(config.threads), "-c", combinedURL.path],
                    outputFile: outputURL
                )
                try? FileManager.default.removeItem(at: combinedURL)
                try? FileManager.default.removeItem(at: mergedURL)
                try? FileManager.default.removeItem(at: unmergedR1URL)
                try? FileManager.default.removeItem(at: unmergedR2URL)
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
                    let result = try await runner.run(.bbduk, arguments: args, environment: env, timeout: 1800)
                    guard result.isSuccess else {
                        throw BatchImportError.unknownRecipe("bbduk length filter failed: \(result.stderr.suffix(500))")
                    }
                } else {
                    // Use seqkit seq for single-ended or mixed content
                    var seqkitArgs = ["seq", "-j", String(config.threads), currentURL.path, "-o", outputURL.path]
                    if let m = minLen { seqkitArgs += ["-m", String(m)] }
                    if let m = maxLen { seqkitArgs += ["-M", String(m)] }
                    let result = try await runner.run(.seqkit, arguments: seqkitArgs, timeout: 1800)
                    guard result.isSuccess else {
                        throw BatchImportError.unknownRecipe("seqkit length filter failed: \(result.stderr.suffix(500))")
                    }
                }

            default:
                // Skip unsupported step kinds — log a warning
                logger.warning("FASTQBatchImporter: unsupported recipe step \(step.kind.rawValue) — skipping")
                log?(.stepComplete(
                    sample: pair.sampleName,
                    step: stepName + " (skipped)",
                    durationSeconds: Date().timeIntervalSince(stepStart)
                ))
                continue
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

    // MARK: - Private Helpers

    /// Creates a temp workspace directory anchored at the project (or system temp as fallback).
    private static func createIngestionWorkspace(anchoredAt projectDir: URL) throws -> URL {
        do {
            return try ProjectTempDirectory.create(prefix: "lungfish-batch-", in: projectDir)
        } catch {
            // Fallback: use .itemReplacementDirectory near the project
            let fm = FileManager.default
            let tmp = try fm.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: projectDir,
                create: true
            )
            return tmp
        }
    }

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
            timeout: 1800
        )
        guard result.isSuccess else {
            throw BatchImportError.unknownRecipe("reformat.sh interleave failed: \(result.stderr.suffix(500))")
        }
    }

    /// Builds the PATH/JAVA_HOME/BBMAP_JAVA environment dictionary for BBTools scripts.
    private static func bbToolsEnvironment() async -> [String: String] {
        let runner = NativeToolRunner.shared
        var env: [String: String] = [:]
        if let toolsDir = await runner.getToolsDirectory() {
            let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            let jreBinDir = toolsDir.appendingPathComponent("jre/bin")
            env["PATH"] = "\(toolsDir.path):\(jreBinDir.path):\(existingPath)"
            let javaURL = jreBinDir.appendingPathComponent("java")
            let javaHome = toolsDir.appendingPathComponent("jre")
            if FileManager.default.fileExists(atPath: javaURL.path) {
                env["JAVA_HOME"] = javaHome.path
                env["BBMAP_JAVA"] = javaURL.path
            }
        }
        return env
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

    /// Concatenates multiple FASTQ files into a single destination file.
    private static func concatenateFiles(_ sources: [URL], to destination: URL) throws {
        let fm = FileManager.default
        fm.createFile(atPath: destination.path, contents: nil)
        guard let output = FileHandle(forWritingAtPath: destination.path) else {
            throw BatchImportError.unknownRecipe("Cannot open destination for concatenation: \(destination.path)")
        }
        defer { output.closeFile() }
        for source in sources {
            if let data = fm.contents(atPath: source.path) {
                output.write(data)
            }
        }
    }

    /// Writes a per-sample JSON log to the specified log directory.
    private static func writePerSampleLog(pair: SamplePair, bundleURL: URL, logDir: URL) {
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let logFile = logDir.appendingPathComponent("\(pair.sampleName).import.log")
            let entry: [String: Any] = [
                "sample": pair.sampleName,
                "r1": pair.r1.lastPathComponent,
                "r2": pair.r2?.lastPathComponent ?? NSNull(),
                "bundle": bundleURL.lastPathComponent,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
            ]
            let data = try JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: logFile, options: .atomic)
        } catch {
            logger.warning("Failed to write per-sample log for \(pair.sampleName): \(error.localizedDescription)")
        }
    }

    // MARK: - Private Utilities

    /// Strips FASTQ extensions from a URL, returning the base stem.
    private static func fastqStem(_ url: URL) -> String {
        var name = url.lastPathComponent
        let extensions = [".fastq.gz", ".fq.gz", ".fastq", ".fq"]
        for ext in extensions {
            if name.lowercased().hasSuffix(ext) {
                name = String(name.dropLast(ext.count))
                return name
            }
        }
        return name
    }
}
