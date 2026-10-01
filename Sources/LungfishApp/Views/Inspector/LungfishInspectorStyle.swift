// LungfishInspectorStyle.swift - Shared SwiftUI Inspector typography and controls
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishKit

@MainActor
enum LungfishInspectorStyle {
    static var sectionTitleFont: Font { ContentTypographyModel.shared.font(for: .emphasizedBody) }
    static var controlFont: Font { ContentTypographyModel.shared.font(for: .body) }

    static func segmentedControlFont(isSelected: Bool) -> Font {
        controlFont.weight(isSelected ? .semibold : .regular)
    }
}

struct LungfishInspectorSegmentedButtonGrid<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let accessibilityLabel: String
    let label: (Option) -> String
    var minimumLabelScale: CGFloat = 1

    private var columnCount: Int { max(1, min(options.count, 2)) }

    /// The options in rows of `columnCount`, for an eager `Grid` whose
    /// every button is in the accessibility tree.
    private var rows: [[Option]] {
        stride(from: 0, to: options.count, by: columnCount).map { start in
            Array(options[start..<min(start + columnCount, options.count)])
        }
    }

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row, id: \.self) { option in
                        Button {
                            selection = option
                        } label: {
                            optionLabel(option)
                        }
                        .buttonStyle(.plain)
                        .help(label(option))
                        .accessibilityAddTraits(selection == option ? .isSelected : [])
                    }
                }
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private func optionLabel(_ option: Option) -> some View {
        let minimumHeight = max(
            28,
            ContentTypographyModel.shared.resolvedNSFont(for: .body).pointSize * 2
        )
        return fittedOptionLabel(option)
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .padding(.horizontal, 4)
            .background(background(for: option))
            .foregroundStyle(selection == option ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func fittedOptionLabel(_ option: Option) -> some View {
        let text = Text(label(option))
            .font(LungfishInspectorStyle.segmentedControlFont(isSelected: selection == option))
            .truncationMode(.tail)
        if minimumLabelScale < 1 {
            text
                .lineLimit(1)
                .minimumScaleFactor(minimumLabelScale)
                .allowsTightening(true)
        } else {
            text.lineLimit(2)
        }
    }

    @ViewBuilder
    private func background(for option: Option) -> some View {
        if selection == option {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlColor))
        }
    }
}
