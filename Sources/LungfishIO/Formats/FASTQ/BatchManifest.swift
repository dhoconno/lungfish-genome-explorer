// BatchManifest.swift - Batch processing and cross-sample comparison manifests
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.io", category: "BatchManifest")

// MARK: - Batch Manifest

/// Top-level manifest for a batch processing run.
///
/// Stored at `batch-runs/{batch-name}/batch.manifest.json` inside the
/// demux group folder. Records the recipe used, timing, and barcode list.
public struct BatchManifest: Codable, Sendable, Equatable {
    public static let filename = "batch.manifest.json"

    public let batchID: UUID
    public let recipeName: String
    public let recipeID: UUID
    public let batchName: String
    public let startedAt: Date
    public var completedAt: Date?
    public let barcodeCount: Int
    public let stepCount: Int
    public let barcodeLabels: [String]

    public init(
        batchID: UUID = UUID(),
        recipeName: String,
        recipeID: UUID,
        batchName: String,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        barcodeCount: Int,
        stepCount: Int,
        barcodeLabels: [String]
    ) {
        self.batchID = batchID
        self.recipeName = recipeName
        self.recipeID = recipeID
        self.batchName = batchName
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.barcodeCount = barcodeCount
        self.stepCount = stepCount
        self.barcodeLabels = barcodeLabels
    }

    // MARK: - Persistence

    public static func load(from directoryURL: URL) -> BatchManifest? {
        let url = directoryURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(BatchManifest.self, from: data)
        } catch {
            logger.warning("Failed to load batch manifest: \(error)")
            return nil
        }
    }

    public func save(to directoryURL: URL) throws {
        let url = directoryURL.appendingPathComponent(Self.filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Batch Comparison Manifest

/// Cross-barcode comparison data generated after a batch processing run.
///
/// Stored at `batch-runs/{batch-name}/comparison.json`. Contains per-barcode,
/// per-step metrics for rendering the comparison table UI.
public struct BatchComparisonManifest: Codable, Sendable, Equatable {
    public static let filename = "comparison.json"

    public let batchID: UUID
    public let generatedAt: Date
    public let recipeName: String
    public let steps: [StepDefinition]
    public let barcodes: [BarcodeSummary]

    public init(
        batchID: UUID,
        generatedAt: Date = Date(),
        recipeName: String,
        steps: [StepDefinition],
        barcodes: [BarcodeSummary]
    ) {
        self.batchID = batchID
        self.generatedAt = generatedAt
        self.recipeName = recipeName
        self.steps = steps
        self.barcodes = barcodes
    }

    // MARK: - Persistence

    public static func load(from directoryURL: URL) -> BatchComparisonManifest? {
        let url = directoryURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(BatchComparisonManifest.self, from: data)
        } catch {
            logger.warning("Failed to load comparison manifest: \(error)")
            return nil
        }
    }

    public func save(to directoryURL: URL) throws {
        let url = directoryURL.appendingPathComponent(Self.filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Step Definition

/// Describes one step in the pipeline for comparison table column headers.
public struct StepDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: Int { index }

    /// Zero-based index in the recipe.
    public let index: Int

    /// Operation kind (e.g., "qualityTrim").
    public let operationKind: String

    /// Short label for column headers (e.g., "qtrim-Q20").
    public let shortLabel: String

    /// Longer description (e.g., "Quality trim Q20 w4 (cutRight)").
    public let displaySummary: String

    public init(index: Int, operationKind: String, shortLabel: String, displaySummary: String) {
        self.index = index
        self.operationKind = operationKind
        self.shortLabel = shortLabel
        self.displaySummary = displaySummary
    }
}

// MARK: - Barcode Summary

/// Per-barcode metrics across all pipeline steps.
public struct BarcodeSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String { label }

    /// Barcode label (e.g., "bc01", "SampleA").
    public let label: String

    /// Metrics for the raw input (before any processing).
    public let inputMetrics: StepMetrics

    /// Results for each pipeline step.
    public let stepResults: [StepResult]

    public init(label: String, inputMetrics: StepMetrics, stepResults: [StepResult]) {
        self.label = label
        self.inputMetrics = inputMetrics
        self.stepResults = stepResults
    }

    /// The final output metrics (last successful step, or input if none completed).
    public var finalMetrics: StepMetrics {
        stepResults.last(where: { $0.status == .completed })?.metrics ?? inputMetrics
    }

    /// Cumulative retention rate from raw input to final output.
    public var cumulativeRetention: Double {
        guard inputMetrics.readCount > 0 else { return 0 }
        return Double(finalMetrics.readCount) / Double(inputMetrics.readCount)
    }
}

// MARK: - Step Result

/// Result of one pipeline step for one barcode.
public struct StepResult: Codable, Sendable, Equatable {
    /// Step index (matches `StepDefinition.index`).
    public let stepIndex: Int

    /// Completion status.
    public let status: StepStatus

    /// Output metrics (nil if failed or cancelled).
    public let metrics: StepMetrics

    /// Error message if failed.
    public let errorMessage: String?

    /// Relative path to the output bundle within the batch directory.
    public let bundleRelativePath: String?

    public init(
        stepIndex: Int,
        status: StepStatus,
        metrics: StepMetrics,
        errorMessage: String? = nil,
        bundleRelativePath: String? = nil
    ) {
        self.stepIndex = stepIndex
        self.status = status
        self.metrics = metrics
        self.errorMessage = errorMessage
        self.bundleRelativePath = bundleRelativePath
    }
}

/// Completion status for a single barcode at a single step.
public enum StepStatus: String, Codable, Sendable, CaseIterable {
    case completed
    case failed
    case cancelled
    case skipped
}

// MARK: - Step Metrics

/// Quantitative metrics for a FASTQ dataset at a given pipeline stage.
///
/// These are the core values displayed in the cross-sample comparison table.
/// All fields are present for completed steps; failed/skipped steps may have
/// zero values.
public struct StepMetrics: Codable, Sendable, Equatable {
    public let readCount: Int
    public let baseCount: Int64
    public let meanReadLength: Double
    public let medianReadLength: Int
    public let n50ReadLength: Int
    public let meanQuality: Double
    public let q20Percentage: Double
    public let q30Percentage: Double
    public let gcContent: Double

    /// Percentage of reads retained from this step's input (0-100).
    /// Nil for the raw input metrics.
    public let readsRetainedPercent: Double?

    /// Percentage of reads retained from the original raw input (0-100).
    /// Nil for the raw input metrics.
    public let cumulativeRetainedPercent: Double?

    public init(
        readCount: Int,
        baseCount: Int64,
        meanReadLength: Double,
        medianReadLength: Int,
        n50ReadLength: Int,
        meanQuality: Double,
        q20Percentage: Double,
        q30Percentage: Double,
        gcContent: Double,
        readsRetainedPercent: Double? = nil,
        cumulativeRetainedPercent: Double? = nil
    ) {
        self.readCount = readCount
        self.baseCount = baseCount
        self.meanReadLength = meanReadLength
        self.medianReadLength = medianReadLength
        self.n50ReadLength = n50ReadLength
        self.meanQuality = meanQuality
        self.q20Percentage = q20Percentage
        self.q30Percentage = q30Percentage
        self.gcContent = gcContent
        self.readsRetainedPercent = readsRetainedPercent
        self.cumulativeRetainedPercent = cumulativeRetainedPercent
    }

    /// Creates step metrics from an existing `FASTQDatasetStatistics`.
    public init(
        from stats: FASTQDatasetStatistics,
        inputReadCount: Int? = nil,
        rawInputReadCount: Int? = nil
    ) {
        self.readCount = stats.readCount
        self.baseCount = stats.baseCount
        self.meanReadLength = stats.meanReadLength
        self.medianReadLength = stats.medianReadLength
        self.n50ReadLength = stats.n50ReadLength
        self.meanQuality = stats.meanQuality
        self.q20Percentage = stats.q20Percentage
        self.q30Percentage = stats.q30Percentage
        self.gcContent = stats.gcContent

        if let inputCount = inputReadCount, inputCount > 0 {
            self.readsRetainedPercent = Double(stats.readCount) / Double(inputCount) * 100.0
        } else {
            self.readsRetainedPercent = nil
        }

        if let rawCount = rawInputReadCount, rawCount > 0 {
            self.cumulativeRetainedPercent = Double(stats.readCount) / Double(rawCount) * 100.0
        } else {
            self.cumulativeRetainedPercent = nil
        }
    }

    /// Empty metrics for failed/skipped steps.
    public static let empty = StepMetrics(
        readCount: 0, baseCount: 0, meanReadLength: 0, medianReadLength: 0,
        n50ReadLength: 0, meanQuality: 0, q20Percentage: 0, q30Percentage: 0,
        gcContent: 0
    )
}
