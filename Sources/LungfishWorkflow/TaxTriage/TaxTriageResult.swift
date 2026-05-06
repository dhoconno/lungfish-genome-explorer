// TaxTriageResult.swift - Result model for TaxTriage pipeline execution
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - TaxTriageResult

public struct TaxTriageIgnoredFailure: Sendable, Codable, Equatable {
    public let processPath: String
    public let processName: String
    public let taskLabel: String
    public let sampleID: String?
    public let exitCode: Int

    public init(
        processPath: String,
        processName: String,
        taskLabel: String,
        sampleID: String?,
        exitCode: Int
    ) {
        self.processPath = processPath
        self.processName = processName
        self.taskLabel = taskLabel
        self.sampleID = sampleID
        self.exitCode = exitCode
    }
}

public struct TaxTriageSampleFailure: Sendable, Codable, Equatable {
    public let sampleID: String
    public let outputDirectory: URL
    public let errorDescription: String

    public init(sampleID: String, outputDirectory: URL, errorDescription: String) {
        self.sampleID = sampleID
        self.outputDirectory = outputDirectory
        self.errorDescription = errorDescription
    }
}

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

    private enum CodingKeys: String, CodingKey {
        case config
        case runtime
        case exitCode
        case outputDirectory
        case reportFiles
        case metricsFiles
        case kronaFiles
        case logFile
        case traceFile
        case allOutputFiles
        case deduplicatedReadCounts
        case perSampleDeduplicatedReadCounts
        case sourceBundleURLs
        case ignoredFailures
        case sampleFailures
    }

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

    /// Nextflow task failures that were explicitly ignored by the pipeline.
    ///
    /// These do not make the overall Nextflow run fail, but they indicate
    /// sample-level data loss that should be surfaced in the UI.
    public let ignoredFailures: [TaxTriageIgnoredFailure]

    public var hasIgnoredFailures: Bool {
        !ignoredFailures.isEmpty
    }

    /// Sample-level failures recorded by the app's serial TaxTriage batch runner.
    ///
    /// These represent whole sample pipeline failures that did not prevent later
    /// samples from running. Legacy single Nextflow runs leave this empty.
    public let sampleFailures: [TaxTriageSampleFailure]

    public var hasSampleFailures: Bool {
        !sampleFailures.isEmpty
    }

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
        sourceBundleURLs: [URL]? = nil,
        ignoredFailures: [TaxTriageIgnoredFailure] = [],
        sampleFailures: [TaxTriageSampleFailure] = []
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
        self.ignoredFailures = ignoredFailures
        self.sampleFailures = sampleFailures
    }

    // MARK: - Summary

    /// A human-readable summary of the pipeline results.
    public var summary: String {
        var lines: [String] = []

        if isSuccess {
            if hasIgnoredFailures || hasSampleFailures {
                lines.append("TaxTriage pipeline completed with warnings")
            } else {
                lines.append("TaxTriage pipeline completed successfully")
            }
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

        if hasIgnoredFailures {
            let sampleCount = Set(ignoredFailures.compactMap(\.sampleID)).count
            let sampleSummary = sampleCount > 0 ? " across \(sampleCount) samples" : ""
            lines.append("Ignored sample failures: \(ignoredFailures.count)\(sampleSummary)")
        }

        if hasSampleFailures {
            lines.append("Failed samples: \(sampleFailures.count)")
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.config = try container.decode(TaxTriageConfig.self, forKey: .config)
        self.runtime = try container.decode(TimeInterval.self, forKey: .runtime)
        self.exitCode = try container.decode(Int32.self, forKey: .exitCode)
        self.outputDirectory = try container.decode(URL.self, forKey: .outputDirectory)
        self.reportFiles = try container.decodeIfPresent([URL].self, forKey: .reportFiles) ?? []
        self.metricsFiles = try container.decodeIfPresent([URL].self, forKey: .metricsFiles) ?? []
        self.kronaFiles = try container.decodeIfPresent([URL].self, forKey: .kronaFiles) ?? []
        self.logFile = try container.decodeIfPresent(URL.self, forKey: .logFile)
        self.traceFile = try container.decodeIfPresent(URL.self, forKey: .traceFile)
        self.allOutputFiles = try container.decodeIfPresent([URL].self, forKey: .allOutputFiles) ?? []
        self.deduplicatedReadCounts = try container.decodeIfPresent([String: Int].self, forKey: .deduplicatedReadCounts)
        self.perSampleDeduplicatedReadCounts = try container.decodeIfPresent([String: [String: Int]].self, forKey: .perSampleDeduplicatedReadCounts)
        self.sourceBundleURLs = try container.decodeIfPresent([URL].self, forKey: .sourceBundleURLs)
        self.ignoredFailures = try container.decodeIfPresent([TaxTriageIgnoredFailure].self, forKey: .ignoredFailures) ?? []
        self.sampleFailures = try container.decodeIfPresent([TaxTriageSampleFailure].self, forKey: .sampleFailures) ?? []
    }

    public static func parseIgnoredFailures(fromNextflowLogText logText: String) -> [TaxTriageIgnoredFailure] {
        let pattern = #"NOTE:\s+Process `([^`]+)\s+\(([^)]+)\)` terminated with an error exit status \((\d+)\) -- Error is ignored"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsRange = NSRange(logText.startIndex..<logText.endIndex, in: logText)
        return regex.matches(in: logText, range: nsRange).compactMap { match in
            guard match.numberOfRanges == 4,
                  let processRange = Range(match.range(at: 1), in: logText),
                  let taskRange = Range(match.range(at: 2), in: logText),
                  let exitCodeRange = Range(match.range(at: 3), in: logText),
                  let exitCode = Int(String(logText[exitCodeRange])) else {
                return nil
            }

            let processPath = String(logText[processRange])
            let taskLabel = String(logText[taskRange])
            let processName = processPath.split(separator: ":").last.map(String.init) ?? processPath
            let sampleID = extractSampleID(fromTaskLabel: taskLabel)

            return TaxTriageIgnoredFailure(
                processPath: processPath,
                processName: processName,
                taskLabel: taskLabel,
                sampleID: sampleID,
                exitCode: exitCode
            )
        }
    }

    public static func sanitizeIgnoredFailures(
        _ failures: [TaxTriageIgnoredFailure],
        outputDirectory: URL
    ) -> [TaxTriageIgnoredFailure] {
        failures.filter {
            !isBenignEmptyReferenceAlignmentFailure($0, outputDirectory: outputDirectory)
        }
    }

    private static func extractSampleID(fromTaskLabel taskLabel: String) -> String? {
        let candidate = taskLabel.split(separator: ".").first.map(String.init)
        guard let candidate, !candidate.isEmpty else { return nil }
        return candidate
    }

    private static func isBenignEmptyReferenceAlignmentFailure(
        _ failure: TaxTriageIgnoredFailure,
        outputDirectory: URL
    ) -> Bool {
        guard failure.processName == "ALIGNMENT_PER_SAMPLE",
              let sampleID = failure.sampleID else {
            return false
        }

        let mergedTaxidURL = outputDirectory
            .appendingPathComponent("map", isDirectory: true)
            .appendingPathComponent("\(sampleID).merged.taxid.tsv")
        let combinedMapURL = outputDirectory
            .appendingPathComponent("combine", isDirectory: true)
            .appendingPathComponent("\(sampleID).combined.gcfmap.tsv")
        let referenceFastaURL = outputDirectory
            .appendingPathComponent("download", isDirectory: true)
            .appendingPathComponent("\(sampleID).dwnld.references.fasta")

        return hasAtMostOneNonEmptyLine(at: mergedTaxidURL) &&
            isEmptyFile(at: combinedMapURL) &&
            isEmptyFile(at: referenceFastaURL)
    }

    private static func hasAtMostOneNonEmptyLine(at url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let lineCount = text.split(whereSeparator: \.isNewline).count
        return lineCount <= 1
    }

    private static func isEmptyFile(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return false
        }
        return fileSize.intValue == 0
    }
}
