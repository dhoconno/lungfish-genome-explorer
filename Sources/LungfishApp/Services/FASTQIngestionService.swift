// FASTQIngestionService.swift - App-level FASTQ ingestion with OperationCenter
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishOperations
import LungfishWorkflow
import LungfishKit
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

actor FASTQImportSlotCoordinator {
    static let shared = FASTQImportSlotCoordinator()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var activeImports = 0
    private var waiters: [Waiter] = []
    private let maxConcurrentImports: Int

    init(maxConcurrentImports: Int = 1) {
        self.maxConcurrentImports = maxConcurrentImports
    }

    func testingSnapshot() -> (activeImports: Int, waitingImports: Int) {
        (activeImports, waiters.count)
    }

    func acquire() async throws {
        try Task.checkCancellation()
        guard activeImports >= maxConcurrentImports else {
            activeImports += 1
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }

        do {
            try Task.checkCancellation()
        } catch {
            release()
            throw error
        }
    }

    func release() {
        guard activeImports > 0 else { return }
        guard !waiters.isEmpty else {
            activeImports -= 1
            return
        }
        let next = waiters.removeFirst()
        next.continuation.resume()
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private enum FASTQSampleSheetMetadataProvenanceError: LocalizedError {
    case missingBundleProvenance(String)

    var errorDescription: String? {
        switch self {
        case .missingBundleProvenance(let path):
            return "Cannot apply FASTQ sample-sheet metadata because the imported bundle is missing provenance: \(path)"
        }
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
        existingMetadata: PersistedFASTQMetadata? = nil,
        routeContext: OperationRouteContext? = nil
    ) {
        ingestIfNeeded(
            url: url,
            pairingMode: pairingMode,
            pairedFile: pairedFile,
            existingMetadata: existingMetadata,
            routeContext: routeContext,
            runner: CLIReadsRunner()
        )
    }

    /// The same ingestion on `runner`, so a test can run a built `lungfish-cli`. The run is
    /// `lungfish-cli fastq ingest` since Phase 2.10 lane A47 M3: the command writes the output, the
    /// sidecar and a record that names the original's digest, and only then removes the original.
    /// The command reads the sidecar beside `url` itself, so `existingMetadata` only decides whether
    /// the file is skipped.
    static func ingestIfNeeded(
        url: URL,
        pairingMode: FASTQIngestionConfig.PairingMode,
        pairedFile: URL?,
        existingMetadata: PersistedFASTQMetadata?,
        routeContext: OperationRouteContext?,
        runner: CLIReadsRunner
    ) {
        // Skip if already ingested
        if let existing = existingMetadata ?? FASTQMetadataStore.load(for: url),
           let ingestion = existing.ingestion,
           ingestion.isClumpified && ingestion.isCompressed {
            logger.info("Skipping ingestion for \(url.lastPathComponent) — already processed")
            return
        }

        Self.startInPlaceIngestionThroughCLI(
            url: url,
            pairingMode: pairingMode,
            pairedFile: pairedFile,
            routeContext: routeContext,
            runner: runner
        )
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
        routeContext: OperationRouteContext? = nil,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        // The launch declares no bundle lock, so `begin` cannot refuse it today. A refusal
        // launches nothing and reaches the caller through `completion`.
        let began = Self.beginSingleFileImportOperation(
            sourceURL: sourceURL,
            projectDirectory: projectDirectory,
            bundleName: bundleName,
            routeContext: routeContext
        ) { opID in
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
        if case .refused(let refusal) = began {
            completion(.failure(OperationRefusedError(refusal)))
        }
    }

    // MARK: - Pipeline Runners

    nonisolated static func withImportSlot<Value>(
        _ body: () async throws -> Value
    ) async throws -> Value {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Importing FASTQ files"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        try await FASTQImportSlotCoordinator.shared.acquire()
        do {
            let value = try await body()
            await FASTQImportSlotCoordinator.shared.release()
            return value
        } catch {
            await FASTQImportSlotCoordinator.shared.release()
            throw error
        }
    }

    /// Ingests paired FASTQ files using user-configured settings.
    ///
    /// - Parameters:
    ///   - pair: The sample's R1, optional R2 and optional unpaired reads.
    ///   - projectDirectory: Destination project directory.
    ///   - bundleName: Name for the `.lungfishfastq` bundle.
    ///   - importConfig: User-configured import settings from the import sheet.
    ///   - completion: Called on the main actor with the bundle URL or error.
    public static func ingestAndBundle(
        pair: FASTQFilePair,
        projectDirectory: URL,
        bundleName: String,
        importConfig: FASTQImportConfiguration,
        forceReplace: Bool = false,
        routeContext: OperationRouteContext? = nil,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        // The launch declares no bundle lock, so `begin` cannot refuse it today. A refusal
        // launches nothing and reaches the caller through `completion`.
        let began = Self.beginFASTQPairImportOperation(
            pair: pair,
            projectDirectory: projectDirectory,
            bundleName: bundleName,
            importConfig: importConfig,
            forceReplace: forceReplace,
            routeContext: routeContext
        ) { opID in
            let task = Task.detached {
                await Self.runIngestAndBundle(
                    pair: pair,
                    projectDirectory: projectDirectory,
                    bundleName: bundleName,
                    importConfig: importConfig,
                    forceReplace: forceReplace,
                    operationID: opID,
                    completion: completion
                )
            }

            OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
        }
        if case .refused(let refusal) = began {
            completion(.failure(OperationRefusedError(refusal)))
        }
    }

    /// Ingests using source inputs in place, creates the bundle, moves processed file in.
    nonisolated private static func runIngestAndBundle(
        sourceURL: URL,
        projectDirectory: URL,
        bundleName: String,
        operationID opID: UUID,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) async {
        // Legacy entry point — wrap in a single-file pair with defaults.
        let pair = FASTQFilePair(r1: sourceURL, r2: nil)
        await runIngestAndBundle(
            pair: pair,
            projectDirectory: projectDirectory,
            bundleName: bundleName,
            importConfig: legacySingleFileImportConfiguration(for: sourceURL),
            operationID: opID,
            completion: completion
        )
    }

    /// Ingests using CLIImportRunner subprocess (shared code path with CLI).
    ///
    /// Spawns `lungfish-cli import fastq` as a subprocess, parses its JSON progress
    /// events, and bridges them to ``OperationCenter`` for the Operations Panel.
    /// The CLI creates the bundle and writes first-class provenance itself.
    nonisolated private static func runIngestAndBundle(
        pair: FASTQFilePair,
        projectDirectory: URL,
        bundleName: String,
        importConfig: FASTQImportConfiguration,
        forceReplace: Bool = false,
        operationID opID: UUID,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) async {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                _ = OperationCenter.shared.updateWithLog(
                    id: opID,
                    progress: 0,
                    detail: "Waiting for available import slot\u{2026}"
                )
            }
        }
        let result: Result<URL, Error>
        do {
            result = try await withImportSlot {
                await _runCLIImport(
                    pair: pair,
                    projectDirectory: projectDirectory,
                    bundleName: bundleName,
                    importConfig: importConfig,
                    forceReplace: forceReplace,
                    operationID: opID
                )
            }
        } catch {
            result = .failure(error)
        }

        // Deliver the result on the main actor
        logger.info("runIngestAndBundle: delivering result to main actor")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch result {
                case .success(let bundleURL):
                    logger.info("runIngestAndBundle: completing operation for \(bundleURL.lastPathComponent)")
                    guard OperationCenter.shared.complete(
                        id: opID,
                        detail: "Imported \(bundleURL.lastPathComponent)",
                        bundleURLs: [bundleURL]
                    ) else {
                        completion(.failure(CancellationError()))
                        return
                    }
                    completion(.success(bundleURL))
                case .failure(let error):
                    guard OperationCenter.shared.fail(id: opID, detail: error.localizedDescription) else {
                        completion(.failure(CancellationError()))
                        return
                    }
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
        forceReplace: Bool = false,
        operationID opID: UUID
    ) async -> Result<URL, Error> {
        let args = cliImportArguments(
            pair: pair,
            projectDirectory: projectDirectory,
            importConfig: importConfig,
            bundleName: bundleName,
            force: forceReplace
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

        if !pair.metadata.isEmpty {
            do {
                try saveSampleSheetMetadata(pair: pair, bundleURL: bundleURL)
            } catch {
                return .failure(error)
            }
        }

        logger.info("ingestAndBundle: Created bundle \(bundleURL.lastPathComponent) via CLIImportRunner — returning success")
        return .success(bundleURL)
    }

    nonisolated static func cliImportCommandPreview(
        pair: FASTQFilePair,
        projectDirectory: URL,
        importConfig: FASTQImportConfiguration,
        bundleName: String? = nil,
        force: Bool = false
    ) -> String {
        CLIImportRunner.commandLine(
            arguments: cliImportArguments(
                pair: pair,
                projectDirectory: projectDirectory,
                importConfig: importConfig,
                bundleName: bundleName,
                force: force
            )
        )
    }

    nonisolated static func cliImportCommandPreview(
        sourceURL: URL,
        projectDirectory: URL,
        bundleName: String? = nil
    ) -> String {
        cliImportCommandPreview(
            pair: FASTQFilePair(r1: sourceURL, r2: nil),
            projectDirectory: projectDirectory,
            importConfig: legacySingleFileImportConfiguration(for: sourceURL),
            bundleName: bundleName
        )
    }

    nonisolated static func cliImportArguments(
        pair: FASTQFilePair,
        projectDirectory: URL,
        importConfig: FASTQImportConfiguration,
        bundleName: String? = nil,
        force: Bool = false
    ) -> [String] {
        CLIImportRunner.buildCLIArguments(
            r1: pair.r1, r2: pair.r2, unpaired: pair.unpaired, // every file of the sample, in one CLI run
            projectDirectory: projectDirectory,
            platform: importConfig.cliPlatformValue,
            recipeName: resolvedRecipeName(for: importConfig),
            qualityBinning: importConfig.qualityBinning.rawValue,
            optimizeStorage: !importConfig.skipClumpify,
            clumpingTool: importConfig.clumpingTool,
            pairingMode: importConfig.cliPairingMode,
            compressionLevel: importConfig.compressionLevel?.rawValue ?? "balanced",
            bundleName: bundleName,
            force: force
        )
    }

    nonisolated static func cliPlatformString(for platform: LungfishIO.SequencingPlatform) -> String {
        platform.importCLIValue
    }

    nonisolated static func resolvedRecipeName(for importConfig: FASTQImportConfiguration) -> String? {
        if let name = importConfig.recipeName {
            return name
        }
        guard let recipe = importConfig.postImportRecipe, !recipe.steps.isEmpty else { return nil }
        // The legacy built-in VSP2 recipe runs as the merged recipe's VSP2 preset. It is matched by its id and
        // passed as a preset id, never matched by a recipe's name (ruling BIO-PRESET P3). `ProcessingRecipe.id`
        // defaults to `UUID()` and the static is built without one, so each launch has its own id. The compare
        // holds for that instance, and a copy decoded from a file another launch wrote no longer maps to the preset.
        if recipe.id == ProcessingRecipe.illuminaVSP2TargetEnrichment.id {
            return "vsp2-target-enrichment"
        }
        return recipe.name.lowercased()
    }

    nonisolated static func testingSaveSampleSheetMetadata(pair: FASTQFilePair, bundleURL: URL) throws {
        try saveSampleSheetMetadata(pair: pair, bundleURL: bundleURL)
    }

    nonisolated private static func saveSampleSheetMetadata(pair: FASTQFilePair, bundleURL: URL) throws {
        guard !pair.metadata.isEmpty else { return }
        guard try ProvenanceEnvelopeReader.load(from: bundleURL) != nil else {
            throw FASTQSampleSheetMetadataProvenanceError.missingBundleProvenance(bundleURL.path)
        }

        let metadata = FASTQBundleCSVMetadata(
            keyValuePairs: ["sample": pair.sampleName].merging(pair.metadata) { current, _ in current }
        )
        let metadataURL = FASTQBundleCSVMetadata.metadataURL(in: bundleURL)
        let snapshot = try ProvenancePublicationSnapshot(
            urls: [metadataURL] + ProvenancePublicationArtifacts.bundleRootArtifacts(for: bundleURL),
            backupNamePrefix: "lungfish-fastq-samplesheet-metadata"
        )
        defer { snapshot.discard() }

        do {
            try FASTQBundleCSVMetadata.save(metadata, to: bundleURL)
            try appendSampleSheetMetadataProvenance(
                pair: pair,
                metadata: metadata,
                bundleURL: bundleURL,
                metadataURL: metadataURL
            )
        } catch {
            do {
                try snapshot.restore()
            } catch {
                logger.error("Failed to restore FASTQ sample-sheet metadata snapshot: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    nonisolated private static func appendSampleSheetMetadataProvenance(
        pair: FASTQFilePair,
        metadata: FASTQBundleCSVMetadata,
        bundleURL: URL,
        metadataURL: URL
    ) throws {
        guard let existingEnvelope = try ProvenanceEnvelopeReader.load(from: bundleURL) else {
            throw FASTQSampleSheetMetadataProvenanceError.missingBundleProvenance(bundleURL.path)
        }

        let metadataClock = ProvenanceRunClock()
        let metadataDescriptor = try ProvenanceFileDescriptor.file(url: metadataURL, format: .text, role: .output)
        var inputs: [ProvenanceFileDescriptor] = []
        if let sampleSheetURL = pair.sampleSheetURL {
            inputs.append(try ProvenanceFileDescriptor.file(url: sampleSheetURL, format: .text, role: .input))
        }
        let command = sampleSheetMetadataCommand(
            pair: pair,
            metadata: metadata,
            bundleURL: bundleURL,
            metadataURL: metadataURL
        )
        let completedAt = metadataClock.now
        let metadataStep = ProvenanceStep(
            toolName: LungfishAppIdentity.recordedToolName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: command,
            durableReplayArgv: command,
            inputs: inputs,
            outputs: [metadataDescriptor],
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(metadataClock.startedAt),
            startedAt: metadataClock.startedAt,
            completedAt: completedAt
        )

        let outputs = deduplicatedProvenanceFilesPreferringLast(existingEnvelope.outputs + [metadataDescriptor])
        let files = deduplicatedProvenanceFilesPreferringLast(
            existingEnvelope.files + inputs + [metadataDescriptor]
        )
        let options = sampleSheetMetadataOptions(
            existing: existingEnvelope.options,
            pair: pair,
            metadata: metadata,
            metadataURL: metadataURL
        )
        let output = existingEnvelope.output.map {
            $0.path == metadataDescriptor.path && $0.role == metadataDescriptor.role ? metadataDescriptor : $0
        } ?? metadataDescriptor

        let mergedEnvelope = existingEnvelope.with {
            $0.options = options
            $0.files = files
            $0.output = output
            $0.outputs = outputs
            $0.steps = existingEnvelope.steps + [metadataStep]
            $0.wallTimeSeconds = InPlaceIngestionProvenance.combinedWallTime(
                existingEnvelope.wallTimeSeconds,
                metadataStep.wallTimeSeconds
            )
            $0.exitStatus = existingEnvelope.exitStatus ?? 0
        }
        try ProvenanceWriter().write(mergedEnvelope, to: bundleURL)
    }

    nonisolated private static func sampleSheetMetadataCommand(
        pair: FASTQFilePair,
        metadata: FASTQBundleCSVMetadata,
        bundleURL: URL,
        metadataURL: URL
    ) -> [String] {
        var command = [
            LungfishAppIdentity.recordedToolName,
            "fastq",
            "sample-sheet-metadata",
            "--bundle", bundleURL.path,
            "--metadata-csv", metadataURL.path,
            "--sample", pair.sampleName,
        ]
        if let sampleSheetURL = pair.sampleSheetURL {
            command += ["--sample-sheet", sampleSheetURL.path]
        }
        for (key, value) in metadata.keyValuePairs.sorted(by: { $0.key < $1.key }) {
            command += ["--set", "\(key)=\(value)"]
        }
        return command
    }

    nonisolated private static func sampleSheetMetadataOptions(
        existing: ProvenanceOptions,
        pair: FASTQFilePair,
        metadata: FASTQBundleCSVMetadata,
        metadataURL: URL
    ) -> ProvenanceOptions {
        let metadataParameters = metadata.keyValuePairs.mapValues { ParameterValue.string($0) }
        var explicit = existing.explicit
        explicit["sampleName"] = .string(pair.sampleName)
        explicit["sampleSheet"] = pair.sampleSheetURL.map(ParameterValue.file) ?? .null
        explicit["sampleSheetMetadata"] = .dictionary(metadataParameters)

        var resolved = existing.resolvedDefaults
        resolved["metadataCSV"] = .file(metadataURL)
        resolved["sampleSheetMetadataApplied"] = .boolean(true)

        return ProvenanceOptions(
            explicit: explicit,
            defaults: existing.defaults,
            resolvedDefaults: resolved
        )
    }

    nonisolated private static func deduplicatedProvenanceFilesPreferringLast(
        _ descriptors: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        var result: [ProvenanceFileDescriptor] = []
        for descriptor in descriptors.reversed() {
            let key = "\(descriptor.role.rawValue)\u{0}\(descriptor.path)"
            guard seen.insert(key).inserted else { continue }
            result.append(descriptor)
        }
        return result.reversed()
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
}
