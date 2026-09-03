// MSASequenceScopePicker.swift - "Sequences to align" scope selector
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// Whether an alignment run covers every sequence in the source file or only
/// the sequences the user selected in the viewport.
public enum MSASequenceScope: String, CaseIterable, Sendable {
    case all
    case selected
}

/// A two-row radio group offering "all" versus "selected" for a MAFFT run.
///
/// Modelled on ``MultiBundleRunModePicker`` but with one deliberate
/// difference: there is no locked-row concept. A row the user can never enable
/// is noise, so either both scopes are real choices and the picker renders, or
/// it is replaced by a single line of text stating what will happen.
public struct MSASequenceScopePicker: View {
    let allCount: Int
    let selectedCount: Int
    @Binding var selection: MSASequenceScope

    public init(allCount: Int, selectedCount: Int, selection: Binding<MSASequenceScope>) {
        self.allCount = allCount
        self.selectedCount = selectedCount
        self._selection = selection
    }

    /// Visible only when both scopes are meaningful and different: a known
    /// total, a non-empty selection, and a selection smaller than the total.
    public nonisolated static func isVisible(allCount: Int, selectedCount: Int) -> Bool {
        allCount > 0 && selectedCount > 0 && selectedCount < allCount
    }

    /// Pure, testable description of one radio row.
    public struct RowState: Equatable, Sendable {
        public let scope: MSASequenceScope
        public let title: String
        public let caption: String

        public init(scope: MSASequenceScope, title: String, caption: String) {
            self.scope = scope
            self.title = title
            self.caption = caption
        }
    }

    public nonisolated static func rowStates(allCount: Int, selectedCount: Int) -> [RowState] {
        [
            RowState(
                scope: .all,
                title: "All sequences (\(allCount))",
                caption: "Every sequence in the source file."
            ),
            RowState(
                scope: .selected,
                title: "Selected sequences (\(selectedCount))",
                caption: "Only the sequences selected in the viewport."
            ),
        ]
    }

    /// Shown in place of the picker when there is no choice to make.
    public nonisolated static func summaryText(allCount: Int, selectedCount: Int) -> String {
        if selectedCount > 0 && (allCount == 0 || selectedCount == allCount) {
            return "Aligning the \(selectedCount) sequences you selected."
        }
        return "Aligning all \(allCount) sequences."
    }

    public var body: some View {
        if Self.isVisible(allCount: allCount, selectedCount: selectedCount) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sequences to align")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.lungfishSecondaryText)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.rowStates(allCount: allCount, selectedCount: selectedCount), id: \.scope) { row in
                        Button {
                            selection = row.scope
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: selection == row.scope ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(Color.lungfishOrangeFallback)
                                    .imageScale(.medium)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.primary)
                                    Text(row.caption)
                                        .font(.caption)
                                        .foregroundStyle(Color.lungfishSecondaryText)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mafft-sequence-scope-\(row.scope.rawValue)")
                        .accessibilityAddTraits(selection == row.scope ? .isSelected : [])
                    }
                }
            }
        } else {
            Text(Self.summaryText(allCount: allCount, selectedCount: selectedCount))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("mafft-sequence-scope-summary")
        }
    }
}
