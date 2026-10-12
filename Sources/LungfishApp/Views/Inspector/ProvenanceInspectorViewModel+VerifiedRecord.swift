// ProvenanceInspectorViewModel+VerifiedRecord.swift - Whether a record a native loader verified stated its status
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

extension VerifiedProvenanceRecord {
    /// Whether the record stated how its run ended (Phase 2.8 decision P3).
    ///
    /// A loader that decoded the record from its bytes may say. Otherwise the sidecar's own text decides,
    /// read the way the lookup reads a record it finds, so a canonical envelope that holds no `status` key
    /// reads Not recorded here as it does there. A sidecar that cannot be read counts as stating its status,
    /// as a canonical envelope does. Reading writes nothing.
    var statesItsStatus: Bool {
        if let statusWasRecorded { return statusWasRecorded }
        guard let data = try? Data(contentsOf: sidecarURL),
              let reading = try? ProvenanceEnvelopeReader.read(data) else { return true }
        return reading.statusWasRecorded
    }
}

extension ProvenanceInspectorViewModel {
    /// Sets the Run Status row of a record a native loader verified.
    ///
    /// Such a record has no reading, so `applyRunStatus` counts it as stating its status. When the record
    /// did not state one, the envelope holds the word the decoder derived from the exit status, which cannot
    /// tell a completed run from a cancelled one, so the row reads Not recorded and never shows that word.
    /// A record the lookup found passes nil and keeps the row its reading gave it.
    func applyVerifiedRunStatus(_ statusWasRecorded: Bool?, to envelope: ProvenanceEnvelope) {
        guard let statusWasRecorded else { return }
        summary.runStatus = ProvenanceRunStatusDisplay(envelope.status, wasRecorded: statusWasRecorded)
    }
}
