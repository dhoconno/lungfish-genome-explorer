// TaxTriageBatchExporter.swift - Batch-level export for TaxTriage multi-sample runs
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

// MARK: - TaxTriageBatchExporter

/// Generates batch-level exports from multi-sample TaxTriage results.
///
/// Produces:
/// - Cross-sample organism matrix CSV (organisms as rows, samples as columns, TASS scores as values)
/// - Summary text report with batch metadata, per-sample highlights, and contamination flags
///
/// Thread-safe: all methods are pure functions operating on provided data.
public enum TaxTriageBatchExporter {

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
    ///   - controlsNotRecorded: True when the result does not say which samples were controls, so the Contamination
    ///     Risk column reads Not recorded instead of Yes or No.
    ///   - controlsNotChecked: True when a control never ran or cannot be found, so an organism that no control
    ///     that ran holds reads Not checked instead of No.
    /// - Returns: CSV string.
    public static func generateOrganismMatrixCSV(
        metrics: [TaxTriageMetric],
        sampleIds: [String],
        negativeControlSampleIds: Set<String> = [],
        controlsNotRecorded: Bool = false,
        controlsNotChecked: Bool = false
    ) -> String {
        let rows = buildCrossSampleData(
            metrics: metrics,
            sampleIds: sampleIds,
            negativeControlSampleIds: negativeControlSampleIds
        )

        var csv = "Organism,Mean TASS,Samples Detected,Contamination Risk"
        for sid in sampleIds {
            csv += ",\(DelimitedText.csvField(sid))"
        }
        csv += "\n"

        for row in rows {
            csv += "\(DelimitedText.csvField(row.organism))"
            csv += ",\(String(format: "%.4f", row.meanTASS))"
            csv += ",\(row.sampleCount)/\(sampleIds.count)"
            let risk = row.isContaminationRisk ? "Yes" : (controlsNotChecked ? notChecked : "No")
            csv += ",\(controlsNotRecorded ? notRecorded : risk)"
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
    public static func generateSummaryReport(
        result: TaxTriageResult,
        config: TaxTriageConfig,
        metrics: [TaxTriageMetric],
        sampleIds: [String]
    ) -> String {
        // The controls as the results name them, since the pipeline renames a sample (lane TTBUILDDB).
        let match = TaxTriageControlMatch(
            samples: config.samples,
            failedSampleIDs: result.sampleFailures.map(\.sampleID),
            databaseSampleIds: sampleIds
        )
        let negControlIds = match.controlSampleIds
        let controlsNotRecorded = TaxTriageExportSource.controlsAreNotRecorded(in: config)
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
        Platform: \(controlsNotRecorded ? notRecorded : config.platform.displayName)
        Runtime: \(controlsNotRecorded ? notRecorded : String(format: "%.1f", result.runtime) + " seconds")
        Exit Code: \(controlsNotRecorded ? notRecorded : String(result.exitCode))

        """

        if controlsNotRecorded {
            report += "Negative Controls: Not recorded. This import does not say which samples were controls, "
                + "so contamination risk is unknown.\n"
        } else if !match.controls.isEmpty {
            report += "Negative Controls: \(match.controls.map(controlLabel).joined(separator: ", "))\n"
            for note in match.notes {
                report += "\(note)\n"
            }
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

        if !match.controls.isEmpty {
            let contamOrganisms = rows.filter(\.isContaminationRisk)
            report += "\n--- Contamination Risk Organisms ---\n\n"
            if contamOrganisms.isEmpty {
                if !match.hasUncheckedControl {
                    report += "  No organisms detected in negative controls.\n"
                } else if match.controls.contains(where: { $0.state == .found || $0.state == .noOrganisms }) {
                    report += "  No organisms detected in the negative controls that ran.\n"
                }
            } else {
                for row in contamOrganisms {
                    let samples = row.perSampleTASS.keys.sorted().joined(separator: ", ")
                    report += "  \(row.organism) (detected in: \(samples))\n"
                }
            }
            if match.hasUncheckedControl {
                report += "  \(uncheckedWords(of: match))\n"
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

    /// The word an export shows where the import did not record a value (BIO ruling BIO-IMPORT-BATCH, item 3).
    public static let notRecorded = "Not recorded"

    /// The word an export shows for Contamination Risk where a negative control never ran or cannot be found, so
    /// the organism may be in it (lane TTBUILDDB, row TAXTRIAGE-FAILED-CONTROL-READS-CLEAN).
    public static let notChecked = "Not checked"

    /// A control as the `Negative Controls:` line names it, with what the result says about it.
    private static func controlLabel(_ control: TaxTriageControlMatch.Control) -> String {
        var remarks: [String] = []
        if control.isRenamed { remarks.append("named \(control.resultsName) in the results") }
        switch control.state {
        case .found: break
        case .noOrganisms: remarks.append("no organisms listed")
        case .failed: remarks.append("failed, never ran")
        case .notFound: remarks.append("not found in the results")
        }
        return remarks.isEmpty ? control.sampleId : "\(control.sampleId) (\(remarks.joined(separator: ", ")))"
    }

    /// The words that take the place of `No organisms detected in negative controls.` where a control never ran or
    /// cannot be found. They say what is unknown and what to do (BIO reviews them).
    private static func uncheckedWords(of match: TaxTriageControlMatch) -> String {
        let partly = match.controls.contains { $0.state == .found || $0.state == .noOrganisms }
        var sentences = [partly ? "Contamination risk is only partly checked." : "Contamination risk is not checked."]
        let failed = match.failedControls.map(\.sampleId)
        if !failed.isEmpty {
            sentences.append(failed.count == 1
                ? "The negative control \(failed[0]) failed, so it was never classified."
                : "The negative controls \(TaxTriageControlMatch.listing(failed)) failed, so they were never classified.")
            sentences.append(
                "Run \(failed.count == 1 ? "it" : "them") again, or check \(failed.count == 1 ? "it" : "them") "
                    + "another way, before you rely on these results."
            )
        }
        let missing = match.notFoundControls
        if !missing.isEmpty {
            let names = missing.map { $0.isRenamed ? "\($0.sampleId) (named \($0.resultsName) in the results)" : $0.sampleId }
            sentences.append(
                "The results hold no organisms for the negative control\(missing.count == 1 ? "" : "s") "
                    + "\(TaxTriageControlMatch.listing(names)), but they hold samples that the run does not list "
                    + "(\(match.unlistedSampleIds.joined(separator: ", "))), so Lungfish cannot tell whether "
                    + "\(missing.count == 1 ? "its" : "their") organisms are among them."
            )
            sentences.append("Look in the control's own results before you rely on these results.")
        }
        return sentences.joined(separator: " ")
    }

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

}
