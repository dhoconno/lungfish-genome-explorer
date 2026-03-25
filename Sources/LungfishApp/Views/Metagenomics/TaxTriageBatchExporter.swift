// TaxTriageBatchExporter.swift - Batch-level export for TaxTriage multi-sample runs
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

// MARK: - TaxTriageBatchExporter

/// Generates batch-level exports from multi-sample TaxTriage results.
///
/// Produces:
/// - Cross-sample organism matrix CSV (organisms as rows, samples as columns, TASS scores as values)
/// - Summary text report with batch metadata, per-sample highlights, and contamination flags
///
/// Thread-safe: all methods are pure functions operating on provided data.
enum TaxTriageBatchExporter {

    // MARK: - Organism Matrix CSV

    /// Generates a cross-sample organism matrix as CSV.
    ///
    /// Rows are organisms (sorted by number of samples detected, then mean TASS).
    /// Columns are: Organism, Mean TASS, # Samples, then one column per sample ID
    /// containing the TASS score (empty if not detected).
    ///
    /// - Parameters:
    ///   - metrics: All parsed metrics across all samples.
    ///   - sampleIds: Ordered sample identifiers.
    ///   - negativeControlSampleIds: Sample IDs marked as negative controls.
    /// - Returns: CSV string.
    static func generateOrganismMatrixCSV(
        metrics: [TaxTriageMetric],
        sampleIds: [String],
        negativeControlSampleIds: Set<String> = []
    ) -> String {
        let rows = buildCrossSampleData(
            metrics: metrics,
            sampleIds: sampleIds,
            negativeControlSampleIds: negativeControlSampleIds
        )

        var csv = "Organism,Mean TASS,Samples Detected,Contamination Risk"
        for sid in sampleIds {
            csv += ",\(escapeCSV(sid))"
        }
        csv += "\n"

        for row in rows {
            csv += "\(escapeCSV(row.organism))"
            csv += ",\(String(format: "%.4f", row.meanTASS))"
            csv += ",\(row.sampleCount)/\(sampleIds.count)"
            csv += ",\(row.isContaminationRisk ? "Yes" : "No")"
            for sid in sampleIds {
                if let score = row.perSampleTASS[sid] {
                    csv += ",\(String(format: "%.4f", score))"
                } else {
                    csv += ","
                }
            }
            csv += "\n"
        }

        return csv
    }

    // MARK: - Summary Text Report

    /// Generates a summary text report for a batch run.
    ///
    /// Includes batch metadata, per-sample organism counts, high-confidence organisms,
    /// and contamination risk warnings.
    ///
    /// - Parameters:
    ///   - result: The TaxTriage pipeline result.
    ///   - config: The TaxTriage config.
    ///   - metrics: All parsed metrics.
    ///   - sampleIds: Ordered sample identifiers.
    /// - Returns: Plain text report string.
    static func generateSummaryReport(
        result: TaxTriageResult,
        config: TaxTriageConfig,
        metrics: [TaxTriageMetric],
        sampleIds: [String]
    ) -> String {
        let negControlIds = Set(config.samples.filter(\.isNegativeControl).map(\.sampleId))
        let rows = buildCrossSampleData(
            metrics: metrics,
            sampleIds: sampleIds,
            negativeControlSampleIds: negControlIds
        )

        var report = """
        ============================================================
        TaxTriage Batch Analysis Report
        ============================================================

        Date: \(ISO8601DateFormatter().string(from: Date()))
        Samples: \(sampleIds.count)
        Platform: \(config.platform.displayName)
        Runtime: \(String(format: "%.1f", result.runtime)) seconds
        Exit Code: \(result.exitCode)

        """

        if !negControlIds.isEmpty {
            report += "Negative Controls: \(negControlIds.sorted().joined(separator: ", "))\n"
        }

        report += "\n--- Per-Sample Summary ---\n\n"

        for sid in sampleIds {
            let sampleMetrics = metrics.filter { $0.sample == sid }
            let highConf = sampleMetrics.filter { $0.tassScore >= 0.8 }.count
            let isNTC = negControlIds.contains(sid)
            let ntcTag = isNTC ? " [NTC]" : ""
            report += "  \(sid)\(ntcTag): \(sampleMetrics.count) organisms (\(highConf) high confidence)\n"
        }

        report += "\n--- Cross-Sample Organisms ---\n\n"

        let multiSampleOrganisms = rows.filter { $0.sampleCount > 1 }
        if multiSampleOrganisms.isEmpty {
            report += "  No organisms detected in multiple samples.\n"
        } else {
            for row in multiSampleOrganisms {
                let risk = row.isContaminationRisk ? " [CONTAMINATION RISK]" : ""
                report += "  \(row.organism): \(row.sampleCount)/\(sampleIds.count) samples, mean TASS=\(String(format: "%.3f", row.meanTASS))\(risk)\n"
            }
        }

        if !negControlIds.isEmpty {
            let contamOrganisms = rows.filter(\.isContaminationRisk)
            report += "\n--- Contamination Risk Organisms ---\n\n"
            if contamOrganisms.isEmpty {
                report += "  No organisms detected in negative controls.\n"
            } else {
                for row in contamOrganisms {
                    let samples = row.perSampleTASS.keys.sorted().joined(separator: ", ")
                    report += "  \(row.organism) (detected in: \(samples))\n"
                }
            }
        }

        report += "\n--- High-Confidence Organisms (TASS >= 0.8) ---\n\n"

        let highConf = rows.filter { $0.meanTASS >= 0.8 }
        if highConf.isEmpty {
            report += "  None.\n"
        } else {
            for row in highConf {
                report += "  \(row.organism): mean TASS=\(String(format: "%.3f", row.meanTASS)), \(row.sampleCount) sample(s)\n"
            }
        }

        report += "\n============================================================\n"
        return report
    }

    // MARK: - Helpers

    /// Builds cross-sample organism data.
    private struct CrossSampleData {
        let organism: String
        let sampleCount: Int
        let meanTASS: Double
        let perSampleTASS: [String: Double]
        let isContaminationRisk: Bool
    }

    private static func buildCrossSampleData(
        metrics: [TaxTriageMetric],
        sampleIds: [String],
        negativeControlSampleIds: Set<String>
    ) -> [CrossSampleData] {
        var byOrganism: [String: [TaxTriageMetric]] = [:]
        for metric in metrics {
            let key = metric.organism.lowercased().trimmingCharacters(in: .whitespaces)
            byOrganism[key, default: []].append(metric)
        }

        var rows: [CrossSampleData] = []
        for (_, group) in byOrganism {
            guard let first = group.first else { continue }
            let detectedSamples = Set(group.compactMap(\.sample))
            let tassScores = group.map(\.tassScore)
            let meanTASS = tassScores.isEmpty ? 0 : tassScores.reduce(0, +) / Double(tassScores.count)

            var perSample: [String: Double] = [:]
            for metric in group {
                if let sample = metric.sample {
                    perSample[sample] = metric.tassScore
                }
            }

            let inNegativeControl = !negativeControlSampleIds.isEmpty
                && !detectedSamples.intersection(negativeControlSampleIds).isEmpty

            rows.append(CrossSampleData(
                organism: first.organism,
                sampleCount: detectedSamples.count,
                meanTASS: meanTASS,
                perSampleTASS: perSample,
                isContaminationRisk: inNegativeControl
            ))
        }

        return rows.sorted {
            if $0.sampleCount != $1.sampleCount { return $0.sampleCount > $1.sampleCount }
            return $0.meanTASS > $1.meanTASS
        }
    }

    private static func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
