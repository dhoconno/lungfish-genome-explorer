// ProvenanceSection+AppStep.swift - The note beside the Command row of a step that ran inside the app
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishWorkflow
import SwiftUI

/// The words and the identifier of the note under the Command row of a step that ran inside the app (V1-7, R3).
enum ProvenanceAppStepNote {
    static let words = "This step ran inside the app and has no command to run in Terminal."
    static let identifier = "provenance-step-command-app-step-note"
}

extension ProvenanceLineageStep {
    /// Whether the step ran inside the app, so that its recorded words are no command for a Terminal. The step holds
    /// its command as text and no argv, so the words are read back into an argv and given to
    /// ``ProvenanceAppStep/isAppStep(_:)``, the predicate the exporter uses. Words that do not parse are no app
    /// step, and the step keeps its Copy Command.
    var ranInsideTheApp: Bool {
        guard !command.isEmpty, let argv = try? AdvancedCommandLineOptions.parse(command) else { return false }
        return ProvenanceAppStep.isAppStep(argv)
    }

    /// The note under the step's Command row, or nil for a step with a command to run.
    var appStepNote: String? { ranInsideTheApp ? ProvenanceAppStepNote.words : nil }
}

extension ProvenanceSection {
    /// The note under the Command row of a step that ran inside the app, or nothing for any other step. It is secondary
    /// text with the same words as its tooltip, in the form of the rename note. It stays out of Copy Step and Copy All
    /// Steps, and it follows the Command row, so VoiceOver reads it after the row.
    @ViewBuilder
    func appStepNoteRow(of step: ProvenanceLineageStep) -> some View {
        if let note = step.appStepNote {
            Text(note)
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, usesGenotypePresentation ? 0 : 104)
                .help(note)
                .accessibilityIdentifier(ProvenanceAppStepNote.identifier)
        }
    }
}
