// MappingDocumentStepRow.swift - One command of a mapping run as a disclosure row of Run Settings
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// A Run Settings step row on the Document tab: the invocation's label, a
/// disclosure control and the command.
///
/// Collapsed, the command reads in up to three middle-truncated lines that
/// cannot be selected, because selecting truncated text drew the whole
/// command over the rows below. Expanded, the whole command wraps inside the
/// row, which grows, and can be selected. No line break is inserted, so the
/// shown text and a partial selection hold the same single-line command.
/// Commands are code, so they read in the monospaced Inspector font, which
/// follows View > Content Text Size.
struct MappingDocumentStepRow: View {
    /// The width of the trailing label column, which the context rows share.
    static let labelWidth: CGFloat = 92
    /// The gap between the label column and the value column.
    static let columnSpacing: CGFloat = 8

    let step: MappingDocumentStep
    /// The row's position among the steps, counting from 1, which names its
    /// identifiers.
    let number: Int
    @Binding var isExpanded: Bool

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
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(step.label)
        .accessibilityIdentifier("mapping-step-\(number)")
    }

    /// A plain focusable button. Right Arrow expands, Left Arrow collapses
    /// and Return toggles through ``ProvenanceDisclosureKeyCommand``, and
    /// Space reaches the button itself, as on the Provenance tab.
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
            Text(step.command)
                .font(commandFont)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Command")
                .accessibilityValue(step.command)
                .accessibilityIdentifier("mapping-step-\(number)-command")
        } else {
            Text(step.command)
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
