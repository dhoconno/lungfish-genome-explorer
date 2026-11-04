// TaxTriageProvenanceRows.swift - The rows the TaxTriage provenance popover and summary bar show
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTIMPORT, row IMPORT-TAXTRIAGE-BATCH-HIDDEN, UX-IMPORT-BATCH item 4 widened by BIO-IMPORT-BATCH
// item 4. A TaxTriage import whose record lists no samples could not read the run's own record, so its config and
// its runtime are the importer's defaults. The popover and the summary bar read Not recorded for the run's facts in
// that case and keep the counts of the folder (the report and metrics files), which are true.

import Foundation
import LungfishWorkflow

enum TaxTriageProvenanceRows {
    /// One label and value of the popover.
    struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// The word shown where the import did not record the run's value.
    static let notRecorded = TaxTriageBatchExporter.notRecorded

    /// The counts and run facts the popover opens with. With no samples recorded the run's facts read Not recorded.
    static func runRows(result: TaxTriageResult, config: TaxTriageConfig) -> [Row] {
        let recorded = !config.samples.isEmpty
        return [
            Row(label: "Samples", value: shown(recorded, "\(config.samples.count)")),
            Row(label: "Platform", value: shown(recorded, config.platform.displayName)),
            Row(label: "Runtime", value: shown(recorded, String(format: "%.1f seconds", result.runtime))),
            Row(label: "Exit Code", value: shown(recorded, "\(result.exitCode)")),
            Row(label: "Reports", value: "\(result.reportFiles.count)"),
            Row(label: "Metrics Files", value: "\(result.metricsFiles.count)"),
        ]
    }

    /// The pipeline settings the popover shows below the counts. With no samples recorded they read Not recorded.
    static func settingRows(config: TaxTriageConfig) -> [Row] {
        let recorded = !config.samples.isEmpty
        return [
            Row(label: "Classifiers", value: shown(recorded, config.classifiers.joined(separator: ", "))),
            Row(label: "K2 Confidence", value: shown(recorded, String(format: "%.2f", config.k2Confidence))),
            Row(label: "Top Hits", value: shown(recorded, "\(config.topHitsCount)")),
            Row(label: "Skip Assembly", value: shown(recorded, config.skipAssembly ? "Yes" : "No")),
            Row(label: "Max CPUs", value: shown(recorded, "\(config.maxCpus)")),
            Row(label: "Max Memory", value: shown(recorded, config.maxMemory)),
        ]
    }

    /// The summary bar's Samples card, where nil reads Not recorded. A result with no sidecar keeps the card's
    /// earlier value of one sample.
    static func summarySampleCount(_ result: TaxTriageResult?) -> Int? {
        guard let result else { return 1 }
        return result.config.samples.isEmpty ? nil : result.config.samples.count
    }

    /// The summary bar's Runtime card, where nil reads Not recorded. A result with no sidecar keeps the card's
    /// earlier value of zero.
    static func summaryRuntime(_ result: TaxTriageResult?) -> TimeInterval? {
        guard let result else { return 0 }
        return result.config.samples.isEmpty ? nil : result.runtime
    }

    private static func shown(_ recorded: Bool, _ value: @autoclosure () -> String) -> String {
        recorded ? value() : notRecorded
    }
}
