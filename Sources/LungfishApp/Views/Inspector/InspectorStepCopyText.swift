// InspectorStepCopyText.swift - The plain text the Inspector's step copy commands write
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The text Copy Step and Copy All Steps put on the clipboard.
///
/// It is plain text with `\n` line ends and no trailing newline. The first
/// line is the step's title as its surface names it, and each line after it
/// is one `Label: value` fact the surface shows for that step, in display and
/// VoiceOver order. A fact the record does not hold is left out, never
/// filled, and the command is always whole, never truncated or re-wrapped.
/// The text records what ran. Copy Command is the route into a terminal.
enum InspectorStepCopyText {
    /// Copy Step on the Document tab: the step's label with the run's
    /// version for its tool, the Recorded row's text, then the whole command.
    static func mappingStep(_ step: MappingDocumentStep) -> String {
        var lines = [title(step.label, version: step.version)]
        if !step.recorded.isEmpty {
            lines.append("Recorded: \(step.recorded)")
        }
        if !step.command.isEmpty {
            lines.append("Command: \(step.command)")
        }
        return lines.joined(separator: "\n")
    }

    /// Copy All Steps on the Document tab.
    static func mappingSteps(_ steps: [MappingDocumentStep]) -> String {
        allSteps(steps.map(mappingStep))
    }

    /// Copy All Steps on either tab: the Copy Step text of every step of the
    /// run in row order, joined by one blank line, so it always equals what
    /// copying each step in turn gives.
    static func allSteps(_ stepTexts: [String]) -> String {
        stepTexts.joined(separator: "\n\n")
    }

    /// `text` without the line ends it finishes with, which a recorded stderr carries.
    static func withoutTrailingNewlines(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isNewline {
            end = text.index(before: end)
        }
        return String(text[..<end])
    }

    /// `<label> <version>` with trailing white space trimmed, which is the
    /// label alone when the record holds no version for the tool.
    static func title(_ label: String, version: String?) -> String {
        let line = version.map { "\(label) \($0)" } ?? label
        var end = line.endIndex
        while end > line.startIndex, line[line.index(before: end)].isWhitespace {
            end = line.index(before: end)
        }
        return String(line[..<end])
    }
}
