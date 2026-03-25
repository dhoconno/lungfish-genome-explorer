// TaxTriageResult.swift - Result model for TaxTriage pipeline execution
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - TaxTriageResult

/// The result of a completed TaxTriage pipeline execution.
///
/// Contains paths to all output files produced by the pipeline, along with
/// runtime metadata for provenance tracking. Results can be serialized to
/// disk for later review or comparison.
///
/// ## Output Files
///
/// TaxTriage produces several categories of output:
/// - **Reports**: Per-sample organism identification reports
/// - **Metrics**: TASS confidence scoring TSV files
/// - **Visualization**: Krona interactive HTML charts
/// - **Logs**: Nextflow execution logs and trace files
///
/// ## Example
///
/// ```swift
/// let result = try await TaxTriagePipeline.shared.run(config: config) { progress, message in
///     print("\(Int(progress * 100))% \(message)")
/// }
/// print("Completed in \(String(format: "%.1f", result.runtime))s")
/// for report in result.reportFiles {
///     print("Report: \(report.lastPathComponent)")
/// }
/// ```
public struct TaxTriageResult: Sendable, Codable, Equatable {

    // MARK: - Properties

    /// The configuration used for this run.
    public let config: TaxTriageConfig

    /// Total pipeline runtime in seconds.
    public let runtime: TimeInterval

    /// The Nextflow exit code (0 = success).
    public let exitCode: Int32

    /// Whether the pipeline completed successfully.
    public var isSuccess: Bool {
        exitCode == 0
    }

    // MARK: - Output Files

    /// The top-level output directory.
    public let outputDirectory: URL

    /// Per-sample organism identification report files.
    ///
    /// These text-format reports list identified organisms with confidence scores.
    public let reportFiles: [URL]

    /// TASS confidence metrics TSV files.
    ///
    /// Tab-separated files with detailed classification confidence metrics.
    public let metricsFiles: [URL]

    /// Krona interactive HTML visualization files.
    ///
    /// One per sample (unless ``TaxTriageConfig/skipKrona`` was true).
    public let kronaFiles: [URL]

    /// Nextflow execution log file.
    public let logFile: URL?

    /// Nextflow trace file for detailed process timing.
    public let traceFile: URL?

    /// All output files discovered after pipeline completion.
    public let allOutputFiles: [URL]

    /// Cached deduplicated (unique) read counts per normalized organism name.
    ///
    /// Populated after the first background deduplication pass and persisted
    /// so subsequent loads skip the expensive BAM scan.
    public var deduplicatedReadCounts: [String: Int]?

    /// Per-sample deduplicated (unique) read counts.
    ///
    /// Outer key: normalized organism name. Inner key: sample ID. Value: unique read count.
    /// Populated during background deduplication for multi-sample batch runs and persisted
    /// to the sidecar so the batch overview can display unique reads per sample instantly
    /// on subsequent opens.
    public var perSampleDeduplicatedReadCounts: [String: [String: Int]]?

    /// URLs of the source FASTQ bundles that contributed samples to this run.
    ///
    /// Persisted for provenance tracking and sidebar cross-referencing.
    /// `nil` for legacy single-bundle runs. Populated from the config's
    /// ``TaxTriageConfig/sourceBundleURLs`` at result creation time.
    public var sourceBundleURLs: [URL]?

    // MARK: - Initialization

    /// Creates a TaxTriage result.
    ///
    /// - Parameters:
    ///   - config: The configuration used.
    ///   - runtime: Total execution time.
    ///   - exitCode: Nextflow process exit code.
    ///   - outputDirectory: Top-level output directory.
    ///   - reportFiles: Organism report files.
    ///   - metricsFiles: TASS metrics files.
    ///   - kronaFiles: Krona HTML files.
    ///   - logFile: Nextflow log file.
    ///   - traceFile: Nextflow trace file.
    ///   - allOutputFiles: All discovered output files.
    public init(
        config: TaxTriageConfig,
        runtime: TimeInterval,
        exitCode: Int32,
        outputDirectory: URL,
        reportFiles: [URL] = [],
        metricsFiles: [URL] = [],
        kronaFiles: [URL] = [],
        logFile: URL? = nil,
        traceFile: URL? = nil,
        allOutputFiles: [URL] = [],
        deduplicatedReadCounts: [String: Int]? = nil,
        perSampleDeduplicatedReadCounts: [String: [String: Int]]? = nil,
        sourceBundleURLs: [URL]? = nil
    ) {
        self.config = config
        self.runtime = runtime
        self.exitCode = exitCode
        self.outputDirectory = outputDirectory
        self.reportFiles = reportFiles
        self.metricsFiles = metricsFiles
        self.kronaFiles = kronaFiles
        self.logFile = logFile
        self.traceFile = traceFile
        self.allOutputFiles = allOutputFiles
        self.deduplicatedReadCounts = deduplicatedReadCounts
        self.perSampleDeduplicatedReadCounts = perSampleDeduplicatedReadCounts
        self.sourceBundleURLs = sourceBundleURLs
    }

    // MARK: - Summary

    /// A human-readable summary of the pipeline results.
    public var summary: String {
        var lines: [String] = []

        if isSuccess {
            lines.append("TaxTriage pipeline completed successfully")
        } else {
            lines.append("TaxTriage pipeline failed (exit code \(exitCode))")
        }

        let runtimeStr = String(format: "%.1f", runtime)
        lines.append("Runtime: \(runtimeStr)s")
        lines.append("Samples: \(config.samples.count)")
        lines.append("Reports: \(reportFiles.count)")
        lines.append("Metrics: \(metricsFiles.count)")

        if !kronaFiles.isEmpty {
            lines.append("Krona visualizations: \(kronaFiles.count)")
        }

        lines.append("Total output files: \(allOutputFiles.count)")

        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    /// Saves this result to a JSON file in the output directory.
    ///
    /// The result is written to `taxtriage-result.json` in the output directory.
    ///
    /// - Throws: If JSON encoding or file writing fails.
    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        let resultURL = outputDirectory.appendingPathComponent("taxtriage-result.json")
        try data.write(to: resultURL)
    }

    /// Loads a previously saved TaxTriage result from disk.
    ///
    /// - Parameter directory: The output directory containing `taxtriage-result.json`.
    /// - Returns: The decoded result.
    /// - Throws: If the file does not exist or decoding fails.
    public static func load(from directory: URL) throws -> TaxTriageResult {
        let resultURL = directory.appendingPathComponent("taxtriage-result.json")
        let data = try Data(contentsOf: resultURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TaxTriageResult.self, from: data)
    }
}
