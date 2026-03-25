// BatchRunHistory.swift - Batch run log for TaxTriage pipeline executions
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: "com.lungfish.app", category: "BatchRunHistory")

// MARK: - BatchRunRecord

/// A single entry in the batch run history log.
struct BatchRunRecord: Codable, Sendable, Equatable {

    /// Unique run identifier (matches the output directory name).
    let runId: String

    /// ISO 8601 timestamp when the run started.
    let startedAt: Date

    /// ISO 8601 timestamp when the run completed (or failed).
    let completedAt: Date

    /// Sample IDs included in the batch.
    let sampleIds: [String]

    /// Sample IDs marked as negative controls.
    let negativeControlSampleIds: [String]

    /// Sequencing platform used.
    let platform: String

    /// Absolute path to the output directory.
    let outputDirectory: String

    /// Pipeline exit code (0 = success).
    let exitCode: Int32

    /// Runtime in seconds.
    let runtime: TimeInterval

    /// Whether the run completed successfully.
    var isSuccess: Bool { exitCode == 0 }

    /// Key pipeline parameters for comparison.
    let parameters: BatchRunParameters
}

/// Key pipeline parameters recorded for comparison between runs.
struct BatchRunParameters: Codable, Sendable, Equatable {
    let classifiers: [String]
    let k2Confidence: Double
    let topHitsCount: Int
    let skipAssembly: Bool
    let kraken2DatabasePath: String?
}

// MARK: - BatchRunHistoryLog

/// The full batch run history file.
struct BatchRunHistoryLog: Codable, Sendable {
    static let filename = "batch-run-history.json"

    var schemaVersion: Int = 1
    var runs: [BatchRunRecord] = []
}

// MARK: - BatchRunHistory

/// Manages the batch run history log stored as JSON in the output directory's parent.
///
/// The history file lives alongside (or inside) the output directory, enabling
/// users to track multiple runs in the same project area.
enum BatchRunHistory {

    /// Records a completed TaxTriage batch run in the history log.
    ///
    /// The history file is stored in the output directory itself.
    ///
    /// - Parameters:
    ///   - result: The completed pipeline result.
    ///   - config: The pipeline configuration.
    static func recordRun(result: TaxTriageResult, config: TaxTriageConfig) {
        let record = BatchRunRecord(
            runId: result.outputDirectory.lastPathComponent,
            startedAt: Date(timeIntervalSinceNow: -result.runtime),
            completedAt: Date(),
            sampleIds: config.samples.map(\.sampleId),
            negativeControlSampleIds: config.samples.filter(\.isNegativeControl).map(\.sampleId),
            platform: config.platform.rawValue,
            outputDirectory: result.outputDirectory.path,
            exitCode: result.exitCode,
            runtime: result.runtime,
            parameters: BatchRunParameters(
                classifiers: config.classifiers,
                k2Confidence: config.k2Confidence,
                topHitsCount: config.topHitsCount,
                skipAssembly: config.skipAssembly,
                kraken2DatabasePath: config.kraken2DatabasePath?.path
            )
        )

        do {
            var log = loadHistory(from: result.outputDirectory) ?? BatchRunHistoryLog()
            // Avoid duplicate entries for the same runId
            log.runs.removeAll { $0.runId == record.runId }
            log.runs.append(record)
            try saveHistory(log, to: result.outputDirectory)
            logger.info("Recorded batch run \(record.runId, privacy: .public) (\(config.samples.count) samples)")
        } catch {
            logger.error("Failed to record batch run: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Loads the batch run history from a directory.
    ///
    /// - Parameter directory: The output directory containing the history file.
    /// - Returns: The history log, or nil if no history exists.
    static func loadHistory(from directory: URL) -> BatchRunHistoryLog? {
        let url = directory.appendingPathComponent(BatchRunHistoryLog.filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BatchRunHistoryLog.self, from: data)
    }

    /// Loads all history records from a directory (convenience).
    static func loadRecords(from directory: URL) -> [BatchRunRecord] {
        loadHistory(from: directory)?.runs ?? []
    }

    // MARK: - Private

    private static func saveHistory(_ log: BatchRunHistoryLog, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(log)
        let url = directory.appendingPathComponent(BatchRunHistoryLog.filename)
        try data.write(to: url, options: .atomic)
    }
}
