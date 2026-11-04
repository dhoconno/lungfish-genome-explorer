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
    ///   - metrics: The parsed metrics of the samples the export was asked for.
    ///   - sampleIds: Ordered sample identifiers.
    ///   - negativeControlSampleIds: Sample IDs marked as negative controls.
    ///   - controlMetrics: Every row of the negative controls across all samples, whatever the selection. An organism
    ///     a control holds is a contamination risk even when the selection leaves the control out (lane TTCONTROLS).
    ///   - controlsNotRecorded: True when the result does not say which samples were controls, so the Contamination
    ///     Risk column reads Not recorded instead of Yes or No.
    ///   - controlsNotChecked: True when a control never ran or cannot be found, so an organism that no control
    ///     that ran holds reads Not checked instead of No.
    /// - Returns: CSV string.
    public static func generateOrganismMatrixCSV(
        metrics: [TaxTriageMetric],
        sampleIds: [String],
        negativeControlSampleIds: Set<String> = [],
        controlMetrics: [TaxTriageMetric] = [],
        controlsNotRecorded: Bool = false,
        controlsNotChecked: Bool = false
    ) -> String {
        let rows = buildCrossSampleData(
            metrics: metrics,
            sampleIds: sampleIds,
            negativeControlSampleIds: negativeControlSampleIds,
            controlMetrics: controlMetrics
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
    ///   - metrics: The parsed metrics of the samples the export was asked for.
    ///   - sampleIds: Ordered sample identifiers.
    ///   - controlMetrics: Every row of the negative controls across all samples, whatever the selection, so the
    ///     contamination section names what a control holds even when the selection leaves the control out.
    /// - Returns: Plain text report string.
    public static func generateSummaryReport(
        result: TaxTriageResult,
        config: TaxTriageConfig,
        metrics: [TaxTriageMetric],
        sampleIds: [String],
        controlMetrics: [TaxTriageMetric] = []
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
            negativeControlSampleIds: negControlIds,
            controlMetrics: controlMetrics
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
            let heldByControlsOnly = organismsOnlyControlsHold(beside: rows, controlMetrics: controlMetrics)
            report += "\n--- Contamination Risk Organisms ---\n\n"
            if contamOrganisms.isEmpty && heldByControlsOnly.isEmpty {
                if !match.hasUncheckedControl {
                    report += "  No organisms detected in negative controls.\n"
                } else if match.controls.contains(where: { $0.state == .found || $0.state == .noOrganisms }) {
                    report += "  No organisms detected in the negative controls that ran.\n"
                }
            } else {
                for row in contamOrganisms {
                    report += "  \(row.organism) (detected in: \(row.detectedIn.joined(separator: ", ")))\n"
                }
                for (organism, samples) in heldByControlsOnly {
                    report += "  \(organism) (detected in: \(samples.joined(separator: ", ")))\n"
                }
            }
            if let words = match.uncheckedWords {
                report += "  \(words)\n"
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
        case .failed: remarks.append("failed, no result")
        case .notFound: remarks.append("not found in the results")
        }
        return remarks.isEmpty ? control.sampleId : "\(control.sampleId) (\(remarks.joined(separator: ", ")))"
    }

    /// Builds cross-sample organism data.
    private struct CrossSampleData {
        let organism: String
        let sampleCount: Int
        let meanTASS: Double
        let perSampleTASS: [String: Double]
        let isContaminationRisk: Bool
        /// The samples that hold the organism, the ones the export was asked for and the controls that hold it.
        let detectedIn: [String]
    }

    /// The key two spellings of one organism share, as the viewer's flat table and the results export match a control's
    /// organisms (`OrganismNameNormalizer`).
    private static func controlKey(_ organism: String) -> String {
        OrganismNameNormalizer.normalizedKey(organism)
    }

    /// The samples of `controlMetrics` that hold each organism, by ``controlKey(_:)``.
    private static func controlSamplesByOrganism(_ controlMetrics: [TaxTriageMetric]) -> [String: Set<String>] {
        var held: [String: Set<String>] = [:]
        for metric in controlMetrics {
            held[controlKey(metric.organism), default: []].formUnion(metric.sample.map { [$0] } ?? [])
        }
        return held
    }

    /// The organisms a control holds that no row of `rows` names, with the control samples that hold them, in name
    /// order. The report lists them too, since its words are about the controls and not about the selection.
    private static func organismsOnlyControlsHold(
        beside rows: [CrossSampleData],
        controlMetrics: [TaxTriageMetric]
    ) -> [(String, [String])] {
        let shown = Set(rows.map { controlKey($0.organism) })
        var names: [String: String] = [:]
        for metric in controlMetrics where !shown.contains(controlKey(metric.organism)) {
            names[controlKey(metric.organism)] = metric.organism
        }
        let held = controlSamplesByOrganism(controlMetrics)
        return names.keys.sorted().map { (names[$0] ?? $0, (held[$0] ?? []).sorted()) }
    }

    private static func buildCrossSampleData(
        metrics: [TaxTriageMetric],
        sampleIds: [String],
        negativeControlSampleIds: Set<String>,
        controlMetrics: [TaxTriageMetric] = []
    ) -> [CrossSampleData] {
        let heldByControls = controlSamplesByOrganism(controlMetrics)
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

            // A control holds the organism whichever samples the export was asked for.
            let controlSamples = group.reduce(into: Set<String>()) { $0.formUnion(heldByControls[controlKey($1.organism)] ?? []) }
            let inNegativeControl = (!negativeControlSampleIds.isEmpty
                && !detectedSamples.intersection(negativeControlSampleIds).isEmpty)
                || !controlSamples.isEmpty

            rows.append(CrossSampleData(
                organism: first.organism,
                sampleCount: detectedSamples.count,
                meanTASS: meanTASS,
                perSampleTASS: perSample,
                isContaminationRisk: inNegativeControl,
                detectedIn: detectedSamples.union(controlSamples).sorted()
            ))
        }

        return rows.sorted {
            if $0.sampleCount != $1.sampleCount { return $0.sampleCount > $1.sampleCount }
            return $0.meanTASS > $1.meanTASS
        }
    }

}
