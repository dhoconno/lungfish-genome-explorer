// ProvenanceInspectorViewModel+RunStatus.swift - The Run Summary and the Run Status row of the Provenance tab
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

struct ProvenanceRunSummary: Equatable {
    var workflowName: String = "No Provenance"
    var workflowVersion: String = ""
    var toolName: String = ""
    var toolVersion: String = ""
    var createdAt: Date?
    var schemaVersion: Int?
    var runID: UUID?
    /// The sidecar's recorded path, for the copy text, help and accessibility.
    var sidecarPath: String?
    /// The sidecar's path relative to the project it lies in, for display.
    var sidecarDisplayPath: String?
    var statusLabel: String = "No provenance required"
    /// How the run ended, as the Run Status row reads it. Nil when the tab shows no record.
    var runStatus: ProvenanceRunStatusDisplay?
    var exitStatus: Int?
    var wallTimeSeconds: TimeInterval?
    /// A date the reader invented, or an exit status or wall time the record lacks, reads Not
    /// recorded in its row instead of the row being left out.
    var createdAtNotRecorded = false
    var exitStatusNotRecorded = false
    var wallTimeNotRecorded = false
    var stepCount: Int = 0
    var inputCount: Int = 0
    var outputCount: Int = 0
    var signatureCount: Int = 0
}

/// How the Run Status row of the Run Summary reads (plan decision P14).
///
/// The coverage audit counts missing facts only, so a failed or cancelled run whose record holds every
/// fact reads Complete. The row says how the run ended. It reads the record's own `status`. When the
/// record states none, the reader derived one from the exit status, which cannot tell a completed run
/// from a cancelled one, so the row reads Not recorded and never shows the derived word.
enum ProvenanceRunStatusDisplay: Equatable, Sendable {
    /// The record states how the run ended.
    case stated(RunStatus)
    /// The record states no status.
    case notRecorded

    /// The status the reader returned, and whether the record stated it.
    init(_ status: RunStatus, wasRecorded: Bool) {
        self = wasRecorded ? .stated(status) : .notRecorded
    }

    /// The words the row, the Copy text and VoiceOver use. A record that states `running` was written
    /// before its run ended and nothing updated it since, so the run did not finish as far as it knows.
    var label: String {
        switch self {
        case .stated(.completed): return "Completed"
        case .stated(.failed): return "Failed"
        case .stated(.cancelled): return "Cancelled"
        case .stated(.running): return "Not finished"
        case .notRecorded: return "Not recorded"
        }
    }
}

extension ProvenanceInspectorViewModel {
    /// Sets the Run Status row from how the reader read the record's `status`.
    ///
    /// A record that a native loader verified has no reading. It is a canonical envelope, and a canonical
    /// envelope states its status.
    func applyRunStatus(_ reading: ProvenanceEnvelopeReader.Reading?, to envelope: ProvenanceEnvelope) {
        summary.runStatus = ProvenanceRunStatusDisplay(envelope.status, wasRecorded: reading?.statusWasRecorded ?? true)
    }

    /// `rows` without the Process ID row, when the record cannot hold a process ID.
    ///
    /// A record at version 2 or later never holds one, because the encoder drops it (plan decision V5 of
    /// Phase 2.6), so the row could only read Not recorded. A record that does hold one keeps its row,
    /// because the tab shows every fact a record holds. A bare run has no version of its own and the reader
    /// builds its envelope at the current one, so for that shape the version says nothing about the bytes
    /// and the row stays, as it does in the other older formats.
    static func withoutUnrecordedProcessID(
        _ rows: [ProvenanceRuntimeRow],
        in envelope: ProvenanceEnvelope,
        reading: ProvenanceEnvelopeReader.Reading?
    ) -> [ProvenanceRuntimeRow] {
        let statesItsVersion = reading?.shape != .workflowRun
        guard statesItsVersion, envelope.schemaVersion >= 2, envelope.runtimeIdentity.processIdentifier == nil else {
            return rows
        }
        return rows.filter { $0.label != "Process ID" }
    }
}
