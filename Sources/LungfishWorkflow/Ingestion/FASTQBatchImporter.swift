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
    /// Relative path from the scanned root directory (nil for root-level files).
    public let relativePath: String?
    /// Optional metadata imported from a sample sheet row.
    public let metadata: [String: String]
    /// CSV sample sheet that supplied this pair, when applicable.
    public let sampleSheetURL: URL?

    public init(
        sampleName: String,
        r1: URL,
        r2: URL?,
        relativePath: String? = nil,
        metadata: [String: String] = [:],
        sampleSheetURL: URL? = nil
    ) {
        self.sampleName = sampleName
        self.r1 = r1
        self.r2 = r2
        self.relativePath = relativePath
        self.metadata = metadata
        self.sampleSheetURL = sampleSheetURL
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
    case unsupportedRecipe(String, reason: String)
    case unsupportedRecipeStep(recipe: String, step: String)
    case projectNotFound(URL)
    case recipeNotApplicable(recipe: String, sample: String, reason: String)
    case outputBundleAlreadyExists(URL)
    case statisticsUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .noFASTQFilesFound(let url):
            return "No FASTQ files found in \(url.lastPathComponent)"
        case .unknownRecipe(let name):
            return "Unknown recipe '\(name)'. Valid names: vsp2, wgs, hifi"
        case .unsupportedRecipe(let name, let reason):
            return "Unsupported recipe '\(name)': \(reason)"
        case .unsupportedRecipeStep(let recipe, let step):
            return "Legacy batch import cannot execute recipe '\(recipe)' because it contains unsupported step '\(step)'."
        case .projectNotFound(let url):
            return "No .lungfish project found at or above \(url.path)"
        case .recipeNotApplicable(let recipe, let sample, let reason):
            return "Recipe '\(recipe)' cannot be applied to sample '\(sample)': \(reason)"
        case .outputBundleAlreadyExists(let url):
            return "Output FASTQ bundle already exists: \(url.path)"
        case .statisticsUnavailable(let reason):
            return "FASTQ statistics could not be computed: \(reason)"
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
        /// Old-format recipe (for supported unmigrated recipes like WGS and HiFi).
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

    public static func persistedSequencingPlatform(
        for platform: LungfishWorkflow.SequencingPlatform
    ) -> LungfishIO.SequencingPlatform? {
        switch platform {
        case .illumina:
            return .illumina
        case .ont:
            return .oxfordNanopore
        case .pacbio:
            return .pacbio
        case .ultima:
            return .ultima
        }
    }

    public static func persistedAssemblyReadType(
        for platform: LungfishWorkflow.SequencingPlatform
    ) -> FASTQAssemblyReadType? {
        switch platform {
        case .illumina:
            return .illuminaShortReads
        case .ont:
            return .ontReads
        case .pacbio, .ultima:
            return nil
        }
    }

    public static func applyConfirmedPlatformMetadata(
        to metadata: inout PersistedFASTQMetadata,
        platform: LungfishWorkflow.SequencingPlatform
    ) {
        metadata.sequencingPlatform = persistedSequencingPlatform(for: platform)
        if let readType = persistedAssemblyReadType(for: platform) {
            metadata.assemblyReadType = readType
        }
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

    /// Recursively scans `directory` and all subdirectories for FASTQ files,
    /// groups them into pairs per directory, and annotates each pair with its
    /// relative path from the root.
    ///
    /// - Throws: `BatchImportError.noFASTQFilesFound` when no FASTQ files exist
    ///   anywhere under `directory`.
    public static func detectPairsFromDirectoryRecursive(_ directory: URL) throws -> [SamplePair] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw BatchImportError.noFASTQFilesFound(directory)
        }

        // Group FASTQ files by their parent directory
        var filesByDirectory: [URL: [URL]] = [:]
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent.lowercased()
            guard name.hasSuffix(".fastq.gz") || name.hasSuffix(".fq.gz") ||
                  name.hasSuffix(".fastq") || name.hasSuffix(".fq") else { continue }
            let parentDir = fileURL.deletingLastPathComponent()
            filesByDirectory[parentDir, default: []].append(fileURL)
        }

        guard !filesByDirectory.isEmpty else {
            throw BatchImportError.noFASTQFilesFound(directory)
        }

        let rootPath = directory.standardizedFileURL.path
        var allPairs: [SamplePair] = []

        for (dir, urls) in filesByDirectory {
            let sortedURLs = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let basePairs = detectPairs(from: sortedURLs)

            // Compute relative path: nil if same as root, else strip root prefix
            let dirPath = dir.standardizedFileURL.path
            let relativePath: String?
            if dirPath == rootPath {
                relativePath = nil
            } else {
                var rel = dirPath
                if rel.hasPrefix(rootPath) {
                    rel = String(rel.dropFirst(rootPath.count))
                }
                // Trim leading /
                if rel.hasPrefix("/") {
                    rel = String(rel.dropFirst())
                }
                // Trim trailing /
                if rel.hasSuffix("/") {
                    rel = String(rel.dropLast())
                }
                relativePath = rel.isEmpty ? nil : rel
            }

            for pair in basePairs {
                allPairs.append(SamplePair(
                    sampleName: pair.sampleName,
                    r1: pair.r1,
                    r2: pair.r2,
                    relativePath: relativePath
                ))
            }
        }

        // Sort by relativePath (nil first) then sampleName
        allPairs.sort { lhs, rhs in
            let lp = lhs.relativePath ?? ""
            let rp = rhs.relativePath ?? ""
            if lp != rp { return lp < rp }
            return lhs.sampleName < rhs.sampleName
        }

        return allPairs
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

    private static func prepareFASTQBundleParent(for bundleURL: URL) throws {
        try FileManager.default.createDirectory(
            at: bundleURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private static func makeStagingFASTQBundleURL(for publishedBundleURL: URL) throws -> URL {
        let parentURL = publishedBundleURL.deletingLastPathComponent()
        let baseName = publishedBundleURL.deletingPathExtension().lastPathComponent
        let stagingName = ".\(baseName).building-\(UUID().uuidString)"
        return parentURL.appendingPathComponent(stagingName, isDirectory: true)
    }

    private static func makeReplacementBackupURL(for publishedBundleURL: URL) throws -> URL {
        let parentURL = publishedBundleURL.deletingLastPathComponent()
        let backupName = ".\(publishedBundleURL.lastPathComponent).replacing-\(UUID().uuidString)"
        return parentURL.appendingPathComponent(backupName, isDirectory: true)
    }

    private static func publishFASTQBundle(
        from stagingBundleURL: URL,
        to publishedBundleURL: URL,
        replaceExisting: Bool
    ) throws {
        let fileManager = FileManager.default
        var backupURL: URL?

        if fileManager.fileExists(atPath: publishedBundleURL.path) {
            guard replaceExisting else {
                throw BatchImportError.outputBundleAlreadyExists(publishedBundleURL)
            }
            let replacementBackupURL = try makeReplacementBackupURL(for: publishedBundleURL)
            try fileManager.moveItem(at: publishedBundleURL, to: replacementBackupURL)
            backupURL = replacementBackupURL
        }

        do {
            try fileManager.moveItem(at: stagingBundleURL, to: publishedBundleURL)
            if let backupURL {
                try? fileManager.removeItem(at: backupURL)
            }
        } catch {
            if let backupURL,
               !fileManager.fileExists(atPath: publishedBundleURL.path),
               fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: publishedBundleURL)
            }
            throw error
        }
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
        log: (@Sendable (ImportLogEvent) -> Void)? = nil,
        databaseRegistry: DatabaseRegistry = .shared
    ) async -> ImportResult {
        let startTime = Date()
        let recipeName = config.newRecipe?.name ?? config.recipe?.name

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
                log: log,
                databaseRegistry: databaseRegistry
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
        log: (@Sendable (ImportLogEvent) -> Void)?,
        databaseRegistry: DatabaseRegistry
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
            try validateRecipeApplicability(pair: pair, config: config)

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
            var recipeStepResults: [RecipeStepResult] = []

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
                // Total includes recipe steps + clumpify + stats
                tracker.totalSteps = newRecipe.steps.count + 2

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
                    log: log,
                    databaseRegistry: databaseRegistry
                )
                // After VSP2 recipe, output is interleaved (PE merge step produces mixed reads)
                isPairedAfterRecipe = true
            }

            // Step 2: Clumpify + compress (on recipe output, or raw input if no recipe)
            let clumpifyInput: [URL]
            let clumpifyPairingMode: FASTQIngestionConfig.PairingMode
            let deleteIngestionInputsAfterRun: Bool
            if let recipeOutput = recipeOutputFASTQ {
                clumpifyInput = [recipeOutput]
                clumpifyPairingMode = isPairedAfterRecipe ? .interleaved : .singleEnd
                deleteIngestionInputsAfterRun = true
            } else {
                let rawInputs = pair.r2 != nil ? [pair.r1, pair.r2!] : [pair.r1]
                if config.optimizeStorage {
                    clumpifyInput = rawInputs
                    deleteIngestionInputsAfterRun = false
                } else {
                    clumpifyInput = try stageRawInputsForIngestion(rawInputs, in: workspace)
                    deleteIngestionInputsAfterRun = true
                }
                clumpifyPairingMode = pair.r2 != nil ? .pairedEnd : .singleEnd
            }

            let ingestionConfig = FASTQIngestionConfig(
                inputFiles: clumpifyInput,
                pairingMode: clumpifyPairingMode,
                outputDirectory: workspace,
                threads: config.threads,
                deleteOriginals: deleteIngestionInputsAfterRun,
                qualityBinning: config.qualityBinning,
                skipClumpify: !config.optimizeStorage
            )

            // Total steps = recipe steps + clumpify + stats
            let recipeStepCount = config.recipe?.steps.count ?? config.newRecipe?.steps.count ?? 0
            let totalSteps = recipeStepCount + 2  // +1 clumpify, +1 stats
            let clumpifyStepIndex = recipeStepCount + 1
            let statsStepIndex = recipeStepCount + 2
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
            recipeStepResults.append(RecipeStepResult(
                stepName: clumpifyLabel,
                tool: ingestionResult.processingTool ?? (config.optimizeStorage ? "clumpify.sh" : "compression"),
                toolVersion: ingestionResult.processingToolVersion,
                commandLine: ingestionResult.processingCommandLine,
                inputReadCount: nil,
                outputReadCount: nil,
                durationSeconds: Date().timeIntervalSince(clumpifyStart)
            ))
            printProgress("  \u{2192} \(clumpifyLabel)... done (\(Int(Date().timeIntervalSince(clumpifyStart)))s)")

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
            applyConfirmedPlatformMetadata(to: &metadata, platform: config.platform)
            if let recipe = config.newRecipe, !recipeStepResults.isEmpty {
                metadata.ingestion?.recipeApplied = RecipeAppliedInfo(
                    recipeID: recipe.id,
                    recipeName: recipe.name,
                    appliedDate: Date(),
                    stepResults: recipeStepResults
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

            // Write per-sample log if logDirectory is set
            if let logDir = config.logDirectory {
                writePerSampleLog(pair: pair, bundleURL: bundleURL, logDir: logDir)
            }

            // Step: Compute FASTQ statistics
            let statsLabel = "Compute statistics"
            log?(.stepStart(sample: pair.sampleName, step: statsLabel, stepIndex: statsStepIndex, totalSteps: totalSteps))
            let statsStart = Date()
            var statsError: String?
            do {
                try await computeAndCacheStatistics(for: stagingBundleFASTQURL)
            } catch {
                statsError = error.localizedDescription
                logger.warning("Stats computation failed for \(pair.sampleName): \(error)")
                throw error
            }
            let statsCompletedAt = Date()
            log?(.stepComplete(sample: pair.sampleName, step: statsLabel,
                               durationSeconds: statsCompletedAt.timeIntervalSince(statsStart)))
            recipeStepResults.append(RecipeStepResult(
                stepName: statsLabel,
                tool: "seqkit",
                toolVersion: nil,
                commandLine: nil,
                inputReadCount: nil,
                outputReadCount: nil,
                durationSeconds: statsCompletedAt.timeIntervalSince(statsStart)
            ))

            try await writeImportProvenance(
                pair: pair,
                config: config,
                stagingBundleURL: stagingBundleURL,
                stagingBundleFASTQURL: stagingBundleFASTQURL,
                publishedBundleURL: bundleURL,
                publishedBundleFASTQURL: publishedBundleFASTQURL,
                sourceIngestionOutputURL: ingestionResult.outputFile,
                ingestionResult: ingestionResult,
                recipeStepResults: recipeStepResults,
                statsStartedAt: statsStart,
                statsCompletedAt: statsCompletedAt,
                statsError: statsError
            )

            try publishFASTQBundle(
                from: stagingBundleURL,
                to: bundleURL,
                replaceExisting: config.forceReimport || !isCompleteFASTQImportBundle(at: bundleURL)
            )
            didPublishBundle = true

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

    private static func validateRecipeApplicability(pair: SamplePair, config: ImportConfig) throws {
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

    // MARK: - Provenance

    private static func writeImportProvenance(
        pair: SamplePair,
        config: ImportConfig,
        stagingBundleURL: URL,
        stagingBundleFASTQURL: URL,
        publishedBundleURL: URL,
        publishedBundleFASTQURL: URL,
        sourceIngestionOutputURL: URL,
        ingestionResult: FASTQIngestionResult,
        recipeStepResults: [RecipeStepResult],
        statsStartedAt: Date,
        statsCompletedAt: Date,
        statsError: String?
    ) async throws {
        let originalInputURLs = [pair.r1] + (pair.r2.map { [$0] } ?? [])
        let sampleSheetInput = pair.sampleSheetURL.map {
            ProvenanceRecorder.fileRecord(url: $0, format: .text, role: .input)
        }
        let stagingMetadataURL = FASTQMetadataStore.metadataURL(for: stagingBundleFASTQURL)
        let stagingCSVMetadataURL = FASTQBundleCSVMetadata.metadataURL(in: stagingBundleURL)
        let publishedMetadataURL = FASTQMetadataStore.metadataURL(for: publishedBundleFASTQURL)
        let publishedCSVMetadataURL = FASTQBundleCSVMetadata.metadataURL(in: publishedBundleURL)
        var steps: [StepExecution] = []
        steps.append(contentsOf: recipeProvenanceSteps(
            recipeStepResults: recipeStepResults,
            originalInputURLs: originalInputURLs,
            bundleFASTQURL: stagingBundleFASTQURL
        ))
        steps.append(contentsOf: rehydratedIngestionSteps(
            ingestionResult.provenanceSteps,
            sourceOutputURL: sourceIngestionOutputURL,
            finalOutputURL: stagingBundleFASTQURL,
            originalInputURLs: originalInputURLs
        ))

        let finalizedAt = Date()
        steps.append(StepExecution(
            toolName: "lungfish import fastq",
            toolVersion: WorkflowRun.currentAppVersion,
            command: reproducibleImportCommand(pair: pair, config: config),
            inputs: originalInputURLs.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input) }
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

        steps.append(StepExecution(
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
        ))

        let completedAt = Date()
        let command = reproducibleImportCommand(pair: pair, config: config)
        var builder = ProvenanceRunBuilder(
            workflowName: "lungfish import fastq",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish import fastq",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(command)
        .durableReplayArgv(command)
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
                ingestionResult: ingestionResult
            )
        )
        .runtime(ProvenanceRuntimeIdentity())
        for inputURL in originalInputURLs {
            builder = try builder.input(inputURL, format: .fastq, role: .input)
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
        for step in steps {
            builder = builder.step(ProvenanceStep(stepExecution: step))
        }

        let envelope = try builder.complete(
            exitStatus: 0,
            stderr: statsError,
            startedAt: steps.map(\.startTime).min() ?? completedAt,
            endedAt: completedAt
        )
        let finalEnvelope = rewriteStagedBundlePaths(
            in: envelope,
            stagingBundleURL: stagingBundleURL,
            publishedBundleURL: publishedBundleURL
        )
        try ProvenanceWriter().write(
            finalEnvelope,
            to: stagingBundleURL,
            bundleLayoutRoot: publishedBundleURL
        )
    }

    private static func rewriteStagedBundlePaths(
        in envelope: ProvenanceEnvelope,
        stagingBundleURL: URL,
        publishedBundleURL: URL
    ) -> ProvenanceEnvelope {
        let options = ProvenanceOptions(
            explicit: envelope.options.explicit.mapValues {
                rewriteStagedParameterValue($0, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
            },
            defaults: envelope.options.defaults.mapValues {
                rewriteStagedParameterValue($0, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
            },
            resolvedDefaults: envelope.options.resolvedDefaults.mapValues {
                rewriteStagedParameterValue($0, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
            }
        )
        let steps = envelope.steps.map { step in
            let replayArgv = rewriteStagedArguments(
                step.durableReplayArgv ?? step.argv,
                stagingBundleURL: stagingBundleURL,
                publishedBundleURL: publishedBundleURL
            )
            let replayCommand = replayArgv.map(shellEscape).joined(separator: " ")
            return ProvenanceStep(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                githubReleaseVersion: step.githubReleaseVersion,
                argv: step.argv,
                durableReplayArgv: replayArgv,
                reproducibleCommand: replayCommand,
                inputs: step.inputs.map {
                    rewriteStagedDescriptor($0, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
                },
                outputs: step.outputs.map {
                    rewriteStagedDescriptor($0, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
                },
                exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                startedAt: step.startedAt,
                completedAt: step.completedAt
            )
        }

        let durableReplayArgv = rewriteStagedArguments(
            envelope.durableReplayArgv ?? envelope.argv,
            stagingBundleURL: stagingBundleURL,
            publishedBundleURL: publishedBundleURL
        )
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
            files: envelope.files.map {
                rewriteStagedDescriptor($0, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
            },
            output: envelope.output.map {
                rewriteStagedDescriptor($0, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
            },
            outputs: envelope.outputs.map {
                rewriteStagedDescriptor($0, stagingBundleURL: stagingBundleURL, publishedBundleURL: publishedBundleURL)
            },
            steps: steps,
            wallTimeSeconds: envelope.wallTimeSeconds,
            exitStatus: envelope.exitStatus,
            stderr: envelope.stderr,
            signatures: [],
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
        bundleFASTQURL: URL
    ) -> [StepExecution] {
        recipeStepResults.compactMap { result in
            guard result.stepName != "Compute statistics",
                  !result.stepName.localizedCaseInsensitiveContains("Clumpify"),
                  !result.stepName.localizedCaseInsensitiveContains("Compress") else {
                return nil
            }
            let command = recipeStepCommandArguments(for: result)
            let timestamp = Date()
            return StepExecution(
                toolName: result.tool,
                toolVersion: result.toolVersion ?? "unknown",
                command: command,
                inputs: originalInputURLs.map {
                    ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input)
                },
                outputs: [ProvenanceRecorder.fileRecord(url: bundleFASTQURL, format: .fastq, role: .output)],
                exitCode: 0,
                wallTime: result.durationSeconds,
                stderr: nil,
                startTime: timestamp.addingTimeInterval(-result.durationSeconds),
                endTime: timestamp
            )
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

    private static func rehydratedIngestionSteps(
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
            return StepExecution(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                containerImage: step.containerImage,
                containerDigest: step.containerDigest,
                command: step.command,
                durableReplayArgv: durableReplayArgv,
                inputs: step.inputs,
                outputs: outputs,
                exitCode: step.exitCode,
                wallTime: step.wallTime,
                peakMemoryBytes: step.peakMemoryBytes,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
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
        [
            "sampleName": .string(pair.sampleName),
            "r1": .file(pair.r1),
            "r2": pair.r2.map(ParameterValue.file) ?? .null,
            "sampleSheet": pair.sampleSheetURL.map(ParameterValue.file) ?? .null,
            "sampleSheetMetadata": pair.metadata.isEmpty ? .null : .dictionary(
                pair.metadata.mapValues { .string($0) }
            ),
            "projectDirectory": .file(config.projectDirectory),
            "outputBundle": .file(bundleURL),
            "platform": .string(config.platform.rawValue),
            "recipe": .string(config.newRecipe?.id ?? config.recipe?.name ?? "none"),
            "qualityBinning": .string(config.qualityBinning.rawValue),
            "optimizeStorage": .boolean(config.optimizeStorage),
            "compressionLevel": .string(config.compressionLevel.rawValue),
            "threads": .integer(config.threads),
            "forceReimport": .boolean(config.forceReimport),
        ]
    }

    private static func provenanceDefaultParameters(config: ImportConfig) -> [String: ParameterValue] {
        [
            "platform": .string(LungfishWorkflow.SequencingPlatform.illumina.rawValue),
            "recipe": .string("none"),
            "qualityBinning": .string(
                (config.newRecipe?.qualityBinning ?? config.platform.defaultQualityBinning).rawValue
            ),
            "optimizeStorage": .boolean(config.platform.defaultOptimizeStorage),
            "compressionLevel": .string(config.platform.defaultCompressionLevel.rawValue),
            "threads": .integer(4),
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
        ingestionResult: FASTQIngestionResult
    ) -> [String: ParameterValue] {
        var parameters = provenanceParameters(pair: pair, config: config, bundleURL: bundleURL)
        parameters["primaryFASTQ"] = .file(bundleFASTQURL)
        parameters["metadataJSON"] = .file(metadataURL)
        parameters["metadataCSV"] = FileManager.default.fileExists(atPath: csvMetadataURL.path)
            ? .file(csvMetadataURL)
            : .null
        parameters["pairedEndInput"] = .boolean(pair.r2 != nil)
        parameters["outputPairingMode"] = .string(ingestionResult.pairingMode.rawValue)
        parameters["wasClumpified"] = .boolean(ingestionResult.wasClumpified)
        parameters["originalFilenames"] = .array(ingestionResult.originalFilenames.map { .string($0) })
        parameters["originalSizeBytes"] = .integer(Int(ingestionResult.originalSizeBytes))
        parameters["finalSizeBytes"] = .integer(Int(ingestionResult.finalSizeBytes))
        parameters["processingTool"] = ingestionResult.processingTool.map(ParameterValue.string) ?? .null
        parameters["processingToolVersion"] = ingestionResult.processingToolVersion.map(ParameterValue.string) ?? .null
        parameters["processingCommandLine"] = ingestionResult.processingCommandLine.map(ParameterValue.string) ?? .null
        return parameters
    }

    private static func reproducibleImportCommand(pair: SamplePair, config: ImportConfig) -> [String] {
        if let sampleSheetURL = pair.sampleSheetURL {
            var command = [
                "lungfish", "import", "fastq",
                "--samplesheet", sampleSheetURL.path,
                "--project", config.projectDirectory.path,
                "--platform", config.platform.rawValue,
                "--recipe", config.newRecipe?.id ?? config.recipe?.name ?? "none",
                "--quality-binning", config.qualityBinning.rawValue,
                "--compression", config.compressionLevel.rawValue,
                "--threads", String(config.threads),
            ]
            if !config.optimizeStorage {
                command.append("--no-optimize-storage")
            }
            if config.forceReimport {
                command.append("--force")
            }
            return command
        }

        var command = [
            "lungfish", "import", "fastq",
            pair.r1.path,
        ]
        if let r2 = pair.r2 {
            command.append(r2.path)
        }
        command += [
            "--project", config.projectDirectory.path,
            "--platform", config.platform.rawValue,
            "--recipe", config.newRecipe?.id ?? config.recipe?.name ?? "none",
            "--quality-binning", config.qualityBinning.rawValue,
            "--compression", config.compressionLevel.rawValue,
            "--threads", String(config.threads),
        ]
        if !config.optimizeStorage {
            command.append("--no-optimize-storage")
        }
        if config.forceReimport {
            command.append("--force")
        }
        return command
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
                    args += ["-O", r2OutputURL.path]
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
                    args += ["-O", r2OutputURL.path]
                }
                switch step.qualityTrimMode ?? .cutRight {
                case .cutRight: args.append("--cut_right")
                case .cutFront: args.append("--cut_front")
                case .cutTail: args.append("--cut_tail")
                case .cutBoth: args += ["--cut_front", "--cut_right"]
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
                        .pigz, arguments: ["-d", "-c", currentURL.path], outputFile: tmp)
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
                        timeout: 7200
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
                        timeout: 7200
                    )
                    guard deaconResult.isSuccess else {
                        throw BatchImportError.unknownRecipe("deacon filter failed: \(deaconResult.stderr.suffix(500))")
                    }
                }

                let compResult = try await runner.runWithFileOutput(
                    .pigz,
                    arguments: ["-p", String(config.threads), "-c", scrubOutputURL.path],
                    outputFile: outputURL
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
                ]
                if strictness == .strict { args.append("strict=t") }

                let env = await bbToolsEnvironment()
                let mergeResult = try await runner.run(.bbmerge, arguments: args, environment: env, timeout: 1800)
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
                    .pigz,
                    arguments: ["-p", String(config.threads), "-c", combinedURL.path],
                    outputFile: outputURL
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
            timeout: 900
        )
        guard seqkitResult.isSuccess else {
            logger.warning("seqkit stats failed: \(seqkitResult.stderr)")
            throw BatchImportError.statisticsUnavailable(
                "seqkit stats exited \(seqkitResult.exitCode): \(seqkitResult.stderr)"
            )
        }

        let requiredStats = try parseRequiredSeqkitStats(stdout: seqkitResult.stdout)
        let seqkitMeta = requiredStats.metadata

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
            timeout: 1800
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
            timeout: 1800
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
