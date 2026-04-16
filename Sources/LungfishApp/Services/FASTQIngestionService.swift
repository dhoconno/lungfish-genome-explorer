// FASTQIngestionService.swift - App-level FASTQ ingestion with OperationCenter
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "FASTQIngestionService")

private struct FASTQImportManifest: Codable, Sendable {
    let formatVersion: Int
    let bundleName: String
    let createdAt: Date
    let sourceFilenames: [String]
    let originalSizeBytes: Int64
    let finalFilename: String
    let finalSizeBytes: Int64
    let recipeApplied: RecipeAppliedInfo?
}

private actor FASTQImportSlotCoordinator {
    static let shared = FASTQImportSlotCoordinator()

    private var activeImports = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrentImports = 1

    private init() {}

    func acquire() async {
        if activeImports >= maxConcurrentImports {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        activeImports += 1
    }

    func release() {
        activeImports = max(0, activeImports - 1)
        guard activeImports < maxConcurrentImports, !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        next.resume()
    }
}

// MARK: - FASTQIngestionService

/// App-level service that runs the FASTQ ingestion pipeline (clumpify → compress)
/// and reports progress via OperationCenter.
///
/// Call `ingestIfNeeded` from any FASTQ import path (SRA download, drag-drop, file import).
/// The service checks the sidecar metadata to skip already-ingested files.
@MainActor
public enum FASTQIngestionService {

    /// Ingests a FASTQ file if it hasn't already been processed.
    ///
    /// Runs clumpify → compress in the background via OperationCenter.
    /// The processed file replaces the original. Metadata sidecar is updated.
    ///
    /// - Parameters:
    ///   - url: URL of the FASTQ file to ingest
    ///   - pairingMode: Pairing mode (single-end, paired-end, interleaved)
    ///   - pairedFile: For paired-end, the second file (R2). The first is `url` (R1).
    ///   - existingMetadata: Existing metadata to preserve (SRA info, download date, etc.)
    public static func ingestIfNeeded(
        url: URL,
        pairingMode: FASTQIngestionConfig.PairingMode = .singleEnd,
        pairedFile: URL? = nil,
        existingMetadata: PersistedFASTQMetadata? = nil
    ) {
        // Skip if already ingested
        if let existing = existingMetadata ?? FASTQMetadataStore.load(for: url),
           let ingestion = existing.ingestion,
           ingestion.isClumpified && ingestion.isCompressed {
            logger.info("Skipping ingestion for \(url.lastPathComponent) — already processed")
            return
        }

        let inputFiles: [URL]
        if let pairedFile, pairingMode == .pairedEnd {
            inputFiles = [url, pairedFile]
        } else {
            inputFiles = [url]
        }

        let outputDir = url.deletingLastPathComponent()
        let config = FASTQIngestionConfig(
            inputFiles: inputFiles,
            pairingMode: pairingMode,
            outputDirectory: outputDir,
            threads: ProcessInfo.processInfo.activeProcessorCount,
            deleteOriginals: true
        )

        let baseName = FASTQIngestionPipeline.deriveBaseName(from: url)
        let title = "FASTQ Ingestion: \(baseName)"

        // Register the operation FIRST so we have a stable ID to pass to the detached task.
        let cliCmd = "# lungfish import fastq \(url.path) (CLI command not yet available \u{2014} use GUI)"
        let opID = OperationCenter.shared.start(
            title: title,
            detail: "Preparing...",
            operationType: .ingestion,
            cliCommand: cliCmd
        )

        let task = Task.detached {
            await Self.runIngestion(
                config: config,
                operationID: opID,
                existingMetadata: existingMetadata
            )
        }

        // Store cancellation callback now that we have the task handle.
        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    // MARK: - Ingest and Bundle

    /// Ingests a FASTQ file in a temp directory, then creates a `.lungfishfastq`
    /// bundle in the project directory with the processed file.
    ///
    /// Flow: source-in-place → workspace intermediates → clumpify + compress → create bundle → move into bundle.
    ///
    /// - Parameters:
    ///   - sourceURL: Original FASTQ file (not modified).
    ///   - projectDirectory: Where to create the `.lungfishfastq` bundle.
    ///   - completion: Called on main thread with the bundle URL on success, or error.
    public static func ingestAndBundle(
        sourceURL: URL,
        projectDirectory: URL,
        bundleName: String,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        let title = "FASTQ Import: \(bundleName)"

        let cliCmd = "# lungfish import fastq \(sourceURL.path) (CLI command not yet available \u{2014} use GUI)"
        let opID = OperationCenter.shared.start(
            title: title,
            detail: "Preparing import workspace\u{2026}",
            operationType: .ingestion,
            cliCommand: cliCmd
        )

        let task = Task.detached {
            await Self.runIngestAndBundle(
                sourceURL: sourceURL,
                projectDirectory: projectDirectory,
                bundleName: bundleName,
                operationID: opID,
                completion: completion
            )
        }

        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    // MARK: - Pipeline Runners

    /// Runs the ingestion pipeline off the main actor.
    ///
    /// Must be `nonisolated` — the cooperative executor does not reliably schedule
    /// `@MainActor` methods called from `Task.detached`.  We hop to `MainActor.run`
    /// only for the few OperationCenter mutations that need it.
    nonisolated private static func runIngestion(
        config: FASTQIngestionConfig,
        operationID opID: UUID,
        existingMetadata: PersistedFASTQMetadata?
    ) async {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                OperationCenter.shared.update(
                    id: opID,
                    progress: 0,
                    detail: "Waiting for available import slot\u{2026}"
                )
            }
        }
        await FASTQImportSlotCoordinator.shared.acquire()
        defer {
            Task { await FASTQImportSlotCoordinator.shared.release() }
        }

        do {
            let pipeline = FASTQIngestionPipeline()
            let result = try await pipeline.run(config: config) { fraction, message in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(
                            id: opID,
                            progress: fraction,
                            detail: message
                        )
                    }
                }
            }

            guard result.wasClumpified else {
                throw FASTQIngestionError.clumpifyFailed("pipeline completed without clumpifying reads")
            }
            // Update metadata sidecar
            let pairingMode: IngestionMetadata.PairingMode = {
                switch result.pairingMode {
                case .singleEnd: return .singleEnd
                case .pairedEnd: return .interleaved  // paired-end becomes interleaved after clumpify
                case .interleaved: return .interleaved
                }
            }()

            let ingestion = IngestionMetadata(
                isClumpified: result.wasClumpified,
                isCompressed: true,
                pairingMode: pairingMode,
                qualityBinning: result.qualityBinning.rawValue,
                originalFilenames: result.originalFilenames,
                ingestionDate: Date(),
                originalSizeBytes: result.originalSizeBytes
            )

            var metadata = existingMetadata ?? PersistedFASTQMetadata()
            metadata.ingestion = ingestion
            FASTQMetadataStore.save(metadata, for: result.outputFile)

            let savedStr = ByteCountFormatter.string(
                fromByteCount: result.originalSizeBytes - result.finalSizeBytes,
                countStyle: .file
            )
            let detail = result.wasClumpified
                ? "Clumpified and compressed (saved \(savedStr))"
                : "Compressed (saved \(savedStr))"

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.complete(id: opID, detail: detail, bundleURLs: [])
                }
            }

            logger.info("Ingestion complete: \(result.outputFile.lastPathComponent)")

        } catch is CancellationError {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.fail(id: opID, detail: "Cancelled")
                }
            }
        } catch {
            logger.error("Ingestion failed: \(error)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.fail(id: opID, detail: "\(error)")
                }
            }
        }
    }

    /// Ingests paired FASTQ files using user-configured settings.
    ///
    /// - Parameters:
    ///   - pair: The R1 (and optional R2) file pair.
    ///   - projectDirectory: Destination project directory.
    ///   - bundleName: Name for the `.lungfishfastq` bundle.
    ///   - importConfig: User-configured import settings from the import sheet.
    ///   - completion: Called on the main actor with the bundle URL or error.
    public static func ingestAndBundle(
        pair: FASTQFilePair,
        projectDirectory: URL,
        bundleName: String,
        importConfig: FASTQImportConfiguration,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        let title = "FASTQ Import: \(bundleName)"

        let cliCmd: String = {
            var args = ["lungfish-cli", "import", "fastq", pair.r1.path]
            if let r2 = pair.r2 { args.append(r2.path) }
            args += ["--project", projectDirectory.path, "--format", "json"]
            return args.joined(separator: " ")
        }()
        let opID = OperationCenter.shared.start(
            title: title,
            detail: "Preparing import workspace\u{2026}",
            operationType: .ingestion,
            cliCommand: cliCmd
        )

        let task = Task.detached {
            await Self.runIngestAndBundle(
                pair: pair,
                projectDirectory: projectDirectory,
                bundleName: bundleName,
                importConfig: importConfig,
                operationID: opID,
                completion: completion
            )
        }

        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    /// Ingests using source inputs in place, creates the bundle, moves processed file in.
    nonisolated private static func runIngestAndBundle(
        sourceURL: URL,
        projectDirectory: URL,
        bundleName: String,
        operationID opID: UUID,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) async {
        // Legacy entry point — wrap in a single-file pair with defaults
        let pair = FASTQFilePair(r1: sourceURL, r2: nil)
        let importConfig = FASTQImportConfiguration(
            inputFiles: [sourceURL],
            detectedPlatform: .unknown,
            confirmedPlatform: .unknown,
            pairingMode: .singleEnd,
            qualityBinning: .illumina4,
            skipClumpify: false,
            deleteOriginals: false,
            postImportRecipe: nil,
            resolvedPlaceholders: [:],
            recipeName: nil,
            compressionLevel: nil
        )
        await runIngestAndBundle(
            pair: pair,
            projectDirectory: projectDirectory,
            bundleName: bundleName,
            importConfig: importConfig,
            operationID: opID,
            completion: completion
        )
    }

    /// Ingests using CLIImportRunner subprocess (shared code path with CLI).
    ///
    /// Spawns `lungfish-cli import fastq` as a subprocess, parses its JSON progress
    /// events, and bridges them to ``OperationCenter`` for the Operations Panel.
    /// After the CLI creates the bundle, this method computes FASTQ statistics
    /// and records provenance (which the CLI does not do).
    nonisolated private static func runIngestAndBundle(
        pair: FASTQFilePair,
        projectDirectory: URL,
        bundleName: String,
        importConfig: FASTQImportConfiguration,
        operationID opID: UUID,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) async {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                OperationCenter.shared.update(
                    id: opID,
                    progress: 0,
                    detail: "Waiting for available import slot\u{2026}"
                )
            }
        }
        await FASTQImportSlotCoordinator.shared.acquire()

        // Run the import, then ALWAYS release the slot before returning.
        // We avoid `defer { Task { await release() } }` because that
        // fire-and-forget Task is not guaranteed to execute promptly from
        // a Task.detached context.
        let result = await _runCLIImport(
            pair: pair,
            projectDirectory: projectDirectory,
            bundleName: bundleName,
            importConfig: importConfig,
            operationID: opID
        )

        await FASTQImportSlotCoordinator.shared.release()

        // Deliver the result on the main actor
        logger.info("runIngestAndBundle: delivering result to main actor")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch result {
                case .success(let bundleURL):
                    logger.info("runIngestAndBundle: completing operation for \(bundleURL.lastPathComponent)")
                    OperationCenter.shared.complete(
                        id: opID,
                        detail: "Imported \(bundleURL.lastPathComponent)",
                        bundleURLs: [bundleURL]
                    )
                    completion(.success(bundleURL))
                case .failure(let error):
                    OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
                    completion(.failure(error))
                }
            }
        }
    }

    /// Core CLI import logic, factored out so the slot can be released via
    /// a plain `await` rather than a fire-and-forget `Task`.
    nonisolated private static func _runCLIImport(
        pair: FASTQFilePair,
        projectDirectory: URL,
        bundleName: String,
        importConfig: FASTQImportConfiguration,
        operationID opID: UUID
    ) async -> Result<URL, Error> {
        do {
            // 1. Map GUI platform to CLI string
            let platformStr: String
            switch importConfig.confirmedPlatform {
            case .illumina:       platformStr = "illumina"
            case .oxfordNanopore: platformStr = "ont"
            case .pacbio:         platformStr = "pacbio"
            case .ultima:         platformStr = "ultima"
            default:              platformStr = "illumina"
            }

            // 2. Resolve recipe name — prefer V2 recipeName, fall back to legacy postImportRecipe
            let recipeName: String? = {
                if let name = importConfig.recipeName {
                    return name
                }
                guard let recipe = importConfig.postImportRecipe, !recipe.steps.isEmpty else { return nil }
                if recipe.name.lowercased().contains("vsp2") {
                    if let nr = RecipeRegistryV2.allRecipes().first(where: { $0.name.lowercased().contains("vsp2") }) {
                        return nr.id
                    }
                }
                return recipe.name.lowercased()
            }()

            // 3. Resolve compression level
            let compressionStr = importConfig.compressionLevel?.rawValue ?? "balanced"

            // 4. Build CLI arguments
            let qualityBinning = importConfig.qualityBinning.rawValue
            let optimizeStorage = !importConfig.skipClumpify

            let args = CLIImportRunner.buildCLIArguments(
                r1: pair.r1,
                r2: pair.r2,
                projectDirectory: projectDirectory,
                platform: platformStr,
                recipeName: recipeName,
                qualityBinning: qualityBinning,
                optimizeStorage: optimizeStorage,
                compressionLevel: compressionStr
            )

            // 5. Spawn CLI runner
            final class ResultTracker: @unchecked Sendable {
                var bundleURL: URL?
                var errorMessage: String?
            }
            let tracker = ResultTracker()

            let runner = CLIImportRunner()
            await runner.run(
                arguments: args,
                operationID: opID,
                projectDirectory: projectDirectory,
                onBundleCreated: { url in tracker.bundleURL = url },
                onError: { error in tracker.errorMessage = error }
            )

            // 6. Handle failure
            if let errorMsg = tracker.errorMessage, tracker.bundleURL == nil {
                return .failure(NSError(
                    domain: "FASTQIngestionService", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: errorMsg]
                ))
            }

            guard let bundleURL = tracker.bundleURL else {
                return .failure(NSError(
                    domain: "FASTQIngestionService", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Import produced no output bundle"]
                ))
            }

            logger.info("CLI import produced bundle at \(bundleURL.path)")
            // Statistics are computed by the CLI as the final pipeline step —
            // no duplicate computation needed here.

            // 7. Record provenance
            var parameters: [String: ParameterValue] = [
                "platform": .string(importConfig.confirmedPlatform.rawValue),
                "pairingMode": .string(importConfig.pairingMode.rawValue),
                "qualityBinning": .string(importConfig.qualityBinning.rawValue),
                "skipClumpify": .boolean(importConfig.skipClumpify),
            ]
            if let recipeName {
                parameters["recipe"] = .string(recipeName)
            }
            let runID = await ProvenanceRecorder.shared.beginRun(
                name: "FASTQ Import: \(bundleName)",
                parameters: parameters
            )
            await ProvenanceRecorder.shared.completeRun(runID, status: .completed)
            try? await ProvenanceRecorder.shared.save(runID: runID, to: bundleURL)

            logger.info("ingestAndBundle: Created bundle \(bundleURL.lastPathComponent) via CLIImportRunner — returning success")
            return .success(bundleURL)

        } catch is CancellationError {
            return .failure(CancellationError())
        } catch {
            logger.error("ingestAndBundle: \(error)")
            return .failure(error)
        }
    }

    nonisolated private static func writeImportManifest(
        to bundleURL: URL,
        bundleName: String,
        sourceFilenames: [String],
        originalSizeBytes: Int64,
        finalFilename: String,
        finalSizeBytes: Int64,
        recipeApplied: RecipeAppliedInfo?
    ) throws {
        let manifest = FASTQImportManifest(
            formatVersion: 1,
            bundleName: bundleName,
            createdAt: Date(),
            sourceFilenames: sourceFilenames,
            originalSizeBytes: originalSizeBytes,
            finalFilename: finalFilename,
            finalSizeBytes: finalSizeBytes,
            recipeApplied: recipeApplied
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let url = bundleURL.appendingPathComponent("manifest.json")
        try data.write(to: url, options: .atomic)
    }

    nonisolated private static func interleavePairedInput(
        r1: URL,
        r2: URL,
        output: URL
    ) async throws {
        let runner = NativeToolRunner.shared
        let env = await bbToolsEnvironment()

        let result = try await runner.run(
            .reformat,
            arguments: [
                "in1=\(r1.path)",
                "in2=\(r2.path)",
                "out=\(output.path)",
                "interleaved=t",
                "ow=t",
            ],
            environment: env,
            timeout: 3600
        )
        guard result.isSuccess else {
            throw FASTQIngestionError.clumpifyFailed("reformat.sh interleave failed: \(result.stderr)")
        }
    }

    /// Creates an ingestion workspace preferring the same filesystem volume as `anchor`.
    ///
    /// Uses `.itemReplacementDirectory` when available to keep heavy intermediate I/O
    /// local to the source volume. Falls back to the global temp directory if needed.
    nonisolated private static func createIngestionWorkspace(anchoredAt anchor: URL) throws -> URL {
        let fm = FileManager.default
        do {
            return try fm.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: anchor,
                create: true
            )
        } catch {
            let fallback = try ProjectTempDirectory.createFromContext(
                prefix: "fastq-ingest-", contextURL: anchor)
            logger.error("createIngestionWorkspace: same-volume workspace unavailable; falling back to \(fallback.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return fallback
        }
    }

    nonisolated private static func shouldDelayInterleaveForVSP2(
        recipe: ProcessingRecipe,
        pairingMode: FASTQIngestionConfig.PairingMode,
        inputFileCount: Int
    ) -> Bool {
        guard pairingMode == .pairedEnd, inputFileCount == 2 else { return false }
        guard recipe.name == ProcessingRecipe.illuminaVSP2TargetEnrichment.name else { return false }
        let kinds = recipe.steps.map(\.kind)
        let expected: [FASTQDerivativeOperationKind] = [
            .deduplicate,
            .adapterTrim,
            .qualityTrim,
            .humanReadScrub,
            .pairedEndMerge,
            .lengthFilter,
        ]
        guard kinds.count >= expected.count else { return false }
        return Array(kinds.prefix(expected.count)) == expected
    }

    nonisolated private static func bbToolsEnvironment() async -> [String: String] {
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return CoreToolLocator.bbToolsEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            existingPath: existingPath
        )
    }

    nonisolated private static func runVSP2RecipeWithDelayedInterleave(
        r1: URL,
        r2: URL,
        recipe: ProcessingRecipe,
        tempDir: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> (url: URL, stepResults: [RecipeStepResult]) {
        let runner = NativeToolRunner.shared
        let threadCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let physicalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        let heapGB = max(4, min(31, physicalMemoryGB * 60 / 100))

        var currentR1 = r1
        var currentR2 = r2
        var previousR1: URL? = nil
        var previousR2: URL? = nil
        var prefixStepResults: [RecipeStepResult] = []
        var consumedSteps = 0

        for step in recipe.steps {
            switch step.kind {
            case .deduplicate, .adapterTrim, .qualityTrim:
                break
            default:
                break
            }
            if step.kind != .deduplicate && step.kind != .adapterTrim && step.kind != .qualityTrim {
                break
            }

            let start = Date()
            let recipeCount = max(1, recipe.steps.count)
            progress(Double(consumedSteps) / Double(recipeCount), "\(step.displaySummary)…")
            var commandLine: String?

            let outR1 = tempDir.appendingPathComponent("paired_step_\(consumedSteps + 1)_R1.fastq")
            let outR2 = tempDir.appendingPathComponent("paired_step_\(consumedSteps + 1)_R2.fastq")

            switch step.kind {
            case .deduplicate:
                let env = await bbToolsEnvironment()
                var args = [
                    "in1=\(currentR1.path)",
                    "in2=\(currentR2.path)",
                    "out1=\(outR1.path)",
                    "out2=\(outR2.path)",
                    "-Xmx\(heapGB)g",
                    "dedupe=t",
                    "subs=\(step.deduplicateSubstitutions ?? 0)",
                    "ow=t",
                ]
                if step.deduplicateOptical == true {
                    args.append("optical=t")
                    args.append("dupedist=\(step.deduplicateOpticalDistance ?? 2500)")
                }
                commandLine = "clumpify.sh " + args.joined(separator: " ")
                let dedupeResult = try await runner.run(.clumpify, arguments: args, environment: env, timeout: 3600)
                guard dedupeResult.isSuccess else {
                    throw FASTQIngestionError.clumpifyFailed("paired deduplication failed: \(dedupeResult.stderr)")
                }

            case .adapterTrim:
                var args = [
                    "-i", currentR1.path,
                    "-I", currentR2.path,
                    "-o", outR1.path,
                    "-O", outR2.path,
                    "-w", String(threadCount),
                    "--disable_quality_filtering",
                    "--disable_length_filtering",
                    "--json", "/dev/null",
                    "--html", "/dev/null",
                ]
                switch step.adapterMode ?? .autoDetect {
                case .autoDetect:
                    break
                case .specified:
                    if let sequence = step.adapterSequence {
                        args += ["--adapter_sequence", sequence]
                    }
                    if let sequenceR2 = step.adapterSequenceR2 {
                        args += ["--adapter_sequence_r2", sequenceR2]
                    }
                case .fastaFile:
                    if let fastaPath = step.adapterFastaFilename, fastaPath.hasPrefix("/") {
                        args += ["--adapter_fasta", fastaPath]
                    }
                }
                commandLine = "fastp " + args.joined(separator: " ")
                let trimResult = try await runner.run(.fastp, arguments: args, timeout: 3600)
                guard trimResult.isSuccess else {
                    throw FASTQIngestionError.clumpifyFailed("paired adapter trim failed: \(trimResult.stderr)")
                }

            case .qualityTrim:
                var args = [
                    "-i", currentR1.path,
                    "-I", currentR2.path,
                    "-o", outR1.path,
                    "-O", outR2.path,
                    "-w", String(threadCount),
                    "-W", String(step.windowSize ?? 4),
                    "-M", String(step.qualityThreshold ?? 20),
                    "--disable_adapter_trimming",
                    "--disable_quality_filtering",
                    "--disable_length_filtering",
                    "--json", "/dev/null",
                    "--html", "/dev/null",
                ]
                switch step.qualityTrimMode ?? .cutRight {
                case .cutRight:
                    args.append("--cut_right")
                case .cutFront:
                    args.append("--cut_front")
                case .cutTail:
                    args.append("--cut_tail")
                case .cutBoth:
                    args.append("--cut_front")
                    args.append("--cut_right")
                }
                commandLine = "fastp " + args.joined(separator: " ")
                let trimResult = try await runner.run(.fastp, arguments: args, timeout: 3600)
                guard trimResult.isSuccess else {
                    throw FASTQIngestionError.clumpifyFailed("paired quality trim failed: \(trimResult.stderr)")
                }

            default:
                break
            }

            let duration = Date().timeIntervalSince(start)
            prefixStepResults.append(
                RecipeStepResult(
                    stepName: step.displaySummary,
                    tool: step.toolUsed ?? step.kind.rawValue,
                    toolVersion: step.toolVersion,
                    commandLine: commandLine,
                    durationSeconds: duration
                )
            )

            // Delete previous step's intermediate files (not the original inputs)
            if let prev1 = previousR1 { try? FileManager.default.removeItem(at: prev1) }
            if let prev2 = previousR2 { try? FileManager.default.removeItem(at: prev2) }

            previousR1 = outR1
            previousR2 = outR2
            currentR1 = outR1
            currentR2 = outR2
            consumedSteps += 1
        }

        guard consumedSteps > 0 else {
            throw FASTQIngestionError.clumpifyFailed("VSP2 delayed-interleave optimization could not consume any paired-prefix steps")
        }

        progress(Double(consumedSteps) / Double(max(1, recipe.steps.count)), "Interleaving paired-end reads…")
        let interleavedInput = tempDir.appendingPathComponent("recipe-input-delayed-interleaved.fastq")
        try await interleavePairedInput(r1: currentR1, r2: currentR2, output: interleavedInput)

        let remainingSteps = Array(recipe.steps.dropFirst(consumedSteps))
        guard !remainingSteps.isEmpty else {
            return (interleavedInput, prefixStepResults)
        }

        let derivativeService = FASTQDerivativeService()
        let materialized = try await derivativeService.runMaterializedRecipe(
            fastqURL: interleavedInput,
            steps: remainingSteps,
            isInterleaved: true,
            tempDir: tempDir,
            measureReadCounts: false,
            progress: { fraction, message in
                let done = Double(consumedSteps) + fraction * Double(remainingSteps.count)
                let total = Double(max(1, recipe.steps.count))
                progress(min(1, done / total), message)
            }
        )

        return (materialized.url, prefixStepResults + materialized.stepResults)
    }

    // MARK: - CLI Subprocess Import

    /// Spawns `lungfish import fastq` as a child process for memory-safe batch import.
    ///
    /// Progress is parsed from the CLI's stdout JSON lines. The app stays alive
    /// even if the CLI process is killed by jetsam.
    public static func importViaSubprocess(
        inputDirectory: URL,
        projectDirectory: URL,
        recipe: String,
        qualityBinning: QualityBinningScheme = .illumina4,
        completion: @escaping @MainActor (Result<Int, Error>) -> Void
    ) {
        let title = "FASTQ Batch Import"
        let cliCmd = "lungfish import fastq \(inputDirectory.path) --project \(projectDirectory.path) --recipe \(recipe)"
        let opID = OperationCenter.shared.start(
            title: title,
            detail: "Starting batch import\u{2026}",
            operationType: .ingestion,
            cliCommand: cliCmd
        )

        let task = Task.detached {
            await Self.runCLISubprocess(
                inputDirectory: inputDirectory,
                projectDirectory: projectDirectory,
                recipe: recipe,
                qualityBinning: qualityBinning,
                operationID: opID,
                completion: completion
            )
        }

        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    nonisolated private static func runCLISubprocess(
        inputDirectory: URL,
        projectDirectory: URL,
        recipe: String,
        qualityBinning: QualityBinningScheme,
        operationID opID: UUID,
        completion: @escaping @MainActor (Result<Int, Error>) -> Void
    ) async {
        do {
            guard let cliURL = CLIImportRunner.cliBinaryPath() else {
                throw BatchImportError.projectNotFound(Bundle.main.bundleURL)
            }

            guard FileManager.default.isExecutableFile(atPath: cliURL.path) else {
                throw BatchImportError.projectNotFound(cliURL)
            }

            let process = Process()
            process.executableURL = cliURL
            process.arguments = [
                "import", "fastq",
                inputDirectory.path,
                "--project", projectDirectory.path,
                "--recipe", recipe,
                "--quality-binning", qualityBinning.rawValue,
            ]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()

            // Track last known progress so detail-only events can reuse it
            var lastProgress: Double = 0.0

            // Parse JSON lines from stdout for progress updates
            let handle = stdoutPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                guard let text = String(data: data, encoding: .utf8) else { continue }

                for line in text.split(separator: "\n") {
                    guard let jsonData = line.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                          let event = dict["event"] as? String else { continue }

                    let detail: String
                    var progress: Double? = nil

                    switch event {
                    case "sampleStart":
                        let sample = dict["sample"] as? String ?? "?"
                        let index = dict["index"] as? Int ?? 0
                        let total = dict["total"] as? Int ?? 1
                        detail = "[\(index)/\(total)] \(sample)"
                        progress = Double(index - 1) / Double(max(1, total))
                    case "stepStart":
                        let sample = dict["sample"] as? String ?? "?"
                        let step = dict["step"] as? String ?? "?"
                        detail = "\(sample): \(step)"
                    case "sampleComplete":
                        let sample = dict["sample"] as? String ?? "?"
                        detail = "\(sample): complete"
                    case "sampleSkip":
                        let sample = dict["sample"] as? String ?? "?"
                        detail = "\(sample): skipped"
                    case "sampleFailed":
                        let sample = dict["sample"] as? String ?? "?"
                        let error = dict["error"] as? String ?? "unknown error"
                        detail = "\(sample): failed — \(error)"
                    case "importComplete":
                        let completed = dict["completed"] as? Int ?? 0
                        let failed = dict["failed"] as? Int ?? 0
                        detail = "Complete: \(completed) imported, \(failed) failed"
                        progress = 1.0
                    default:
                        continue
                    }

                    let resolvedProgress = progress ?? lastProgress
                    if let p = progress { lastProgress = p }

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.update(id: opID, progress: resolvedProgress, detail: detail)
                        }
                    }
                }
            }

            process.waitUntilExit()

            let exitCode = process.terminationStatus
            if exitCode == 0 {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.complete(id: opID, detail: "Batch import complete", bundleURLs: [])
                        completion(.success(Int(exitCode)))
                    }
                }
            } else {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrStr = String(data: stderrData, encoding: .utf8) ?? "unknown error"
                let truncated = String(stderrStr.suffix(500))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.fail(id: opID, detail: "Exit code \(exitCode): \(truncated)")
                        completion(.failure(BatchImportError.projectNotFound(projectDirectory)))
                    }
                }
            }

        } catch {
            logger.error("CLI subprocess failed: \(error)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.fail(id: opID, detail: "\(error)")
                    completion(.failure(error))
                }
            }
        }
    }
}
