// FASTQDerivativeService+Batch.swift - Batch operations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {

    // MARK: - Batch Operations

    /// Result of a batch operation on multiple FASTQ bundles.
    public struct BatchResult: Sendable {
        /// Bundles that were successfully processed.
        public let outputBundleURLs: [URL]

        /// Input bundles that failed, with error descriptions.
        public let failures: [(inputURL: URL, error: String)]

        /// The batch operation record for manifest persistence.
        public let record: BatchOperationRecord

        /// Total wall clock time in seconds.
        public let wallClockSeconds: Double
    }

    /// Applies a derivative operation to multiple FASTQ bundles in sequence.
    ///
    /// Each input bundle is processed individually via `createDerivative`. Results are
    /// stored as children of each input bundle. A `BatchOperationRecord` is written to
    /// the common parent directory for sidebar virtual group creation.
    ///
    /// - Parameters:
    ///   - inputBundleURLs: The FASTQ bundles to process.
    ///   - request: The operation to apply to each bundle.
    ///   - commonParentDirectory: Directory where batch-operations.json is stored.
    ///   - progress: Callback reporting (fraction, message) across all bundles.
    /// - Returns: A `BatchResult` with output URLs, failures, and the batch record.
    public func createBatchDerivative(
        from inputBundleURLs: [URL],
        request: FASTQDerivativeRequest,
        commonParentDirectory: URL?,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> BatchResult {
        let startTime = Date()
        let totalCount = inputBundleURLs.count
        let batchOperationID = UUID()
        var outputURLs: [URL] = []
        var failures: [(URL, String)] = []

        for (index, inputURL) in inputBundleURLs.enumerated() {
            let bundleName = inputURL.deletingPathExtension().lastPathComponent
            let fraction = Double(index) / Double(max(1, totalCount))
            progress?(fraction, "Processing \(bundleName) (\(index + 1)/\(totalCount))...")

            do {
                let outputURL = try await createDerivative(
                    from: inputURL,
                    request: request,
                    batchOperationID: batchOperationID,
                    progress: { message in
                        let subFraction = fraction + (1.0 / Double(max(1, totalCount))) * 0.9
                        progress?(subFraction, "[\(bundleName)] \(message)")
                    }
                )
                outputURLs.append(outputURL)
            } catch {
                failures.append((inputURL, error.localizedDescription))
                derivativeLogger.warning("Batch operation failed for \(bundleName): \(error)")
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        progress?(1.0, "Batch complete: \(outputURLs.count)/\(totalCount) succeeded")

        // Build the batch record
        let record = BatchOperationRecord(
            id: batchOperationID,
            label: request.batchLabel,
            operationKind: request.operationKindString,
            parameters: request.batchParameters,
            outputBundlePaths: outputURLs.compactMap { url in
                commonParentDirectory.flatMap { parent in
                    relativePath(from: parent, to: url)
                } ?? url.lastPathComponent
            },
            inputBundlePaths: inputBundleURLs.compactMap { url in
                commonParentDirectory.flatMap { parent in
                    relativePath(from: parent, to: url)
                } ?? url.lastPathComponent
            },
            failureCount: failures.count,
            wallClockSeconds: elapsed
        )

        // Persist the batch record to the common parent directory
        if let parentDir = commonParentDirectory {
            do {
                try FASTQBatchManifest.appendOperation(record, to: parentDir)
                derivativeLogger.info("Saved batch operation record to \(parentDir.path, privacy: .public)")
            } catch {
                derivativeLogger.warning("Failed to save batch manifest: \(error)")
            }
        }

        return BatchResult(
            outputBundleURLs: outputURLs,
            failures: failures,
            record: record,
            wallClockSeconds: elapsed
        )
    }

    func attachBatchOperationID(_ batchOperationID: UUID, to bundleURL: URL) throws {
        guard let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else {
            throw FASTQDerivativeError.derivedManifestMissing
        }
        let updatedManifest = FASTQDerivedBundleManifest(
            id: manifest.id,
            name: manifest.name,
            createdAt: manifest.createdAt,
            parentBundleRelativePath: manifest.parentBundleRelativePath,
            rootBundleRelativePath: manifest.rootBundleRelativePath,
            rootFASTQFilename: manifest.rootFASTQFilename,
            payload: manifest.payload,
            lineage: manifest.lineage,
            operation: manifest.operation,
            cachedStatistics: manifest.cachedStatistics,
            pairingMode: manifest.pairingMode,
            readClassification: manifest.readClassification,
            batchOperationID: batchOperationID,
            sequenceFormat: manifest.sequenceFormat,
            provenance: manifest.provenance,
            payloadChecksums: manifest.payloadChecksums
        )
        try FASTQBundle.saveDerivedManifest(updatedManifest, in: bundleURL)
    }

    /// Computes a relative path from one URL to another.
    func relativePath(from base: URL, to target: URL) -> String? {
        let basePath = base.standardizedFileURL.path
        let normalizedBase = basePath.hasSuffix("/") ? basePath : basePath + "/"
        let targetPath = target.standardizedFileURL.path
        guard targetPath.hasPrefix(normalizedBase) else { return nil }
        return String(targetPath.dropFirst(normalizedBase.count))
    }

}
