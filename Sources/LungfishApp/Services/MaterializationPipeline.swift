// MaterializationPipeline.swift - Actor-based materialization with bounded concurrency
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "MaterializationPipeline")

// MARK: - Job Types

/// Progress snapshot for an in-flight materialization job.
public struct MaterializationProgress: Sendable {
    public let jobID: UUID
    public let fraction: Double
    public let message: String
    public let bundleURL: URL
}

/// Result of a completed materialization job.
public struct MaterializationResult: Sendable {
    public let jobID: UUID
    public let bundleURL: URL
    public let checksum: String
    public let duration: TimeInterval
}

/// Error type for materialization failures.
public enum MaterializationError: Error, LocalizedError {
    case notVirtual(URL)
    case alreadyMaterializing(UUID)
    case bundleNotFound(URL)
    case materializationFailed(URL, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .notVirtual(let url):
            return "Bundle is not virtual: \(url.lastPathComponent)"
        case .alreadyMaterializing(let taskID):
            return "Already materializing (task \(taskID))"
        case .bundleNotFound(let url):
            return "Bundle not found: \(url.path)"
        case .materializationFailed(let url, let error):
            return "Materialization failed for \(url.lastPathComponent): \(error)"
        }
    }
}

// MARK: - MaterializationPipeline

/// Manages concurrent materialization of virtual FASTQ derivatives into physical files.
///
/// Jobs are enqueued and executed with bounded concurrency. Progress is reported
/// via `@Sendable` callbacks. The pipeline writes materialized FASTQ files into the
/// bundle's directory and updates the manifest with `.materialized(checksum:)`.
///
/// Uses `DispatchQueue.main.async { MainActor.assumeIsolated { } }` for UI progress
/// updates — never `Task { @MainActor in }`.
public actor MaterializationPipeline {

    public static let shared = MaterializationPipeline()

    private let derivativeService: FASTQDerivativeService
    private let maxConcurrency: Int
    private let provenanceWriter: @Sendable (ProvenanceEnvelope, URL) throws -> URL

    /// Active jobs tracked by their task ID.
    private var activeJobs: [UUID: Task<MaterializationResult, Error>] = [:]

    /// Progress snapshots for in-flight jobs.
    private var progressSnapshots: [UUID: MaterializationProgress] = [:]

    public init(
        derivativeService: FASTQDerivativeService = .shared,
        maxConcurrency: Int = 2,
        provenanceWriter: @escaping @Sendable (ProvenanceEnvelope, URL) throws -> URL = { envelope, bundleURL in
            try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
        }
    ) {
        self.derivativeService = derivativeService
        self.maxConcurrency = max(1, maxConcurrency)
        self.provenanceWriter = provenanceWriter
    }

    // MARK: - Single Job

    /// Enqueues a single bundle for materialization.
    ///
    /// Returns immediately with a job ID. The materialization runs asynchronously.
    /// Progress is reported via the callback. The bundle's manifest is updated
    /// with `.materialized(checksum:)` on success.
    ///
    /// - Parameters:
    ///   - descriptor: The virtual FASTQ descriptor specifying what to materialize.
    ///   - onProgress: Progress callback (called on an arbitrary queue).
    /// - Returns: The job UUID for tracking.
    public func materialize(
        _ descriptor: VirtualFASTQDescriptor,
        onProgress: (@Sendable (MaterializationProgress) -> Void)? = nil
    ) throws -> UUID {
        let bundleURL = descriptor.bundleURL
        let jobID = UUID()

        // Verify the bundle exists and is virtual
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw MaterializationError.bundleNotFound(bundleURL)
        }
        if let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
            if case .materializing(let existingID) = manifest.materializationState {
                // Already materializing — don't double-enqueue
                throw MaterializationError.alreadyMaterializing(existingID)
            }
            if manifest.isMaterialized {
                throw MaterializationError.notVirtual(bundleURL)
            }
        }

        let sourceInputDescriptors = try CLISequenceInputMaterialization.originalInputDescriptors(for: bundleURL)
        let provenanceWriter = provenanceWriter

        // Mark as materializing in the manifest
        updateManifestState(bundleURL: bundleURL, state: .materializing(taskID: jobID))

        let task = Task<MaterializationResult, Error> { [derivativeService] in
            let startTime = Date()
            do {
                let checksum = try await Self.executeMaterialization(
                    bundleURL: bundleURL,
                    derivativeService: derivativeService,
                    jobID: jobID,
                    startedAt: startTime,
                    sourceInputDescriptors: sourceInputDescriptors,
                    provenanceWriter: provenanceWriter,
                    onProgress: onProgress
                )

                let result = MaterializationResult(
                    jobID: jobID,
                    bundleURL: bundleURL,
                    checksum: checksum,
                    duration: Date().timeIntervalSince(startTime)
                )

                logger.info("Materialized \(bundleURL.lastPathComponent) in \(result.duration, format: .fixed(precision: 1))s")
                return result

            } catch {
                logger.error("Materialization failed for \(bundleURL.lastPathComponent): \(error)")
                throw MaterializationError.materializationFailed(bundleURL, underlying: error)
            }
        }

        activeJobs[jobID] = task
        return jobID
    }

    /// Waits for a specific materialization job to complete.
    public func awaitJob(_ jobID: UUID) async throws -> MaterializationResult {
        guard let task = activeJobs[jobID] else {
            throw MaterializationError.bundleNotFound(URL(fileURLWithPath: "/unknown"))
        }
        let result = try await task.value
        activeJobs.removeValue(forKey: jobID)
        progressSnapshots.removeValue(forKey: jobID)
        return result
    }

    /// Cancels a materialization job and resets the bundle's state to virtual.
    public func cancel(_ jobID: UUID) {
        if let task = activeJobs.removeValue(forKey: jobID) {
            task.cancel()
        }
        if let progress = progressSnapshots.removeValue(forKey: jobID) {
            updateManifestState(bundleURL: progress.bundleURL, state: nil)
        }
    }

    /// Returns the current progress for a job, if active.
    public func progress(for jobID: UUID) -> MaterializationProgress? {
        progressSnapshots[jobID]
    }

    /// Returns all active job IDs.
    public var activeJobIDs: [UUID] {
        Array(activeJobs.keys)
    }

    // MARK: - Batch Materialization

    /// Materializes multiple virtual bundles with bounded concurrency.
    ///
    /// - Parameters:
    ///   - descriptors: The virtual FASTQ descriptors to materialize.
    ///   - onProgress: Per-job progress callback.
    /// - Returns: Array of results (successes and failures).
    public func materializeBatch(
        _ descriptors: [VirtualFASTQDescriptor],
        onProgress: (@Sendable (MaterializationProgress) -> Void)? = nil
    ) async -> [(descriptor: VirtualFASTQDescriptor, result: Result<MaterializationResult, Error>)] {
        await withTaskGroup(of: (Int, VirtualFASTQDescriptor, Result<MaterializationResult, Error>).self) { group in
            var results: [(Int, VirtualFASTQDescriptor, Result<MaterializationResult, Error>)] = []
            var nextIndex = 0
            var activeTasks = 0

            while nextIndex < descriptors.count || activeTasks > 0 {
                while activeTasks < maxConcurrency && nextIndex < descriptors.count {
                    let descriptor = descriptors[nextIndex]
                    let idx = nextIndex
                    nextIndex += 1
                    activeTasks += 1

                    group.addTask { [self] in
                        do {
                            let jobID = try await self.materialize(descriptor, onProgress: onProgress)
                            let result = try await self.awaitJob(jobID)
                            return (idx, descriptor, .success(result))
                        } catch {
                            return (idx, descriptor, .failure(error))
                        }
                    }
                }

                if let result = await group.next() {
                    results.append(result)
                    activeTasks -= 1
                }
            }

            return results
                .sorted { $0.0 < $1.0 }
                .map { ($0.1, $0.2) }
        }
    }

    // MARK: - Private

    /// Executes the materialization: exports the virtual FASTQ to a file inside the bundle.
    private static func executeMaterialization(
        bundleURL: URL,
        derivativeService: FASTQDerivativeService,
        jobID: UUID,
        startedAt: Date,
        sourceInputDescriptors: [ProvenanceFileDescriptor],
        provenanceWriter: @Sendable (ProvenanceEnvelope, URL) throws -> URL,
        onProgress: (@Sendable (MaterializationProgress) -> Void)?
    ) async throws -> String {
        let materializedFilename = "materialized.fastq"
        let fm = FileManager.default
        let outputURL = bundleURL.appendingPathComponent(materializedFilename)
        let temporaryOutputURL = bundleURL.appendingPathComponent(".\(jobID.uuidString).\(materializedFilename).tmp")
        var provenanceBackup: ProvenanceArtifactBackup?

        do {
            provenanceBackup = try ProvenanceArtifactBackup.capture(bundleURL: bundleURL)
            try? fm.removeItem(at: temporaryOutputURL)
            try await derivativeService.exportMaterializedFASTQ(
                fromDerivedBundle: bundleURL,
                to: temporaryOutputURL,
                progress: { message in
                    onProgress?(MaterializationProgress(
                        jobID: jobID,
                        fraction: 0.5,
                        message: message,
                        bundleURL: bundleURL
                    ))
                }
            )

            try? fm.removeItem(at: outputURL)
            try fm.moveItem(at: temporaryOutputURL, to: outputURL)
            let checksum = try ProvenanceFileHasher.sha256(of: outputURL)

            onProgress?(MaterializationProgress(
                jobID: jobID,
                fraction: 0.9,
                message: "Computing statistics...",
                bundleURL: bundleURL
            ))
            let stats = try await computeStatistics(for: outputURL)

            if var manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
                if let stats {
                    manifest = FASTQDerivedBundleManifest(
                        id: manifest.id,
                        name: manifest.name,
                        createdAt: manifest.createdAt,
                        parentBundleRelativePath: manifest.parentBundleRelativePath,
                        rootBundleRelativePath: manifest.rootBundleRelativePath,
                        rootFASTQFilename: manifest.rootFASTQFilename,
                        payload: manifest.payload,
                        lineage: manifest.lineage,
                        operation: manifest.operation,
                        cachedStatistics: stats,
                        pairingMode: manifest.pairingMode,
                        readClassification: manifest.readClassification,
                        batchOperationID: manifest.batchOperationID,
                        sequenceFormat: manifest.sequenceFormat,
                        provenance: manifest.provenance,
                        payloadChecksums: manifest.payloadChecksums
                    )
                }
                manifest.materializationState = .materialized(checksum: checksum)
                try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
            }

            try writeMaterializationProvenance(
                bundleURL: bundleURL,
                materializedURL: outputURL,
                manifestURL: FASTQBundle.derivedManifestURL(in: bundleURL),
                sourceInputDescriptors: sourceInputDescriptors,
                startedAt: startedAt,
                completedAt: Date(),
                provenanceWriter: provenanceWriter
            )
            provenanceBackup?.discard()

            return checksum
        } catch {
            try? fm.removeItem(at: temporaryOutputURL)
            cleanupFailedMaterialization(bundleURL: bundleURL, outputURL: outputURL, provenanceBackup: provenanceBackup)
            throw error
        }
    }

    /// Computes FASTQ statistics from a materialized file using a streaming collector.
    private static func computeStatistics(for url: URL) async throws -> FASTQDatasetStatistics? {
        // Strip a trailing `.gz` before checking the format extension so a
        // compressed `reads.fastq.gz` is still recognized as FASTQ.
        // `FASTQReader` decompresses transparently.
        var formatURL = url
        if formatURL.pathExtension.lowercased() == "gz" {
            formatURL = formatURL.deletingPathExtension()
        }
        let ext = formatURL.pathExtension.lowercased()
        guard ext == "fastq" || ext == "fq" else {
            return nil // Only compute for FASTQ files, not FASTA
        }
        let reader = FASTQReader(validateSequence: false)
        let collector = FASTQStatisticsCollector()
        for try await record in reader.records(from: url) {
            collector.process(record)
        }
        return collector.finalize()
    }

    private static func writeMaterializationProvenance(
        bundleURL: URL,
        materializedURL: URL,
        manifestURL: URL,
        sourceInputDescriptors: [ProvenanceFileDescriptor],
        startedAt: Date,
        completedAt: Date,
        provenanceWriter: @Sendable (ProvenanceEnvelope, URL) throws -> URL
    ) throws {
        let appArgv = materializationAppArgv(bundleURL: bundleURL, outputURL: materializedURL)
        let replayArgv = materializationReplayArgv(bundleURL: bundleURL, outputURL: materializedURL)
        let outputs = [
            try ProvenanceFileDescriptor.file(url: materializedURL, format: .fastq, role: .output),
            try ProvenanceFileDescriptor.file(url: manifestURL, format: .json, role: .output),
        ]
        let wallTime = completedAt.timeIntervalSince(startedAt)
        let step = ProvenanceStep(
            toolName: "Lungfish App",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: appArgv,
            durableReplayArgv: replayArgv,
            reproducibleCommand: replayArgv.map(shellEscape).joined(separator: " "),
            inputs: sourceInputDescriptors,
            outputs: outputs,
            exitStatus: 0,
            wallTimeSeconds: wallTime,
            startedAt: startedAt,
            completedAt: completedAt
        )
        let envelope = ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: "lungfish fastq persistent materialization",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish App",
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(name: "Lungfish App", version: WorkflowRun.currentAppVersion, kind: "app"),
            argv: appArgv,
            durableReplayArgv: replayArgv,
            reproducibleCommand: replayArgv.map(shellEscape).joined(separator: " "),
            options: ProvenanceOptions(
                explicit: [
                    "inputBundle": .file(bundleURL),
                    "output": .file(materializedURL),
                    "materializedFilename": .string(materializedURL.lastPathComponent),
                    "persistentBundleOutput": .boolean(true),
                    "statistics": .boolean(true),
                ],
                defaults: [
                    "materializedFilename": .string("materialized.fastq"),
                    "persistentBundleOutput": .boolean(true),
                    "statistics": .boolean(true),
                ],
                resolvedDefaults: [
                    "materializedFilename": .string(materializedURL.lastPathComponent),
                    "persistentBundleOutput": .boolean(true),
                    "statistics": .boolean(true),
                ]
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(executablePath: "Lungfish.app"),
            files: deduplicated(sourceInputDescriptors + outputs),
            output: outputs.first,
            outputs: outputs,
            steps: [step],
            wallTimeSeconds: wallTime,
            exitStatus: 0
        )
        _ = try provenanceWriter(envelope, bundleURL)
    }

    private static func materializationAppArgv(bundleURL: URL, outputURL: URL) -> [String] {
        [
            "lungfish-app-workflow:fastq-materialize",
            bundleURL.standardizedFileURL.path,
            "--output",
            outputURL.standardizedFileURL.path,
        ]
    }

    private static func materializationReplayArgv(bundleURL: URL, outputURL: URL) -> [String] {
        [
            CLICommandIdentity.executableName,
            "fastq",
            "materialize",
            bundleURL.standardizedFileURL.path,
            "--output",
            outputURL.standardizedFileURL.path,
        ]
    }

    private static func cleanupFailedMaterialization(
        bundleURL: URL,
        outputURL: URL,
        provenanceBackup: ProvenanceArtifactBackup?
    ) {
        let fm = FileManager.default
        try? fm.removeItem(at: outputURL)
        provenanceBackup?.restore()
        guard var manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else { return }
        manifest.materializationState = nil
        try? FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
    }

    private static func deduplicated(_ descriptors: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        var result: [ProvenanceFileDescriptor] = []
        for descriptor in descriptors {
            let key = "\(descriptor.role.rawValue)\u{0}\(descriptor.path)"
            if seen.insert(key).inserted {
                result.append(descriptor)
            }
        }
        return result
    }

    private struct ProvenanceArtifactBackup {
        let provenanceURL: URL
        let provenanceData: Data?
        let provenanceDirectoryURL: URL
        let temporaryProvenanceDirectoryURL: URL?

        static func capture(bundleURL: URL) throws -> ProvenanceArtifactBackup {
            let fm = FileManager.default
            let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            let provenanceData = fm.fileExists(atPath: provenanceURL.path)
                ? try Data(contentsOf: provenanceURL)
                : nil
            let provenanceDirectoryURL = bundleURL.appendingPathComponent(
                ProvenanceWriter.bundleProvenanceDirectoryName,
                isDirectory: true
            )
            let temporaryProvenanceDirectoryURL: URL?
            if fm.fileExists(atPath: provenanceDirectoryURL.path) {
                let backupURL = bundleURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        ".\(bundleURL.lastPathComponent)-provenance-backup-\(UUID().uuidString)",
                        isDirectory: true
                    )
                try fm.copyItem(at: provenanceDirectoryURL, to: backupURL)
                temporaryProvenanceDirectoryURL = backupURL
            } else {
                temporaryProvenanceDirectoryURL = nil
            }
            return ProvenanceArtifactBackup(
                provenanceURL: provenanceURL,
                provenanceData: provenanceData,
                provenanceDirectoryURL: provenanceDirectoryURL,
                temporaryProvenanceDirectoryURL: temporaryProvenanceDirectoryURL
            )
        }

        func restore() {
            let fm = FileManager.default
            try? fm.removeItem(at: provenanceURL)
            if let provenanceData {
                try? provenanceData.write(to: provenanceURL, options: .atomic)
            }
            try? fm.removeItem(at: provenanceDirectoryURL)
            if let temporaryProvenanceDirectoryURL {
                try? fm.copyItem(at: temporaryProvenanceDirectoryURL, to: provenanceDirectoryURL)
            }
            discard()
        }

        func discard() {
            if let temporaryProvenanceDirectoryURL {
                try? FileManager.default.removeItem(at: temporaryProvenanceDirectoryURL)
            }
        }
    }

    /// Updates the materialization state in a bundle's manifest.
    private func updateManifestState(bundleURL: URL, state: MaterializationState?) {
        guard var manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else { return }
        manifest.materializationState = state
        try? FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
    }
}
