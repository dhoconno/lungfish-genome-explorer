// ProvenanceInspectorViewModel+StepCopy.swift - Copy Step, Copy Command and Copy All Steps of a Lineage step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishWorkflow
import SwiftUI

/// A Lineage step's command after a rename moved a folder it names (R-B2). The record keeps the command as it ran,
/// which the Command row's tooltip and Copy Step still give.
struct ProvenanceRenamedCommand: Equatable, Sendable {
    /// The Command row's text, each moved path in its new folder and shortened as the row shortens any path.
    let label: String
    /// What Copy Command copies, the recorded command with each moved path in its new folder.
    let copyCommand: String
    /// The note beside the Command row, `This command ran in <old>. The row and Copy Command name <new>, where the
    /// record is now.` It reads the same after a rename and after the sidebar's Duplicate.
    let note: String
}

extension ProvenanceInspectorViewModel {
    /// Copy Step on the Provenance tab: the step's title line, then its lines in the order its disclosure shows them
    /// and VoiceOver reads them. The header's Copy text writes every step through this function, so a step copied
    /// alone equals its block there.
    func stepCopyText(of step: ProvenanceLineageStep) -> String {
        var lines = ["\(step.ordinal). \(step.toolName) \(step.toolVersion)".trimmingCharacters(in: .whitespaces)]
        appendStepLines(of: step, to: &lines)
        return lines.joined(separator: "\n")
    }

    /// A step's text for the clipboard. It is the step's block of the Copy text without the line ends a recorded stderr
    /// finishes with, so Copy Step ends without a newline and Copy All Steps joins by one blank line (Q-U2 rules 1 and 7).
    func stepClipboardText(of step: ProvenanceLineageStep) -> String {
        InspectorStepCopyText.withoutTrailingNewlines(stepCopyText(of: step))
    }

    /// Copy All Steps on the Provenance tab: every step of `run` in row order, joined by one blank line.
    func allStepsCopyText(of run: ProvenanceLineageRun) -> String {
        InspectorStepCopyText.allSteps(run.steps.map { stepClipboardText(of: $0) })
    }

    /// The commands a Lineage step's label and Command row offer, in the context menu and, under the same titles and
    /// in the same order, as VoiceOver actions. Copy Command copies the recorded command whole, not the shortened
    /// form the row shows, with each path a rename moved in its new folder when `renamed` says so (R-B2). Copy Step
    /// keeps the command as it ran. A step that ran inside the app has no command a Terminal can run, so its Copy
    /// Command is off in both places while Copy Step and Copy All Steps stay on (V1-7, R3).
    func stepCopyActions(
        _ step: ProvenanceLineageStep,
        in run: ProvenanceLineageRun,
        renamed: ProvenanceRenamedCommand? = nil
    ) -> [ContextAction] {
        [
            .command("Copy Step") { self.writeStepCopy(self.stepClipboardText(of: step)) },
            .command("Copy Command", isEnabled: !step.command.isEmpty && !step.ranInsideTheApp) {
                self.writeStepCopy(renamed?.copyCommand ?? step.command)
            },
            .divider(),
            .command("Copy All Steps") { self.writeStepCopy(self.allStepsCopyText(of: run)) },
        ]
    }

    /// The steps of the shown record whose command names a folder a rename moved, by step id. It is built off the main
    /// actor, because the Command row's shortening asks the file system whether each path exists (SWIFT 6).
    func renamedCommands() async -> [UUID: ProvenanceRenamedCommand] {
        guard let envelope = resolvedEnvelope, let recordURL = resolvedSidecarURL else { return [:] }
        return await Task.detached(priority: .userInitiated) {
            Self.renamedCommands(of: envelope, recordURL: recordURL)
        }.value
    }

    /// The renamed commands of `envelope`, read at `recordURL`. The record is only read, never written.
    nonisolated static func renamedCommands(
        of envelope: ProvenanceEnvelope,
        recordURL: URL
    ) -> [UUID: ProvenanceRenamedCommand] {
        let projectURL = PortablePath.anchors(for: recordURL).project
        let files = envelope.files + envelope.outputs + [envelope.output].compactMap { $0 }
            + envelope.steps.flatMap { $0.inputs + $0.outputs }
        let renames = ProvenanceCommandPresentation.folderRenames(
            commands: envelope.steps.map(\.reproducibleCommand),
            filePaths: files.map(\.path),
            recordURL: recordURL,
            projectURL: projectURL
        )
        guard let note = ProvenanceCommandPresentation.renameNote(renames, projectURL: projectURL) else { return [:] }
        // Read once for every step, here off the main actor (M875 TOOLROOT-ONCE).
        let toolRoot = PortablePath.defaultManagedRoots.toolRoot
        var commands: [UUID: ProvenanceRenamedCommand] = [:]
        for step in envelope.steps {
            let recorded = ProvenanceCommandPresentation.quotingProjectPath(step.reproducibleCommand, projectURL: projectURL)
            let copy = ProvenanceCommandPresentation.movingRenamedPaths(
                step.reproducibleCommand, renames: renames, projectURL: projectURL
            )
            guard copy != recorded else { continue }
            commands[step.id] = ProvenanceRenamedCommand(
                label: ProvenanceCommandPresentation.display(copy, projectURL: projectURL, toolRoot: toolRoot),
                copyCommand: copy,
                note: note
            )
        }
        return commands
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
