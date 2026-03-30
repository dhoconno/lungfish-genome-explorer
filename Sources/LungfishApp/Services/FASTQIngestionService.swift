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
            var args = [pair.r1.path]
            if let r2 = pair.r2 { args.append(r2.path) }
            return "# lungfish import fastq " + args.joined(separator: " ") + " (CLI command not yet available \u{2014} use GUI)"
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
            resolvedPlaceholders: [:]
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

    /// Ingests in a temp directory using user-configured settings.
    nonisolated private static func runIngestAndBundle(
        pair: FASTQFilePair,
        projectDirectory: URL,
        bundleName: String,
        importConfig: FASTQImportConfiguration,
        operationID opID: UUID,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) async {
        let fm = FileManager.default
        var tempDir: URL?
        var createdBundleURL: URL?

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
            // 1. Create a temp workspace on the source volume and process inputs in place.
            let workspace = try createIngestionWorkspace(anchoredAt: pair.r1)
            tempDir = workspace

            var inputFiles = [pair.r1]
            if let r2 = pair.r2 {
                inputFiles.append(r2)
            }

            logger.info("ingestAndBundle: Using source inputs in place (\(inputFiles.count) file(s)); workspace at \(workspace.path, privacy: .public)")

            let originalFilenames = inputFiles.map(\.lastPathComponent)
            let originalSizeBytes = inputFiles.reduce(Int64(0)) { total, url in
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                return total + (attrs?[.size] as? Int64 ?? 0)
            }

            let resolvedRecipe = importConfig.postImportRecipe?
                .resolved(with: importConfig.resolvedPlaceholders)
            var recipeStepResults: [RecipeStepResult] = []

            // 2. Run import pipeline in temp.
            // Recipe imports are optimized to avoid running clumpify twice.
            var outputFile: URL
            var resultWasClumpified = false
            var resultQualityBinning = importConfig.qualityBinning
            var resultPairingMode = importConfig.pairingMode
            var finalSizeBytes: Int64 = 0
            var resultOriginalFilenames = originalFilenames
            var resultOriginalSizeBytes = originalSizeBytes
            if let recipe = resolvedRecipe, !recipe.steps.isEmpty {
                let recipeOutputURL: URL
                let workingIsInterleaved: Bool

                if shouldDelayInterleaveForVSP2(
                    recipe: recipe,
                    pairingMode: importConfig.pairingMode,
                    inputFileCount: inputFiles.count
                ) {
                    let optimizedResult = try await runVSP2RecipeWithDelayedInterleave(
                        r1: pair.r1,
                        r2: inputFiles[1],
                        recipe: recipe,
                        tempDir: workspace,
                        progress: { fraction, message in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    OperationCenter.shared.update(
                                        id: opID,
                                        progress: 0.05 + fraction * 0.60,
                                        detail: "\(bundleName): \(message)"
                                    )
                                }
                            }
                        }
                    )
                    recipeOutputURL = optimizedResult.url
                    recipeStepResults = optimizedResult.stepResults
                    workingIsInterleaved = true
                } else {
                    var workingFASTQ = pair.r1
                    var isInterleaved = importConfig.pairingMode == .interleaved

                    if inputFiles.count == 2 {
                        let tempR2 = inputFiles[1]
                        let interleavedInput = workspace.appendingPathComponent("recipe-input-interleaved.fastq")
                        try await interleavePairedInput(r1: pair.r1, r2: tempR2, output: interleavedInput)
                        workingFASTQ = interleavedInput
                        isInterleaved = true
                    }

                    let derivativeService = FASTQDerivativeService()
                    let materialized = try await derivativeService.runMaterializedRecipe(
                        fastqURL: workingFASTQ,
                        steps: recipe.steps,
                        isInterleaved: isInterleaved,
                        tempDir: workspace,
                        measureReadCounts: false,
                        progress: { fraction, message in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    OperationCenter.shared.update(
                                        id: opID,
                                        progress: 0.05 + fraction * 0.60,
                                        detail: "\(bundleName): \(message)"
                                    )
                                }
                            }
                        }
                    )
                    recipeOutputURL = materialized.url
                    recipeStepResults = materialized.stepResults
                    workingIsInterleaved = isInterleaved
                }

                let clumpifyConfig = FASTQIngestionConfig(
                    inputFiles: [recipeOutputURL],
                    pairingMode: workingIsInterleaved ? .interleaved : .singleEnd,
                    outputDirectory: workspace,
                    threads: ProcessInfo.processInfo.activeProcessorCount,
                    deleteOriginals: true,
                    qualityBinning: importConfig.qualityBinning,
                    skipClumpify: false
                )
                let clumpified = try await FASTQIngestionPipeline().run(config: clumpifyConfig) { fraction, message in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.update(
                                id: opID,
                                progress: 0.65 + fraction * 0.15,
                                detail: "\(bundleName): \(message)"
                            )
                        }
                    }
                }

                let finalAttrs = try? fm.attributesOfItem(atPath: clumpified.outputFile.path)
                outputFile = clumpified.outputFile
                resultWasClumpified = clumpified.wasClumpified
                resultQualityBinning = clumpified.qualityBinning
                resultPairingMode = clumpified.pairingMode
                finalSizeBytes = (finalAttrs?[.size] as? Int64) ?? 0
            } else {
                let config = FASTQIngestionConfig(
                    inputFiles: inputFiles,
                    pairingMode: importConfig.pairingMode,
                    outputDirectory: workspace,
                    threads: ProcessInfo.processInfo.activeProcessorCount,
                    deleteOriginals: false,
                    qualityBinning: importConfig.qualityBinning,
                    // paired-end skip-clumpify is not supported by FASTQIngestionPipeline
                    skipClumpify: importConfig.skipClumpify && importConfig.pairingMode != .pairedEnd
                )
                let pipeline = FASTQIngestionPipeline()
                let pipelineResult = try await pipeline.run(config: config) { fraction, message in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.update(
                                id: opID,
                                progress: fraction * 0.75,
                                detail: message
                            )
                        }
                    }
                }
                outputFile = pipelineResult.outputFile
                resultWasClumpified = pipelineResult.wasClumpified
                resultQualityBinning = pipelineResult.qualityBinning
                resultPairingMode = pipelineResult.pairingMode
                resultOriginalFilenames = pipelineResult.originalFilenames
                resultOriginalSizeBytes = pipelineResult.originalSizeBytes
                finalSizeBytes = pipelineResult.finalSizeBytes
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.update(id: opID, progress: 0.80, detail: "Creating bundle\u{2026}")
                }
            }

            // 3. Create .lungfishfastq bundle in project and mark as processing.
            let bundleURL = projectDirectory.appendingPathComponent(
                "\(bundleName).\(FASTQBundle.directoryExtension)"
            )
            createdBundleURL = bundleURL
            try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            FASTQBundle.markProcessing(bundleURL, detail: "Finalizing import\u{2026}")

            // 4. Move processed file into bundle
            let destFASTQ = bundleURL.appendingPathComponent(outputFile.lastPathComponent)
            try fm.moveItem(at: outputFile, to: destFASTQ)

            // 5. Write ingestion metadata sidecar in bundle
            let pairingMode: IngestionMetadata.PairingMode = {
                switch resultPairingMode {
                case .singleEnd: return .singleEnd
                case .pairedEnd: return .interleaved
                case .interleaved: return .interleaved
                }
            }()

            let ingestion = IngestionMetadata(
                isClumpified: resultWasClumpified,
                isCompressed: true,
                pairingMode: pairingMode,
                qualityBinning: resultQualityBinning.rawValue,
                originalFilenames: resultOriginalFilenames,
                ingestionDate: Date(),
                originalSizeBytes: resultOriginalSizeBytes
            )

            var metadata = PersistedFASTQMetadata()
            metadata.ingestion = ingestion
            if let recipe = resolvedRecipe, !recipeStepResults.isEmpty {
                metadata.ingestion?.recipeApplied = RecipeAppliedInfo(
                    recipeID: recipe.id.uuidString,
                    recipeName: recipe.name,
                    appliedDate: Date(),
                    stepResults: recipeStepResults
                )
            }
            try writeImportManifest(
                to: bundleURL,
                bundleName: bundleName,
                sourceFilenames: resultOriginalFilenames,
                originalSizeBytes: resultOriginalSizeBytes,
                finalFilename: destFASTQ.lastPathComponent,
                finalSizeBytes: finalSizeBytes,
                recipeApplied: metadata.ingestion?.recipeApplied
            )

            // 6. Record provenance
            var parameters: [String: ParameterValue] = [
                "platform": .string(importConfig.confirmedPlatform.rawValue),
                "pairingMode": .string(importConfig.pairingMode.rawValue),
                "qualityBinning": .string(importConfig.qualityBinning.rawValue),
                "skipClumpify": .boolean(importConfig.skipClumpify),
            ]
            if let recipe = resolvedRecipe, !recipe.steps.isEmpty {
                parameters["recipe"] = .string(recipe.name)
            }
            let runID = await ProvenanceRecorder.shared.beginRun(
                name: "FASTQ Import: \(bundleName)",
                parameters: parameters
            )

            if !recipeStepResults.isEmpty {
                for step in recipeStepResults {
                    let recordedCommand = step.commandLine.map { [$0] } ?? [step.stepName]
                    await ProvenanceRecorder.shared.recordStep(
                        runID: runID,
                        toolName: step.tool,
                        toolVersion: step.toolVersion ?? "unknown",
                        command: recordedCommand,
                        inputs: [FileRecord(path: bundleURL.lastPathComponent, format: .fastq, role: .input)],
                        outputs: [FileRecord(path: bundleURL.lastPathComponent, format: .fastq, role: .output)],
                        exitCode: 0,
                        wallTime: step.durationSeconds
                    )
                }
            }

            if resultWasClumpified {
                let inputRecords = resultOriginalFilenames.map { name in
                    FileRecord(path: name, format: .fastq, role: .input)
                }
                await ProvenanceRecorder.shared.recordStep(
                    runID: runID,
                    toolName: "clumpify.sh",
                    toolVersion: "BBTools",
                    command: ["clumpify.sh"],
                    inputs: inputRecords,
                    outputs: [FileRecord(
                        path: destFASTQ.lastPathComponent,
                        sizeBytes: UInt64(finalSizeBytes),
                        format: .fastq,
                        role: .output
                    )],
                    exitCode: 0,
                    wallTime: 0
                )
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.update(
                        id: opID,
                        progress: 0.85,
                        detail: "Computing FASTQ statistics\u{2026}"
                    )
                }
            }
            _ = try await FASTQStatisticsService.computeAndCache(
                for: destFASTQ,
                existingMetadata: metadata,
                progress: { count in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.update(
                                id: opID,
                                progress: 0.90,
                                detail: "Computing FASTQ statistics\u{2026} \(count) reads processed"
                            )
                        }
                    }
                }
            )

            await ProvenanceRecorder.shared.completeRun(runID, status: .completed)
            try? await ProvenanceRecorder.shared.save(runID: runID, to: bundleURL)

            // 7. Clean up temp directory
            if let workspace = tempDir {
                try? fm.removeItem(at: workspace)
            }

            let savedStr = ByteCountFormatter.string(
                fromByteCount: resultOriginalSizeBytes - finalSizeBytes,
                countStyle: .file
            )
            let detail = resultWasClumpified
                ? "Imported and clumpified (saved \(savedStr))"
                : "Imported and compressed (saved \(savedStr))"

            logger.info("ingestAndBundle: Created bundle \(bundleURL.lastPathComponent)")

            // Clear processing marker only after stats are cached.
            FASTQBundle.clearProcessing(bundleURL)

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.complete(id: opID, detail: detail, bundleURLs: [bundleURL])
                    completion(.success(bundleURL))
                }
            }

        } catch is CancellationError {
            if let workspace = tempDir {
                try? fm.removeItem(at: workspace)
            }
            if let bundleURL = createdBundleURL {
                FASTQBundle.clearProcessing(bundleURL)
                try? fm.removeItem(at: bundleURL)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.fail(id: opID, detail: "Cancelled")
                    completion(.failure(CancellationError()))
                }
            }
        } catch {
            if let workspace = tempDir {
                try? fm.removeItem(at: workspace)
            }
            if let bundleURL = createdBundleURL {
                FASTQBundle.clearProcessing(bundleURL)
                try? fm.removeItem(at: bundleURL)
            }
            logger.error("ingestAndBundle: \(error)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.fail(id: opID, detail: "\(error)")
                    completion(.failure(error))
                }
            }
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
        let toolsDir = await runner.getToolsDirectory()
        var env: [String: String] = [:]
        if let toolsDir {
            let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            let jreBinDir = toolsDir.appendingPathComponent("jre/bin")
            env["PATH"] = "\(toolsDir.path):\(jreBinDir.path):\(existingPath)"
            let javaURL = jreBinDir.appendingPathComponent("java")
            if FileManager.default.fileExists(atPath: javaURL.path) {
                env["JAVA_HOME"] = toolsDir.appendingPathComponent("jre").path
                env["BBMAP_JAVA"] = javaURL.path
            }
        }

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
            let fallback = fm.temporaryDirectory
                .appendingPathComponent("lungfish-fastq-ingest-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: fallback, withIntermediateDirectories: true)
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
        let runner = NativeToolRunner.shared
        let toolsDir = await runner.getToolsDirectory()
        var env: [String: String] = [:]
        if let toolsDir {
            let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            let jreBinDir = toolsDir.appendingPathComponent("jre/bin")
            env["PATH"] = "\(toolsDir.path):\(jreBinDir.path):\(existingPath)"
            let javaURL = jreBinDir.appendingPathComponent("java")
            if FileManager.default.fileExists(atPath: javaURL.path) {
                env["JAVA_HOME"] = toolsDir.appendingPathComponent("jre").path
                env["BBMAP_JAVA"] = javaURL.path
            }
        }
        return env
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
        let heapGB = max(4, min(31, physicalMemoryGB * 80 / 100))

        var currentR1 = r1
        var currentR2 = r2
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
}
