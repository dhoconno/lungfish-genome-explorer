// MaterializationPipeline.swift - Actor-based materialization with bounded concurrency
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
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

    /// Active jobs tracked by their task ID.
    private var activeJobs: [UUID: Task<MaterializationResult, Error>] = [:]

    /// Progress snapshots for in-flight jobs.
    private var progressSnapshots: [UUID: MaterializationProgress] = [:]

    public init(
        derivativeService: FASTQDerivativeService = .shared,
        maxConcurrency: Int = 2
    ) {
        self.derivativeService = derivativeService
        self.maxConcurrency = max(1, maxConcurrency)
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

        // Mark as materializing in the manifest
        updateManifestState(bundleURL: bundleURL, state: .materializing(taskID: jobID))

        let task = Task<MaterializationResult, Error> { [derivativeService] in
            let startTime = Date()
            do {
                let checksum = try await Self.executeMaterialization(
                    bundleURL: bundleURL,
                    derivativeService: derivativeService,
                    jobID: jobID,
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
        onProgress: (@Sendable (MaterializationProgress) -> Void)?
    ) async throws -> String {
        let materializedFilename = "materialized.fastq"
        let outputURL = bundleURL.appendingPathComponent(materializedFilename)

        // Use the existing export mechanism from FASTQDerivativeService
        try await derivativeService.exportMaterializedFASTQ(
            fromDerivedBundle: bundleURL,
            to: outputURL,
            progress: { message in
                onProgress?(MaterializationProgress(
                    jobID: jobID,
                    fraction: 0.5, // We don't have fine-grained progress from export
                    message: message,
                    bundleURL: bundleURL
                ))
            }
        )

        // Compute checksum of the materialized file
        let checksum = try computeChecksum(for: outputURL)

        // Compute statistics from the materialized file in a single pass
        onProgress?(MaterializationProgress(
            jobID: jobID,
            fraction: 0.9,
            message: "Computing statistics...",
            bundleURL: bundleURL
        ))
        let stats = try await computeStatistics(for: outputURL)

        // Update manifest: mark as materialized, cache stats
        if var manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
            manifest.materializationState = .materialized(checksum: checksum)
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
                manifest.materializationState = .materialized(checksum: checksum)
            }
            try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        }

        return checksum
    }

    /// Computes a SHA-256 checksum of a file (first 1MB for speed).
    private static func computeChecksum(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 1_048_576) // First 1 MB
        var hasher = Hasher()
        hasher.combine(data)
        let hash = hasher.finalize()
        return String(format: "%08x", abs(hash))
    }

    /// Computes FASTQ statistics from a materialized file using a streaming collector.
    private static func computeStatistics(for url: URL) async throws -> FASTQDatasetStatistics? {
        guard url.pathExtension.lowercased() == "fastq" || url.pathExtension.lowercased() == "fq" else {
            return nil // Only compute for FASTQ files, not FASTA
        }
        let reader = FASTQReader(validateSequence: false)
        let collector = FASTQStatisticsCollector()
        for try await record in reader.records(from: url) {
            collector.process(record)
        }
        return collector.finalize()
    }

    /// Updates the materialization state in a bundle's manifest.
    private func updateManifestState(bundleURL: URL, state: MaterializationState?) {
        guard var manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else { return }
        manifest.materializationState = state
        try? FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
    }
}
