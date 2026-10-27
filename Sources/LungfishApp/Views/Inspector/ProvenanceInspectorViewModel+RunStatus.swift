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
    /// The Linux run an adopted record holds, whose time the summary reads beside the adopt's. Nil for a record that is
    /// not an adopted run, which reads Wall Time as it always did.
    var linuxRun: ProvenanceLinuxRun?
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

    /// `rows` without the Process ID row, when the record's format never holds a process ID.
    ///
    /// The format decides, not a version the reader may have filled in. A record in a current format that
    /// never holds a process ID shows no row, because the row could only read Not recorded. That means an
    /// envelope at version 2 or later, whose encoder drops the ID (plan decision V5 of Phase 2.6), and a
    /// typed record such as `mapping-provenance.json`, which never held one. It also means a version 1
    /// envelope that states its own status and holds no ID, which is the shape of the alignment and tree
    /// records of Phase 2.7 that hold `createdAt` (alignment export, discriminating sites, subtree export,
    /// derived trees and tree import, plan decision P13). A record that holds a process ID keeps its row,
    /// because the tab shows every fact a record holds. Any other version 1 envelope keeps its row,
    /// because that format could hold an ID and no earlier writer left it out of an envelope that states a
    /// status. An envelope that embeds a legacy run keeps its row too, since the run states the status and
    /// that writer recorded the process. A bare run and a primitive record keep theirs, because the Older
    /// record format shows every fact it lacks as Not recorded. Their version decides nothing, since the
    /// reader builds the envelope of a bare run at the current version and a primitive record can state
    /// version 2 itself.
    static func withoutUnrecordedProcessID(
        _ rows: [ProvenanceRuntimeRow],
        in envelope: ProvenanceEnvelope,
        reading: ProvenanceEnvelopeReader.Reading?
    ) -> [ProvenanceRuntimeRow] {
        let formatNeverHoldsOne: Bool
        switch reading?.shape {
        case .typedRecord?:
            formatNeverHoldsOne = true // a typed record never holds a process ID
        case .workflowRun?, .primitive?:
            formatNeverHoldsOne = false // the Older record format shows every fact it lacks as Not recorded
        case .envelope?:
            // The version 2 encoder drops the ID (2.6 V5). A version 1 envelope that states its own status is a
            // 2.7 native record (P13), and one that embeds a legacy run states it through the run instead.
            let statesItsOwnStatus = reading?.statusWasRecorded == true && envelope.legacyRun == nil
            formatNeverHoldsOne = envelope.schemaVersion >= 2 || statesItsOwnStatus
        case nil:
            formatNeverHoldsOne = envelope.schemaVersion >= 2 // a record a loader verified has no reading
        }
        guard formatNeverHoldsOne, envelope.runtimeIdentity.processIdentifier == nil else { return rows }
        return rows.filter { $0.label != "Process ID" }
    }
}
