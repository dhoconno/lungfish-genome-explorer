// FASTQBatchManifest.swift - Tracks batch operations across multiple FASTQ bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.io", category: "FASTQBatchManifest")

/// Records a batch operation that was applied uniformly across multiple FASTQ bundles.
///
/// Stored as `batch-operations.json` inside a parent bundle's `demux/` directory (or at
/// the project level). Each entry records which operation was run, its parameters, and
/// the relative paths to all output bundles. This enables the sidebar to create virtual
/// "batch group" nodes for quick re-selection of batch results.
///
/// ```
/// parent.lungfishfastq/
///   demux/
///     barcode01.lungfishfastq/
///       derivatives/
///         length-filtered.lungfishfastq
///     barcode02.lungfishfastq/
///       derivatives/
///         length-filtered.lungfishfastq
///     batch-operations.json          <-- this file
/// ```
public struct FASTQBatchManifest: Codable, Sendable, Equatable {
    public static let filename = "batch-operations.json"

    /// All batch operations recorded at this level.
    public var operations: [BatchOperationRecord]

    public init(operations: [BatchOperationRecord] = []) {
        self.operations = operations
    }

    // MARK: - Persistence

    /// Loads the batch manifest from a directory, if present.
    public static func load(from directoryURL: URL) -> FASTQBatchManifest? {
        let url = directoryURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(FASTQBatchManifest.self, from: data)
        } catch {
            logger.warning("Failed to load batch manifest: \(error)")
            return nil
        }
    }

    /// Saves the batch manifest to a directory.
    public func save(to directoryURL: URL) throws {
        let url = directoryURL.appendingPathComponent(Self.filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Appends a new batch operation record to the manifest at the given directory.
    /// Creates the manifest file if it doesn't exist.
    public static func appendOperation(
        _ record: BatchOperationRecord,
        to directoryURL: URL
    ) throws {
        var manifest = load(from: directoryURL) ?? FASTQBatchManifest()
        manifest.operations.append(record)
        try manifest.save(to: directoryURL)
    }
}

/// A single batch operation that was applied to multiple bundles.
public struct BatchOperationRecord: Codable, Sendable, Equatable, Identifiable {
    /// Unique identifier for this batch operation.
    public let id: UUID

    /// Human-readable label for the operation (e.g., "Filter by Length (500-5000 bp)").
    public let label: String

    /// The operation kind (matches FASTQDerivativeOperation.Kind).
    public let operationKind: String

    /// ISO 8601 timestamp when the operation was performed.
    public let performedAt: Date

    /// Parameters used for the operation (key-value pairs for display).
    public let parameters: [String: String]

    /// Relative paths from this manifest's directory to each output bundle.
    /// e.g., ["barcode01.lungfishfastq/length-filtered.lungfishfastq", ...]
    public let outputBundlePaths: [String]

    /// Relative paths from this manifest's directory to each input bundle.
    /// e.g., ["barcode01.lungfishfastq", ...]
    public let inputBundlePaths: [String]

    /// Number of bundles successfully processed.
    public var successCount: Int { outputBundlePaths.count }

    /// Number of bundles that failed (if any).
    public let failureCount: Int

    /// Total wall clock time in seconds.
    public let wallClockSeconds: Double

    public init(
        id: UUID = UUID(),
        label: String,
        operationKind: String,
        performedAt: Date = Date(),
        parameters: [String: String] = [:],
        outputBundlePaths: [String],
        inputBundlePaths: [String],
        failureCount: Int = 0,
        wallClockSeconds: Double = 0
    ) {
        self.id = id
        self.label = label
        self.operationKind = operationKind
        self.performedAt = performedAt
        self.parameters = parameters
        self.outputBundlePaths = outputBundlePaths
        self.inputBundlePaths = inputBundlePaths
        self.failureCount = failureCount
        self.wallClockSeconds = wallClockSeconds
    }
}
