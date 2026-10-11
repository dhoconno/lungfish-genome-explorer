// ProvenanceInspectorViewModel+RunStatus.swift - The Run Summary the Provenance tab shows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

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
