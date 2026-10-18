// ProvenanceInspectorViewModel+StepCopy.swift - Copy Step, Copy Command and Copy All Steps of a Lineage step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

extension ProvenanceInspectorViewModel {
    /// Copy Step on the Provenance tab: the step's title line, then its lines in the order its disclosure shows them
    /// and VoiceOver reads them. The header's Copy text writes every step through this function, so a step copied
    /// alone equals its block there.
    func stepCopyText(of step: ProvenanceLineageStep) -> String {
        var lines = ["\(step.ordinal). \(step.toolName) \(step.toolVersion)".trimmingCharacters(in: .whitespaces)]
        appendStepLines(of: step, to: &lines)
        return lines.joined(separator: "\n")
    }

    /// Copy All Steps on the Provenance tab: every step of `run` in row order, joined by one blank line.
    func allStepsCopyText(of run: ProvenanceLineageRun) -> String {
        InspectorStepCopyText.allSteps(run.steps.map { stepCopyText(of: $0) })
    }

    /// The commands a Lineage step's label and Command row offer, in the context menu and, under the same titles and
    /// in the same order, as VoiceOver actions. Copy Command copies the recorded command whole, not the shortened
    /// form the row shows.
    func stepCopyActions(_ step: ProvenanceLineageStep, in run: ProvenanceLineageRun) -> [ContextAction] {
        [
            .command("Copy Step") { self.writeStepCopy(self.stepCopyText(of: step)) },
            .command("Copy Command", isEnabled: !step.command.isEmpty) { self.writeStepCopy(step.command) },
            .divider(),
            .command("Copy All Steps") { self.writeStepCopy(self.allStepsCopyText(of: run)) },
        ]
    }

    private func writeStepCopy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

extension View {
    /// A Lineage step's copy commands, with the Copy Step text that Command-C copies while the view has focus, or
    /// nothing for a row without them, such as a run.
    @ViewBuilder
    func lineageStepCopy(text: String?, actions: [ContextAction]) -> some View {
        if let text {
            contextActions(actions).copyable([text])
        } else {
            self
        }
    }
}
