// MappingDocumentStepRow.swift - One command of a mapping run as a disclosure row of Run Settings
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// A Run Settings step row on the Document tab: the invocation's label, a
/// disclosure control, the command and a copy icon.
///
/// Collapsed, the command reads in up to three middle-truncated lines that
/// cannot be selected, because selecting truncated text drew the whole
/// command over the rows below. Expanded, the whole command wraps inside the
/// row, which grows, and can be selected. No line break is inserted, so the
/// shown text and a partial selection hold one single-line command. The row
/// shows each project path relative to the project and a tool under the
/// reader's tool root by its name, as the Provenance tab's Command row does.
/// Copy Command, Copy Step, the tooltip and VoiceOver give the whole command
/// with every path in full, so a pasted command runs outside the project.
/// Commands are code, so they read in the monospaced Inspector font, which
/// follows View > Content Text Size.
///
/// Copy Step runs from the copy icon, from the row's context menu, from the
/// same VoiceOver actions and from Command-C while the disclosure control
/// has focus. The menu and the actions also offer Copy Command and Copy All
/// Steps.
struct MappingDocumentStepRow: View {
    /// The width of the trailing label column, which the context rows share.
    static let labelWidth: CGFloat = 92
    /// The gap between the label column and the value column.
    static let columnSpacing: CGFloat = 8

    let step: MappingDocumentStep
    /// The command as the row shows it, project-relative
    /// (``MappingDocumentStateBuilder/shownCommands(of:projectURL:fileExists:toolRoot:)``).
    /// It is `step.command` until that form is built.
    let shownCommand: String
    /// The row's position among the steps, counting from 1, which names its
    /// identifiers.
    let number: Int
    @Binding var isExpanded: Bool
    /// The row's Copy Step text.
    let copyText: String
    /// Writes text to the section's pasteboard.
    let copy: (String) -> Void
    /// The Copy All Steps text of the row's run.
    let allStepsText: () -> String

    private var commandFont: Font { LungfishInspectorStyle.controlFont.monospaced() }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.columnSpacing) {
            Text(step.label)
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)
                .lineLimit(2)
                // The row itself carries the label.
                .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                disclosureControl
                command
                InspectorCopyButton(
                    help: "Copy this step",
                    accessibilityLabel: "Copy \(step.label) step",
                    identifier: "mapping-step-\(number)-copy"
                ) {
                    copy(copyText)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(step.label)
        .accessibilityIdentifier("mapping-step-\(number)")
        .contextActions(copyActions)
    }

    /// The row's commands, in the context menu and, under the same titles
    /// and in the same order, as its VoiceOver actions.
    private var copyActions: [ContextAction] {
        [
            .command("Copy Step") { copy(copyText) },
            .command("Copy Command", isEnabled: !step.command.isEmpty) { copy(step.command) },
            .divider(),
            .command("Copy All Steps") { copy(allStepsText()) },
        ]
    }

    /// A plain focusable button. Right Arrow expands, Left Arrow collapses
    /// and Return toggles through ``ProvenanceDisclosureKeyCommand``, and
    /// Space reaches the button itself, as on the Provenance tab. While it
    /// has focus, Edit > Copy copies the step.
    private var disclosureControl: some View {
        Button {
            isExpanded.toggle()
        } label: {
            // Both chevrons share one frame, so the command never shifts.
            ZStack {
                Image(systemName: "chevron.right").opacity(isExpanded ? 0 : 1)
                Image(systemName: "chevron.down").opacity(isExpanded ? 1 : 0)
            }
            .font(LungfishInspectorStyle.controlFont)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .onKeyPress(keys: [.rightArrow, .leftArrow, .return]) { press in
            guard let next = ProvenanceDisclosureKeyCommand.expansion(
                after: press.key,
                isExpanded: isExpanded
            ) else { return .ignored }
            isExpanded = next
            return .handled
        }
        .copyable([copyText])
        .accessibilityLabel("\(step.label) command")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides the full command.")
        .accessibilityIdentifier("mapping-step-\(number)-toggle")
        .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") {
            isExpanded.toggle()
        }
    }

    @ViewBuilder
    private var command: some View {
        if isExpanded {
            Text(shownCommand)
                .font(commandFont)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(ifPresent: shownCommand == step.command ? nil : step.command)
                .accessibilityLabel("Command")
                .accessibilityValue(step.command)
                .accessibilityIdentifier("mapping-step-\(number)-command")
        } else {
            Text(shownCommand)
                .font(commandFont)
                .lineLimit(3)
                .truncationMode(.middle)
                // Truncated text is never selectable, whatever an enclosing
                // view sets.
                .textSelection(.disabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { isExpanded = true }
                .help(step.command)
                .accessibilityLabel("Command")
                .accessibilityValue(step.command)
                .accessibilityIdentifier("mapping-step-\(number)-command")
        }
    }
}

/// A borderless copy button whose icon turns into a checkmark for one second
/// after a click, in the same frame so nothing moves, as the AI Assistant's
/// copy button does. The other copy routes give no feedback, and the button
/// makes no sound or announcement.
struct InspectorCopyButton: View {
    /// The visible title, or nil for an icon-only button.
    var title: String?
    let help: String
    let accessibilityLabel: String
    let identifier: String
    let action: () -> Void

    @State private var showsCheckmark = false
    @State private var clickCount = 0

    var body: some View {
        Button {
            action()
            showsCheckmark = true
            clickCount += 1
        } label: {
            if let title {
                Label {
                    Text(title)
                } icon: {
                    icon
                }
                .labelStyle(.titleAndIcon)
            } else {
                icon
            }
        }
        .buttonStyle(.borderless)
        .font(LungfishInspectorStyle.controlFont)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
        .task(id: clickCount) {
            guard clickCount > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            showsCheckmark = false
        }
    }

    /// Both symbols share one frame, so the swap moves nothing.
    private var icon: some View {
        ZStack {
            Image(systemName: "doc.on.doc").opacity(showsCheckmark ? 0 : 1)
            Image(systemName: "checkmark").opacity(showsCheckmark ? 1 : 0)
        }
    }
}

private extension View {
    /// A tooltip only when there is text for one, as the Provenance tab's rows set theirs.
    @ViewBuilder
    func help(ifPresent text: String?) -> some View {
        if let text {
            help(text)
        } else {
            self
        }
    }
}
