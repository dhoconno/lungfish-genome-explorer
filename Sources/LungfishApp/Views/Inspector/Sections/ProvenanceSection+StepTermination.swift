// ProvenanceSection+StepTermination.swift - The rows a step's observation adds to its disclosure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

extension ProvenanceSection {
    /// One row of a step's disclosure that its observation adds, or nothing when the row does not show.
    ///
    /// The disclosure draws Environment after the Command, Termination after Exit Status and Output after Wall
    /// Time. The Copy text lists the same lines in the same order (`appendStepLines(of:to:)`), and the order the
    /// rows are drawn in is the order VoiceOver reads them. Each value carries its own accessibility identifier
    /// beside `provenance-step-command`.
    @ViewBuilder
    func stepObservationRow(_ line: ProvenanceStepTerminationDisplay.Line, of step: ProvenanceLineageStep) -> some View {
        if let text = step.observation?.text(of: line) {
            summaryRow(line.label, value: text, accessibilityIdentifier: line.identifier)
        }
    }
}
