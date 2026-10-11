// ProvenanceInspectorViewModel+RecordShape.swift - The Older record format and the facts a record's shape never held
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// How the Provenance tab reads a record by the shape the tolerant reader decoded it as (plan
/// decisions V6 and S4).
///
/// A record that decodes as a bare `WorkflowRun` or through the primitive adapter is in the Older
/// record format. An envelope of any schema version is never, and neither is a typed record such as
/// `mapping-provenance.json`, which the finder converts through its own type. The label never hides
/// a gap. A fact the shape never held reads Not recorded and does not make the record Incomplete,
/// and a fact the shape could hold and lacks still does.
struct ProvenanceRecordShapeRule: Equatable, Sendable {
    static let olderRecordFormatTitle = "Older record format"
    static let olderRecordFormatMessage = "This record was written in an older format. "
        + "It shows every fact it holds, and a fact that format never recorded reads Not recorded."

    /// The sentence `ProvenanceCompleteness` gives a record that states no exit status.
    private static let missingExitStatusSentence = "Exit status is missing."

    /// The shape that decoded the record, or nil for a record a native bundle loader verified.
    let shape: ProvenanceEnvelopeReader.RecordShape?

    init(_ reading: ProvenanceEnvelopeReader.Reading?) {
        shape = reading?.shape
    }

    var isOlderRecordFormat: Bool {
        shape == .workflowRun || shape == .primitive
    }

    /// Whether a missing exit status is a fact the shape never held. A bare run derives one from its
    /// status, so only the primitive records, which early writers wrote at the end of an operation
    /// without stating how it ended, never held one.
    var neverHeldAnExitStatus: Bool {
        shape == .primitive
    }

    /// The gaps in `envelope` that count against the record. They are the sentences of
    /// `ProvenanceCompleteness`, less the one for a fact the shape never held.
    func issues(in envelope: ProvenanceEnvelope) -> [String] {
        ProvenanceCompleteness.issues(in: envelope).filter {
            !(neverHeldAnExitStatus && $0 == Self.missingExitStatusSentence)
        }
    }
}

extension ProvenanceAuditStatus {
    /// The status as the Provenance tab spells it.
    var displayName: String {
        switch self {
        case .notRequired: return "No provenance required"
        case .present: return "Complete"
        case .missing: return "Missing provenance"
        case .legacy: return ProvenanceRecordShapeRule.olderRecordFormatTitle
        case .invalid, .incomplete, .stale: return rawValue.capitalized
        }
    }
}

extension ProvenanceCoverageMonitor {
    /// The audit of a record that was found, by the shape it decoded as.
    ///
    /// An envelope or typed record is Complete or Incomplete by the completeness rule. A bare run or
    /// primitive record is the Older record format when nothing it could hold is missing, and is
    /// Incomplete when something is. The Older record format sentence then comes last, so the label
    /// never hides the gap.
    func recordAudit(
        _ resolved: (sidecarURL: URL, reading: ProvenanceEnvelopeReader.Reading),
        requirement: ProvenanceRequirement
    ) -> ProvenanceAuditResult {
        let rule = ProvenanceRecordShapeRule(resolved.reading)
        let issues = rule.issues(in: resolved.reading.envelope)
        let status: ProvenanceAuditStatus = issues.isEmpty ? (rule.isOlderRecordFormat ? .legacy : .present) : .incomplete
        return ProvenanceAuditResult(
            status: status,
            requirement: requirement,
            sidecarURL: resolved.sidecarURL,
            messages: issues + (rule.isOlderRecordFormat ? [ProvenanceRecordShapeRule.olderRecordFormatMessage] : []),
            isOlderRecordFormat: rule.isOlderRecordFormat
        )
    }
}

extension ProvenanceInspectorViewModel {
    /// Marks the Run Summary rows whose fact the record lacks, from how the reader read it.
    ///
    /// A date the reader invented, with the file's date or 1970, is not a fact the record holds, so
    /// the row reads Not recorded. So does an exit status or wall time the record lacks. The shape
    /// decides whether the record is Incomplete and never whether a row shows.
    func applyReading(_ reading: ProvenanceEnvelopeReader.Reading?, to envelope: ProvenanceEnvelope) {
        if reading?.createdAtWasInvented == true {
            summary.createdAt = nil
            summary.createdAtNotRecorded = true
        }
        summary.exitStatusNotRecorded = envelope.exitStatus == nil
        summary.wallTimeNotRecorded = envelope.wallTimeSeconds == nil
    }
}
