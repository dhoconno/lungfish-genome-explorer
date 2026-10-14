// ProvenanceInspectorViewModel+VerifiedRecord.swift - Whether a record a native loader verified stated its status
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

extension VerifiedProvenanceRecord {
    /// Whether the record stated how its run ended (Phase 2.8 decision P3).
    ///
    /// The loader that decoded the record from its verified bytes, off the main actor, says. A canonical
    /// envelope that holds no `status` key then reads Not recorded here as it does in a lookup. This reads
    /// nothing, where it once read the sidecar for each presentation (Phase 2.10 lane U35). A record whose
    /// loader said nothing counts as stating its status, as a canonical envelope does.
    var statesItsStatus: Bool {
        statusWasRecorded ?? true
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
