// ProvenanceInspectorViewModel+RunTimes.swift - The time rows of the Run Summary and the Linux run an adopted record holds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// The Linux run that an adopted record holds, for the Run Summary's time rows (walk WO-5, UX-WALK row WO-5).
///
/// The record's own wall time times only the Mac's write of the record, a fraction of a second, so an adopted run does
/// not show it. The Linux run is the `lungfish-executor run` step, whose wall time the adopt copies from the run
/// record's `wallSeconds`. A summary that read the record's time alone said `Wall Time <1s` for a run that took
/// minutes. A record is an adopted run when it holds that step. The quality-count step of the same record also runs the
/// `lungfish-executor` binary, under the tool name `lungfish-executor`, and is not the run.
struct ProvenanceLinuxRun: Equatable, Sendable {
    /// The tool name of the executor's step. `ExecutorRunAdoption.executorToolName` in LungfishWorkflow sets it and keeps
    /// it to itself, so the adopted record in `Tests/Fixtures/provenance-adopted-run` pins this copy.
    static let executorStepToolName = "lungfish-executor run"

    /// The wall time the executor's step records, or nil when the launcher's record lost it.
    var wallTimeSeconds: TimeInterval?

    /// The run an adopted record holds, or nil for a record that is not an adopted run.
    init?(_ envelope: ProvenanceEnvelope) {
        guard let step = envelope.steps.first(where: { $0.toolName == Self.executorStepToolName }) else { return nil }
        wallTimeSeconds = step.wallTimeSeconds
    }
}

/// One row of the Run Summary, a label and the words of its value.
struct ProvenanceSummaryRow: Identifiable, Equatable, Sendable {
    var id: String { label }
    var label: String
    var value: String
}

extension ProvenanceRunSummary {
    /// The label of an adopted run's own wall time, from the launcher's record of the Linux run.
    static let linuxRunTimeLabel = "Wall Time (Linux run)"

    /// The time rows of the Run Summary in screen order, for the tab and the Copy text alike. `format` writes a duration.
    ///
    /// A record that is not an adopted run reads Wall Time, or Not recorded when the record lacks it, or no row when
    /// nothing marks it missing. An adopted run reads the Linux run's time alone, Not recorded when the launcher's record
    /// lost it.
    func timeRows(format: (TimeInterval) -> String) -> [ProvenanceSummaryRow] {
        let recordedTime: String?
        if let wallTimeSeconds {
            recordedTime = format(wallTimeSeconds)
        } else {
            recordedTime = wallTimeNotRecorded ? "Not recorded" : nil
        }
        guard let linuxRun else {
            return recordedTime.map { [ProvenanceSummaryRow(label: "Wall Time", value: $0)] } ?? []
        }
        return [ProvenanceSummaryRow(label: Self.linuxRunTimeLabel, value: linuxRun.wallTimeSeconds.map(format) ?? "Not recorded")]
    }
}

extension ProvenanceInspectorViewModel {
    /// The Run Summary rows of the Copy text, in the order of the tab. The times read in seconds, as they always did.
    var runSummaryCopyRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Workflow", summary.workflowName),
            ("Workflow Version", summary.workflowVersion),
            ("Tool", toolText),
            ("Step Tools", stepToolsText ?? ""),
            ("Created", summary.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? (summary.createdAtNotRecorded ? "Not recorded" : "")),
            ("Run Status", summary.runStatus?.label ?? ""),
            ("Exit Status", summary.exitStatus.map(String.init) ?? (summary.exitStatusNotRecorded ? "Not recorded" : "")),
        ]
        rows += summary.timeRows { "\(String(format: "%.2f", $0)) s" }.map { ($0.label, $0.value) }
        rows += [
            ("Steps", "\(summary.stepCount)"),
            ("Inputs", "\(summary.inputCount)"),
            ("Outputs", "\(summary.outputCount)"),
            ("Sidecar", summary.sidecarDisplayPath ?? summary.sidecarPath ?? ""),
        ]
        return rows
    }
}
